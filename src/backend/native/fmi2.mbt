///|
/// A loaded FMI 2.0.4 Co-Simulation library.
///
/// The shim resolves the exported `fmi2*` functions once, checks that the FMU
/// uses the `default` type platform and keeps the dynamic library loaded until
/// `close` is called. Instances borrow the library, so the library refuses to
/// unload while one of them is still alive.
pub struct Fmi2Library {
  library : DynamicLibrary
  shim : @c.Pointer[Unit]
  mut open_instances : Int32
  mut closed : Bool
}

///|
pub(all) suberror Fmi2Error {
  Fmi2LibraryLoad(DynamicLibraryError)
  Fmi2LibraryUnload(DynamicLibraryError)
  Fmi2ShimRejected(detail~ : String)
  Fmi2InstantiateFailed(instance_name~ : String, detail~ : String)
  Fmi2InstanceFreed(operation~ : String)
  Fmi2StatusFailed(operation~ : String, status~ : @fmi.FmiStatus)
  Fmi2InstancesAlive(count~ : Int32)
  // The FMU does not declare the capability the call needs.
  Fmi2CapabilityMissing(operation~ : String, capability~ : String)
}

///|
pub fn Fmi2Error::message(self : Fmi2Error) -> String {
  match self {
    Fmi2LibraryLoad(error) => error.message()
    Fmi2LibraryUnload(error) => error.message()
    Fmi2ShimRejected(detail~) =>
      "the FMU is not a usable FMI 2 library: " + detail
    Fmi2InstantiateFailed(instance_name~, detail~) =>
      "fmi2Instantiate failed for '" + instance_name + "': " + detail
    Fmi2InstanceFreed(operation~) =>
      "cannot call " + operation + " on a released FMI instance"
    Fmi2StatusFailed(operation~, status~) =>
      operation + " failed with status " + status.name()
    Fmi2CapabilityMissing(operation~, capability~) =>
      operation + " is not available: the FMU does not declare " + capability
    Fmi2InstancesAlive(count~) =>
      "the library still owns " +
      count.to_string() +
      " live instance(s); free them first"
  }
}

///|
/// A log message forwarded by the FMU.
///
/// Messages are truncated to 4096 bytes before decoding, on a UTF-8 character
/// boundary, so a truncated message is always valid text.
pub(all) struct Fmi2LogMessage {
  status : @fmi.FmiStatus
  instance_name : String
  category : String
  message : String
}

///|
struct Fmi2LogSink {
  callback : (Fmi2LogMessage) -> Unit
  mut active : Bool
}

///|
/// A live FMI 2 Co-Simulation instance.
///
/// The native component handle stays private; callers only see status codes,
/// doubles and log messages.
pub struct Fmi2Instance {
  library : Fmi2Library
  handle : @c.Pointer[Unit]
  sink : Fmi2LogSink
  mut freed : Bool
}

///|
#borrow(instance_name, guid, resource_path)
extern "C" fn fmi2_instance_new(
  library : @c.Pointer[Unit],
  instance_name : Bytes,
  guid : Bytes,
  resource_path : Bytes,
  interface_kind : Int32,
  logging_on : Int32,
  log_sink : (Int32, Bytes, Bytes, Bytes) -> Unit,
  log_deliver : FuncRef[
    ((Int32, Bytes, Bytes, Bytes) -> Unit, Int32, Bytes, Bytes, Bytes) -> Unit,
  ],
) -> @c.Pointer[Unit] = "moonfmi_fmi2_instance_new"

///|
extern "C" fn fmi2_library_new(handle : @c.Pointer[Unit]) -> @c.Pointer[Unit] = "moonfmi_fmi2_library_new"

///|
extern "C" fn fmi2_library_version(handle : @c.Pointer[Unit]) -> Bytes = "moonfmi_fmi2_library_version"

///|
extern "C" fn fmi2_library_free(handle : @c.Pointer[Unit]) -> Unit = "moonfmi_fmi2_library_free"

///|
extern "C" fn fmi2_instance_free(handle : @c.Pointer[Unit]) -> Unit = "moonfmi_fmi2_instance_free"

///|
extern "C" fn fmi2_instance_log_count(handle : @c.Pointer[Unit]) -> UInt64 = "moonfmi_fmi2_instance_log_count"

///|
extern "C" fn fmi2_instance_is_freed(handle : @c.Pointer[Unit]) -> Int32 = "moonfmi_fmi2_instance_is_freed"

