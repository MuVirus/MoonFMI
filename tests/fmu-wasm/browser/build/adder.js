"use components";
import { log } from "./host_shim.mjs";

const emptyFunc = () => {};

let dv = new DataView(new ArrayBuffer());
const dataView = mem => dv.buffer === mem.buffer ? dv : dv = new DataView(mem.buffer);

function toUint32(val) {
  
  return val >>> 0;
}

const utf16Decoder = new TextDecoder('utf-16', { fatal: true, ignoreBOM: true });
const TEXT_DECODER_UTF8 = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });
const T_FLAG = 1 << 30;
const T_OWN = 2 ** 32;
const HANDLE_INDEX_SPACES = new Map();

function getHandleIndexSpace(key) {
  let space = HANDLE_INDEX_SPACES.get(key);
  if (space === undefined) {
    // One index space per component instance (Canonical ABI
    // `inst.handles`): resource handles, waitables, waitable sets and
    // error contexts share it. Freed indices are reused LIFO, as
    // `Table.add` does. Index 0 is never a handle.
    space = {
      next: 1,
      free: [],
      alloc() { return this.free.length > 0 ? this.free.pop() : this.next++; },
      release(idx) { this.free.push(idx); },
    };
    HANDLE_INDEX_SPACES.set(key, space);
  }
  return space;
}


function rscTableCreateOwn(table, rep) {
  // Reps are u32: one from a core function arrives as a signed i32
  rep >>>= 0;
  table._createdReps.add(rep);
  const handle = getHandleIndexSpace(table._componentIdx ?? table).alloc();
  table[handle << 1] = 0;
  table[(handle << 1) + 1] = rep + T_OWN;
  return handle;
}

const RESOURCE_SCOPE_TASKS = new Map();
const WebAssemblyRuntimeError = WebAssembly.RuntimeError;

function rscTableRemove(table, handle) {
  const scope = table[handle << 1];
  const val = table[(handle << 1) + 1];
  const own = val >= T_OWN;
  const rep = own ? val - T_OWN: val;
  // A borrowed entry can store zero without being freed.
  if (val === undefined || (scope & T_FLAG) !== 0) {
    throw new WebAssemblyRuntimeError(`unknown handle index ${handle}`);
  }
  if (own && scope !== 0) {
    throw new WebAssemblyRuntimeError('cannot remove owned resource while borrowed');
  }
  const borrowTask = own ? undefined : RESOURCE_SCOPE_TASKS.get(scope);
  // Mark the slot freed and give its index back to the instance's space.
  table[handle << 1] = T_FLAG;
  table[(handle << 1) + 1] = 0;
  getHandleIndexSpace(table._componentIdx ?? table).release(handle);
  borrowTask?.removeBorrowedHandle();
  return { rep, scope, own };
}

let RESOURCE_SCOPE_ID = 0;
const ASYNC_TASKS_BY_COMPONENT_IDX = new Map();
const ASYNC_CURRENT_COMPONENT_IDXS = [];
const CURRENT_TASK_META = {};

function getCurrentTask(componentIdx, taskID) {
  let usedGlobal = false;
  if (componentIdx === undefined || componentIdx === null) {
    throw new Error('missing component idx'); // TODO(fix)
    // componentIdx = ASYNC_CURRENT_COMPONENT_IDXS.at(-1);
    // usedGlobal = true;
  }
  
  const taskMetas = ASYNC_TASKS_BY_COMPONENT_IDX.get(componentIdx);
  if (taskMetas === undefined || taskMetas.length === 0) { return undefined; }
  
  if (taskID) {
    return taskMetas.find(meta => meta.task.id() === taskID);
  }
  
  // The task whose guest code is running is the one the metadata
  // wrappers record for the component (and restore when a suspended
  // stack resumes). The component's most recently created task may
  // be another one, e.g. a prepared callee that has not entered yet
  // while an earlier task of the component is suspended.
  const current = CURRENT_TASK_META[componentIdx];
  if (current && current.taskID !== undefined) {
    const currentMeta = taskMetas.find(meta => meta.task.id() === current.taskID);
    if (currentMeta) { return currentMeta; }
  }
  
  const taskMeta = taskMetas[taskMetas.length - 1];
  if (!taskMeta || !taskMeta.task) { return undefined; }
  
  return taskMeta;
}
const ASYNC_STATE = new Map();

function promiseWithResolvers() {
  if (Promise.withResolvers) {
    return Promise.withResolvers();
  } else {
    let resolve;
    let reject;
    const promise = new Promise((res, rej) => {
      resolve = res;
      reject = rej;
    });
    return { promise, resolve, reject };
  }
}

const _debugLog = (...args) => {
  if (!globalThis?.process?.env?.JCO_DEBUG) { return; }
  console.debug(...args);
};

class Waitable {
  #componentIdx;
  
  #pendingEventFn = null;
  
  #promise;
  #resolve;
  #reject;
  
  #waitableSet = null;
  
  #hasSyncWaiter = false;
  
  #idx = null; // to component-global waitables
  
  target;
  
  constructor(args) {
    const { componentIdx, target } = args;
    this.#componentIdx = componentIdx;
    this.target = args.target;
    this.#resetPromise();
  }
  