///|
extern "C" fn fmi2_setup_experiment(
  handle : @c.Pointer[Unit],
  tolerance_defined : Int32,
  tolerance : Double,
  start_time : Double,
  stop_time_defined : Int32,
  stop_time : Double,
) -> Int32 = "moonfmi_fmi2_setup_experiment"

///|
extern "C" fn fmi2_enter_initialization_mode(
  handle : @c.Pointer[Unit],
) -> Int32 = "moonfmi_fmi2_enter_initialization_mode"

///|
extern "C" fn fmi2_exit_initialization_mode(handle : @c.Pointer[Unit]) -> Int32 = "moonfmi_fmi2_exit_initialization_mode"

///|
extern "C" fn fmi2_terminate(handle : @c.Pointer[Unit]) -> Int32 = "moonfmi_fmi2_terminate"

///|
extern "C" fn fmi2_do_step(
  handle : @c.Pointer[Unit],
  current_time : Double,
  step_size : Double,
  new_step : Int32,
) -> Int32 = "moonfmi_fmi2_do_step"

///|
#borrow(references, values)
extern "C" fn fmi2_get_real(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[Double],
  count : Int32,
) -> Int32 = "moonfmi_fmi2_get_real"

///|
#borrow(references, values)
extern "C" fn fmi2_set_real(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[Double],
  count : Int32,
) -> Int32 = "moonfmi_fmi2_set_real"

///|
extern "C" fn fmi2_last_error() -> Bytes = "moonfmi_fmi2_last_error"

///|
extern "C" fn fmi2_set_time(handle : @c.Pointer[Unit], time : Double) -> Int32 = "moonfmi_fmi2_set_time"

///|
#borrow(states)
extern "C" fn fmi2_set_continuous_states(
  handle : @c.Pointer[Unit],
  states : FixedArray[Double],
  count : Int32,
) -> Int32 = "moonfmi_fmi2_set_continuous_states"

///|
#borrow(states)
extern "C" fn fmi2_get_continuous_states(
  handle : @c.Pointer[Unit],
  states : FixedArray[Double],
  count : Int32,
) -> Int32 = "moonfmi_fmi2_get_continuous_states"

///|
#borrow(derivatives)
extern "C" fn fmi2_get_derivatives(
  handle : @c.Pointer[Unit],
  derivatives : FixedArray[Double],
  count : Int32,
) -> Int32 = "moonfmi_fmi2_get_derivatives"

///|
#borrow(indicators)
extern "C" fn fmi2_get_event_indicators(
  handle : @c.Pointer[Unit],
  indicators : FixedArray[Double],
  count : Int32,
) -> Int32 = "moonfmi_fmi2_get_event_indicators"

///|
#borrow(nominals)
extern "C" fn fmi2_get_nominals_of_continuous_states(
  handle : @c.Pointer[Unit],
  nominals : FixedArray[Double],
  count : Int32,
) -> Int32 = "moonfmi_fmi2_get_nominals_of_continuous_states"

///|
extern "C" fn fmi2_enter_event_mode(handle : @c.Pointer[Unit]) -> Int32 = "moonfmi_fmi2_enter_event_mode"

///|
#borrow(needed, terminate, nominals_changed, states_changed, time_defined, next_event_time)
extern "C" fn fmi2_new_discrete_states(
  handle : @c.Pointer[Unit],
  needed : FixedArray[Int32],
  terminate : FixedArray[Int32],
  nominals_changed : FixedArray[Int32],
  states_changed : FixedArray[Int32],
  time_defined : FixedArray[Int32],
  next_event_time : FixedArray[Double],
) -> Int32 = "moonfmi_fmi2_new_discrete_states"

///|
extern "C" fn fmi2_enter_continuous_time_mode(
  handle : @c.Pointer[Unit],
) -> Int32 = "moonfmi_fmi2_enter_continuous_time_mode"

///|
#borrow(enter_event_mode, terminate_simulation)
extern "C" fn fmi2_completed_integrator_step(
  handle : @c.Pointer[Unit],
  no_set_fmu_state_prior : Int32,
  enter_event_mode : FixedArray[Int32],
  terminate_simulation : FixedArray[Int32],
) -> Int32 = "moonfmi_fmi2_completed_integrator_step"

///|
fn fmi2_error_text() -> String {
  @utf8.decode_lossy(fmi2_last_error().exact_view())
}

///|
/// FMI 2 expects `fmuResourceLocation` to be a URI. Callers normally have a
/// filesystem path, so a plain absolute path is converted here. A value that
/// already starts with `file:` is passed through unchanged.
fn fmi2_resource_location(path : String) -> String {
  let slashes = path.replace_all(old="\\", new="/")
  let prefixed = if slashes.has_prefix("file:") {
    slashes
  } else if slashes.length() >= 2 && slashes[1] == ':' {
    "file:///" + slashes
  } else if slashes.has_prefix("/") {
    "file://" + slashes
  } else {
    slashes
  }
  if prefixed.has_suffix("/") {
    prefixed
  } else {
    prefixed + "/"
  }
}

///|
pub fn Fmi2Library::open(path : String) -> Fmi2Library raise Fmi2Error {
  let library = DynamicLibrary::open(path) catch {
    error => raise Fmi2LibraryLoad(error)
  }
  let shim = fmi2_library_new(library.handle)
  if shim.is_null() {
    let detail = fmi2_error_text()
    library.close() catch {
      _ => ()
    }
    raise Fmi2ShimRejected(detail~)
  }
  { library, shim, open_instances: 0, closed: false, }
}

///|
pub fn Fmi2Library::path(self : Fmi2Library) -> String {
  self.library.path()
}

///|
/// The `fmi2GetVersion` string reported by the FMU, normally `"2.0"`.
pub fn Fmi2Library::version(self : Fmi2Library) -> String {
  @utf8.decode_lossy(fmi2_library_version(self.shim).exact_view())
}

///|
pub fn Fmi2Library::is_closed(self : Fmi2Library) -> Bool {
  self.closed
}

///|
/// The number of instances that were created by this library and not freed.
pub fn Fmi2Library::open_instance_count(self : Fmi2Library) -> Int32 {
  self.open_instances
}

///|
/// Unloads the FMU binary. Every instance must be freed first, because the
/// FMU's code disappears when the dynamic library is unloaded.
pub fn Fmi2Library::close(self : Fmi2Library) -> Unit raise Fmi2Error {
  if self.closed {
    return
  }
  if self.open_instances > 0 {
    raise Fmi2InstancesAlive(count=self.open_instances)
  }
  fmi2_library_free(self.shim)
  self.closed = true
  self.library.close() catch {
    error => raise Fmi2LibraryUnload(error)
  }
}

///|
/// Creates a Co-Simulation instance.
///
/// `resource_path` is the directory that holds the FMU's `resources/` folder
/// and must be absolute; FMI 2 requires it to end with a path separator.
/// `on_log` is called synchronously from whichever thread the FMU logs on, so
/// it must not block. Once `free` starts, it is never called again.
pub fn Fmi2Library::instantiate(
  self : Fmi2Library,
  instance_name~ : String,
  guid~ : String,
  resource_path~ : String,
  logging_on~ : Bool = true,
  on_log~ : (Fmi2LogMessage) -> Unit = fn(_) {  },
) -> Fmi2Instance raise Fmi2Error {
  if self.closed {
    raise Fmi2ShimRejected(detail="the library has already been unloaded")
  }
  let sink : Fmi2LogSink = { callback: on_log, active: true, }
  let handle = fmi2_instance_new(
    self.shim,
    @utf8.encode(instance_name),
    @utf8.encode(guid),
    @utf8.encode(fmi2_resource_location(resource_path)),
    0,
    if logging_on {
      1
    } else {
      0
    },
    fn(status, name, category, message) {
      if sink.active {
        (sink.callback)({
          status: @fmi.FmiStatus::from_int32(status),
          instance_name: @utf8.decode_lossy(name.exact_view()),
          category: @utf8.decode_lossy(category.exact_view()),
          message: @utf8.decode_lossy(message.exact_view()),
        })
      }
    },
    fn(deliver, status, name, category, message) {
      deliver(status, name, category, message)
    },
  )
  if handle.is_null() {
    raise Fmi2InstantiateFailed(instance_name~, detail=fmi2_error_text())
  }
  self.open_instances = self.open_instances + 1
  { library: self, handle, sink, freed: false, }
}