  componentIdx() { return this.#componentIdx; }
  isInSet() { return this.#waitableSet !== null; }
  
  idx() { return this.#idx; }
  setIdx(idx) {
    if (idx === 0) { throw new Error("waitable idx cannot be zero"); }
    this.#idx = idx;
  }
  
  setTarget(tgt) { this.target = tgt; }
  
  #resetPromise() {
    const { promise, resolve, reject } = promiseWithResolvers()
    this.#promise = promise;
    this.#resolve = resolve;
    this.#reject = reject;
  }
  
  resolve() { this.#resolve(); }
  reject(err) { this.#reject(err); }
  promise() { return this.#promise; }
  
  hasPendingEvent() {
    // _debugLog('[Waitable#hasPendingEvent()]', {
      //     componentIdx: this.#componentIdx,
      //     waitable: this,
      //     waitableSet: this.#waitableSet,
      //     hasPendingEvent: this.#pendingEventFn !== null,
      // });
      return this.#pendingEventFn !== null;
    }
    
    setPendingEvent(fn) {
      _debugLog('[Waitable#setPendingEvent()] args', {
        waitable: this,
        inSet: this.#waitableSet,
      });
      this.#pendingEventFn = fn;
    }
    
    getPendingEvent() {
      _debugLog('[Waitable#getPendingEvent()] args', {
        waitable: this,
        inSet: this.#waitableSet,
        hasPendingEvent: this.#pendingEventFn !== null,
      });
      if (this.#pendingEventFn === null) { return null; }
      const eventFn = this.#pendingEventFn;
      this.#pendingEventFn = null;
      const e = eventFn();
      this.#resetPromise();
      return e;
    }
    
    join(waitableSet) {
      _debugLog('[Waitable#join()] args', {
        waitable: this,
        waitableSet: waitableSet,
        isRemoval: waitableSet === null,
      });
      
      if (this.#waitableSet === undefined) {
        throw new TypeError('waitable set must be not be undefined');
      }
      
      if (this.#waitableSet) {
        this.#waitableSet.removeWaitable(this);
      }
      
      this.#waitableSet = waitableSet;
      
      if (waitableSet) {
        this.#waitableSet.addWaitable(this);
      }
    }
    
    drop() {
      _debugLog('[Waitable#drop()] args', {
        componentIdx: this.#componentIdx,
        waitable: this,
      });
      this.join(null);
    }
    
    async waitForPendingEvent(args) {
      const { cstate } = args;
      if (!cstate) { throw new TypeError('missing component state'); }
      
      if (this.#waitableSet !== null || this.#hasSyncWaiter) {
        throw new Error("waitable is already in a set/has a sync waiter");
      }
      this.#hasSyncWaiter = true;
      await cstate.waitUntil({
        cancellable: false,
        readyFn: () => this.hasPendingEvent(),
      });
      this.#hasSyncWaiter = false;
    }
    
  }
  const INSTANCE_FLAGS = new Map();
  const STORE_TRAP = { error: null };
  const STORE_ASYNC_STATE = { deadlockCheck: null, pendingHostOperations: 0 };
  
  function _checkForDeadlock() {
    if (STORE_ASYNC_STATE.deadlockCheck !== null || STORE_TRAP.error !== null) { return; }
    STORE_ASYNC_STATE.deadlockCheck = setTimeout(() => {
      STORE_ASYNC_STATE.deadlockCheck = null;
      if (STORE_TRAP.error !== null || STORE_ASYNC_STATE.pendingHostOperations > 0) { return; }
      
      const suspendedTasks = new Set();
      for (const state of ASYNC_STATE.values()) {
        if (state.hasPendingSchedulerWork()) {
          state.runTickLoop();
          return;
        }
        for (const meta of state.suspendedTaskMetas()) {
          suspendedTasks.add(meta.task);
        }
      }
      
      const unresolvedRoots = new Set();
      for (const task of suspendedTasks) {
        const root = task.getRootTask();
        if (!root.isResolvedState()) { unresolvedRoots.add(root); }
      }
      if (unresolvedRoots.size === 0) { return; }
      
      const err = new WebAssemblyRuntimeError('wasm trap: deadlock detected: event loop cannot make further progress');
      // Which tasks were waiting, and on whose behalf. The message stays
      // exactly what the Canonical ABI calls for, so this rides alongside
      // it: a deadlock reported from a real program is otherwise a bare
      // sentence, and the state that produced it is gone by the time
      // anyone reads the failure.
      err.deadlockDetail = {
        pendingHostOperations: STORE_ASYNC_STATE.pendingHostOperations,
        suspendedTasks: [...suspendedTasks].map((task) => ({
          taskID: task.id(),
          componentIdx: task.componentIdx(),
          state: task.taskState(),
          rootTaskID: task.getRootTask().id(),
        })),
        unresolvedRootTaskIDs: [...unresolvedRoots].map((root) => root.id()),
      };
      STORE_TRAP.error = err;
      for (const root of unresolvedRoots) {
        root.setErrored(err);
        root.reject(err);
      }
      for (const task of suspendedTasks) {
        if (!task.isResolvedState() && unresolvedRoots.has(task.getRootTask())) {
          task.setErrored(err);
          task.reject(err);
        }
      }
      // A deadlock is a trap of the whole store: no instance may be entered again.
      for (const state of ASYNC_STATE.values()) { state.markTrapped(err); }
      for (const state of ASYNC_STATE.values()) { state.abandonLockWaiters(); }
      for (const state of ASYNC_STATE.values()) { state.abandonAdmissionWaiters(); }
      for (const state of ASYNC_STATE.values()) { state.runTickLoop(); }
    }, 0);
  }
  
  const CORE_TRAP_MESSAGES = new Map([
  ['unreachable', "wasm trap: wasm `unreachable` instruction executed"],
  ['memory access out of bounds', "wasm trap: out of bounds memory access"],
  ['divide by zero', "wasm trap: integer divide by zero"],
  ['remainder by zero', "wasm trap: integer divide by zero"],
  ['divide result unrepresentable', "wasm trap: integer overflow"],
  ['float unrepresentable in integer range', "wasm trap: invalid conversion to integer"],
  ['table index is out of bounds', "wasm trap: undefined element: out of bounds table access"],
  ['function signature mismatch', "wasm trap: indirect call type mismatch"],
  ['call stack exhausted', "wasm trap: call stack exhausted"],
  ]);
  function _normalizeCoreTrap(err) {
    if (!(err instanceof WebAssemblyRuntimeError)) { return err; }
    const message = CORE_TRAP_MESSAGES.get(err.message);
    if (message !== undefined) { err.message = message; }
    return err;
  }
  
  class RepTable {
    // Sentinel marking a freed slot; the freelist link for a freed slot
    // lives in the odd cell. This keeps get()/contains()/remove() on freed
    // reps well-defined (previously they returned/corrupted freelist links).
    static FREE = Symbol('RepTable.free');
    
    #data = [0, null];
    #size = 0;
    #target;
    // An index space shared with the other handle kinds of a component
    // instance (see `getHandleIndexSpace`); without one, this table keeps
    // its own free list.
    #space = null;
    
    constructor(args) {
      this.target = args?.target;
      this.#space = args?.space ?? null;
    }
    
    data() { return this.#data; }
    
    insert(val) {
      if (this.#space !== null) {
        const rep = this.#space.alloc();
        this.#data[rep << 1] = val;
        this.#data[(rep << 1) + 1] = null;
        this.#size += 1;
        return rep;
      }
      _debugLog('[RepTable#insert()] args', { val, target: this.target });
      const freeIdx = this.#data[0];
      if (freeIdx === 0) {
        this.#data.push(val);
        this.#data.push(null);
        const rep = (this.#data.length >> 1) - 1;
        _debugLog('[RepTable#insert()] inserted', { val, target: this.target, rep });
        this.#size += 1;
        return rep;
      }
      const placementIdx = freeIdx << 1;
      if (this.#data[placementIdx] !== RepTable.FREE) {
        throw new Error('corrupt rep table freelist: head does not point at a freed slot');
      }
      this.#data[0] = this.#data[placementIdx + 1];
      this.#data[placementIdx] = val;
      this.#data[placementIdx + 1] = null;
      _debugLog('[RepTable#insert()] inserted', { val, target: this.target, rep: freeIdx });
      this.#size += 1;
      return freeIdx;
    }
    
    get(rep) {
      _debugLog('[RepTable#get()] args', { rep, target: this.target });
      if (rep === 0) { throw new WebAssemblyRuntimeError('invalid resource rep during get, (cannot be 0)'); }
      
      const baseIdx = rep << 1;
      const val = this.#data[baseIdx];
      if (val === RepTable.FREE) { return undefined; }
      return val;
    }
    
    contains(rep) {
      _debugLog('[RepTable#contains()] args', { rep, target: this.target });
      if (rep === 0) { throw new Error('invalid resource rep during contains, (cannot be 0)'); }
      
      const baseIdx = rep << 1;
      const val = this.#data[baseIdx];
      return val !== RepTable.FREE && !!val;
    }
    
    remove(rep) {
      _debugLog('[RepTable#remove()] args', { rep, target: this.target });
      if (rep === 0) { throw new Error('invalid resource rep during remove, (cannot be 0)'); }
      if (this.#space !== null) {
        const baseIdx = rep << 1;
        const val = this.#data[baseIdx];
        if (val === undefined || val === RepTable.FREE) {
          throw new WebAssemblyRuntimeError(`unknown handle index ${rep}`);
        }
        this.#data[baseIdx] = RepTable.FREE;
        this.#data[baseIdx + 1] = null;
        this.#size -= 1;
        this.#space.release(rep);
        return val;
      }
      if (this.#data.length === 2) { throw new Error('invalid'); }
      
      const baseIdx = rep << 1;
      if (baseIdx >= this.#data.length) {
        throw new Error(`invalid rep [${rep}] during remove, out of range`);
      }
      const val = this.#data[baseIdx];
      if (val === RepTable.FREE) {
        throw new WebAssemblyRuntimeError(`double removal of rep [${rep}] (already freed)`);
      }
      
      this.#data[baseIdx] = RepTable.FREE;
      this.#data[baseIdx + 1] = this.#data[0];
      this.#data[0] = rep;
      this.#size -= 1;
      
      return val;
    }
    
    size() { return this.#size; }
    
    clear() {
      _debugLog('[RepTable#clear()] args', { rep, target: this.target });
      this.#data = [0, null];
    }
  }
  
  class ComponentAsyncState {
    static EVENT_HANDLER_EVENTS = [ 'backpressure-change' ];
    
    static TickResult = {
      // no suspended tasks remain
      DONE: 'done',
      // a suspended task was resumed (more may be ready)
      RESUMED: 'resumed',
      // suspended tasks remain but none were ready
      IDLE: 'idle',
    };
    
    #componentIdx;
    #callingAsyncImport = false;
    #syncImportWait = promiseWithResolvers();
    #lockHolderTaskID = null;
    #lockWaiters = [];
    #admissionQueue = [];
    #lockHandoffScheduled = false;
    #pendingTaskStarts = 0;
    #parkedTasks = new Map();
    // Suspended threads, oldest first (a Map iterates in insertion
    // order, so no separate queue is kept for them).
    #suspendedThreadsByRef = new Map();
    #errored = null;
    #trapped = false;
    #trapError = null;
    #backpressure = 0;
    #backpressureWaiters = 0n;
    
    #handlerMap = new Map();
    #nextHandlerID = 0n;
    
    #tickLoop = null;
    #tickLoopInterval = null;
    
    #onExclusiveReleaseHandlers = [];
    
    #mayLeave = true;
    
    handles;
    subtasks;
    threads;
    
    constructor(args) {
      this.#componentIdx = args.componentIdx;
      this.handles = new RepTable({
        target: `component [${this.#componentIdx}] handles (waitable objects)`,
        space: getHandleIndexSpace(this.#componentIdx),
      });
      this.subtasks = new RepTable({ target: `component [${this.#componentIdx}] subtasks` });
      this.threads = new RepTable({ target: `component [${this.#componentIdx}] threads` });
    };
    
    componentIdx() { return this.#componentIdx; }
    
    get mayLeave() {
      const flags = INSTANCE_FLAGS.get(this.#componentIdx);
      return flags === undefined ? this.#mayLeave : flags.value === 1;
    }
    set mayLeave(value) {
      if (typeof value !== 'boolean') { throw new TypeError('mayLeave must be a boolean'); }
      this.#mayLeave = value;
      const flags = INSTANCE_FLAGS.get(this.#componentIdx);
      if (flags !== undefined) { flags.value = value ? 1 : 0; }
    }
    
    errored() { return this.#errored !== null; }
    setErrored(err) {
      _debugLog('[ComponentAsyncState#setErrored()] component errored', { err, componentIdx: this.#componentIdx });
      if (this.#errored) { return; }
      if (!err) {
        err = new Error('error elswehere (see other component instance error)')
        err.componentIdx = this.#componentIdx;
      }
      this.#errored = err;
    }
    
    markTrapped(err) {
      if (!(err instanceof WebAssemblyRuntimeError)) {
        return false;
      }
      err = _normalizeCoreTrap(err);
      this.#trapped = true;
      if (this.#trapError === null) { this.#trapError = err; }
      _debugLog('[ComponentAsyncState#markTrapped()] component trapped', { err, componentIdx: this.#componentIdx });
      if (STORE_TRAP.error === null) { STORE_TRAP.error = err; }
      return true;
    }
    
    isTrapped() { return this.#trapped; }
    // For work that was already under way or queued when the instance
    // trapped: it fails with that trap (nothing runs after a trap).
    throwIfInterrupted() {
      if (this.#trapped) {
        throw this.#trapError ?? new WebAssemblyRuntimeError("wasm trap: cannot enter component instance");
      }
    }
    throwIfTrapped() {
      if (this.#trapped) {
        throw new WebAssemblyRuntimeError("wasm trap: cannot enter component instance");
      }
    }
    
    callingSyncImport(val) {
      if (val === undefined) { return this.#callingAsyncImport; }
      if (typeof val !== 'boolean') { throw new TypeError('invalid setting for async import'); }
      const prev = this.#callingAsyncImport;
      this.#callingAsyncImport = val;
      if (prev === true && this.#callingAsyncImport === false) {
        this.#notifySyncImportEnd();
      }
    }
    
    #notifySyncImportEnd() {
      const existing = this.#syncImportWait;
      this.#syncImportWait = promiseWithResolvers();
      existing.resolve();
    }
    
    async waitForSyncImportCallEnd() {
      await this.#syncImportWait.promise;
    }
    
    setBackpressure(v) {
      this.#backpressure = v;
      return this.#backpressure
    }
    getBackpressure() { return this.#backpressure; }
    
    incrementBackpressure() {
      const current = this.#backpressure;
      if (current < 0 || current > 2**16) {
        throw new Error(`invalid current backpressure value [${current}]`);
      }
      const newValue = this.getBackpressure() + 1;
      if (newValue >= 2**16) {
        throw new Error(`invalid new backpressure value [${newValue}], overflow`);
      }
      return this.setBackpressure(newValue);
    }
    
    decrementBackpressure() {
      const current = this.#backpressure;
      if (current < 0 || current > 2**16) {
        throw new Error(`invalid current backpressure value [${current}]`);
      }
      // Canonical ABI `backpressure.dec`: trap if the counter would go
      // below zero.
      const newValue = current - 1;
      if (newValue < 0) {
        throw new WebAssemblyRuntimeError('backpressure counter underflow');
      }
      return this.setBackpressure(newValue);
    }
    hasBackpressure() { return this.#backpressure > 0; }
    
    waitForBackpressure() {
      let backpressureCleared = false;
      const cstate = this;
      cstate.addBackpressureWaiter();
      const handlerID = this.registerHandler({
        event: 'backpressure-change',
        fn: (bp) => {
          if (bp === 0) {
            cstate.removeHandler(handlerID);
            backpressureCleared = true;
          }
        }
      });
      return new Promise((resolve) => {
        const interval = setInterval(() => {
          if (backpressureCleared) { return; }
          clearInterval(interval);
          cstate.removeBackpressureWaiter();
          resolve(null);
        }, 0);
      });
    }
    
    registerHandler(args) {
      const { event, fn } = args;
      if (!event) { throw new Error("missing handler event"); }
      if (!fn) { throw new Error("missing handler fn"); }
      
      if (!ComponentAsyncState.EVENT_HANDLER_EVENTS.includes(event)) {
        throw new Error(`unrecognized event handler [${event}]`);
      }
      
      const handlerID = this.#nextHandlerID++;
      let handlers = this.#handlerMap.get(event);
      if (!handlers) {
        handlers = [];
        this.#handlerMap.set(event, handlers)
      }
      
      handlers.push({ id: handlerID, fn, event });
      return handlerID;
    }
    
    removeHandler(args) {
      const { event, handlerID } = args;
      const registeredHandlers = this.#handlerMap.get(event);
      if (!registeredHandlers) { return; }
      const found = registeredHandlers.find(h => h.id === handlerID);
      if (!found) { return; }
      this.#handlerMap.set(event, this.#handlerMap.get(event).filter(h => h.id !== handlerID));
    }
    
    getBackpressureWaiters() { return this.#backpressureWaiters; }
    addBackpressureWaiter() { this.#backpressureWaiters++; }
    removeBackpressureWaiter() {
      this.#backpressureWaiters--;
      if (this.#backpressureWaiters < 0) {
        throw new Error("unexepctedly negative number of backpressure waiters");
      }
    }
    
    // The per-slice mutual-exclusion lock for guest execution in this
    // component instance. Guest slices (callback invocations and
    // sync-lifted bodies) must be atomic per component even across the
    // JSPI suspensions jco introduces for host imports: wit-bindgen's
    // executors publish per-task state in single linear-memory cells
    // (the wasip3-task pointer, context-local storage discipline) that
    // an interleaved slice of the same component corrupts
    //
    // The lock is *owned*: acquisition records the holder task and
    // release is a no-op for anyone else, so a task exiting can no
    // longer drop a hold it does not own (blind acquire/release-any
    // was the previous discipline). Contended acquisition queues
    // FIFO; release hands the lock to the next waiter directly.
    isExclusivelyLocked() { return this.#lockHolderTaskID !== null; }
    exclusivelyLockedBy(taskID) { return this.#lockHolderTaskID === taskID; }
    
    exclusiveLock(taskID) {
      _debugLog('[ComponentAsyncState#exclusiveLock()]', {
        holder: this.#lockHolderTaskID,
        requester: taskID,
        componentIdx: this.#componentIdx,
      });
      if (taskID === undefined || taskID === null) {
        throw new Error('exclusive lock requires the acquiring task id');
      }
      if (this.#lockHolderTaskID !== null) {
        throw new Error(`component [${this.#componentIdx}] exclusive lock held by task [${this.#lockHolderTaskID}], requested by [${taskID}]`);
      }
      this.#lockHolderTaskID = taskID;
    }
    
    // Awaitable acquisition: takes the lock immediately when free,
    // otherwise queues FIFO behind the current holder and earlier
    // waiters. The resolved promise implies ownership.
    acquireExclusiveLock(taskID) {
      if (taskID === undefined || taskID === null) {
        throw new Error('exclusive lock requires the acquiring task id');
      }
      if (this.#lockHolderTaskID === null) {
        this.#lockHolderTaskID = taskID;
        _debugLog('[ComponentAsyncState#acquireExclusiveLock()] acquired', {
          holder: taskID,
          componentIdx: this.#componentIdx,
        });
        return;
      }
      if (this.#lockHolderTaskID === taskID) {
        throw new Error(`task [${taskID}] already holds the lock for component [${this.#componentIdx}]`);
      }
      _debugLog('[ComponentAsyncState#acquireExclusiveLock()] waiting', {
        holder: this.#lockHolderTaskID,
        requester: taskID,
        componentIdx: this.#componentIdx,
        queued: this.#lockWaiters.length,
      });
      return new Promise((resolve) => {
        this.#lockWaiters.push({ taskID, resolve });
      });
    }
    
    // Release every queued entry without granting ownership, so that
    // calls waiting to enter a trapped store fail instead of hanging.
    // FIFO admission of tasks entering this instance (Canonical ABI
    // `inst.pending`): a task enters only after every task that asked to
    // enter before it has entered or given up, so calls enter in the order
    // they were made, whatever each waits for on the way.
    takeAdmissionTicket(taskID) {
      const ticket = { taskID, ...promiseWithResolvers() };
      this.#admissionQueue.push(ticket);
      return ticket;
    }
    hasPendingAdmissions() { return this.#admissionQueue.length > 0; }
    waitForAdmissionTurn(ticket) {
      if (this.#admissionQueue[0] === ticket) { return; }
      return ticket.promise;
    }
    releaseAdmissionTicket(ticket) {
      const idx = this.#admissionQueue.indexOf(ticket);
      if (idx === -1) { return; }
      this.#admissionQueue.splice(idx, 1);
      if (idx === 0 && this.#admissionQueue.length > 0) {
        this.#admissionQueue[0].resolve();
      }
    }
    // Release every queued entry (the instance trapped): each then fails
    // in `enter()` instead of waiting forever.
    abandonAdmissionWaiters() {
      const tickets = this.#admissionQueue.splice(0);
      for (const ticket of tickets) { ticket.resolve(); }
    }
    
    abandonLockWaiters() {
      const waiters = this.#lockWaiters.splice(0);
      for (const waiter of waiters) { waiter.resolve(); }
    }
    
    cancelExclusiveLockWaiter(taskID) {
      const idx = this.#lockWaiters.findIndex(waiter => waiter.taskID === taskID);
      if (idx === -1) { return false; }
      const [waiter] = this.#lockWaiters.splice(idx, 1);
      // Release the awaiting `enter()` continuation without granting
      // ownership. It observes the task's resolved cancellation state
      // before attempting to execute guest code.
      waiter.resolve();
      return true;
    }
    
    exclusiveRelease(taskID) {
      _debugLog('[ComponentAsyncState#exclusiveRelease()] args', {
        holder: this.#lockHolderTaskID,
        releaser: taskID,
        componentIdx: this.#componentIdx,
      });
      if (this.#lockHolderTaskID !== taskID) {
        // Ownerless releases were the historical behavior; a foreign
        // release now leaves the hold intact
        _debugLog('[ComponentAsyncState#exclusiveRelease()] ignoring foreign release', {
          holder: this.#lockHolderTaskID,
          releaser: taskID,
          componentIdx: this.#componentIdx,
        });
        return false;
      }
      
      // Make the release observable before handing the lock to the next
      // asynchronous guest slice.
      //
      // Release handlers may expose a lifted value whose consumer immediately
      // performs a synchronous call on the same component; that call must run
      // while the instance is genuinely unlocked, not via enterSync's
      // lock-free fallback code.
      this.#lockHolderTaskID = null;
      
      this.#onExclusiveReleaseHandlers = this.#onExclusiveReleaseHandlers.filter(v => !!v);
      for (const [idx, f] of this.#onExclusiveReleaseHandlers.entries()) {
        try {
          this.#onExclusiveReleaseHandlers[idx] = null;
          f();
        } catch (err) {
          _debugLog("error while executing handler for next exclusive release", err);
          throw err;
        }
      }
      this.#scheduleLockHandoff();
      return true;
    }
    
    #scheduleLockHandoff() {
      if (this.#lockHandoffScheduled || this.#lockWaiters.length === 0) { return; }
      this.#lockHandoffScheduled = true;
      queueMicrotask(() => {
        this.#lockHandoffScheduled = false;
        // A synchronous call triggered by a release handler gets the
        // first opportunity to use the unlocked component. Its own
        // release schedules the next handoff; re-queueing one here
        // would spin the microtask queue for as long as the holder
        // stays blocked (e.g. in a synchronous wait), starving every
        // timer, the deadlock detector included.
        if (this.#lockHolderTaskID !== null) { return; }
        const next = this.#lockWaiters.shift();
        if (!next) { return; }
        this.#lockHolderTaskID = next.taskID;
        next.resolve();
      });
    }
    
    onNextExclusiveRelease(fn) {
      _debugLog('[ComponentAsyncState#()onNextExclusiveRelease] registering');
      this.#onExclusiveReleaseHandlers.push(fn);
    }
    
    async waitForExclusiveRelease() {
      while (this.isExclusivelyLocked()) {
        await new Promise(resolve => this.onNextExclusiveRelease(resolve));
      }
    }
    
    // Callback drivers refer to the implicit thread by task ID.
    // Stackful built-ins pass their current thread directly.
    #getSuspendedTaskMeta(taskID) {
      const metas = [...this.#suspendedThreadsByRef.values()].filter(meta => meta.thread.taskID() === taskID);
      return metas.find(meta => meta.cancellable && this.suspendedThreadReady(meta.thread)) ?? metas[0];
    }
    
    suspendTask(args) {
      const { task, ...opts } = args;
      task.endFirstSlice();
      return this.suspendThread({ thread: task.defaultThread(), ...opts });
    }
    
    resumeTaskByID(taskID) {
      const meta = this.#getSuspendedTaskMeta(taskID);
      return meta ? this.resumeThread(meta.thread) : false;
    }
    
    suspendedTaskReady(taskID) {
      const meta = this.#getSuspendedTaskMeta(taskID);
      return meta ? this.suspendedThreadReady(meta.thread) : false;
    }
    
    suspendedTaskCancellable(taskID) {
      return !!this.#getSuspendedTaskMeta(taskID)?.cancellable;
    }
    
    isTaskSuspended(taskID) {
      return !!this.#getSuspendedTaskMeta(taskID);
    }
    
    *suspendedTaskMetas() {
      for (const meta of this.#suspendedThreadsByRef.values()) {
        yield { ...meta, task: meta.thread.task() };
      }
    }
    
    #removeSuspendedThreadMeta(thread) {
      const meta = this.#suspendedThreadsByRef.get(thread);
      this.#suspendedThreadsByRef.delete(thread);
      return meta;
    }
    
    suspendThread(args) {
      const { thread, readyFn, cancellable, onResume, suspended = false } = args;
      _debugLog('[ComponentAsyncState#suspendThread()]', {
        threadID: thread.id(),
        taskID: thread.taskID(),
        componentIdx: this.#componentIdx,
      });
      
      if (thread.componentIdx() !== this.#componentIdx) {
        throw new Error('assert: thread component idx should match async state');
      }
      if (this.#suspendedThreadsByRef.has(thread)) {
        throw new Error(`thread [${thread.id()}] already suspended`);
      }
      
      let promise;
      let resume;
      if (onResume) {
        resume = () => onResume(!thread.isCancelled() && !thread.isRejected() && !this.isTrapped());
      } else {
        const resolvers = promiseWithResolvers();
        promise = resolvers.promise;
        resume = () => resolvers.resolve(!thread.isCancelled() && !thread.isRejected() && !this.isTrapped());
      }
      this.#suspendedThreadsByRef.set(thread, { thread, cancellable, readyFn, resume, suspended });
      
      thread.notifyProgress();
      
      this.runTickLoop();
      _checkForDeadlock();
      
      return promise;
    }
    
    resumeThread(thread) {
      const meta = this.#removeSuspendedThreadMeta(thread);
      if (!meta) { return false; }
      meta.resume();
      return true;
    }
    
    markThreadReady(thread) {
      const meta = this.#suspendedThreadsByRef.get(thread);
      if (!meta || !meta.suspended) { return false; }
      meta.suspended = false;
      meta.readyFn = () => true;
      this.runTickLoop();
      return true;
    }
    
    isThreadSuspended(thread) {
      return this.#suspendedThreadsByRef.get(thread)?.suspended ?? false;
    }
    
    isThreadReady(thread) {
      const meta = this.#suspendedThreadsByRef.get(thread);
      return !!meta && !meta.suspended && (meta.thread.isRejected() || meta.readyFn());
    }
    
    suspendedThreadReady(thread) {
      const meta = this.#suspendedThreadsByRef.get(thread);
      if (!meta) { return false; }
      if (!meta.readyFn) {
        throw new Error(`suspended thread [${thread.id()}] is missing a readiness function`);
      }
      if (this.isTrapped() || meta.thread.isRejected()) { return true; }
      if (!meta.readyFn()) { return false; }
      const task = meta.thread.task();
      return !task.needsExclusiveLock()
      || !this.isExclusivelyLocked()
      || this.exclusivelyLockedBy(task.id());
    }
    
    addPendingTaskStart() { this.#pendingTaskStarts++; }
    removePendingTaskStart() { this.#pendingTaskStarts--; }
    
    hasPendingSchedulerWork() {
      if (this.#pendingTaskStarts > 0) { return true; }
      if (this.#lockHandoffScheduled) { return true; }
      for (const meta of this.#suspendedThreadsByRef.values()) {
        if (this.suspendedThreadReady(meta.thread)) { return true; }
      }
      return false;
    }
    
    async runTickLoop() {
      if (this.#tickLoop !== null) { return; }
      this.#tickLoop = 1;
      setTimeout(async () => {
        let result = this.tick();
        while (result !== ComponentAsyncState.TickResult.DONE) {
          if (result === ComponentAsyncState.TickResult.IDLE) {
            _checkForDeadlock();
          }
          // After resuming a task, re-tick as soon as the resumed
          // slice's microtask continuations have drained (timeout 0)
          // so queued sibling resumptions aren't charged the idle
          // polling interval; otherwise poll at the idle cadence.
          const delay = result === ComponentAsyncState.TickResult.RESUMED ? 0 : 10;
          await new Promise((resolve) => setTimeout(resolve, delay));
          result = this.tick();
        }
        this.#tickLoop = null;
      }, 10);
    }
    
    tick() {
      // (resuming returns immediately below, so the map is never
      // mutated while this loop is still iterating it)
      for (const [thread, meta] of this.#suspendedThreadsByRef) {
        if (!meta || !meta.readyFn) {
          throw new Error(`missing/invalid thread meta despite thread [${thread.id()}] being present`);
        }
        
        if (this.isTrapped() || meta.thread.isRejected()) {
          _debugLog('[ComponentAsyncState#tick()] detected thread rejection, leaving early', { meta });
          this.resumeThread(thread);
          return ComponentAsyncState.TickResult.RESUMED;
        }
        
        if (!this.suspendedThreadReady(thread)) { continue; }
        
        _debugLog('[ComponentAsyncState#tick()] resuming thread via tick', {
          threadID: thread.id(),
          componentIdx: this.#componentIdx,
        });
        this.resumeThread(thread);
        
        // Resume only one thread per tick so its current-thread
        // register window closes before another continuation runs.
        return ComponentAsyncState.TickResult.RESUMED;
      }
      
      const idle = this.#suspendedThreadsByRef.size > 0;
      return idle
      ? ComponentAsyncState.TickResult.IDLE
      : ComponentAsyncState.TickResult.DONE;
    }
    
    createWaitable(args) {
      return new Waitable({ target: args?.target, });
    }
  }
  
  function getOrCreateAsyncState(componentIdx, init) {
    if (!ASYNC_STATE.has(componentIdx)) {
      const newState = new ComponentAsyncState({ componentIdx });
      ASYNC_STATE.set(componentIdx, newState);
    }
    return ASYNC_STATE.get(componentIdx);
  }
  
  function getCurrentThread(componentIdx, threadID, taskID) {
    // Host (-1) tasks have no component instance, and so no thread table.
    if (componentIdx === -1) { return undefined; }
    if (threadID === undefined || threadID === null || threadID === 0) { return undefined; }
    
    const cstate = getOrCreateAsyncState(componentIdx);
    const thread = cstate.threads.get(threadID);
    if (!thread) { return undefined; }
    
    // Thread indices are recycled once a thread exits (the thread table
    // reuses freed slots) but task ids never are. A register that still
    // names an exited thread, e.g. during a post-return that runs after
    // its task exited, must not resolve to whichever newer thread took
    // the slot; callers then fall back as for a missing thread.
    if (taskID !== undefined && thread.taskID() !== taskID) { return undefined; }
    
    return { id: threadID, componentIdx, taskID: thread.taskID(), task: thread.task(), thread };
  }
  const ASYNC_CURRENT_TASK_IDS = [];
  
  function clearCurrentThread(componentIdx, taskID, opts = {}) {
    _debugLog('[clearCurrentThread()] args', { componentIdx, taskID });
    
    if (componentIdx === undefined || componentIdx === null) {
      throw new Error('missing/invalid component instance index while ending current task');
    }
    
    const tasks = ASYNC_TASKS_BY_COMPONENT_IDX.get(componentIdx);
    if (!tasks || !Array.isArray(tasks)) {
      throw new Error('missing/invalid tasks for component instance while ending task');
    }
    if (tasks.length == 0) {
      throw new Error(`no current tasks for component instance [${componentIdx}] while ending task`);
    }
    
    const taskIdx = taskID === undefined
    ? tasks.length - 1
    : tasks.findIndex(meta => meta.id === taskID);
    if (taskIdx === -1) { return; }
    
    const taskMeta = tasks[taskIdx];
    if (!opts.preserveTask) {
      tasks.splice(taskIdx, 1);
    }
    const globalTaskIdx = ASYNC_CURRENT_TASK_IDS.lastIndexOf(taskMeta.id);
    if (globalTaskIdx !== -1) {
      ASYNC_CURRENT_TASK_IDS.splice(globalTaskIdx, 1);
      ASYNC_CURRENT_COMPONENT_IDXS.splice(globalTaskIdx, 1);
    }
    return taskMeta.task;
  }
  const symbolDispose = Symbol.dispose || Symbol.for('dispose');
  
  // Dispose of a host-provided value that a guest discarded, using `disposeFn`
  // if provided, otherwise the value's `Symbol.asyncDispose` or `Symbol.dispose`.
  //
  // Disposal runs in a microtask, so host code never runs inside a canonical
  // built-in (where it could re-enter the component), and errors are reported
  // rather than surfaced to the guest.
  function _disposeHostValue(value, disposeFn) {
    if (!disposeFn) {
      if (value === null || (typeof value !== 'object' && typeof value !== 'function')) { return; }
      if (typeof Symbol.asyncDispose === 'symbol' && typeof value[Symbol.asyncDispose] === 'function') {
        disposeFn = value[Symbol.asyncDispose];
      } else if (typeof value[symbolDispose] === 'function') {
        disposeFn = value[symbolDispose];
      } else {
        return;
      }
    }
    const reportErr = (err) => console.error('[jco] error while disposing discarded host value', err);
    queueMicrotask(() => {
      try {
        const res = disposeFn.call(value);
        if (res && typeof res.then === 'function') { res.then(undefined, reportErr); }
      } catch (err) {
        reportErr(err);
      }
    });
  }
  
  const GLOBAL_COMPONENT_MEMORY_MAP = new Map();
  
  function lookupMemoriesForComponent(args) {
    const { componentIdx } = args ?? {};
    if (args.componentIdx === undefined) { throw new TypeError("missing component idx"); }
    
    const metas = GLOBAL_COMPONENT_MEMORY_MAP.get(componentIdx);
    if (!metas) { return []; }
    
    if (args.memoryIdx === undefined) {
      return Object.values(metas);
    }
    
    const meta = metas[args.memoryIdx];
    return meta?.memory;
  }
  
  class AsyncSubtask {
    static _ID = 0n;
    
    static State = {
      STARTING: 0,
      STARTED: 1,
      RETURNED: 2,
      CANCELLED_BEFORE_STARTED: 3,
      CANCELLED_BEFORE_RETURNED: 4,
    };
    
    #id;
    #state = AsyncSubtask.State.STARTING;
    #componentIdx;
    
    #parentTask;
    #childTask = null;
    
    #dropped = false;
    #cancelRequested = false;
    
    #memoryIdx = null;
    #lenders = null;
    
    #waitable = null;
    
    #callbackFn = null;
    #callbackFnName = null;
    
    #postReturnFn = null;
    #onProgressFn = null;
    #pendingEventFn = null;
    
    #callMetadata = {};
    
    #resolved = false;
    
    #onResolveHandlers = [];
    #onStartHandlers = [];
    
    #result = null;
    #resultSet = false;
    
    // Pending value returned by a host implementation of this (async import)
    // subtask, held so it can be disposed if the guest discards the call
    #hostPendingResult = null;
    
    fnName;
    target;
    isAsync;
    isManualAsync;
    // One execution slice awaited by the conditional cancel trampoline.
    cancelProgress = null;
    
    constructor(args) {
      if (typeof args.componentIdx !== 'number') {
        throw new Error('invalid componentIdx for subtask creation');
      }
      this.#componentIdx = args.componentIdx;
      
      this.#id = ++AsyncSubtask._ID;
      this.fnName = args.fnName;
      
      if (!args.parentTask) { throw new Error('missing parent task during subtask creation'); }
      this.#parentTask = args.parentTask;
      
      if (args.childTask) { this.#childTask = args.childTask; }
      
      if (args.memoryIdx) { this.#memoryIdx = args.memoryIdx; }
      
      if (!args.waitable) { throw new Error("missing/invalid waitable"); }
      this.#waitable = args.waitable;
      
      if (args.callMetadata) { this.#callMetadata = args.callMetadata; }
      
      this.#lenders = [];
      this.target = args.target;
      this.isAsync = args.isAsync;
      this.isManualAsync = args.isManualAsync;
    }
    
    id() { return this.#id; }
    parentTaskID() { return this.#parentTask?.id(); }
    childTaskID() { return this.#childTask?.id(); }
    state() { return this.#state; }
    
    waitable() { return this.#waitable; }
    waitableRep() { return this.#waitable.idx(); }
    // The handle index is allocated only when the guest gets to see the
    // subtask (an async lower that did not complete at once), and after the
    // lifted arguments have freed theirs (Canonical ABI `canon_lower`).
    ensureHandle() {
      const existing = this.#waitable.idx();
      if (existing !== null && existing !== undefined) { return existing; }
      const idx = this.#getComponentState().handles.insert(this);
      this.#waitable.setIdx(idx);
      this.#waitable.setTarget(`waitable for subtask (waitable id [${idx}], subtask internal ID [${this.id()}])`);
      return idx;
    }
    
    join() { return this.#waitable.join(...arguments); }
    getPendingEvent() { return this.#waitable.getPendingEvent(...arguments); }
    hasPendingEvent() { return this.#waitable.hasPendingEvent(...arguments); }
    setPendingEvent() { return this.#waitable.setPendingEvent(...arguments); }
    
    setTarget(tgt) { this.target = tgt; }
    
    getResult() {
      if (!this.#resultSet) { throw new Error("subtask result has not been set") }
      return this.#result;
    }
    setResult(v) {
      if (this.#resultSet) { throw new Error("subtask result has already been set"); }
      this.#result = v;
      this.#resultSet = true;
    }
    
    componentIdx() { return this.#componentIdx; }
    
    setChildTask(t) {
      if (!t) { throw new Error('cannot set missing/invalid child task on subtask'); }
      if (this.#childTask) { throw new Error('child task is already set on subtask'); }
      if (this.#parentTask === t) { throw new Error("parent cannot be child"); }
      this.#childTask = t;
    }
    getChildTask(t) { return this.#childTask; }
    
    getParentTask() { return this.#parentTask; }
    
    setCallbackFn(f, name) {
      if (!f) { return; }
      if (this.#callbackFn) { throw new Error('callback fn can only be set once'); }
      this.#callbackFn = f;
      this.#callbackFnName = name;
    }
    
    getCallbackFnName() {
      if (!this.#callbackFn) { return undefined; }
      return this.#callbackFn.name;
    }
    
    setPostReturnFn(f) {
      if (!f) { return; }
      if (this.#postReturnFn) { throw new Error('postReturn fn can only be set once'); }
      this.#postReturnFn = f;
    }
    
    setOnProgressFn(f) {
      if (this.#onProgressFn) { throw new Error('on progress fn can only be set once'); }
      this.#onProgressFn = f;
    }
    
    isNotStarted() {
      return this.#state == AsyncSubtask.State.STARTING;
    }
    
    cancellationRequested() { return this.#cancelRequested; }
    
    // Request cooperative cancellation of this subtask, on behalf of the
    // supertask (i.e. `canon subtask.cancel`).
    //
    // If the callee is another guest task, the request is delivered to it and
    // the callee confirms via `task.cancel` (or still resolves via `task.return`).
    //
    // If the callee is a host function, the pending call is treated as
    // immediately cancelled -- consistent with hosts being expected to resolve
    // cancellation promptly -- and any later host resolution is discarded
    // (see `AsyncTask#onResolve`). The host is notified of the discard by
    // disposing the pending value it returned (see `setHostPendingResult`).
    requestCancellation() {
      _debugLog('[AsyncSubtask#requestCancellation()] args', {
        componentIdx: this.#componentIdx,
        subtaskID: this.#id,
        state: this.#state,
        childTaskID: this.childTaskID(),
        fnName: this.fnName,
      });
      if (this.#cancelRequested) {
        throw new Error('cancellation has already been requested for this subtask');
      }
      this.#cancelRequested = true;
      
      if (this.#resolved) { return; }
      
      if (this.#childTask) {
        this.#childTask.requestCancellation();
        return;
      }
      
      this.onResolve(null);
      this.#disposeHostPendingResult();
    }
    
    // Record the value returned by the host implementation of this subtask.
    //
    // Host imports may return a thenable that implements `Symbol.asyncDispose`
    // or `Symbol.dispose`. If the guest cancels the call before its result is
    // delivered, the result is discarded and the thenable is disposed so the
    // host can stop pending work and release anything it produced.
    setHostPendingResult(v) {
      if (v === null || (typeof v !== 'object' && typeof v !== 'function') || typeof v.then !== 'function') {
        return;
      }
      this.#hostPendingResult = v;
      if (this.#resolved && this.#state !== AsyncSubtask.State.RETURNED) {
        this.#disposeHostPendingResult();
      }
    }
    
    #disposeHostPendingResult() {
      const pending = this.#hostPendingResult;
      if (!pending) { return; }
      this.#hostPendingResult = null;
      _disposeHostValue(pending);
    }
    
    registerOnStartHandler(f) {
      this.#onStartHandlers.push(f);
    }
    
    onStart(args) {
      _debugLog('[AsyncSubtask#onStart()] args', {
        componentIdx: this.#componentIdx,
        subtaskID: this.#id,
        parentTaskID: this.parentTaskID(),
        fnName: this.fnName,
        args,
      });
      
      if (this.#onProgressFn) { this.#onProgressFn(); }
      
      // Starting a nested operation is a task execution boundary.
      // In particular, a cancellation handler may synchronously
      // enter an import which then suspends in the host.  Wake a
      // supertask that is driving one cancellation slice so an
      // async `subtask.cancel` can report BLOCKED without waiting
      // for that nested operation to finish.
      this.#parentTask.notifyProgress();
      
      this.#state = AsyncSubtask.State.STARTED;
      
      let result;
      
      // If we have been provided a helper start function as a result of
      // component fusion performed by wasmtime tooling, then we can call that helper and lifts/lowers will
      // be performed for us.
      //
      // See also documentation on `HostIntrinsic::PrepareCall`
      //
      if (this.#callMetadata.startFn) {
        result = this.#callMetadata.startFn.apply(null, args?.startFnParams ?? []);
      }
      
      return result;
    }
    
    
    registerOnResolveHandler(f) {
      this.#onResolveHandlers.push(f);
    }
    
    reject(subtaskErr) {
      if (this.#resolved) { return; }
      
      if (this.#onProgressFn) { this.#onProgressFn(); }
      
      if (this.#state === AsyncSubtask.State.STARTING) {
        this.#state = AsyncSubtask.State.CANCELLED_BEFORE_STARTED;
      } else if (this.#state === AsyncSubtask.State.STARTED) {
        this.#state = AsyncSubtask.State.CANCELLED_BEFORE_RETURNED;
      } else {
        throw new Error('cannot reject a completed subtask');
      }
      
      this.#resolved = true;
      this.#hostPendingResult = null;
      this.#parentTask.removeSubtask(this);
      this.#parentTask.reject(subtaskErr);
    }
    
    onResolve(subtaskValue) {
      _debugLog('[AsyncSubtask#onResolve()] args', {
        componentIdx: this.#componentIdx,
        subtaskID: this.#id,
        isAsync: this.isAsync,
        childTaskID: this.childTaskID(),
        parentTaskID: this.parentTaskID(),
        parentTaskFnName: this.#parentTask?.entryFnName(),
        fnName: this.fnName,
      });
      
      if (this.#resolved) {
        throw new Error('subtask has already been resolved');
      }
      
      if (this.#onProgressFn) { this.#onProgressFn(); }
      
      if (subtaskValue === null && this.#cancelRequested) {
        if (this.#state === AsyncSubtask.State.STARTING) {
          this.#state = AsyncSubtask.State.CANCELLED_BEFORE_STARTED;
        } else {
          if (this.#state !== AsyncSubtask.State.STARTED) {
            throw new Error('resolved subtask must have been started before cancellation');
          }
          this.#state = AsyncSubtask.State.CANCELLED_BEFORE_RETURNED;
        }
      } else {
        if (this.#state !== AsyncSubtask.State.STARTED) {
          throw new Error('resolved subtask must have been started before completion');
        }
        this.#state = AsyncSubtask.State.RETURNED;
        // The host result is delivered to the guest, so it is no longer ours to dispose
        this.#hostPendingResult = null;
      }
      
      this.setResult(subtaskValue);
      
      for (const f of this.#onResolveHandlers) {
        try {
          f(subtaskValue);
        } catch (err) {
          console.error("error during subtask resolve handler", err);
          throw err;
        }
      }
      
      const callMetadata = this.getCallMetadata();
      
      // TODO(fix): we should be able to easily have the caller's meomry
      // to lower into here, but it's not present in PrepareCall
      const memory = callMetadata.memory ?? this.#parentTask?.getReturnMemory() ?? lookupMemoriesForComponent({ componentIdx: this.#parentTask?.componentIdx() })[0];
      // NOTE: cancelled resolutions carry no value, so nothing is lowered
      const returned = this.#state === AsyncSubtask.State.RETURNED;
      if (returned && callMetadata && !callMetadata.returnFn && (this.isAsync || callMetadata.funcTypeIsAsync) && callMetadata.resultPtr && memory) {
        const { resultPtr, realloc } = callMetadata;
        const lowers = callMetadata.lowers; // may have been updated in task.return of the child
        if (lowers && lowers.length > 0) {
          lowers[0]({
            componentIdx: this.#componentIdx,
            memory,
            realloc,
            vals: [subtaskValue],
            storagePtr: resultPtr,
            stringEncoding: callMetadata.stringEncoding,
          });
        }
      }
      
      this.#resolved = true;
      this.#parentTask.removeSubtask(this);
      
      if (!this.isAsync) {
        this.deliverResolve();
        const rep = this.waitableRep();
        if (rep) {
          try {
            const removed = this.#getComponentState().handles.remove(rep);
            if (removed !== this) {
              throw new Error("unexpectedly received non-self Subtask from handle removal");
            }
            this.drop();
          } catch (err) {
            _debugLog('[AsyncSubtask#onResolve()] failed to remove subtask after sync subtask completion', err);
          }
        }
      }
    }
    
    getStateNumber() { return this.#state; }
    isReturned() { return this.#state === AsyncSubtask.State.RETURNED; }
    
    getCallMetadata() { return this.#callMetadata; }
    
    isResolved() {
      if (this.#state === AsyncSubtask.State.STARTING
      || this.#state === AsyncSubtask.State.STARTED) {
        return false;
      }
      if (this.#state === AsyncSubtask.State.RETURNED
      || this.#state === AsyncSubtask.State.CANCELLED_BEFORE_STARTED
      || this.#state === AsyncSubtask.State.CANCELLED_BEFORE_RETURNED) {
        return true;
      }
      throw new Error('unrecognized internal Subtask state [' + this.#state + ']');
    }
    
    addLender(handle) {
      _debugLog('[AsyncSubtask#addLender()] args', { handle });
      if (!Number.isNumber(handle)) { throw new Error('missing/invalid lender handle [' + handle + ']'); }
      
      if (this.#lenders.length === 0 || this.isResolved()) {
        throw new Error('subtask has no lendors or has already been resolved');
      }
      
      handle.lends++;
      this.#lenders.push(handle);
    }
    
    deliverResolve() {
      _debugLog('[AsyncSubtask#deliverResolve()] args', {
        lenders: this.#lenders,
        parentTaskID: this.parentTaskID(),
        subtaskID: this.#id,
        childTaskID: this.childTaskID(),
        resolved: this.isResolved(),
        resolveDelivered: this.resolveDelivered(),
      });
      
      const cannotDeliverResolve = this.resolveDelivered() || !this.isResolved();
      if (cannotDeliverResolve) {
        throw new Error('subtask cannot deliver resolution twice, and the subtask must be resolved');
      }
      
      for (const lender of this.#lenders) {
        lender.lends--;
      }
      
      this.#lenders = null;
    }
    
    resolveDelivered() {
      _debugLog('[AsyncSubtask#resolveDelivered()] args', { });
      if (this.#lenders === null && !this.isResolved()) {
        throw new Error('invalid subtask state, lenders missing and subtask has not been resolved');
      }
      return this.#lenders === null;
    }
    
    drop() {
      _debugLog('[AsyncSubtask#drop()] args', {
        componentIdx: this.#componentIdx,
        parentTaskID: this.#parentTask?.id(),
        parentTaskFnName: this.#parentTask?.entryFnName(),
        childTaskID: this.#childTask?.id(),
        childTaskFnName: this.#childTask?.entryFnName(),
        subtaskFnName: this.fnName,
      });
      if (!this.#waitable) { throw new Error('missing/invalid inner waitable'); }
      if (!this.resolveDelivered()) {
        throw new Error('cannot drop a subtask which has not yet resolved');
      }
      if (this.#waitable) { this.#waitable.drop() }
      this.#dropped = true;
    }
    
    #getComponentState() {
      const state = getOrCreateAsyncState(this.#componentIdx);
      if (!state) {
        throw new Error('invalid/missing async state for component [' + componentIdx + ']');
      }
      return state;
    }
    
    getWaitableHandleIdx() {
      _debugLog('[AsyncSubtask#getWaitableHandleIdx()] args', { });
      if (!this.#waitable) { throw new Error('missing/invalid waitable'); }
      return this.waitableRep();
    }
  }
  
  class FutureValue {
    #start;
    #settled;
    #hideThen = 0;
    #thenFn;
    
    constructor(start) {
      if (typeof start !== 'function') {
        throw new TypeError('future start operation must be a function');
      }
      this.#start = start;
      this.#thenFn = this.#then.bind(this);
    }
    
    get then() {
      return this.#hideThen === 0 ? this.#thenFn : undefined;
    }
    
    #read() {
      if (!this.#settled) {
        // The start operation resolves to a non-thenable box so a
        // future-valued payload cannot be assimilated by this Promise.
        this.#settled = Promise.resolve().then(this.#start);
      }
      return this.#settled;
    }
    
    resolveAsValue(resolve) {
      this.#hideThen++;
      try {
        resolve(this);
      } finally {
        this.#hideThen--;
      }
    }
    
    #deliver(resolve, value) {
      if (value instanceof FutureValue) {
        // Promise resolution reads `then` synchronously. Hide it only
        // for that lookup so resolving this layer yields the inner
        // FutureValue instead of recursively awaiting it.
        value.resolveAsValue(resolve);
        return;
      }
      resolve(value);
    }
    
    #then(resolve, reject) {
      return this.#read().then(
      box => this.#deliver(resolve, box.value),
      reject,
      );
    }
  }
  
  function _postReturnTrap(componentIdx, err) {
    // Core exceptions and stack exhaustion are fatal during cleanup.
    if (!(err instanceof WebAssemblyRuntimeError)) {
      const message = /call stack|stack overflow|too much recursion/i.test(err?.message ?? '')
      ? "wasm trap: call stack exhausted" : "wasm trap: uncaught exception propagated out of component";
      err = new WebAssemblyRuntimeError(message, { cause: err });
    }
    getOrCreateAsyncState(componentIdx).markTrapped(err);
    return err;
  }
  const ASYNC_DETERMINISM = 'random';
  const _coinFlip = () => { return Math.random() > 0.5; };
  
  const ASYNC_EVENT_CODE = {
    NONE: 0,
    SUBTASK: 1,
    STREAM_READ: 2,
    STREAM_WRITE: 3,
    FUTURE_READ: 4,
    FUTURE_WRITE: 5,
    TASK_CANCELLED: 6,
  };
  
  function _getGlobalCurrentThreadMeta(componentIdx) {
    const v = componentIdx === undefined || componentIdx === null
    ? CURRENT_TASK_META.current
    : CURRENT_TASK_META[componentIdx];
    if (v === undefined || v === null) {
      return undefined;
    }
    return { ...v };
  }
  
  
  function _withGlobalCurrentThreadMeta(args) {
    _debugLog('[_withGlobalCurrentThreadMeta()] args', args);
    if (!args) { throw new TypeError('args missing'); }
    if (args.taskID === undefined) { throw new TypeError('missing task ID'); }
    if (args.threadID === undefined) { throw new TypeError('missing thread ID'); }
    if (args.componentIdx === undefined) { throw new TypeError('missing component idx'); }
    if (!args.fn) { throw new TypeError('missing fn'); }
    const { taskID, threadID, componentIdx, fn } = args;
    const previous = CURRENT_TASK_META[componentIdx] ?? null;
    const previousCurrent = CURRENT_TASK_META.current ?? null;
    
    try {
      CURRENT_TASK_META.current =
      CURRENT_TASK_META[componentIdx] = { threadID, taskID, componentIdx };
      return fn();
    } catch (err) {
      _debugLog("error while executing sync callee/callback", {
        ...args,
        err,
      });
      throw err;
    } finally {
      // Synchronous wrappers can nest without any intervening JS
      // scheduling. Restore the caller rather than clearing it so
      // helper core exports (for example fused return adapters) can
      // temporarily run under a different thread of the same component.
      CURRENT_TASK_META[componentIdx] = previous;
      CURRENT_TASK_META.current = previousCurrent;
    }
  }
  
  function _withGlobalCurrentThreadMetaAsync(args) {
    _debugLog('[_withGlobalCurrentThreadMetaAsync()] args', args);
    if (!args) { throw new TypeError('args missing'); }
    if (args.taskID === undefined) { throw new TypeError('missing task ID'); }
    if (args.threadID === undefined) { throw new TypeError('missing thread ID'); }
    if (args.componentIdx === undefined) { throw new TypeError('missing component idx'); }
    if (!args.fn) { throw new TypeError('missing fn'); }
    
    const { taskID, threadID, componentIdx, fn } = args;
    const previous = CURRENT_TASK_META[componentIdx] ?? null;
    const previousCurrent = CURRENT_TASK_META.current ?? null;
    
    let result;
    try {
      CURRENT_TASK_META.current =
      CURRENT_TASK_META[componentIdx] = { taskID, threadID, componentIdx };
      result = fn();
    } catch (err) {
      _debugLog("error while executing sync callee/callback", {
        ...args,
        err,
      });
      CURRENT_TASK_META[componentIdx] = previous;
      CURRENT_TASK_META.current = previousCurrent;
      throw err;
    }
    
    if (result === null ||
    (typeof result !== 'object' && typeof result !== 'function') ||
    typeof result.then !== 'function') {
      CURRENT_TASK_META[componentIdx] = previous;
      CURRENT_TASK_META.current = previousCurrent;
      return result;
    }
    
    return (async () => {
      try {
        return await result;
      } catch (err) {
        _debugLog("error while executing async callee/callback", {
          ...args,
          err,
        });
        throw err;
      } finally {
        if (CURRENT_TASK_META[componentIdx]?.threadID === threadID &&
        CURRENT_TASK_META[componentIdx]?.taskID === taskID) {
          CURRENT_TASK_META[componentIdx] = null;
        }
        if (CURRENT_TASK_META.current?.threadID === threadID &&
        CURRENT_TASK_META.current?.taskID === taskID) {
          CURRENT_TASK_META.current = null;
        }
      }
    })();
  }
  
  class AsyncTask {
    static _ID = 0n;
    // Ids for the implicit threads of host (-1) tasks, which have no
    // component instance thread table (see `addThread`).
    static _HOST_THREAD_ID = 0;
    
    static State = {
      INITIAL: 'initial',
      CANCELLED: 'cancelled',
      CANCEL_PENDING: 'cancel-pending',
      CANCEL_DELIVERED: 'cancel-delivered',
      RESOLVED: 'resolved',
    }
    
    static BlockResult = {
      CANCELLED: 'block.cancelled',
      NOT_CANCELLED: 'block.not-cancelled',
    }
    
    #id;
    #componentIdx;
    #state;
    #isAsync;
    #isManualAsync;
    #callingWasmExport = true;
    #lockFreeEntry = false;
    #preserveFutureResult;
    #entryFnName = null;
    
    #onResolveHandlers = [];
    #progressWaiters = [];
    #completionPromise = null;
    #completionValue;
    #completionReady = false;
    #settleCompletionPromise;
    #rejected = false;
    
    #exitPromise = null;
    #onExitHandlers = [];
    
    #memoryIdx = null;
    #memory = null;
    
    #callbackFn = null;
    #callbackFnName = null;
    
    #postReturnFn = null;
    
    #getCalleeParamsFn = null;
    #calleeIsAsync = null;
    #admissionTicket = null;
    #funcTypeIsAsync = false;
    #returnResultTypeIdx = null;
    
    #stringEncoding = null;
    
    #parentSubtask = null;
    
    #errHandling;
    
    #backpressurePromise;
    #backpressureWaiters = 0n;
    
    #returnLowerFns = null;
    
    #resourceScopeId;
    #resourceBorrowCount = 0;
    #resourceLenders = [];
    #resourceScopeExited = false;
    
    #subtasks = [];
    
    // Threads owned by this task, indexed by their task-scoped
    // thread id (see AsyncThread -- index 0 is always the task's
    // implicit thread, created alongside it).
    #threads = [];
    
    #entered = false;
    #exited = false;
    #errored = null;
    
    cancelled = false;
    cancelRequested = false;
    alwaysTaskReturn = false;
    
    returnCalls =  0;
    tmpRetI64HighBits = 0|0;
    
    constructor(opts) {
      this.#id = ++AsyncTask._ID;
      this.#resourceScopeId = ++RESOURCE_SCOPE_ID;
      RESOURCE_SCOPE_TASKS.set(this.#resourceScopeId, this);
      
      if (opts?.componentIdx === undefined) {
        throw new TypeError('missing component id during task creation');
      }
      this.#componentIdx = opts.componentIdx;
      
      this.#state = AsyncTask.State.INITIAL;
      this.#isAsync = opts?.isAsync ?? false;
      this.#isManualAsync = opts?.isManualAsync ?? false;
      this.#preserveFutureResult = opts?.preserveFutureResult ?? false;
      this.#entryFnName = opts.entryFnName;
      // Tasks that execute guest slices (export calls, fused
      // callees) default to true; import-handler tasks pass false
      // explicitly (they run host code nested inside the caller's
      // already-locked slice).
      this.#callingWasmExport = opts?.callingWasmExport !== false;
      
      const {
        promise: completionPromise,
        resolve: resolveCompletionPromise,
        reject: rejectCompletionPromise,
      } = promiseWithResolvers();
      this.#completionPromise = completionPromise;
      // A nested rejection can reach the root task while its Wasm
      // entrypoint is still suspended, before the export wrapper awaits
      // this promise. Mark it handled immediately while preserving the
      // original rejected promise for the eventual caller.
      completionPromise.catch(() => {});
      
      let completionSettled = false;
      const settleCompletionPromise = () => {
        if (completionSettled || !this.#completionReady) { return; }
        completionSettled = true;
        if (this.#errored !== null) {
          rejectCompletionPromise(this.#errored);
        } else if (this.#rejected) {
          rejectCompletionPromise(this.#completionValue);
        } else if (
        this.#preserveFutureResult
        && this.#completionValue instanceof FutureValue
        ) {
          this.#completionValue.resolveAsValue(resolveCompletionPromise);
        } else {
          resolveCompletionPromise(this.#completionValue);
        }
      };
      
      this.#settleCompletionPromise = settleCompletionPromise;
      this.#onResolveHandlers.push((results) => {
        if (this.#parentSubtask !== null) { return; }
        if (!this.#isAsync && !this.#isManualAsync) { return; }
        this.#completionValue = results;
        this.#completionReady = true;
        // Publish after the current guest slice returns, so a trap
        // in that slice can still reject the call. Do not wait for
        // task exit: detached work may require further host calls
        // or consumption of a returned resource's stream.
      });
      
      const {
        promise: exitPromise,
        resolve: resolveExitPromise,
        reject: rejectExitPromise,
      } = promiseWithResolvers();
      this.#exitPromise = exitPromise;
      
      this.#onExitHandlers.push(() => {
        if (this.#parentSubtask === null && (this.#isAsync || this.#isManualAsync)) {
          settleCompletionPromise();
        }
        resolveExitPromise();
      });
      
      if (opts.callbackFn) { this.#callbackFn = opts.callbackFn; }
      if (opts.callbackFnName) { this.#callbackFnName = opts.callbackFnName; }
      
      if (opts.getCalleeParamsFn) { this.#getCalleeParamsFn = opts.getCalleeParamsFn; }
      if (opts.stringEncoding) { this.#stringEncoding = opts.stringEncoding; }
      
      if (opts.parentSubtask) { this.#parentSubtask = opts.parentSubtask; }
      
      
      if (opts.errHandling) { this.#errHandling = opts.errHandling; }
    }
    
    taskState() { return this.#state; }
    id() { return this.#id; }
    componentIdx() { return this.#componentIdx; }
    entryFnName() { return this.#entryFnName; }
    
    resourceScopeId() { return this.#resourceScopeId; }
    
    addBorrowedHandle() {
      if (this.#resourceScopeExited) {
        throw new Error('cannot add a borrow to an exited resource scope');
      }
      this.#resourceBorrowCount++;
    }
    
    removeBorrowedHandle() {
      if (this.#resourceBorrowCount === 0) {
        throw new Error('resource borrow count underflow');
      }
      this.#resourceBorrowCount--;
    }
    
    addResourceLender(table, handle) {
      if (this.#resourceScopeExited) {
        throw new Error('cannot add a lender to an exited resource scope');
      }
      this.#resourceLenders.push({ table, handle });
    }
    
    validateResourceBorrowScope() {
      if (this.#resourceScopeExited) { return; }
      if (this.#resourceBorrowCount !== 0) {
        throw new WebAssemblyRuntimeError('borrow handles still remain at the end of the call');
      }
      for (const { table, handle } of this.#resourceLenders) {
        const idx = handle << 1;
        const lendCount = table[idx];
        if (!Number.isInteger(lendCount) || lendCount <= 0 || lendCount >= 2**30) {
          throw new Error('invalid resource lender state at scope exit');
        }
        table[idx] = lendCount - 1;
      }
      this.#resourceLenders = [];
      this.#resourceScopeExited = true;
      RESOURCE_SCOPE_TASKS.delete(this.#resourceScopeId);
    }
    
    completionPromise() { return this.#completionPromise; }
    settleCompletion() { this.#settleCompletionPromise(); }
    exitPromise() { return this.#exitPromise; }
    
    waitForProgress() {
      const { promise, resolve } = promiseWithResolvers();
      this.#progressWaiters.push(resolve);
      return promise;
    }
    
    notifyProgress() {
      const waiters = this.#progressWaiters;
      this.#progressWaiters = [];
      for (const resolve of waiters) { resolve(); }
    }
    
    isAsync() { return this.#isAsync; }
    isManualAsync() { return this.#isManualAsync; }
    isSync() { return !this.isAsync(); }
    
    getErrHandling() { return this.#errHandling; }
    
    hasCallback() { return this.#callbackFn !== null; }
    
    getReturnMemoryIdx() { return this.#memoryIdx; }
    setReturnMemoryIdx(idx) {
      if (idx === null) { return; }
      this.#memoryIdx = idx;
    }
    
    getReturnMemory() { return this.#memory; }
    setReturnMemory(m) {
      if (m === null) { return; }
      this.#memory = m;
    }
    
    setReturnLowerFns(fns) { this.#returnLowerFns = fns; }
    getReturnLowerFns() { return this.#returnLowerFns; }
    
    setCalleeIsAsync(value) {
      if (typeof value !== 'boolean') { throw new TypeError('callee async state must be a boolean'); }
      this.#calleeIsAsync = value;
    }
    
    setParentSubtask(subtask) {
      if (!subtask || !(subtask instanceof AsyncSubtask)) { return }
      if (this.#parentSubtask) { throw new Error('parent subtask can only be set once'); }
      this.#parentSubtask = subtask;
    }
    
    getParentSubtask() { return this.#parentSubtask; }
    
    // Registers a newly-created thread as belonging to this task
    // and assigns it its real, *component-instance-scoped* id
    // (`Task.register_thread` in the canonical ABI) -- threads
    // are addressed instance-wide (not per-task) so that a
    // thread of one task can target a thread of another, e.g.
    // via `thread.resume-later`.
    addThread(thread) {
      // Host (-1) tasks model host-side import handling: there is no
      // component instance behind them, so no instance thread table to
      // register with (and none may be materialised on their behalf).
      if (this.#componentIdx === -1) {
        thread.setId(++AsyncTask._HOST_THREAD_ID);
        this.#threads.push(thread);
        return thread;
      }
      const cstate = getOrCreateAsyncState(this.#componentIdx);
      thread.setId(cstate.threads.insert(thread));
      this.#threads.push(thread);
      return thread;
    }
    
    // Unregisters a thread that has finished running
    // (`Task.unregister_thread`), freeing its instance-scoped id.
    removeThread(thread) {
      if (this.#threads.length === 1 && !this.isResolvedState() && !this.isRejected()) {
        throw new WebAssemblyRuntimeError(`(component [${this.#componentIdx}]) task [${this.#id}] exited without resolution`);
      }
      this.settleCompletion();
      if (this.#componentIdx !== -1) {
        const cstate = getOrCreateAsyncState(this.#componentIdx);
        cstate.threads.remove(thread.id());
      }
      this.#threads = this.#threads.filter(t => t !== thread);
      if (this.#exited && this.#threads.length === 0) {
        clearCurrentThread(this.#componentIdx, this.#id);
      }
    }
    
    // The thread created alongside this task (always the first
    // one registered). Used by task-level callback dispatch and
    // exit cleanup, which operate on the task rather than an
    // explicitly identified thread.
    defaultThread() { return this.#threads[0]; }
    
    // TODO(threads): this is very inefficient, we can pass along a root task,
    // and ideally do not need this once thread support is in place
    getRootTask() {
      let currentSubtask = this.getParentSubtask();
      let task = this;
      while (currentSubtask) {
        task = currentSubtask.getParentTask();
        currentSubtask = task.getParentSubtask();
      }
      return task;
    }
    
    setPostReturnFn(f) {
      if (!f) { return; }
      if (this.#postReturnFn) { throw new Error('postReturn fn can only be set once'); }
      this.#postReturnFn = f;
    }
    
    setCallbackFn(f, name) {
      if (!f) { return; }
      if (this.#callbackFn) { throw new Error('callback fn can only be set once'); }
      this.#callbackFn = f;
      this.#callbackFnName = name;
    }
    
    getCallbackFnName() {
      if (!this.#callbackFnName) { return undefined; }
      return this.#callbackFnName;
    }
    
    runCallbackFn(...args) {
      if (!this.#callbackFn) { throw new Error('no callback function has been set for task'); }
      if (this.#callbackFn._jcoMaySuspend === false) {
        return _withGlobalCurrentThreadMeta({
          taskID: this.#id,
          threadID: this.defaultThread().id(),
          componentIdx: this.#componentIdx,
          fn: () => this.#callbackFn.apply(null, args),
        });
      }
      return _withGlobalCurrentThreadMetaAsync({
        taskID: this.#id,
        threadID: this.defaultThread().id(),
        componentIdx: this.#componentIdx,
        fn: () => { return this.#callbackFn.apply(null, args); }
      });
    }
    
    getCalleeParams() {
      if (!this.#getCalleeParamsFn) { throw new Error('missing/invalid getCalleeParamsFn'); }
      return this.#getCalleeParamsFn();
    }
    
    // Legacy manually-async exports are sync-typed in the component
    // but use JSPI precisely so their guest stack may suspend.
    // Canonical ABI: only sync-typed callees may not block (`canon_lift`);
    // an async-lifted callee may, even when called through a sync lowering.
    mayBlock() { return this.isAsync() || this.isManualAsync() || this.isResolvedState() || this.#funcTypeIsAsync }
    // (an async-typed function may block however it was lifted)
    setFuncTypeIsAsync(v) { this.#funcTypeIsAsync = v; }
    // The interned result type of the task's function (checked by `task.return`)
    setReturnResultTypeIdx(v) { this.#returnResultTypeIdx = v; }
    returnResultTypeIdx() { return this.#returnResultTypeIdx; }
    
    mayEnter(task) {
      const cstate = getOrCreateAsyncState(this.#componentIdx);
      if (cstate.hasBackpressure()) {
        _debugLog('[AsyncTask#mayEnter()] disallowed due to backpressure', { taskID: this.#id });
        return false;
      }
      if (!cstate.callingSyncImport()) {
        _debugLog('[AsyncTask#mayEnter()] disallowed due to sync import call', { taskID: this.#id });
        return false;
      }
      const callingSyncExportWithSyncPending = cstate.callingSyncExport && !task.isAsync;
      if (!callingSyncExportWithSyncPending) {
        _debugLog('[AsyncTask#mayEnter()] disallowed due to sync export w/ sync pending', { taskID: this.#id });
        return false;
      }
      return true;
    }
    
    enterSync() {
      if (this.needsExclusiveLock()) {
        const cstate = getOrCreateAsyncState(this.#componentIdx);
        if (!cstate.isExclusivelyLocked()) {
          cstate.exclusiveLock(this.#id);
        } else {
          // A host-called sync export arriving while another
          // task's slice holds the lock: synchronous entry
          // cannot wait, and historically this entry silently
          // stole the hold. Run without the lock instead --
          // the holder's bookkeeping stays intact and its
          // release still pairs
          this.#lockFreeEntry = true;
          _debugLog('[AsyncTask#enterSync()] entering without exclusive lock', {
            taskID: this.#id,
            componentIdx: this.#componentIdx,
          });
        }
      }
      return true;
    }
    
    tryEnter() {
      if (this.#entered) {
        throw new Error(`task with ID [${this.#id}] should not be entered twice`);
      }
      
      if (this.deliverPendingCancel({ cancellable: true })) {
        this.cancel();
        return false;
      }
      
      const cstate = getOrCreateAsyncState(this.#componentIdx);
      if (this.isSync()) {
        this.#entered = true;
        return true;
      }
      if (cstate.hasBackpressure()) { return null; }
      // Entries already queued for this instance go first.
      if (cstate.hasPendingAdmissions()) { return null; }
      if (this.needsExclusiveLock()) {
        if (cstate.isExclusivelyLocked()) { return null; }
        cstate.exclusiveLock(this.#id);
      }
      
      if (this.deliverPendingCancel({ cancellable: true })) {
        cstate.exclusiveRelease(this.#id);
        this.cancel();
        return false;
      }
      
      this.#entered = true;
      return true;
    }
    
    enterHost() {
      if (this.#entered) {
        throw new Error(`task with ID [${this.#id}] should not be entered twice`);
      }
      
      // If cancellation was requested before the task was entered, resolve
      // as cancelled without ever running host code
      if (this.deliverPendingCancel({ cancellable: true })) {
        this.cancel();
        return false;
      }
      
      getOrCreateAsyncState(this.#componentIdx);
      
      this.#entered = true;
      // A guest task may be synchronously blocked in this
      // host entry. Propagate that boundary so an async
      // cancellation driver can yield BLOCKED while the host
      // operation is outstanding.
      const parentTask = this.#parentSubtask?.getParentTask();
      if (
      parentTask?.taskState() === AsyncTask.State.CANCEL_DELIVERED
      || (parentTask && !parentTask.hasCallback())
      ) {
        parentTask.notifyProgress();
      }
      return this.#entered;
    }
    
    async enter(opts) {
      _debugLog('[AsyncTask#enter()] args', {
        taskID: this.#id,
        componentIdx: this.#componentIdx,
        subtaskID: this.getParentSubtask()?.id(),
        args: opts,
        entryFnName: this.#entryFnName,
      });
      
      if (opts?.isHost) { return this.enterHost(); }
      
      if (this.#entered) {
        throw new Error(`task with ID [${this.#id}] should not be entered twice`);
      }
      
      // If cancellation was requested before the task was entered, resolve
      // as cancelled without ever running guest code
      if (this.deliverPendingCancel({ cancellable: true })) {
        this.cancel();
        return false;
      }
      
      const cstate = getOrCreateAsyncState(this.#componentIdx);
      
      // NOTE: concurrent task lifetimes within one component instance are
      // permitted by the Component Model: entry is governed by the
      // backpressure and exclusive-lock checks below (the lock is held per
      // execution slice, not for the task's lifetime).
      //
      // Serializing entire task lifetimes here (the former "execution slot" queue)
      // deadlocks pipelines where a parked long-lived task's progress depends on a
      // later entry into the same component.
      
      // If a task is synchronous then we can avoid component-relevant
      // tracking and immediately enter.
      if (this.isSync()) {
        this.#entered = true;
        
        // TODO(breaking): remove once manually-specifying async fns is removed
        // It is currently possible for an actually sync export to be specified
        // as async via JSPI
        if (this.#isManualAsync) {
          if (this.needsExclusiveLock()) { await cstate.acquireExclusiveLock(this.#id); }
        }
        
        return this.#entered;
      }
      
      // Enter in the order the calls were made: queue behind every
      // earlier entry into this instance, whatever it waits for.
      const ticket = cstate.takeAdmissionTicket(this.#id);
      this.#admissionTicket = ticket;
      let entered = false;
      try {
        entered = await this.#enterQueued(cstate, ticket);
        return entered;
      } finally {
        // An entered task keeps the slot until its first slice ends
        // (`endFirstSlice`): the next call is admitted once this one
        // returned, blocked or trapped, as `Store.invoke` runs a call.
        if (!entered) { this.endFirstSlice(); }
      }
    }
    
    // The first slice of this task ended (it returned, blocked or trapped):
    // the next entry into the instance may be admitted (Canonical ABI
    // `Store.invoke` runs a call until it first blocks or returns).
    endFirstSlice() {
      const ticket = this.#admissionTicket;
      if (ticket === null) { return; }
      this.#admissionTicket = null;
      getOrCreateAsyncState(this.#componentIdx).releaseAdmissionTicket(ticket);
    }
    
    async #enterQueued(cstate, ticket) {
      await cstate.waitForAdmissionTurn(ticket);
      // Cancelled before it started while it was queued: the task was
      // retired already and must not park in a wait as a dead entry.
      if (this.isResolvedState() || this.isCancelled()) { return false; }
      
      // Wait until there is no backpressure *and* the exclusive lock (if
      // needed) is ours. Backpressure can be set while we wait for the
      // lock (by the task holding it), so it's checked again once the lock
      // is acquired, as the Canonical ABI's `enter_implicit_thread` waits
      // for both together.
      while (true) {
        if (cstate.hasBackpressure()) {
          cstate.addBackpressureWaiter();
          
          const result = await this.waitUntil({
            readyFn: () => {
              return !cstate.hasBackpressure();
            },
            cancellable: true,
          });
          
          cstate.removeBackpressureWaiter();
          
          if (!result || this.isCancelled()) {
            if (!this.isResolvedState()) { this.cancel(); }
            return false;
          }
        }
        
        // Acquire the per-slice exclusive lock (FIFO-queued when
        // contended); the first slice runs under this hold and the
        // driver loop releases/re-acquires it per slice thereafter.
        if (this.needsExclusiveLock()) {
          await cstate.acquireExclusiveLock(this.#id);
          if (cstate.hasBackpressure()) {
            cstate.exclusiveRelease(this.#id);
            continue;
          }
        }
        break;
      }
      
      // The store may have trapped (e.g. a deadlock was detected) while
      // this task waited to enter: it must not run, and its call fails
      // with that trap.
      try {
        cstate.throwIfInterrupted();
      } catch (err) {
        cstate.exclusiveRelease(this.#id);
        this.setErrored(err);
        return false;
      }
      
      // Cancellation-before-start may resolve this task while its
      // queued lock acquisition is still pending. Acquiring the lock
      // does not make the already-resolved task runnable again.
      if (this.isResolvedState() || this.isCancelled()) {
        cstate.exclusiveRelease(this.#id);
        return false;
      }
      
      // Cancellation can be requested while entry is waiting for
      // backpressure or its exclusive lock. Do not execute the guest
      // after acquiring a lock for a task that should no longer start.
      if (this.deliverPendingCancel({ cancellable: true })) {
        cstate.exclusiveRelease(this.#id);
        this.cancel();
        return false;
      }
      
      this.#entered = true;
      return this.#entered;
    }
    
    isRunningState() { return this.#state !== AsyncTask.State.RESOLVED; }
    isResolvedState() { return this.#state === AsyncTask.State.RESOLVED; }
    isResolved() { return this.#state === AsyncTask.State.RESOLVED; }
    isExited() { return this.#exited; }
    
    async waitUntil(opts) {
      const { readyFn, cancellable } = opts;
      _debugLog('[AsyncTask#waitUntil()] args', { taskID: this.#id, args: { cancellable } });
      
      // TODO(fix): check for cancel
      // TODO(fix): determinism
      
      const keepGoing = await this.suspendUntil({
        readyFn,
        cancellable,
      });
      
      return keepGoing;
    }
    
    async yieldUntil(opts) {
      const { readyFn, cancellable } = opts;
      _debugLog('[AsyncTask#yieldUntil()]', {
        taskID: this.#id,
        args: {
          cancellable,
        },
        componentIdx: this.#componentIdx,
      });
      
      // A callback YIELD is an explicit request to let other work run.
      // Unlike waits whose condition is already ready, it must always
      // suspend for at least one scheduler turn.
      const keepGoing = await this.immediateSuspend({ readyFn, cancellable });
      if (keepGoing) {
        return {
          code: ASYNC_EVENT_CODE.NONE,
          payload0: 0,
          payload1: 0,
        };
      }
      
      return {
        code: ASYNC_EVENT_CODE.TASK_CANCELLED,
        payload0: 0,
        payload1: 0,
      };
    }
    
    async suspendUntil(opts) {
      const { cancellable, readyFn } = opts;
      _debugLog('[AsyncTask#suspendUntil()] args', {
        taskID: this.#id,
        args: {
          cancellable,
        },
        componentIdx: this.#componentIdx,
      });
      
      const pendingCancelled = this.deliverPendingCancel({ cancellable });
      if (pendingCancelled) { return false; }
      
      const completed = await this.immediateSuspendUntil({ readyFn, cancellable });
      return completed;
    }
    
    suspendUntilCallback(opts, onResume) {
      const { cancellable, readyFn } = opts;
      if (this.deliverPendingCancel({ cancellable })) {
        onResume(false);
        return;
      }
      
      const cstate = getOrCreateAsyncState(this.#componentIdx);
      cstate.suspendTask({
        task: this,
        cancellable,
        readyFn: () => {
          if (cancellable && this.#state === AsyncTask.State.CANCEL_PENDING) {
            return true;
          }
          return readyFn();
        },
        onResume: (keepGoing) => {
          if (keepGoing && this.deliverPendingCancel({ cancellable })) {
            keepGoing = false;
          }
          onResume(keepGoing);
        },
      });
    }
    
    // TODO(threads): equivalent to thread.suspend_until()
    async immediateSuspendUntil(opts) {
      const { cancellable, readyFn } = opts;
      _debugLog('[AsyncTask#immediateSuspendUntil()] args', {
        args: {
          cancellable,
          readyFn,
        },
        taskID: this.#id,
        componentIdx: this.#componentIdx,
      });
      
      const ready = readyFn();
      if (ready && ASYNC_DETERMINISM === 'random') {
        const coinFlip = _coinFlip();
        if (coinFlip) { return true }
      }
      
      const keepGoing = await this.immediateSuspend({ cancellable, readyFn });
      return keepGoing;
    }
    
    async immediateSuspend(opts) {
      // Entry can wait on backpressure before a guest register window exists.
      const cstate = getOrCreateAsyncState(this.#componentIdx);
      const thread = this.#entered
      ? cstate.threads.get(_getGlobalCurrentThreadMeta(this.#componentIdx).threadID)
      : this.defaultThread();
      if (!thread || thread.task() !== this) { throw new Error('invalid current thread for wait'); }
      // A blocking built-in retains automatic backpressure for a
      // synchronous guest slice; explicit thread.* switches release it.
      return thread.suspend({ ...opts, releaseLock: false });
    }
    
    deliverPendingCancel(opts) {
      const { cancellable } = opts;
      _debugLog('[AsyncTask#deliverPendingCancel()]', {
        args: { cancellable },
        taskID: this.#id,
        componentIdx: this.#componentIdx,
      });
      
      if (cancellable && this.#state === AsyncTask.State.CANCEL_PENDING) {
        this.#state = AsyncTask.State.CANCEL_DELIVERED;
        return true;
      }
      
      return false;
    }
    
    isCancelled() { return this.cancelled }
    cancellationRequested() { return this.cancelRequested; }
    cancellationPending() { return this.#state === AsyncTask.State.CANCEL_PENDING; }
    
    // Request cooperative cancellation of this task, called on behalf of a
    // supertask performing `subtask.cancel` on the subtask this task backs.
    //
    // The request is delivered at this task's next cancellable wait
    // (see suspendUntil/immediateSuspend), at which point the task is
    // expected to acknowledge via `task.cancel` or still resolve via
    // `task.return`.
    requestCancellation() {
      _debugLog('[AsyncTask#requestCancellation()] args', {
        taskID: this.#id,
        componentIdx: this.#componentIdx,
        state: this.#state,
      });
      if (this.isResolvedState() || this.cancelRequested) { return; }
      this.cancelRequested = true;
      if (this.#state === AsyncTask.State.INITIAL) {
        this.#state = AsyncTask.State.CANCEL_PENDING;
        // A task still waiting for backpressure or its
        // initial instance lock has no guest thread to
        // resume. Cancellation is therefore delivered
        // and acknowledged eagerly as
        // CANCELLED_BEFORE_STARTED.
        if (!this.#entered) {
          this.deliverPendingCancel({ cancellable: true });
          this.cancel();
          
          const cstate = getOrCreateAsyncState(this.#componentIdx);
          // `enter()` may already be parked either in the scheduler's
          // explicit-backpressure wait or in the exclusive-lock FIFO.
          // Wake/remove that entry work now so it cannot retain a timer,
          // waiter count, or lock-queue slot after cancellation.
          cstate.resumeTaskByID(this.#id);
          cstate.cancelExclusiveLockWaiter(this.#id);
          
          // No guest thread was registered, so no driver loop will call
          // `exit()`. Retire the task's JS bookkeeping explicitly.
          this.exit({ skipExclusiveLockCheck: true });
          return;
        }
      }
      // Nudge the component's tick loop so that any suspended cancellable
      // wait observes the pending cancellation promptly
      getOrCreateAsyncState(this.#componentIdx).runTickLoop();
    }
    
    cancel(args) {
      _debugLog('[AsyncTask#cancel()] args', { });
      if (this.taskState() !== AsyncTask.State.CANCEL_DELIVERED) {
        throw new Error('`task.cancel` called by task which has not been cancelled');
      }
      this.validateResourceBorrowScope();
      this.cancelled = true;
      // Cancelled tasks resolve with no value (spec: `Task.cancel` calls
      // `on_resolve(None)`); an explicit error is only present on the
      // host-driven rejection path (see `reject()`).
      this.onResolve(args?.error ?? null);
      this.#state = AsyncTask.State.RESOLVED;
      // A task cancelled before entry has no driver loop that can
      // report its exit. Entered tasks notify after releasing their
      // component slice in `exit()`.
      if (!this.#entered) { this.notifyProgress(); }
    }
    
    onResolve(taskValue) {
      const handlers = this.#onResolveHandlers;
      this.#onResolveHandlers = [];
      for (const f of handlers) {
        try {
          f(taskValue);
        } catch (err) {
          _debugLog("[AsyncTask#onResolve] error during task resolve handler", err);
          throw err;
        }
      }
      
      // Rejections are control-flow failures, not canonical ABI results.
      // Propagate them through the subtask chain without running return
      // lowering or post-return hooks for a successful result.
      if (this.#rejected) {
        this.#parentSubtask?.reject(taskValue);
        return;
      }
      
      // NOTE: if the parent subtask has already been resolved (e.g. it was
      // cancelled via `subtask.cancel` while this task was still pending),
      // this task's resolution must be discarded rather than delivered.
      const parentSubtaskPending = this.#parentSubtask && !this.#parentSubtask.isResolved();
      const taskReturned = !this.isCancelled();
      
      if (parentSubtaskPending && taskReturned) {
        const meta = this.#parentSubtask.getCallMetadata();
        // Run the rturn fn if it has not already been called -- this *should* have happened in
        // `task.return`, but some paths do not go through task.return (e.g. async lower of sync fn
        // which goes through prepare + async-start-call)
        if (meta.returnFn && !meta.returnFnCalled) {
          _debugLog('[AsyncTask#onResolve()] running returnFn', {
            componentIdx: this.#componentIdx,
            taskID: this.#id,
            subtaskID: this.#parentSubtask.id(),
          });
          const callerTask = this.#parentSubtask.getParentTask();
          _withGlobalCurrentThreadMeta({
            taskID: callerTask.id(),
            threadID: meta.callerThreadID,
            componentIdx: callerTask.componentIdx(),
            fn: () => meta.returnFn.apply(null, [taskValue, meta.resultPtr]),
          });
          meta.returnFnCalled = true;
        }
      }
      
      if (this.#postReturnFn && taskReturned) {
        _debugLog('[AsyncTask#onResolve()] running post return ', {
          componentIdx: this.#componentIdx,
          taskID: this.#id,
        });
        try {
          _withGlobalCurrentThreadMeta({
            taskID: this.#id,
            threadID: this.defaultThread().id(),
            componentIdx: this.#componentIdx,
            fn: () => this.#postReturnFn(taskValue),
          });
        } catch (err) {
          err = _postReturnTrap(this.#componentIdx, err);
          this.reject(err);
          throw err;
        }
      }
      
      if (parentSubtaskPending) {
        this.#parentSubtask.onResolve(taskValue);
      }
    }
    
    registerOnResolveHandler(f) {
      this.#onResolveHandlers.push(f);
    }
    
    isRejected() { return this.#rejected; }
    
    isErrored() { return this.#errored; }
    setErrored(err) {
      // Preserve the originating trap when unwinding through
      // additional guest frames produces secondary traps (often
      // an `unreachable` after a call which was expected to trap).
      if (this.#errored === null) { this.#errored = err; }
    }
    
    reject(taskErr) {
      _debugLog('[AsyncTask#reject()] args', {
        componentIdx: this.#componentIdx,
        taskID: this.#id,
        parentSubtask: this.#parentSubtask,
        parentSubtaskID: this.#parentSubtask?.id(),
        entryFnName: this.entryFnName(),
        callbackFnName: this.#callbackFnName,
        errMsg: taskErr.message,
      });
      
      this.setErrored(taskErr);
      if (this.#rejected) { return; }
      
      // A task may call `task.return` before its callback exits.
      // A trap in cleanup or spawned work must still reject the
      // host call and poison the enclosing task chain.
      if (this.isResolvedState()) {
        this.#rejected = true;
        this.#errored = taskErr;
        const parentTask = this.#parentSubtask?.getParentTask();
        if (parentTask) { parentTask.reject(taskErr); }
        return;
      }
      
      this.#rejected = true;
      this.cancelRequested = true;
      this.#state = AsyncTask.State.CANCEL_PENDING;
      const cancelled = this.deliverPendingCancel({ cancellable: true });
      
      // TODO: do cleanup here to reset the machinery so we can run again?
      
      this.cancel({ error: taskErr });
    }
    
    resolve(results) {
      _debugLog('[AsyncTask#resolve()] args', {
        componentIdx: this.#componentIdx,
        taskID: this.#id,
        entryFnName: this.entryFnName(),
        callbackFnName: this.#callbackFnName,
      });
      
      if (this.#state === AsyncTask.State.RESOLVED) {
        if (this.#errored !== null) { throw this.#errored; }
        throw new Error(`(component [${this.#componentIdx}]) task [${this.#id}]  is already resolved (did you forget to wait for an import?)`);
      }
      
      this.validateResourceBorrowScope();
      
      this.#state = AsyncTask.State.RESOLVED;
      
      switch (results.length) {
        case 0:
        this.onResolve(undefined);
        break;
        case 1:
        this.onResolve(results[0]);
        break;
        default:
        _debugLog('[AsyncTask#resolve()] unexpected number of results', {
          componentIdx: this.#componentIdx,
          results,
          taskID: this.#id,
          subtaskID: this.#parentSubtask?.id(),
          entryFnName: this.#entryFnName,
          callbackFnName: this.#callbackFnName,
        });
        throw new Error('unexpected number of results');
      }
    }
    
    exit(args) {
      _debugLog('[AsyncTask#exit()]', {
        componentIdx: this.#componentIdx,
        taskID: this.#id,
      });
      
      this.endFirstSlice();
      if (this.#exited)  { throw new Error("task has already exited"); }
      
      this.validateResourceBorrowScope();
      
      // Host (-1) tasks have no component instance (and so no async
      // state or exclusive lock); do not materialise one for them.
      const state = this.#componentIdx === -1
      ? null
      : getOrCreateAsyncState(this.#componentIdx);
      if (!state && this.#componentIdx !== -1) {
        throw new Error('missing async state for component [' + this.#componentIdx + ']');
      }
      
      if (state && !args?.skipExclusiveLockCheck && !this.#lockFreeEntry) {
        if (this.needsExclusiveLock() && !state.exclusivelyLockedBy(this.#id)) {
          throw new Error(`task [${this.#id}] exit: component [${this.#componentIdx}] should have been exclusively locked by it`);
        }
      }
      
      // Ownership-checked: releases only this task's own hold (a
      // task exiting while another task's slice holds the lock no
      // longer clears the foreign hold).
      if (state) { state.exclusiveRelease(this.#id); }
      this.notifyProgress();
      
      for (const f of this.#onExitHandlers) {
        try {
          f();
        } catch (err) {
          console.error("error during task exit handler", err);
          throw err;
        }
      }
      
      this.#exited = true;
      this.removeThread(this.defaultThread());
      if (this.#threads.length > 0) {
        clearCurrentThread(this.#componentIdx, this.#id, { preserveTask: true });
      }
    }
    
    needsExclusiveLock() {
      // Host (-1) tasks model host-side import handling: there is no
      // guest linear memory or executor state to protect, and host
      // calls from unrelated guest components would contend spuriously.
      if (this.#componentIdx === -1) { return false; }
      // Import-handler tasks (CallInterface) run host code nested
      // inside the calling guest slice, which already holds the
      // lock; only tasks that execute guest slices need it.
      if (!this.#callingWasmExport) { return false; }
      // A sync-lifted callee cannot be reentered until the whole
      // stackful call returns. This is the Component Model's
      // automatic-backpressure rule for async-lowered calls.
      return !this.#isAsync || this.hasCallback() || this.#calleeIsAsync === false;
    }
    
    createSubtask(args) {
      _debugLog('[AsyncTask#createSubtask()] args', args);
      const { componentIdx, childTask, callMetadata, fnName, isAsync, isManualAsync } = args;
      
      const cstate = getOrCreateAsyncState(this.#componentIdx);
      if (!cstate) {
        throw new Error(`invalid/missing async state for component idx [${componentIdx}]`);
      }
      
      const waitable = new Waitable({
        componentIdx: this.#componentIdx,
        target: `subtask (internal ID [${this.#id}])`,
      });
      
      const newSubtask = new AsyncSubtask({
        componentIdx,
        childTask,
        parentTask: this,
        callMetadata,
        isAsync,
        isManualAsync,
        fnName,
        waitable,
      });
      this.#subtasks.push(newSubtask);
      newSubtask.setTarget(`subtask (internal ID [${newSubtask.id()}], waitable [${waitable.idx()}], component [${componentIdx}])`);
      // The subtask gets a handle index in this task's table only once the
      // guest is given it (see `AsyncSubtask#ensureHandle`).
      return newSubtask;
    }
    
    getLatestSubtask() {
      return this.#subtasks.at(-1);
    }
    
    getSubtaskByWaitableRep(rep) {
      if (rep === undefined) { throw new TypeError('missing rep'); }
      return this.#subtasks.find(s => s.waitableRep() === rep);
    }
    
    currentSubtask() {
      _debugLog('[AsyncTask#currentSubtask()]');
      if (this.#subtasks.length === 0) { return undefined; }
      return this.#subtasks.at(-1);
    }
    
    removeSubtask(subtask) {
      if (this.#subtasks.length === 0) {
        throw new Error('cannot end current subtask: no current subtask');
      }
      this.#subtasks = this.#subtasks.filter(t => t !== subtask);
      return subtask;
    }
  }
  
  function _recordTrap(componentIdx, err, convertsRangeErrors = false) {
    // A built-in reading or writing guest memory past its end fails with a
    // DataView RangeError: that is the Canonical ABI's out-of-bounds trap.
    if (convertsRangeErrors && err instanceof RangeError) {
      err = new WebAssemblyRuntimeError('out of bounds memory access');
    }
    if (err instanceof WebAssemblyRuntimeError) {
      // (a trampoline without a static instance records against the
      // component whose guest code is running)
      const idx = componentIdx ?? CURRENT_TASK_META.current?.componentIdx;
      if (idx !== undefined && idx !== null) {
        getOrCreateAsyncState(idx).markTrapped(err);
      }
    }
    return err;
  }
  
  class AsyncThread {
    static State = {
      // Explicitly spawned (`thread.new-indirect`) threads start
      // here; the implicit thread of a task skips straight to
      // RUNNING since it is the task's own entry.
      NOT_STARTED: 'not-started',
      RUNNING: 'running',
      COMPLETED: 'completed',
    }
    
    // Component-instance-scoped id (the canonical ABI's
    // `Thread.index`) -- globally unique within the instance,
    // *not* per task, since a thread of one task may be
    // targeted (e.g. by `thread.resume-later`) by code
    // running in a different task of the same instance.
    // Assigned post-construction by `Task#addThread()`, which
    // is the only code allowed to insert into the instance's
    // thread table.
    #id = null;
    #componentIdx;
    #task;
    #state;
    #startFn = null;
    storage = [0, 0];
    
    constructor (opts) {
      if (opts?.componentIdx === undefined) {
        throw new TypeError('missing component id during thread creation');
      }
      this.#componentIdx = opts.componentIdx;
      
      if (!opts?.task) {
        throw new TypeError('missing task during thread creation');
      }
      this.#task = opts.task;
      
      // Explicitly spawned threads provide a `startFn` and begin
      // NOT_STARTED; the task's own implicit thread has none and
      // is already running by the time it's constructed.
      if (opts.startFn) {
        this.#startFn = opts.startFn;
        this.#state = AsyncThread.State.NOT_STARTED;
      } else {
        this.#state = AsyncThread.State.RUNNING;
      }
    }
    
    id() { return this.#id; }
    setId(id) {
      if (this.#id !== null) { throw new Error('thread id can only be assigned once'); }
      this.#id = id;
    }
    componentIdx() { return this.#componentIdx; }
    task() { return this.#task; }
    taskID() { return this.#task.id(); }
    state() { return this.#state; }
    
    // Delegate task-scoped bookkeeping that doesn't yet have a
    // thread-specific notion (cancellation, progress waiters,
    // the subtask this task is answering) to the owning task.
    isCancelled() { return this.#task.isCancelled(); }
    isRejected() { return this.#task.isRejected(); }
    notifyProgress() { return this.#task.notifyProgress(); }
    entryFnName() { return this.#task.entryFnName(); }
    getParentSubtask() { return this.#task.getParentSubtask(); }
    
    async suspend(opts) {
      const cstate = getOrCreateAsyncState(this.#componentIdx);
      const task = this.#task;
      task.endFirstSlice();
      task.settleCompletion();
      const { cancellable, readyFn, releaseLock = true } = opts;
      if (task.deliverPendingCancel({ cancellable })) { return false; }
      const reacquireLock = releaseLock && task.needsExclusiveLock() && cstate.exclusivelyLockedBy(task.id());
      if (reacquireLock) { cstate.exclusiveRelease(task.id()); }
      try {
        const keepGoing = await cstate.suspendThread({
          ...opts,
          thread: this,
          readyFn: () => (cancellable && task.cancellationPending()) || readyFn(),
        });
        cstate.throwIfInterrupted();
        if (keepGoing && task.deliverPendingCancel({ cancellable })) { return false; }
        return keepGoing;
      } finally {
        if (reacquireLock && !cstate.exclusivelyLockedBy(task.id())) {
          await cstate.acquireExclusiveLock(task.id());
        }
      }
    }
    
    // Begins running a NOT_STARTED (explicitly spawned) thread's
    // start function. Runs detached -- the caller (`thread.resume-later`)
    // does not wait for the thread to finish or even reach its first
    // suspension point.
    start() {
      if (this.#state !== AsyncThread.State.NOT_STARTED) {
        throw new Error(`cannot start thread [${this.#id}] in state [${this.#state}]`);
      }
      this.#state = AsyncThread.State.RUNNING;
      const startFn = this.#startFn;
      this.#startFn = null;
      
      _withGlobalCurrentThreadMetaAsync({
        threadID: this.#id,
        taskID: this.#task.id(),
        componentIdx: this.#componentIdx,
        fn: () => {
          getOrCreateAsyncState(this.#componentIdx).throwIfInterrupted();
          return startFn();
        },
      }).then(() => {
        this.#state = AsyncThread.State.COMPLETED;
        this.#task.removeThread(this);
      }).catch((err) => {
        err = _recordTrap(this.#componentIdx, err);
        this.#state = AsyncThread.State.COMPLETED;
        _debugLog('[AsyncThread#start()] spawned thread errored', {
          threadID: this.#id,
          taskID: this.#task.id(),
          componentIdx: this.#componentIdx,
          err,
        });
        this.#task.setErrored(err);
        this.#task.reject(err);
        this.#task.removeThread(this);
      });
    }
  }
  
  function createNewCurrentImplicitThread(args) {
    _debugLog('[createNewCurrentImplicitThread()] args', args);
    const {
      componentIdx,
      isAsync,
      isManualAsync,
      preserveFutureResult,
      entryFnName,
      parentSubtaskID,
      callbackFnName,
      getCallbackFn,
      getParamsFn,
      stringEncoding,
      errHandling,
      getCalleeParamsFn,
      resultPtr,
      callingWasmExport,
    } = args;
    if (componentIdx === undefined || componentIdx === null) {
      throw new Error('missing/invalid component instance index while starting task');
    }
    let taskMetas = ASYNC_TASKS_BY_COMPONENT_IDX.get(componentIdx);
    const callbackFn = getCallbackFn ? getCallbackFn() : null;
    
    const newTask = new AsyncTask({
      componentIdx,
      isAsync,
      isManualAsync,
      preserveFutureResult,
      entryFnName,
      callbackFn,
      callbackFnName,
      stringEncoding,
      getCalleeParamsFn,
      resultPtr,
      errHandling,
      callingWasmExport,
    });
    
    const newTaskID = newTask.id();
    const newTaskMeta = { id: newTaskID, componentIdx, task: newTask };
    
    // Every task starts with a single implicit thread, registered
    // the same way as explicitly spawned ones (`thread.new-indirect`):
    // `addThread` assigns its real, instance-scoped id.
    const newThread = newTask.addThread(new AsyncThread({
      componentIdx,
      task: newTask,
    }));
    const newThreadID = newThread.id();
    
    // NOTE: do not track host tasks
    ASYNC_CURRENT_TASK_IDS.push(newTaskID);
    ASYNC_CURRENT_COMPONENT_IDXS.push(componentIdx);
    
    if (!taskMetas) {
      taskMetas = [newTaskMeta];
      ASYNC_TASKS_BY_COMPONENT_IDX.set(componentIdx, [newTaskMeta]);
    } else {
      taskMetas.push(newTaskMeta);
    }
    
    return { task: newTask, thread: newThread, taskID: newTaskID, threadID: newThreadID };
  }
  
  function _checkMayLeave(componentIdx) {
    if (INSTANCE_FLAGS.get(componentIdx)?.value !== 1) {
      throw new WebAssemblyRuntimeError('cannot leave component instance');
    }
  }
  
  function _setGlobalCurrentThreadMeta(args) {
    if (!args) { throw new TypeError('args missing'); }
    if (args.taskID === undefined) { throw new TypeError('missing task ID'); }
    if (args.componentIdx === undefined) { throw new TypeError('missing component idx'); }
    if (args.threadID === undefined) { throw new TypeError('missing thread ID'); }
    const { taskID, threadID, componentIdx } = args;
    return CURRENT_TASK_META.current =
    CURRENT_TASK_META[componentIdx] = { threadID, taskID, componentIdx };
  }
  
  
  async function _clearCurrentTask(args) {
    _debugLog('[_clearCurrentTask()] args', args);
    if (!args) { throw new TypeError('args missing'); }
    if (args.taskID === undefined) { throw new TypeError('missing task ID'); }
    if (args.threadID === undefined) { throw new TypeError('missing thread ID'); }
    if (args.componentIdx === undefined) { throw new TypeError('missing component idx'); }
    const { taskID, threadID, componentIdx } = args;
    
    const meta = CURRENT_TASK_META[componentIdx];
    if (!meta) { throw new Error(`missing current thread meta for component idx [${componentIdx}]`); }
    
    if (meta.threadID !== threadID) {
      throw new Error(`thread ID [${meta.threadID}] != requested ID [${threadID}]`);
    }
    if (meta.taskID !== taskID) {
      throw new Error(`task ID [${meta.taskID}] != requested ID [${taskID}]`);
    }
    if (meta.componentIdx !== componentIdx) {
      throw new Error(`component idx [${meta.componentIdx}] != requested idx [${componentIdx}]`);
    }
    
    CURRENT_TASK_META[componentIdx] = null;
    if (CURRENT_TASK_META.current?.threadID === threadID &&
    CURRENT_TASK_META.current?.taskID === taskID) {
      CURRENT_TASK_META.current = null;
    }
  }
  
  function _lowerImportBackwardsCompat(args) {
    const params = [...arguments].slice(1);
    _debugLog('[_lowerImportBackwardsCompat()] args', { args, params });
    const {
      functionIdx,
      componentIdx,
      isAsync,
      isManualAsync,
      paramLiftFns,
      resultLowerFns,
      hasResultPointer,
      funcTypeIsAsync,
      metadata,
      memoryIdx,
      getMemoryFn,
      getReallocFn,
      importFn,
      stringEncoding,
    } = args;
    
    _checkMayLeave(componentIdx);
    
    const meta = _getGlobalCurrentThreadMeta(componentIdx);
    let taskMeta = meta && getCurrentTask(componentIdx, meta.taskID);
    let createdTask;
    
    // Some components depend on initialization logic (i.e. `_initialize` or some such
    // core wasm export) that is embedded in the component, but is not executed or wizer'd
    // away before the transpiled component is attempted to be used.
    //
    // These components execut their initialization logic *when they are imported* in the
    // transpiled context -- so we may get a call to an export that is lowered without going
    // through `CallWasm` or `CallInterface`.
    //
    // A nested synchronous call can leave global metadata for a task
    // that has already exited. Treat it like a call with no current task.
    if (!taskMeta) {
      if (funcTypeIsAsync || (isAsync && !isManualAsync)) {
        throw new Error('p3 async wasm exports cannot use backwards compat auto-task init');
      }
      
      const { task: newTask, taskID: newTaskID, threadID: newThreadID } = createNewCurrentImplicitThread({
        componentIdx,
        isAsync,
        isManualAsync,
        callingWasmExport: false,
      });
      createdTask = newTask;
      
      // Since we're managing the task creation ourselves we must clear ourselves
      createdTask.registerOnResolveHandler(() => {
        _clearCurrentTask({
          taskID: task.id(),
          threadID: newThreadID,
          componentIdx: task.componentIdx(),
        });
      });
      
      _setGlobalCurrentThreadMeta({
        componentIdx,
        taskID: newTaskID,
        threadID: newThreadID,
      });
      
      taskMeta = getCurrentTask(componentIdx, newTaskID);
    }
    if (!taskMeta) {
      throw new Error('invalid/missing async task meta');
    }
    
    const task = taskMeta.task;
    if (!task) { throw new Error('invalid/missing async task'); }
    
    const cstate = getOrCreateAsyncState(componentIdx);
    
    if (!task.mayBlock() && funcTypeIsAsync && !isAsync) {
      throw new Error("non async exports cannot synchronously call async functions");
    }
    
    // If there is an existing task, this should be part of a subtask
    const memory = getMemoryFn();
    // Canonical ABI lower appends result storage as a trailing
    // param when async lower has any flat result, or sync lower
    // has more than one flat result.
    const resultPtr = hasResultPointer ? params[params.length - 1] >>> 0 : undefined;
    const subtask = task.createSubtask({
      componentIdx,
      parentTask: task,
      fnName: importFn.fnName,
      isAsync,
      isManualAsync,
      callMetadata: {
        memoryIdx,
        memory,
        realloc: getReallocFn?.(),
        getReallocFn,
        resultPtr,
        lowers: resultLowerFns,
        funcTypeIsAsync,
        stringEncoding,
      }
    });
    task.setReturnMemoryIdx(memoryIdx);
    task.setReturnMemory(getMemoryFn());
    
    subtask.onStart();
    
    // If dealing with a sync lowered sync function, we can directly return results
    //
    // TODO(breaking): remove once we get rid of manual async import specification,
    // as func types cannot be detected in that case only (and we don't need that w/ p3)
    if (!isManualAsync && !isAsync && !funcTypeIsAsync) {
      if (createdTask) { createdTask.enterSync(); }
      
      const res = importFn(...params);
      
      // TODO(breaking): remove once we get rid of manual async import specification,
      // as func types cannot be detected in that case only (and we don't need that w/ p3)
      if (!funcTypeIsAsync && !subtask.isReturned()) {
        throw new Error('post-execution subtasks must either be async or returned');
      }
      
      const syncRes = subtask.getResult();
      if (createdTask) { createdTask.resolve([syncRes]); }
      
      return syncRes;
    }
    
    // Sync-lowered async functions requires async behavior because the callee *can* block,
    // but this call must *act* synchronously and return immediately with the result
    // (i.e. not returning until the work is done)
    //
    // TODO(breaking): remove checking for manual async specification here, once we can go p3-only
    //
    if (!isManualAsync && !isAsync && funcTypeIsAsync) {
      const { promise, resolve, reject } = promiseWithResolvers();
      queueMicrotask(async () => {
        try {
          await importFn(...params);
          if (!subtask.isResolved()) {
            await task.suspendUntil({ readyFn: () => subtask.isResolved() });
          }
          resolve(subtask.getResult());
        } catch (err) {
          reject(err);
        }
      });
      return promise;
    }
    
    // NOTE: at this point we know that we are working with an async lowered import
    
    const subtaskState = subtask.getStateNumber();
    if (subtaskState < 0 || subtaskState >= 2**4) {
      throw new Error('invalid subtask state, out of valid range');
    }
    
    subtask.setOnProgressFn(() => {
      subtask.setPendingEvent(() => {
        if (subtask.isResolved()) { subtask.deliverResolve(); }
        const event = {
          code: ASYNC_EVENT_CODE.SUBTASK,
          payload0: subtask.waitableRep(),
          payload1: subtask.getStateNumber(),
        }
        return event;
      });
    });
    
    // This is a hack to maintain backwards compatibility with
    // manually-specified async imports, used in wasm exports that are
    // not actually async (but are specified as so).
    //
    // This is not normal p3 sync behavior but instead anticipating that
    // the caller that is doing manual async will be given the *actual* result,
    // or a promise that resolves to it.
    //
    // TODO(breaking): remove once manually specified async is removed
    //
    // There are a few cases:
    // 1. sync function with async types (e.g. `f: func() -> stream<u32>`)
    // 2. async function with async types (e.g. `f: async func() -> stream<u32>`)
    // 3. async function with sync types (e.g. `f: async func() -> list<u32>`)
    // 4. sync function with non-async types (e.g. `f: func() -> list<u32>`)
    //
    // This hack *only* applies to 4 -- the case where an async JS host function
    // is supplied to a Wasm export which does *not* need to do any async abi
    // lifting/lowering (async ABI did not exist when JSPI integratiton was
    // initially merged to enable asynchronously returning values from the host)
    //
    // The host is called now rather than in a microtask, so that a host which
    // answers synchronously is answered synchronously: a task that cannot block
    // (e.g. a resource destructor) traps on a promise.
    if (!isAsync && !funcTypeIsAsync && isManualAsync) {
      _debugLog('[_lowerImportBackwardsCompat()] calling lowered import', { importFn, params });
      if (createdTask) { createdTask.enterSync(); }
      try {
        const res = importFn(...params);
        const isPromise = res !== null &&
        (typeof res === 'object' || typeof res === 'function') &&
        typeof res.then === 'function';
        // Without a current task the call cannot block, and its caller
        // traps on a promise, so a task created for it ends now.
        if (createdTask) { createdTask.resolve([isPromise ? undefined : res]); }
        if (!isPromise) { return subtask.getResult(); }
        return Promise.resolve(res).then(() => subtask.getResult());
      } catch (err) {
        if (createdTask) { createdTask.reject(err); }
        throw err;
      } finally {
        // Resolution delivers the result; exit retires the implicit
        // thread and removes the task from the component's registry.
        if (createdTask) { createdTask.exit(); }
      }
    }
    
    queueMicrotask(async () => {
      try {
        _debugLog('[_lowerImportBackwardsCompat()] calling lowered import', { importFn, params });
        if (createdTask) { await createdTask.enter(); }
        
        const asyncRes = await importFn(...params);
        if (createdTask) { createdTask.resolve([asyncRes]); }
      } catch (err) {
        _debugLog("[_lowerImportBackwardsCompat()] import fn error:", err);
        task.setErrored(err);
        task.reject(err);
      }
    });
    
    _debugLog('[_lowerImportBackwardsCompat()] async-lowered import return', {
      fnName: importFn.fnName,
      componentIdx,
      subtaskID: subtask.id(),
      waitableRep: subtask.waitableRep(),
      subtaskState,
      packedResult: Number(subtask.waitableRep()) << 4 | subtaskState,
    });
    
    return Number(subtask.ensureHandle()) << 4 | subtaskState;
  }
  
  const CURRENT_TASK_MAY_BLOCK= typeof WebAssembly !== 'undefined' ? new WebAssembly.Global({ value: 'i32', mutable: true }, 0) : false;
  
  
  function _liftFlatU32(ctx) {
    _debugLog('[_liftFlatU32()] args', { ctx });
    let val;
    
    if (ctx.useDirectParams) {
      if (ctx.params.length === 0) { throw new Error('expected at least a single i34 argument'); }
      // core i32 values arrive as signed numbers
      val = ctx.params[0] >>> 0;
      ctx.params = ctx.params.slice(1);
      return [val, ctx];
    }
    
    if (ctx.storageLen !== undefined && ctx.storageLen < 4) {
      throw new Error(`insufficient storage ([${ctx.storageLen}] bytes) for lift (u32 requires 4 bytes)`);
    }
    val = new DataView(ctx.memory.buffer).getUint32(ctx.storagePtr, true);
    ctx.storagePtr += 4;
    if (ctx.storageLen !== undefined) { ctx.storageLen -= 4; }
    
    return [val, ctx];
  }
  
  
  function _liftFlatStringUTF8(ctx) {
    _debugLog('[_liftFlatStringUTF8()] args', { ctx });
    let val;
    
    if (ctx.useDirectParams) {
      if (ctx.params.length < 2) { throw new Error('expected at least two u32 arguments'); }
      let offset = ctx.params[0];
      if (typeof offset === 'bigint') { offset = Number(offset); } else { offset >>>= 0; }
      if (!Number.isSafeInteger(offset)) { throw new Error('invalid offset'); }
      const len = ctx.params[1];
      if (!Number.isSafeInteger(len)) {  throw new Error('invalid len'); }
      val = TEXT_DECODER_UTF8.decode(new DataView(ctx.memory.buffer, offset, len));
      ctx.params = ctx.params.slice(2);
      return [val, ctx];
    }
    
    const rem = ctx.storagePtr % 4;
    if (rem !== 0) { ctx.storagePtr += (4 - rem); }
    
    const dv = new DataView(ctx.memory.buffer);
    const start = dv.getUint32(ctx.storagePtr, true);
    const codeUnits = dv.getUint32(ctx.storagePtr + 4, true);
    
    val = TEXT_DECODER_UTF8.decode(new Uint8Array(ctx.memory.buffer, start, codeUnits));
    
    ctx.storagePtr += 8;
    if (ctx.storageLen !== undefined) { ctx.storageLen -= 8; }
    
    return [val, ctx];
  }
  
  function _liftFlatStringUTF16(ctx) {
    _debugLog('[_liftFlatStringUTF16()] args', { ctx });
    let val;
    
    if (ctx.useDirectParams) {
      if (ctx.params.length < 2) { throw new Error('expected at least two u32 arguments'); }
      let offset = ctx.params[0];
      if (typeof offset === 'bigint') { offset = Number(offset); } else { offset >>>= 0; }
      if (!Number.isSafeInteger(offset)) {  throw new Error('invalid offset'); }
      const len = ctx.params[1];
      if (!Number.isSafeInteger(len)) {  throw new Error('invalid len'); }
      val = utf16Decoder.decode(new DataView(ctx.memory.buffer, offset, len * 2));
      ctx.params = ctx.params.slice(2);
      return [val, ctx];
    }
    
    const rem = ctx.storagePtr % 4;
    if (rem !== 0) { ctx.storagePtr += (4 - rem); }
    
    const dv = new DataView(ctx.memory.buffer);
    const start = dv.getUint32(ctx.storagePtr, true);
    const codeUnits = dv.getUint32(ctx.storagePtr + 4, true);
    
    val = utf16Decoder.decode(new DataView(ctx.memory.buffer, start, codeUnits * 2));
    
    ctx.storagePtr += 8;
    if (ctx.storageLen !== undefined) { ctx.storageLen -= 8; }
    
    return [val, ctx];
  }
  
  function _liftFlatStringAny(ctx) {
    switch (ctx.stringEncoding) {
      case 'utf8':
      return _liftFlatStringUTF8(ctx);
      case 'utf16':
      return _liftFlatStringUTF16(ctx);
      default:
      throw new Error(`missing/unrecognized/unsupported string encoding [${ctx.stringEncoding}]`);
    }
  }
  
  function _trackHostOperation(operation) {
    const result = operation();
    if (result === null ||
    (typeof result !== 'object' && typeof result !== 'function') ||
    typeof result.then !== 'function') {
      return result;
    }
    
    STORE_ASYNC_STATE.pendingHostOperations++;
    const tracked = Promise.resolve(result).finally(() => {
      STORE_ASYNC_STATE.pendingHostOperations--;
      if (STORE_ASYNC_STATE.pendingHostOperations < 0) {
        throw new Error('negative pending host operation count');
      }
      for (const state of ASYNC_STATE.values()) { state.runTickLoop(); }
      _checkForDeadlock();
    });
    
    // Forward disposal to the host's value, so it is notified if a guest
    // discards the value (e.g. a future) produced from this operation
    for (const sym of [Symbol.asyncDispose, symbolDispose]) {
      if (typeof sym === 'symbol' && typeof result[sym] === 'function') {
        tracked[sym] = () => result[sym]();
      }
    }
    
    return tracked;
  }
  
  function _guardMayLeave(componentIdx, fn) {
    return function (...args) {
      _checkMayLeave(componentIdx);
      return fn.apply(this, args);
    };
  }
  
  function _guardTrap(componentIdx, fn, convertsRangeErrors = false) {
    return function (...args) {
      try {
        return fn.apply(this, args);
      } catch (err) {
        throw _recordTrap(componentIdx, err, convertsRangeErrors);
      }
    };
  }
  
  const base64Compile = str => WebAssembly.compile(
  typeof Buffer !== 'undefined'
  ? Buffer.from(str, 'base64')
  : Uint8Array.from(atob(str), b => b.charCodeAt(0))
  );
  
  
  const isNode = typeof process !== 'undefined' && process.versions && process.versions.node;
  let _fs;
  async function fetchCompile (url) {
    if (isNode) {
      _fs = _fs || await import('node:fs/promises');
      return WebAssembly.compile(await _fs.readFile(url));
    }
    return fetch(url).then(WebAssembly.compileStreaming);
  }
  
  const symbolRscHandle = Symbol('handle');
  
  const HANDLE_TABLES= [];
  
  
  function finalizationRegistryCreate (unregister) {
    if (typeof FinalizationRegistry === 'undefined') {
      return { unregister () {} };
    }
    return new FinalizationRegistry(unregister);
  }
  
  class ComponentError extends Error {
    constructor (value) {
      const enumerable = typeof value !== 'string';
      super(enumerable ? `${String(value)} (see error.payload)` : value);
      Object.defineProperty(this, 'payload', { value, enumerable });
    }
  }
  
  const instantiateCore = WebAssembly.instantiate;
  
  function _suspendingImport(componentIdx, fn, syncOnly = false, switchesTask = false, convertsRangeErrors = true, callsHost = false) {
    return function (...args) {
      _checkMayLeave(componentIdx);
      const saved = CURRENT_TASK_META[componentIdx] ?? null;
      
      const savedThread = saved
      ? getCurrentThread(saved.componentIdx, saved.threadID, saved.taskID)
      : null;
      const mayBlock = savedThread
      ? (savedThread?.task.mayBlock() ?? (CURRENT_TASK_MAY_BLOCK.value !== 0))
      : false;
      if (!saved && !mayBlock && !callsHost) {
        throw new WebAssemblyRuntimeError('cannot block a synchronous task before returning');
      }
      
      if (syncOnly || !mayBlock) {
        let result;
        try {
          result = fn.apply(null, args);
        } catch (err) {
          CURRENT_TASK_META[componentIdx] = saved;
          if (!switchesTask) { CURRENT_TASK_META.current = saved; }
          // A trap is recorded before it propagates: nothing else in
          // the store may run after it, not even a queued call.
          throw _recordTrap(componentIdx, err, convertsRangeErrors);
        }
        
        CURRENT_TASK_META[componentIdx] = saved;
        if (!switchesTask) { CURRENT_TASK_META.current = saved; }
        
        if (result !== null &&
        (typeof result === 'object' || typeof result === 'function') &&
        typeof result.then === 'function') {
          // The helper may already have returned a rejected promise.
          // Mark it handled before replacing it with the canonical
          // synchronous-task trap.
          Promise.resolve(result).catch(() => {});
          throw new WebAssemblyRuntimeError('cannot block a synchronous task before returning');
        }
        return result;
      }
      
      return (async () => {
        try {
          const result = await fn.apply(null, args);
          // The instance trapped while this stack was suspended: it
          // must not resume into guest code (Canonical ABI).
          getOrCreateAsyncState(componentIdx).throwIfInterrupted();
          return result;
        } catch (err) {
          throw _recordTrap(componentIdx, err, convertsRangeErrors);
        } finally {
          CURRENT_TASK_META[componentIdx] = saved;
          if (!switchesTask) { CURRENT_TASK_META.current = saved; }
        }
      })();
    };
  }
  
  
  let exports0;
  let exports1;
  let memory0;
  
  const _trampoline1 = function(arg0, arg1, arg2) {
    var ptr0 = (arg1 >>> 0) >>> 0;
    var len0 = arg2;
    var result0 = utf16Decoder.decode(new Uint16Array(memory0.buffer, ptr0, len0));
    _debugLog('[iface="moonfmi:adder/host@0.1.0", function="log"] [Instruction::CallInterface] (sync, @ enter)');
    const hostProvided = true;
    
    let parentTask;
    let task;
    let threadID;
    let subtask;
    
    const createTask = () => {
      ({ task, threadID } = createNewCurrentImplicitThread({
        componentIdx: -1,
        isAsync: false,
        entryFnName: 'log',
        getCallbackFn: () => null,
        callbackFnName: null,
        errHandling: 'none',
        callingWasmExport: false,
      }));
    };
    
    taskCreation: {
      parentTask = getCurrentTask(
      0,
      _getGlobalCurrentThreadMeta(0)?.taskID,
      )?.task;
      
      if (!parentTask) {
        createTask();
        break taskCreation;
      }
      
      createTask();
      
      if (hostProvided) {
        subtask = parentTask.getLatestSubtask();
        if (!subtask) {
          throw new Error(`Missing subtask (in parent task [${parentTask.id()}]) for host import, has the import been lowered? (ensure asyncImports are set properly)`);
        }
        task.setParentSubtask(subtask);
      }
    }
    
    const started = task.enterSync();
    let ret;
    
    
    try {
      _withGlobalCurrentThreadMeta({
        componentIdx: task.componentIdx(),
        taskID: task.id(),
        threadID,
        fn: () => _trackHostOperation(() => log(arg0 >>> 0, result0)),
      })
      ;
    } catch (err) {
      
      _debugLog('[Instruction::CallInterface] error during sync call', {
        taskID: task.id(),
        subtaskID: task.getParentSubtask()?.id(),
        err,
      });
      getOrCreateAsyncState(0).markTrapped(err);
      task.setErrored(err);
      task.reject(err);
      task.exit();
      throw err;
      
    }
    
    _debugLog('[iface="moonfmi:adder/host@0.1.0", function="log"][Instruction::Return]', {
      funcName: 'log',
      paramCount: 0,
      async: false,
      postReturn: false
    });
    task.resolve([ret]);
    task.exit();
  }
  _trampoline1.fnName = 'moonfmi:adder/host@0.1.0#log';
  let exports2;
  let postReturn0;
  let postReturn0Async;
  let postReturn1;
  let postReturn1Async;
  let postReturn2;
  let postReturn2Async;
  
  const handleTable0 = [T_FLAG, 0];
  handleTable0._createdReps = new Set();
  handleTable0._componentIdx = 0;
  const finalizationRegistry0 = finalizationRegistryCreate((handle) => {
    const { rep } = rscTableRemove(handleTable0, handle);
    exports0["1"](rep);
  });
  
  HANDLE_TABLES[0] = handleTable0;
  let cs010ConstructorFmu;
  
  class Fmu{
    constructor() {
      
      const hostProvided = false;
      getOrCreateAsyncState(0).throwIfTrapped();
      
      const { task, threadID } = createNewCurrentImplicitThread({
        componentIdx: 0,
        isAsync: false,
        isManualAsync: false,
        preserveFutureResult: false,
        entryFnName: 'cs010ConstructorFmu',
        getCallbackFn: () => null,
        callbackFnName: null,
        errHandling: 'none',
        callingWasmExport: true,
      });
      task.setCalleeIsAsync(false);
      task.setFuncTypeIsAsync(false);
      task.setReturnResultTypeIdx(2);
      
      const started = task.enterSync();
      CURRENT_TASK_MAY_BLOCK.value = task.mayBlock() ? 1 : 0;
      
      if (null!== null) {
        task.setReturnMemoryIdx(null);
        task.setReturnMemory((() => null)());
      }
      
      
      return _withGlobalCurrentThreadMeta({
        taskID: task.id(),
        threadID,
        componentIdx: task.componentIdx(),
        fn: () => {
          try {
            
            _debugLog('[iface="moonfmi:adder/cs@0.1.0", function="[constructor]fmu"][Instruction::CallWasm] enter', {
              funcName: '[constructor]fmu',
              paramCount: 0,
              async: false,
              postReturn: false,
            });
            
            let ret;
            
            try {
              ret =  _withGlobalCurrentThreadMeta({
                taskID: task.id(),
                threadID,
                componentIdx: task.componentIdx(),
                fn: () => cs010ConstructorFmu(),
              });
            } catch (err) {
              
              _debugLog('[Instruction::CallWasm] error during sync call', {
                taskID: task.id(),
                err,
              });
              getOrCreateAsyncState(0).markTrapped(err);
              task.setErrored(err);
              task.reject(err);
              task.exit();
              throw err;
              
            }
            task.endFirstSlice();
            
            var handle1 = ret;
            var rsc0 = new.target === Fmu ? this : Object.create(Fmu.prototype);
            Object.defineProperty(rsc0, symbolRscHandle, { writable: true, value: handle1});
            finalizationRegistry0.register(rsc0, handle1, rsc0);
            Object.defineProperty(rsc0, symbolDispose, { writable: true, value: function () {
              finalizationRegistry0.unregister(rsc0);
              const handleEntry = rscTableRemove(handleTable0, handle1);
              rsc0[symbolDispose] = emptyFunc;
              rsc0[symbolRscHandle] = undefined;
              exports0["1"](handleEntry.rep);
            }});
            _debugLog('[iface="moonfmi:adder/cs@0.1.0", function="[constructor]fmu"][Instruction::Return]', {
              funcName: '[constructor]fmu',
              paramCount: 1,
              async: false,
              postReturn: false
            });
            task.resolve([rsc0]);
            task.exit();
            return rsc0;
            
          } catch (err) {
            if (!task.isResolvedState()) {
              task.setErrored(err);
              task.reject(err);
            }
            if (!task.isExited()) { task.exit({ skipExclusiveLockCheck: true }); }
            throw err;
          }
        },
      });
      
    }
  }
  let cs010MethodFmuGetVersion;
  
  Fmu.prototype.getVersion = function getVersion() {
    
    const hostProvided = false;
    getOrCreateAsyncState(0).throwIfTrapped();
    
    const { task, threadID } = createNewCurrentImplicitThread({
      componentIdx: 0,
      isAsync: false,
      isManualAsync: false,
      preserveFutureResult: false,
      entryFnName: 'cs010MethodFmuGetVersion',
      getCallbackFn: () => null,
      callbackFnName: null,
      errHandling: 'none',
      callingWasmExport: true,
    });
    task.setCalleeIsAsync(false);
    task.setFuncTypeIsAsync(false);
    task.setReturnResultTypeIdx(4);
    
    const started = task.enterSync();
    CURRENT_TASK_MAY_BLOCK.value = task.mayBlock() ? 1 : 0;
    
    if (0!== null) {
      task.setReturnMemoryIdx(0);
      task.setReturnMemory((() => memory0)());
    }
    
    
    return _withGlobalCurrentThreadMeta({
      taskID: task.id(),
      threadID,
      componentIdx: task.componentIdx(),
      fn: () => {
        try {
          
          
          if (!(this instanceof Fmu)) {
            throw new TypeError('Resource error: Not a valid \"Fmu\" resource.');
          }
          
          
          var handle1 = this[symbolRscHandle];
          if (!handle1 || !(handleTable0[(handle1 << 1) + 1] >= T_OWN)) {
            throw new TypeError('Resource error: Not a valid \"Fmu\" resource.');
          }
          var handle0 = handleTable0[(handle1 << 1) + 1] - T_OWN;
          
          _debugLog('[iface="moonfmi:adder/cs@0.1.0", function="[method]fmu.get-version"][Instruction::CallWasm] enter', {
            funcName: '[method]fmu.get-version',
            paramCount: 1,
            async: false,
            postReturn: true,
          });
          
          let ret;
          
          try {
            ret =  _withGlobalCurrentThreadMeta({
              taskID: task.id(),
              threadID,
              componentIdx: task.componentIdx(),
              fn: () => cs010MethodFmuGetVersion(handle0),
            });
          } catch (err) {
            
            _debugLog('[Instruction::CallWasm] error during sync call', {
              taskID: task.id(),
              err,
            });
            getOrCreateAsyncState(0).markTrapped(err);
            task.setErrored(err);
            task.reject(err);
            task.exit();
            throw err;
            
          }
          task.endFirstSlice();
          
          var ptr2 = dataView(memory0).getUint32(((ret >>> 0)) + 0, true) >>> 0;
          var len2 = dataView(memory0).getUint32(((ret >>> 0)) + 4, true);
          var result2 = utf16Decoder.decode(new Uint16Array(memory0.buffer, ptr2, len2));
          _debugLog('[iface="moonfmi:adder/cs@0.1.0", function="[method]fmu.get-version"][Instruction::Return]', {
            funcName: '[method]fmu.get-version',
            paramCount: 1,
            async: false,
            postReturn: true
          });
          task.resolve([result2]);
          const retCopy = result2;
          
          let cstate = getOrCreateAsyncState(0);
          cstate.mayLeave = false;
          try {
            postReturn0(ret);
          } catch (err) {
            err = _postReturnTrap(0, err);
            // Cleanup can fail after the result was recorded.
            task.reject(err);
            throw err;
          }
          cstate.mayLeave = true;
          task.exit();
          return retCopy;
          
          
        } catch (err) {
          if (!task.isResolvedState()) {
            task.setErrored(err);
            task.reject(err);
          }
          if (!task.isExited()) { task.exit({ skipExclusiveLockCheck: true }); }
          throw err;
        }
      },
    });
    
  };
  let cs010MethodFmuSetReal;
  
  Fmu.prototype.setReal = function setReal(arg1, arg2) {
    
    const hostProvided = false;
    getOrCreateAsyncState(0).throwIfTrapped();
    
    const { task, threadID } = createNewCurrentImplicitThread({
      componentIdx: 0,
      isAsync: false,
      isManualAsync: false,
      preserveFutureResult: false,
      entryFnName: 'cs010MethodFmuSetReal',
      getCallbackFn: () => null,
      callbackFnName: null,
      errHandling: 'none',
      callingWasmExport: true,
    });
    task.setCalleeIsAsync(false);
    task.setFuncTypeIsAsync(false);
    task.setReturnResultTypeIdx(1);
    
    const started = task.enterSync();
    CURRENT_TASK_MAY_BLOCK.value = task.mayBlock() ? 1 : 0;
    
    if (null!== null) {
      task.setReturnMemoryIdx(null);
      task.setReturnMemory((() => null)());
    }
    
    
    return _withGlobalCurrentThreadMeta({
      taskID: task.id(),
      threadID,
      componentIdx: task.componentIdx(),
      fn: () => {
        try {
          
          
          if (!(this instanceof Fmu)) {
            throw new TypeError('Resource error: Not a valid \"Fmu\" resource.');
          }
          
          
          var handle1 = this[symbolRscHandle];
          if (!handle1 || !(handleTable0[(handle1 << 1) + 1] >= T_OWN)) {
            throw new TypeError('Resource error: Not a valid \"Fmu\" resource.');
          }
          var handle0 = handleTable0[(handle1 << 1) + 1] - T_OWN;
          
          _debugLog('[iface="moonfmi:adder/cs@0.1.0", function="[method]fmu.set-real"][Instruction::CallWasm] enter', {
            funcName: '[method]fmu.set-real',
            paramCount: 3,
            async: false,
            postReturn: false,
          });
          
          let ret;
          
          try {
            _withGlobalCurrentThreadMeta({
              taskID: task.id(),
              threadID,
              componentIdx: task.componentIdx(),
              fn: () => cs010MethodFmuSetReal(handle0, toUint32(arg1), +arg2),
            });
          } catch (err) {
            
            _debugLog('[Instruction::CallWasm] error during sync call', {
              taskID: task.id(),
              err,
            });
            getOrCreateAsyncState(0).markTrapped(err);
            task.setErrored(err);
            task.reject(err);
            task.exit();
            throw err;
            
          }
          task.endFirstSlice();
          
          _debugLog('[iface="moonfmi:adder/cs@0.1.0", function="[method]fmu.set-real"][Instruction::Return]', {
            funcName: '[method]fmu.set-real',
            paramCount: 0,
            async: false,
            postReturn: false
          });
          task.resolve([ret]);
          task.exit();
          
        } catch (err) {
          if (!task.isResolvedState()) {
            task.setErrored(err);
            task.reject(err);
          }
          if (!task.isExited()) { task.exit({ skipExclusiveLockCheck: true }); }
          throw err;
        }
      },
    });
    
  };
  let cs010MethodFmuGetReal;
  
  Fmu.prototype.getReal = function getReal(arg1) {
    
    const hostProvided = false;
    getOrCreateAsyncState(0).throwIfTrapped();
    
    const { task, threadID } = createNewCurrentImplicitThread({
      componentIdx: 0,
      isAsync: false,
      isManualAsync: false,
      preserveFutureResult: false,
      entryFnName: 'cs010MethodFmuGetReal',
      getCallbackFn: () => null,
      callbackFnName: null,
      errHandling: 'none',
      callingWasmExport: true,
    });
    task.setCalleeIsAsync(false);
    task.setFuncTypeIsAsync(false);
    task.setReturnResultTypeIdx(7);
    
    const started = task.enterSync();
    CURRENT_TASK_MAY_BLOCK.value = task.mayBlock() ? 1 : 0;
    
    if (null!== null) {
      task.setReturnMemoryIdx(null);
      task.setReturnMemory((() => null)());
    }
    
    
    return _withGlobalCurrentThreadMeta({
      taskID: task.id(),
      threadID,
      componentIdx: task.componentIdx(),
      fn: () => {
        try {
          
          
          if (!(this instanceof Fmu)) {
            throw new TypeError('Resource error: Not a valid \"Fmu\" resource.');
          }
          
          
          var handle1 = this[symbolRscHandle];
          if (!handle1 || !(handleTable0[(handle1 << 1) + 1] >= T_OWN)) {
            throw new TypeError('Resource error: Not a valid \"Fmu\" resource.');
          }
          var handle0 = handleTable0[(handle1 << 1) + 1] - T_OWN;
          
          _debugLog('[iface="moonfmi:adder/cs@0.1.0", function="[method]fmu.get-real"][Instruction::CallWasm] enter', {
            funcName: '[method]fmu.get-real',
            paramCount: 2,
            async: false,
            postReturn: false,
          });
          
          let ret;
          
          try {
            ret =  _withGlobalCurrentThreadMeta({
              taskID: task.id(),
              threadID,
              componentIdx: task.componentIdx(),
              fn: () => cs010MethodFmuGetReal(handle0, toUint32(arg1)),
            });
          } catch (err) {
            
            _debugLog('[Instruction::CallWasm] error during sync call', {
              taskID: task.id(),
              err,
            });
            getOrCreateAsyncState(0).markTrapped(err);
            task.setErrored(err);
            task.reject(err);
            task.exit();
            throw err;
            
          }
          task.endFirstSlice();
          
          _debugLog('[iface="moonfmi:adder/cs@0.1.0", function="[method]fmu.get-real"][Instruction::Return]', {
            funcName: '[method]fmu.get-real',
            paramCount: 1,
            async: false,
            postReturn: false
          });
          task.resolve([ret]);
          task.exit();
          return ret;
          
        } catch (err) {
          if (!task.isResolvedState()) {
            task.setErrored(err);
            task.reject(err);
          }
          if (!task.isExited()) { task.exit({ skipExclusiveLockCheck: true }); }
          throw err;
        }
      },
    });
    
  };
  let cs010MethodFmuDoStep;
  
  Fmu.prototype.doStep = function doStep(arg1, arg2) {
    
    const hostProvided = false;
    getOrCreateAsyncState(0).throwIfTrapped();
    
    const { task, threadID } = createNewCurrentImplicitThread({
      componentIdx: 0,
      isAsync: false,
      isManualAsync: false,
      preserveFutureResult: false,
      entryFnName: 'cs010MethodFmuDoStep',
      getCallbackFn: () => null,
      callbackFnName: null,
      errHandling: 'throw-result-err',
      callingWasmExport: true,
    });
    task.setCalleeIsAsync(false);
    task.setFuncTypeIsAsync(false);
    task.setReturnResultTypeIdx(9);
    
    const started = task.enterSync();
    CURRENT_TASK_MAY_BLOCK.value = task.mayBlock() ? 1 : 0;
    
    if (0!== null) {
      task.setReturnMemoryIdx(0);
      task.setReturnMemory((() => memory0)());
    }
    
    
    return _withGlobalCurrentThreadMeta({
      taskID: task.id(),
      threadID,
      componentIdx: task.componentIdx(),
      fn: () => {
        try {
          
          
          if (!(this instanceof Fmu)) {
            throw new TypeError('Resource error: Not a valid \"Fmu\" resource.');
          }
          
          
          var handle1 = this[symbolRscHandle];
          if (!handle1 || !(handleTable0[(handle1 << 1) + 1] >= T_OWN)) {
            throw new TypeError('Resource error: Not a valid \"Fmu\" resource.');
          }
          var handle0 = handleTable0[(handle1 << 1) + 1] - T_OWN;
          
          _debugLog('[iface="moonfmi:adder/cs@0.1.0", function="[method]fmu.do-step"][Instruction::CallWasm] enter', {
            funcName: '[method]fmu.do-step',
            paramCount: 3,
            async: false,
            postReturn: true,
          });
          
          let ret;
          
          try {
            ret =  _withGlobalCurrentThreadMeta({
              taskID: task.id(),
              threadID,
              componentIdx: task.componentIdx(),
              fn: () => cs010MethodFmuDoStep(handle0, +arg1, +arg2),
            });
          } catch (err) {
            
            _debugLog('[Instruction::CallWasm] error during sync call', {
              taskID: task.id(),
              err,
            });
            getOrCreateAsyncState(0).markTrapped(err);
            task.setErrored(err);
            task.reject(err);
            task.exit();
            throw err;
            
          }
          task.endFirstSlice();
          
          let variant3;
          switch (dataView(memory0).getUint8(((ret >>> 0)) + 0, true)) {
            case 0: {
              variant3= {
                tag: 'ok',
                val: undefined
              };
              break;
            }
            case 1: {
              var ptr2 = dataView(memory0).getUint32(((ret >>> 0)) + 4, true) >>> 0;
              var len2 = dataView(memory0).getUint32(((ret >>> 0)) + 8, true);
              var result2 = utf16Decoder.decode(new Uint16Array(memory0.buffer, ptr2, len2));
              variant3= {
                tag: 'err',
                val: result2
              };
              break;
            }
            default: {
              throw new TypeError('invalid variant discriminant for expected');
            }
          }
          _debugLog('[iface="moonfmi:adder/cs@0.1.0", function="[method]fmu.do-step"][Instruction::Return]', {
            funcName: '[method]fmu.do-step',
            paramCount: 1,
            async: false,
            postReturn: true
          });
          const retCopy = variant3;
          task.resolve([retCopy]);
          
          let cstate = getOrCreateAsyncState(0);
          cstate.mayLeave = false;
          try {
            postReturn1(ret);
          } catch (err) {
            err = _postReturnTrap(0, err);
            // Cleanup can fail after the result was recorded.
            task.reject(err);
            throw err;
          }
          cstate.mayLeave = true;
          task.exit();
          
          
          
          if (typeof retCopy === 'object' && retCopy.tag === 'err') {
            throw new ComponentError(retCopy.val);
          }
          return retCopy.val;
          
          
        } catch (err) {
          if (!task.isResolvedState()) {
            task.setErrored(err);
            task.reject(err);
          }
          if (!task.isExited()) { task.exit({ skipExclusiveLockCheck: true }); }
          throw err;
        }
      },
    });
    
  };
  let cs010MethodFmuTerminate;
  
  Fmu.prototype.terminate = function terminate() {
    
    const hostProvided = false;
    getOrCreateAsyncState(0).throwIfTrapped();
    
    const { task, threadID } = createNewCurrentImplicitThread({
      componentIdx: 0,
      isAsync: false,
      isManualAsync: false,
      preserveFutureResult: false,
      entryFnName: 'cs010MethodFmuTerminate',
      getCallbackFn: () => null,
      callbackFnName: null,
      errHandling: 'none',
      callingWasmExport: true,
    });
    task.setCalleeIsAsync(false);
    task.setFuncTypeIsAsync(false);
    task.setReturnResultTypeIdx(1);
    
    const started = task.enterSync();
    CURRENT_TASK_MAY_BLOCK.value = task.mayBlock() ? 1 : 0;
    
    if (null!== null) {
      task.setReturnMemoryIdx(null);
      task.setReturnMemory((() => null)());
    }
    
    
    return _withGlobalCurrentThreadMeta({
      taskID: task.id(),
      threadID,
      componentIdx: task.componentIdx(),
      fn: () => {
        try {
          
          
          if (!(this instanceof Fmu)) {
            throw new TypeError('Resource error: Not a valid \"Fmu\" resource.');
          }
          
          
          var handle1 = this[symbolRscHandle];
          if (!handle1 || !(handleTable0[(handle1 << 1) + 1] >= T_OWN)) {
            throw new TypeError('Resource error: Not a valid \"Fmu\" resource.');
          }
          var handle0 = handleTable0[(handle1 << 1) + 1] - T_OWN;
          
          _debugLog('[iface="moonfmi:adder/cs@0.1.0", function="[method]fmu.terminate"][Instruction::CallWasm] enter', {
            funcName: '[method]fmu.terminate',
            paramCount: 1,
            async: false,
            postReturn: false,
          });
          
          let ret;
          
          try {
            _withGlobalCurrentThreadMeta({
              taskID: task.id(),
              threadID,
              componentIdx: task.componentIdx(),
              fn: () => cs010MethodFmuTerminate(handle0),
            });
          } catch (err) {
            
            _debugLog('[Instruction::CallWasm] error during sync call', {
              taskID: task.id(),
              err,
            });
            getOrCreateAsyncState(0).markTrapped(err);
            task.setErrored(err);
            task.reject(err);
            task.exit();
            throw err;
            
          }
          task.endFirstSlice();
          
          _debugLog('[iface="moonfmi:adder/cs@0.1.0", function="[method]fmu.terminate"][Instruction::Return]', {
            funcName: '[method]fmu.terminate',
            paramCount: 0,
            async: false,
            postReturn: false
          });
          task.resolve([ret]);
          task.exit();
          
        } catch (err) {
          if (!task.isResolvedState()) {
            task.setErrored(err);
            task.reject(err);
          }
          if (!task.isExited()) { task.exit({ skipExclusiveLockCheck: true }); }
          throw err;
        }
      },
    });
    
  };
  let cs010GetVersion;
  
  function getVersion() {
    
    const hostProvided = false;
    getOrCreateAsyncState(0).throwIfTrapped();
    
    const { task, threadID } = createNewCurrentImplicitThread({
      componentIdx: 0,
      isAsync: false,
      isManualAsync: false,
      preserveFutureResult: false,
      entryFnName: 'cs010GetVersion',
      getCallbackFn: () => null,
      callbackFnName: null,
      errHandling: 'none',
      callingWasmExport: true,
    });
    task.setCalleeIsAsync(false);
    task.setFuncTypeIsAsync(false);
    task.setReturnResultTypeIdx(4);
    
    const started = task.enterSync();
    CURRENT_TASK_MAY_BLOCK.value = task.mayBlock() ? 1 : 0;
    
    if (0!== null) {
      task.setReturnMemoryIdx(0);
      task.setReturnMemory((() => memory0)());
    }
    
    
    return _withGlobalCurrentThreadMeta({
      taskID: task.id(),
      threadID,
      componentIdx: task.componentIdx(),
      fn: () => {
        try {
          
          _debugLog('[iface="moonfmi:adder/cs@0.1.0", function="get-version"][Instruction::CallWasm] enter', {
            funcName: 'get-version',
            paramCount: 0,
            async: false,
            postReturn: true,
          });
          
          let ret;
          
          try {
            ret =  _withGlobalCurrentThreadMeta({
              taskID: task.id(),
              threadID,
              componentIdx: task.componentIdx(),
              fn: () => cs010GetVersion(),
            });
          } catch (err) {
            
            _debugLog('[Instruction::CallWasm] error during sync call', {
              taskID: task.id(),
              err,
            });
            getOrCreateAsyncState(0).markTrapped(err);
            task.setErrored(err);
            task.reject(err);
            task.exit();
            throw err;
            
          }
          task.endFirstSlice();
          
          var ptr0 = dataView(memory0).getUint32(((ret >>> 0)) + 0, true) >>> 0;
          var len0 = dataView(memory0).getUint32(((ret >>> 0)) + 4, true);
          var result0 = utf16Decoder.decode(new Uint16Array(memory0.buffer, ptr0, len0));
          _debugLog('[iface="moonfmi:adder/cs@0.1.0", function="get-version"][Instruction::Return]', {
            funcName: 'get-version',
            paramCount: 1,
            async: false,
            postReturn: true
          });
          task.resolve([result0]);
          const retCopy = result0;
          
          let cstate = getOrCreateAsyncState(0);
          cstate.mayLeave = false;
          try {
            postReturn2(ret);
          } catch (err) {
            err = _postReturnTrap(0, err);
            // Cleanup can fail after the result was recorded.
            task.reject(err);
            throw err;
          }
          cstate.mayLeave = true;
          task.exit();
          return retCopy;
          
          
        } catch (err) {
          if (!task.isResolvedState()) {
            task.setErrored(err);
            task.reject(err);
          }
          if (!task.isExited()) { task.exit({ skipExclusiveLockCheck: true }); }
          throw err;
        }
      },
    });
    
  }
  const trampoline0 = rscTableCreateOwn.bind(null, handleTable0);
  let trampoline1 = _lowerImportBackwardsCompat.bind(
  null,
  {
    trampolineIdx: 1,
    componentIdx: 0,
    isAsync: false,
    isManualAsync: _trampoline1.manuallyAsync,
    paramLiftFns: [_liftFlatU32,_liftFlatStringAny],
    resultLowerFns: [],
    hasResultPointer: false,
    funcTypeIsAsync: false,
    getCallbackFn: () => null,
    getPostReturnFn: () => null,
    isCancellable: false,
    memoryIdx: 0,
    stringEncoding: 'utf16',
    getMemoryFn: () => memory0,
    getReallocFn: undefined,
    importFn: _trampoline1,
  },
  );
  
  const $init = (() => {
    let gen= (function* _initGenerator () {
      const module0 = fetchCompile(new URL('./adder.core.wasm', import.meta.url));
      Promise.resolve(module0).catch(() => {});
      const module1 = base64Compile('AGFzbQEAAAABCwJgA39/fwBgAX8AAwMCAAEEBQFwAQICBxQDATAAAAExAAEIJGltcG9ydHMBAAoZAg0AIAAgASACQQARAAALCQAgAEEBEQEACwAvCXByb2R1Y2VycwEMcHJvY2Vzc2VkLWJ5AQ13aXQtY29tcG9uZW50BzAuMjYzLjAATgRuYW1lABMSd2l0LWNvbXBvbmVudDpzaGltATICACVpbmRpcmVjdC1tb29uZm1pOmFkZGVyL2hvc3RAMC4xLjAtbG9nAQhkdG9yLWZtdQ');
      Promise.resolve(module1).catch(() => {});
      const module2 = base64Compile('AGFzbQEAAAABCwJgA39/fwBgAX8AAioDBmFjdHVhbAEwAAAGYWN0dWFsATEAAQRzaGltCCRpbXBvcnRzAXABAgIJCAEAQQALAgABAC8JcHJvZHVjZXJzAQxwcm9jZXNzZWQtYnkBDXdpdC1jb21wb25lbnQHMC4yNjMuMAAlBG5hbWUAFRR3aXQtY29tcG9uZW50OmZpeHVwcwEHAgABMAEBMQ');
      Promise.resolve(module2).catch(() => {});
      const instanceFlags0 = new WebAssembly.Global({ value: "i32", mutable: true }, 1);
      INSTANCE_FLAGS.set(0, instanceFlags0);
      ({ exports: exports0 } = yield instantiateCore(yield module1));
      ({ exports: exports1 } = yield instantiateCore(yield module0, {
        "[export]moonfmi:adder/cs@0.1.0": {
          "[resource-new]fmu": Object.assign(_guardTrap(0, _guardMayLeave(0, trampoline0), true), { _jcoMaySuspend: false }),
        },
        "moonfmi:adder/host@0.1.0": {
          log: Object.assign(exports0["0"], { _jcoMaySuspend: false }),
        },
      }));
      memory0 = exports1.memory;
      ({ exports: exports2 } = yield instantiateCore(yield module2, {
        actual: {
          "0": Object.assign(_guardTrap(0, trampoline1, false), { _jcoMaySuspend: false }),
          "1": Object.assign(exports1["moonfmi:adder/cs@0.1.0#[dtor]fmu"], { _jcoMaySuspend: false }),
        },
        shim: {
          $imports: exports0.$imports,
        },
      }));
      postReturn0 = exports1["cabi_post_moonfmi:adder/cs@0.1.0#[method]fmu.get-version"];
      
      try {
        postReturn0Async = WebAssembly.promising(exports1["cabi_post_moonfmi:adder/cs@0.1.0#[method]fmu.get-version"]);
      } catch(err) {
        postReturn0Async = exports1["cabi_post_moonfmi:adder/cs@0.1.0#[method]fmu.get-version"];
      }
      
      postReturn1 = exports1["cabi_post_moonfmi:adder/cs@0.1.0#[method]fmu.do-step"];
      
      try {
        postReturn1Async = WebAssembly.promising(exports1["cabi_post_moonfmi:adder/cs@0.1.0#[method]fmu.do-step"]);
      } catch(err) {
        postReturn1Async = exports1["cabi_post_moonfmi:adder/cs@0.1.0#[method]fmu.do-step"];
      }
      
      postReturn2 = exports1["cabi_post_moonfmi:adder/cs@0.1.0#get-version"];
      
      try {
        postReturn2Async = WebAssembly.promising(exports1["cabi_post_moonfmi:adder/cs@0.1.0#get-version"]);
      } catch(err) {
        postReturn2Async = exports1["cabi_post_moonfmi:adder/cs@0.1.0#get-version"];
      }
      
      cs010ConstructorFmu = exports1["moonfmi:adder/cs@0.1.0#[constructor]fmu"];
      cs010MethodFmuGetVersion = exports1["moonfmi:adder/cs@0.1.0#[method]fmu.get-version"];
      cs010MethodFmuSetReal = exports1["moonfmi:adder/cs@0.1.0#[method]fmu.set-real"];
      cs010MethodFmuGetReal = exports1["moonfmi:adder/cs@0.1.0#[method]fmu.get-real"];
      cs010MethodFmuDoStep = exports1["moonfmi:adder/cs@0.1.0#[method]fmu.do-step"];
      cs010MethodFmuTerminate = exports1["moonfmi:adder/cs@0.1.0#[method]fmu.terminate"];
      cs010GetVersion = exports1["moonfmi:adder/cs@0.1.0#get-version"];
    })();
    let promise, resolve, reject;
    function normalizeInstantiationError(e) {
      // Native JSPI rejects a suspending import called from a
      // core start function before entering its JS wrapper.
      // At component instantiation time that always means the
      // implicit synchronous task attempted to block.
      if (typeof WebAssembly !== 'undefined' && typeof WebAssembly.SuspendError === 'function' && e instanceof WebAssembly.SuspendError) {
        return new WebAssembly.RuntimeError('cannot block a synchronous task before returning');
      }
      return e;
    }
    function runNext(value) {
      try {
        let done;
        do {
          ({ value, done } = gen.next(value));
        } while (!(value instanceof Promise) && !done);
        if (done) {
          if (resolve) resolve(value);
          else return value;
        }
        if (!promise) promise = new Promise((_resolve, _reject) => (resolve = _resolve, reject= _reject));
        value.then(runNext, e => reject(normalizeInstantiationError(e)));
      }
      catch (e) {
        e = normalizeInstantiationError(e);
        if (reject) reject(e);
        else throw e;
      }
    }
    const maybeSyncReturn = runNext(null);
    return promise || maybeSyncReturn;
  })();
  
  await $init;
  const cs010 = {
    Fmu: Fmu,
    getVersion: getVersion,
    
  };
  
  export { cs010 as cs, cs010 as "moonfmi:adder/cs@0.1.0",  }
  export const _util = {
    
  }
  
  