///|
/// Creates a Model Exchange instance. The arguments and lifecycle are the
/// same as `instantiate`; the FMU must export the ME function group.
pub fn Fmi2Library::instantiate_me(
  self : Fmi2Library,
  instance_name~ : String,
  guid~ : String,
  resource_path~ : String,
  logging_on~ : Bool = true,
  on_log~ : (Fmi2LogMessage) -> Unit = fn(_) {  },
) -> Fmi2Instance raise Fmi2Error {
  if self.closed {
    raise Fmi2ShimRejected(detail="the library has already been unloaded")
  }
  let sink : Fmi2LogSink = { callback: on_log, active: true, }
  let handle = fmi2_instance_new(
    self.shim,
    @utf8.encode(instance_name),
    @utf8.encode(guid),
    @utf8.encode(fmi2_resource_location(resource_path)),
    1,
    if logging_on {
      1
    } else {
      0
    },
    fn(status, name, category, message) {
      if sink.active {
        (sink.callback)({
          status: @fmi.FmiStatus::from_int32(status),
          instance_name: @utf8.decode_lossy(name.exact_view()),
          category: @utf8.decode_lossy(category.exact_view()),
          message: @utf8.decode_lossy(message.exact_view()),
        })
      }
    },
    fn(deliver, status, name, category, message) {
      deliver(status, name, category, message)
    },
  )
  if handle.is_null() {
    raise Fmi2InstantiateFailed(instance_name~, detail=fmi2_error_text())
  }
  self.open_instances = self.open_instances + 1
  { library: self, handle, sink, freed: false, }
}

///|
fn Fmi2Instance::ensure_live(
  self : Fmi2Instance,
  operation : String,
) -> Unit raise Fmi2Error {
  if self.freed || fmi2_instance_is_freed(self.handle) != 0 {
    raise Fmi2InstanceFreed(operation~)
  }
}

///|
fn fail_on_failure(
  status : @fmi.FmiStatus,
  operation : String,
) -> Unit raise Fmi2Error {
  if status.is_failure() {
    raise Fmi2StatusFailed(operation~, status~)
  }
}

///|
pub fn Fmi2Instance::setup_experiment(
  self : Fmi2Instance,
  start_time~ : Double,
  stop_time? : Double,
  tolerance? : Double,
) -> Unit raise Fmi2Error {
  self.ensure_live("fmi2SetupExperiment")
  let (tolerance_defined, tolerance) = match tolerance {
    Some(value) => (1, value)
    None => (0, 0.0)
  }
  let (stop_time_defined, stop_time) = match stop_time {
    Some(value) => (1, value)
    None => (0, 0.0)
  }
  let status = @fmi.FmiStatus::from_int32(
    fmi2_setup_experiment(
      self.handle,
      tolerance_defined,
      tolerance,
      start_time,
      stop_time_defined,
      stop_time,
    ),
  )
  fail_on_failure(status, "fmi2SetupExperiment")
}

///|
pub fn Fmi2Instance::enter_initialization_mode(
  self : Fmi2Instance,
) -> Unit raise Fmi2Error {
  self.ensure_live("fmi2EnterInitializationMode")
  let status = @fmi.FmiStatus::from_int32(
    fmi2_enter_initialization_mode(self.handle),
  )
  fail_on_failure(status, "fmi2EnterInitializationMode")
}

///|
pub fn Fmi2Instance::exit_initialization_mode(
  self : Fmi2Instance,
) -> Unit raise Fmi2Error {
  self.ensure_live("fmi2ExitInitializationMode")
  let status = @fmi.FmiStatus::from_int32(
    fmi2_exit_initialization_mode(self.handle),
  )
  fail_on_failure(status, "fmi2ExitInitializationMode")
}

///|
/// Advances the simulation.
///
/// The status is returned rather than raised: `Discard` asks the caller to
/// retry the step with a smaller step size and is not an error.
pub fn Fmi2Instance::do_step(
  self : Fmi2Instance,
  current_time : Double,
  step_size : Double,
  new_step~ : Bool = true,
) -> @fmi.FmiStatus {
  if self.freed {
    return Fatal
  }
  @fmi.FmiStatus::from_int32(
    fmi2_do_step(
      self.handle,
      current_time,
      step_size,
      if new_step {
        1
      } else {
        0
      },
    ),
  )
}

///|
pub fn Fmi2Instance::get_real(
  self : Fmi2Instance,
  references : Array[UInt32],
) -> Array[Double] raise Fmi2Error {
  self.ensure_live("fmi2GetReal")
  let count = references.length()
  let refs = FixedArray::make(count, 0U)
  for index, reference in references {
    refs[index] = reference
  }
  let values = FixedArray::make(count, 0.0)
  let status = @fmi.FmiStatus::from_int32(
    fmi2_get_real(self.handle, refs, values, count),
  )
  fail_on_failure(status, "fmi2GetReal")
  let result = Array(capacity=count)
  for value in values {
    result.push(value)
  }
  result
}

///|
pub fn Fmi2Instance::set_real(
  self : Fmi2Instance,
  references : Array[UInt32],
  values : Array[Double],
) -> Unit raise Fmi2Error {
  self.ensure_live("fmi2SetReal")
  if references.length() != values.length() {
    raise Fmi2StatusFailed(operation="fmi2SetReal", status=Error)
  }
  let count = references.length()
  let refs = FixedArray::make(count, 0U)
  let buffer = FixedArray::make(count, 0.0)
  for index, reference in references {
    refs[index] = reference
    buffer[index] = values[index]
  }
  let status = @fmi.FmiStatus::from_int32(
    fmi2_set_real(self.handle, refs, buffer, count),
  )
  fail_on_failure(status, "fmi2SetReal")
}

///|
pub fn Fmi2Instance::get_real_one(
  self : Fmi2Instance,
  reference : UInt32,
) -> Double raise Fmi2Error {
  self.get_real([reference])[0]
}

///|
pub fn Fmi2Instance::set_real_one(
  self : Fmi2Instance,
  reference : UInt32,
  value : Double,
) -> Unit raise Fmi2Error {
  self.set_real([reference], [value])
}

///|
pub fn Fmi2Instance::terminate(self : Fmi2Instance) -> Unit raise Fmi2Error {
  self.ensure_live("fmi2Terminate")
  let status = @fmi.FmiStatus::from_int32(fmi2_terminate(self.handle))
  fail_on_failure(status, "fmi2Terminate")
}

///|
/// The number of log messages that reached the shim.
///
/// Messages the shim dropped because logging was disabled, or that arrived
/// while the instance was being freed, are not counted. Messages that reached
/// the shim but were dropped by an inactive sink (`on_log` is not called once
/// `free` has started) are counted.
pub fn Fmi2Instance::log_count(self : Fmi2Instance) -> UInt64 {
  fmi2_instance_log_count(self.handle)
}

///|
pub fn Fmi2Instance::is_freed(self : Fmi2Instance) -> Bool {
  self.freed
}

///|
/// Releases the FMU instance.
///
/// Log delivery stops before `fmi2FreeInstance` is called, so `on_log` is
/// never invoked once `free` has started, even if the FMU logs while it is
/// shutting down.
pub fn Fmi2Instance::free(self : Fmi2Instance) -> Unit {
  if self.freed {
    return
  }
  self.sink.active = false
  fmi2_instance_free(self.handle)
  self.freed = true
  self.library.open_instances = self.library.open_instances - 1
}

/// Model Exchange operations (task C-13 bindings).

///|
fn me_fail(status : @fmi.FmiStatus, operation : String) -> Unit raise Fmi2Error {
  if status.is_failure() {
    raise Fmi2StatusFailed(operation~, status~)
  }
}

///|
fn out_flag(values : FixedArray[Int32]) -> Bool {
  values[0] != 0
}

///|
pub fn Fmi2Instance::set_time(
  self : Fmi2Instance,
  time : Double,
) -> Unit raise Fmi2Error {
  self.ensure_live("fmi2SetTime")
  let status = @fmi.FmiStatus::from_int32(fmi2_set_time(self.handle, time))
  me_fail(status, "fmi2SetTime")
}

///|
pub fn Fmi2Instance::set_continuous_states(
  self : Fmi2Instance,
  states : FixedArray[Double],
) -> Unit raise Fmi2Error {
  self.ensure_live("fmi2SetContinuousStates")
  let status = @fmi.FmiStatus::from_int32(
    fmi2_set_continuous_states(self.handle, states, states.length()),
  )
  me_fail(status, "fmi2SetContinuousStates")
}

///|
/// Fills `states` with the continuous states (`fmi2GetContinuousStates`).
pub fn Fmi2Instance::get_continuous_states(
  self : Fmi2Instance,
  states : FixedArray[Double],
) -> Unit raise Fmi2Error {
  self.ensure_live("fmi2GetContinuousStates")
  let status = @fmi.FmiStatus::from_int32(
    fmi2_get_continuous_states(self.handle, states, states.length()),
  )
  me_fail(status, "fmi2GetContinuousStates")
}

///|
pub fn Fmi2Instance::get_derivatives(
  self : Fmi2Instance,
  derivatives : FixedArray[Double],
) -> Unit raise Fmi2Error {
  self.ensure_live("fmi2GetDerivatives")
  let status = @fmi.FmiStatus::from_int32(
    fmi2_get_derivatives(self.handle, derivatives, derivatives.length()),
  )
  me_fail(status, "fmi2GetDerivatives")
}

///|
pub fn Fmi2Instance::get_event_indicators(
  self : Fmi2Instance,
  indicators : FixedArray[Double],
) -> Unit raise Fmi2Error {
  self.ensure_live("fmi2GetEventIndicators")
  let status = @fmi.FmiStatus::from_int32(
    fmi2_get_event_indicators(self.handle, indicators, indicators.length()),
  )
  me_fail(status, "fmi2GetEventIndicators")
}

///|
pub fn Fmi2Instance::get_nominals_of_continuous_states(
  self : Fmi2Instance,
  nominals : FixedArray[Double],
) -> Unit raise Fmi2Error {
  self.ensure_live("fmi2GetNominalsOfContinuousStates")
  let status = @fmi.FmiStatus::from_int32(
    fmi2_get_nominals_of_continuous_states(
      self.handle,
      nominals,
      nominals.length(),
    ),
  )
  me_fail(status, "fmi2GetNominalsOfContinuousStates")
}

///|
pub fn Fmi2Instance::enter_event_mode(
  self : Fmi2Instance,
) -> Unit raise Fmi2Error {
  self.ensure_live("fmi2EnterEventMode")
  let status = @fmi.FmiStatus::from_int32(fmi2_enter_event_mode(self.handle))
  me_fail(status, "fmi2EnterEventMode")
}

///|
/// One `fmi2NewDiscreteStates` iteration.
pub fn Fmi2Instance::new_discrete_states(
  self : Fmi2Instance,
) -> @fmi.EventInfo raise Fmi2Error {
  self.ensure_live("fmi2NewDiscreteStates")
  let needed : FixedArray[Int32] = FixedArray::make(1, 0)
  let terminate : FixedArray[Int32] = FixedArray::make(1, 0)
  let nominals_changed : FixedArray[Int32] = FixedArray::make(1, 0)
  let states_changed : FixedArray[Int32] = FixedArray::make(1, 0)
  let time_defined : FixedArray[Int32] = FixedArray::make(1, 0)
  let next_event_time : FixedArray[Double] = FixedArray::make(1, 0.0)
  let status = @fmi.FmiStatus::from_int32(
    fmi2_new_discrete_states(
      self.handle,
      needed,
      terminate,
      nominals_changed,
      states_changed,
      time_defined,
      next_event_time,
    ),
  )
  me_fail(status, "fmi2NewDiscreteStates")
  {
    new_discrete_states_needed: out_flag(needed),
    terminate_simulation: out_flag(terminate),
    nominals_changed: out_flag(nominals_changed),
    states_changed: out_flag(states_changed),
    next_event_time_defined: out_flag(time_defined),
    next_event_time: next_event_time[0],
  }
}

///|
pub fn Fmi2Instance::enter_continuous_time_mode(
  self : Fmi2Instance,
) -> Unit raise Fmi2Error {
  self.ensure_live("fmi2EnterContinuousTimeMode")
  let status = @fmi.FmiStatus::from_int32(
    fmi2_enter_continuous_time_mode(self.handle),
  )
  me_fail(status, "fmi2EnterContinuousTimeMode")
}

///|
/// `fmi2CompletedIntegratorStep`; returns
/// `(enter_event_mode, terminate_simulation)`.
pub fn Fmi2Instance::completed_integrator_step(
  self : Fmi2Instance,
  no_set_fmu_state_prior~ : Bool = true,
) -> (Bool, Bool) raise Fmi2Error {
  self.ensure_live("fmi2CompletedIntegratorStep")
  let enter : FixedArray[Int32] = FixedArray::make(1, 0)
  let terminate : FixedArray[Int32] = FixedArray::make(1, 0)
  let status = @fmi.FmiStatus::from_int32(
    fmi2_completed_integrator_step(
      self.handle,
      if no_set_fmu_state_prior {
        1
      } else {
        0
      },
      enter,
      terminate,
    ),
  )
  me_fail(status, "fmi2CompletedIntegratorStep")
  (out_flag(enter), out_flag(terminate))
}

///|
/// Capability bits reported by `moonfmi_fmi2_library_fmu_state_support`.
const FMU_STATE_FLAG : Int32 = 1

///|
const FMU_STATE_SERIALIZED_FLAG : Int32 = 2

///|
extern "C" fn fmi2_library_fmu_state_support(
  library : @c.Pointer[Unit],
) -> Int32 = "moonfmi_fmi2_library_fmu_state_support"

///|
#borrow(status_out)
extern "C" fn fmi2_get_fmu_state(
  handle : @c.Pointer[Unit],
  status_out : FixedArray[Int32],
) -> @c.Pointer[Unit] = "moonfmi_fmi2_get_fmu_state"

///|
extern "C" fn fmi2_set_fmu_state(
  handle : @c.Pointer[Unit],
  state : @c.Pointer[Unit],
) -> Int32 = "moonfmi_fmi2_set_fmu_state"

///|
extern "C" fn fmi2_free_fmu_state(
  handle : @c.Pointer[Unit],
  state : @c.Pointer[Unit],
) -> Int32 = "moonfmi_fmi2_free_fmu_state"

///|
#borrow(buffer, written_out)
#borrow(handle, state, buffer, written_out)
extern "C" fn fmi2_serialize_fmu_state(
  handle : @c.Pointer[Unit],
  state : @c.Pointer[Unit],
  buffer : FixedArray[Byte],
  size : Int32,
  written_out : FixedArray[Int32],
) -> Int32 = "moonfmi_fmi2_serialize_fmu_state"

///|
#borrow(buffer, state_out)
extern "C" fn fmi2_deserialize_fmu_state(
  handle : @c.Pointer[Unit],
  buffer : FixedArray[Byte],
  size : Int32,
  state_out : FixedArray[@c.Pointer[Unit]],
) -> Int32 = "moonfmi_fmi2_deserialize_fmu_state"

///|
/// Whether the FMU exports the `fmi2*FMUstate` group (canGetAndSetFMUstate).
pub fn Fmi2Instance::supports_fmu_state(self : Fmi2Instance) -> Bool {
  (fmi2_library_fmu_state_support(self.library.shim) & FMU_STATE_FLAG) != 0
}

///|
/// Whether the FMU also exports the byte-level serialize pair.
pub fn Fmi2Instance::supports_serialized_fmu_state(self : Fmi2Instance) -> Bool {
  let flags = fmi2_library_fmu_state_support(self.library.shim)
  (flags & FMU_STATE_SERIALIZED_FLAG) != 0
}

///|
fn Fmi2Instance::require_fmu_state(
  self : Fmi2Instance,
  operation~ : String,
) -> Unit raise Fmi2Error {
  self.ensure_live(operation)
  if !self.supports_fmu_state() {
    raise Fmi2CapabilityMissing(operation~, capability="canGetAndSetFMUstate")
  }
}

///|
/// Captures the FMU state (`fmi2GetFMUstate`). The state must be released
/// with `free_fmu_state`. Raises `Fmi2CapabilityMissing` when the FMU does
/// not declare canGetAndSetFMUstate.
pub fn Fmi2Instance::get_fmu_state(
  self : Fmi2Instance,
) -> @c.Pointer[Unit] raise Fmi2Error {
  self.require_fmu_state(operation="fmi2GetFMUstate")
  let status_out : FixedArray[Int32] = FixedArray::make(1, 0)
  let state = fmi2_get_fmu_state(self.handle, status_out)
  fail_on_failure(@fmi.FmiStatus::from_int32(status_out[0]), "fmi2GetFMUstate")
  state
}

///|
/// Restores a previously captured FMU state (`fmi2SetFMUstate`).
pub fn Fmi2Instance::set_fmu_state(
  self : Fmi2Instance,
  state : @c.Pointer[Unit],
) -> Unit raise Fmi2Error {
  self.require_fmu_state(operation="fmi2SetFMUstate")
  let status = @fmi.FmiStatus::from_int32(
    fmi2_set_fmu_state(self.handle, state),
  )
  fail_on_failure(status, "fmi2SetFMUstate")
}

///|
/// Releases a captured FMU state (`fmi2FreeFMUstate`).
pub fn Fmi2Instance::free_fmu_state(
  self : Fmi2Instance,
  state : @c.Pointer[Unit],
) -> Unit raise Fmi2Error {
  self.require_fmu_state(operation="fmi2FreeFMUstate")
  let status = @fmi.FmiStatus::from_int32(
    fmi2_free_fmu_state(self.handle, state),
  )
  fail_on_failure(status, "fmi2FreeFMUstate")
}

///|
/// Restores a state from serialized bytes (`fmi2DeSerializeFMUstate`).
pub fn Fmi2Instance::deserialize_fmu_state(
  self : Fmi2Instance,
  buffer : FixedArray[Byte],
) -> @c.Pointer[Unit] raise Fmi2Error {
  self.ensure_live("fmi2DeSerializeFMUstate")
  if !self.supports_serialized_fmu_state() {
    raise Fmi2CapabilityMissing(
      operation="fmi2DeSerializeFMUstate",
      capability="canSerializeFMUstate",
    )
  }
  let state_out : FixedArray[@c.Pointer[Unit]] = FixedArray::make(
    1,
    @c.Pointer::null(),
  )
  let status = @fmi.FmiStatus::from_int32(
    fmi2_deserialize_fmu_state(self.handle, buffer, buffer.length(), state_out),
  )
  fail_on_failure(status, "fmi2DeSerializeFMUstate")
  state_out[0]
}

///|
#borrow(state, size_out)
extern "C" fn fmi2_serialized_fmu_state_size(
  handle : @c.Pointer[Unit],
  state : @c.Pointer[Unit],
  size_out : FixedArray[Int32],
) -> Int32 = "moonfmi_fmi2_serialized_fmu_state_size"

///|
/// Whether the FMU exports a serialized-state size query. Standard FMI 2
/// has none; Reference-FMUs ship a non-standard
/// `fmi2SerializedFMUstateSize` which we use when present.
pub fn Fmi2Instance::supports_serialized_state_size(
  self : Fmi2Instance,
) -> Bool {
  let flags = fmi2_library_fmu_state_support(self.library.shim)
  (flags & FMU_STATE_SERIALIZED_FLAG) != 0
}

///|
/// Serializes a captured FMU state into fresh bytes
/// (`fmi2SerializeFMUstate`). The buffer is sized via the FMU's size query
/// when it exports one; otherwise the call grows the buffer until the FMU
/// accepts it.
pub fn Fmi2Instance::serialize_fmu_state(
  self : Fmi2Instance,
  state : @c.Pointer[Unit],
) -> FixedArray[Byte] raise Fmi2Error {
  self.ensure_live("fmi2SerializeFMUstate")
  if !self.supports_serialized_fmu_state() {
    raise Fmi2CapabilityMissing(
      operation="fmi2SerializeFMUstate",
      capability="canSerializeFMUstate",
    )
  }
  let size_out : FixedArray[Int32] = FixedArray::make(1, 0)
  if @fmi.FmiStatus::from_int32(
      fmi2_serialized_fmu_state_size(self.handle, state, size_out),
    )
    is Ok {
    let buffer : FixedArray[Byte] = FixedArray::make(size_out[0], b'\x00')
    ignore(self.serialize_into(state, buffer))
    return buffer
  }
  // No size query: grow until the FMU accepts the buffer.
  let mut size = 256
  while size <= 65536 {
    let buffer : FixedArray[Byte] = FixedArray::make(size, b'\x00')
    let outcome : Result[Int32, Fmi2Error] = Ok(
      self.serialize_into(state, buffer),
    ) catch {
      error => Err(error)
    }
    match outcome {
      Ok(_) => return buffer
      Err(_) => {
        size = size * 4
        continue
      }
    }
  }
  raise Fmi2StatusFailed(
    operation="fmi2SerializeFMUstate",
    status=@fmi.FmiStatus::Error,
  )
}

///|
fn Fmi2Instance::serialize_into(
  self : Fmi2Instance,
  state : @c.Pointer[Unit],
  buffer : FixedArray[Byte],
) -> Int32 raise Fmi2Error {
  let written_out : FixedArray[Int32] = FixedArray::make(1, 0)
  let status = @fmi.FmiStatus::from_int32(
    fmi2_serialize_fmu_state(
      self.handle,
      state,
      buffer,
      buffer.length(),
      written_out,
    ),
  )
  fail_on_failure(status, "fmi2SerializeFMUstate")
  written_out[0]
}
