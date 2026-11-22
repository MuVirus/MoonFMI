///|
/// A loaded FMI 3.0.2 library.
///
/// The shim resolves the exported `fmi3*` functions in groups (Co-Simulation,
/// Model Exchange, one group per value type) and records which groups are
/// present, because an FMU only has to export the functions for the
/// interface and variable types it actually declares. Calls into a missing
/// group raise a `Fmi3CapabilityMissing` error instead of crashing.
pub struct Fmi3Library {
  library : DynamicLibrary
  shim : @c.Pointer[Unit]
  mut open_instances : Int32
  mut closed : Bool
}

///|
pub(all) suberror Fmi3Error {
  Fmi3LibraryLoad(DynamicLibraryError)
  Fmi3LibraryUnload(DynamicLibraryError)
  Fmi3ShimRejected(detail~ : String)
  Fmi3InstantiateFailed(instance_name~ : String, detail~ : String)
  Fmi3InstanceFreed(operation~ : String)
  Fmi3StatusFailed(operation~ : String, status~ : @fmi.FmiStatus)
  Fmi3CapabilityMissing(operation~ : String, detail~ : String)
  Fmi3InstancesAlive(count~ : Int32)
}

///|
pub fn Fmi3Error::message(self : Fmi3Error) -> String {
  match self {
    Fmi3LibraryLoad(error) => error.message()
    Fmi3LibraryUnload(error) => error.message()
    Fmi3ShimRejected(detail~) =>
      "the FMU is not a usable FMI 3 library: " + detail
    Fmi3InstantiateFailed(instance_name~, detail~) =>
      "fmi3Instantiate failed for '" + instance_name + "': " + detail
    Fmi3InstanceFreed(operation~) =>
      "cannot call " + operation + " on a released FMI instance"
    Fmi3StatusFailed(operation~, status~) =>
      operation + " failed with status " + status.name()
    Fmi3CapabilityMissing(operation~, detail~) =>
      operation + " is not available: " + detail
    Fmi3InstancesAlive(count~) =>
      "the library still owns " +
      count.to_string() +
      " live instance(s); free them first"
  }
}

///|
/// A log message forwarded by the FMU. FMI 3 has no instance name in the
/// log callback, unlike FMI 2.
pub(all) struct Fmi3LogMessage {
  status : @fmi.FmiStatus
  category : String
  message : String
}

///|
struct Fmi3LogSink {
  callback : (Fmi3LogMessage) -> Unit
  mut active : Bool
}

///|
/// One FMU intermediate update, delivered from inside `fmi3DoStep`
/// (FMI 3.0.2 §2.2.6: the FMU reports progress and offers the host the
/// variable access and early-return negotiation). The callback answers
/// with `true` to ask the FMU to return early at the update's own time —
/// honored only when the update reported `can_return_early`.
pub(all) struct Fmi3IntermediateUpdate {
  time : Double
  set_requested : Bool
  get_allowed : Bool
  step_finished : Bool
  can_return_early : Bool
}

///|
struct Fmi3IntermediateSink {
  callback : (Fmi3IntermediateUpdate) -> Bool
  active : Bool
}

///|
/// The result of one `fmi3DoStep` call. `early_return` and
/// `last_successful_time` only carry information when early return was
/// allowed at instantiation; this host never allows it. The call status
/// travels with the result because `Discard` is not a failure: the caller
/// decides how to react (master-algorithm.md §3.5).
pub(all) struct Fmi3DoStepResult {
  status : @fmi.FmiStatus
  event_handling_needed : Bool
  terminate_simulation : Bool
  early_return : Bool
  last_successful_time : Double
}

///|
/// A live FMI 3 instance (Co-Simulation or Model Exchange).
pub struct Fmi3Instance {
  library : Fmi3Library
  handle : @c.Pointer[Unit]
  sink : Fmi3LogSink
  intermediate : Fmi3IntermediateSink
  /// Whether the CS instantiation ran with `eventModeUsed = true`; only
  /// then does `initialize` run the event settlement and EnterStepMode
  /// (without it the FMU leaves initialization in Step Mode already).
  event_mode_used : Bool
  mut freed : Bool
  /// Model-description capability declarations. Generated FMUs ship
  /// fmi3Error stubs so symbol-resolving hosts (FMPy) can load them; the
  /// capability verdict must come from the model description instead.
  mut declared_fmu_state : Bool
  mut declared_serialized : Bool
  /// FMU state captured by `begin_rollback_point` for the step in
  /// progress (C-11 rollback, master-algorithm.md §3.5). `None` unless a
  /// rollback point is armed; while armed, `fmi3DoStep` is called with
  /// `noSetFMUStatePrior = fmi3False` because the master may roll the
  /// step back through `fmi3SetFMUState`.
  mut saved_state : @c.Pointer[Unit]?
  /// `fmi3EnterInitializationMode` arguments, stored by
  /// `setup_experiment` and applied by `initialize`.
  mut pending_tolerance : Double?
  mut pending_start : Double
  mut pending_stop : Double?
}

///|
extern "C" fn fmi3_library_new(handle : @c.Pointer[Unit]) -> @c.Pointer[Unit] = "moonfmi_fmi3_library_new"

///|
extern "C" fn fmi3_library_has_flag(
  handle : @c.Pointer[Unit],
  flag : Int32,
) -> Int32 = "moonfmi_fmi3_library_has_flag"

///|
/// Capability flag ids; mirrors the enum in `fmi3_shim.c`.
let flag_float32 : Int32 = 2

///|
let flag_float64 : Int32 = 3

///|
let flag_int8 : Int32 = 4

///|
let flag_uint8 : Int32 = 5

///|
let flag_int16 : Int32 = 6

///|
let flag_uint16 : Int32 = 7

///|
let flag_int32 : Int32 = 8

///|
let flag_uint32 : Int32 = 9

///|
let flag_int64 : Int32 = 10

///|
let flag_uint64 : Int32 = 11

///|
let flag_boolean : Int32 = 12

///|
let flag_string : Int32 = 13

///|
let flag_binary : Int32 = 14

///|
let flag_clock : Int32 = 15

///|
let flag_fmu_state : Int32 = 16

///|
fn shim_has_flag(shim : @c.Pointer[Unit], flag : Int32) -> Bool {
  fmi3_library_has_flag(shim, flag) != 0
}

///|
extern "C" fn fmi3_library_version(handle : @c.Pointer[Unit]) -> Bytes = "moonfmi_fmi3_library_version"

///|
extern "C" fn fmi3_library_free(handle : @c.Pointer[Unit]) -> Unit = "moonfmi_fmi3_library_free"

///|
extern "C" fn fmi3_instance_free(handle : @c.Pointer[Unit]) -> Unit = "moonfmi_fmi3_instance_free"

///|
extern "C" fn fmi3_instance_log_count(handle : @c.Pointer[Unit]) -> UInt64 = "moonfmi_fmi3_instance_log_count"

///|
extern "C" fn fmi3_instance_is_freed(handle : @c.Pointer[Unit]) -> Int32 = "moonfmi_fmi3_instance_is_freed"

///|
#borrow(instance_name, instantiation_token, resource_path)
extern "C" fn fmi3_instance_new(
  library : @c.Pointer[Unit],
  instance_name : Bytes,
  instantiation_token : Bytes,
  resource_path : Bytes,
  interface_kind : Int32,
  logging_on : Int32,
  log_sink : (Int32, Bytes, Bytes) -> Unit,
  log_deliver : FuncRef[
    ((Int32, Bytes, Bytes) -> Unit, Int32, Bytes, Bytes) -> Unit,
  ],
  event_mode_used : Int32,
  early_return_allowed : Int32,
  intermediate_sink : (Double, Int32, Int32, Int32, Int32) -> Int32,
  intermediate_deliver : FuncRef[
    (
      (Double, Int32, Int32, Int32, Int32) -> Int32,
      Double,
      Int32,
      Int32,
      Int32,
      Int32,
    ) -> Int32,
  ],
) -> @c.Pointer[Unit] = "moonfmi_fmi3_instance_new"

///|
extern "C" fn fmi3_last_error() -> Bytes = "moonfmi_fmi3_last_error"

///|
extern "C" fn fmi3_enter_initialization_mode(
  handle : @c.Pointer[Unit],
  tolerance_defined : Int32,
  tolerance : Double,
  start_time : Double,
  stop_time_defined : Int32,
  stop_time : Double,
) -> Int32 = "moonfmi_fmi3_enter_initialization_mode"

///|
extern "C" fn fmi3_exit_initialization_mode(handle : @c.Pointer[Unit]) -> Int32 = "moonfmi_fmi3_exit_initialization_mode"

///|
extern "C" fn fmi3_terminate(handle : @c.Pointer[Unit]) -> Int32 = "moonfmi_fmi3_terminate"

///|
#borrow(event_needed, terminate, early_return, last_successful_time)
extern "C" fn fmi3_do_step(
  handle : @c.Pointer[Unit],
  current_time : Double,
  step_size : Double,
  no_set_fmu_state_prior : Int32,
  event_needed : FixedArray[Int32],
  terminate : FixedArray[Int32],
  early_return : FixedArray[Int32],
  last_successful_time : FixedArray[Double],
) -> Int32 = "moonfmi_fmi3_do_step"

///|
extern "C" fn fmi3_enter_step_mode(handle : @c.Pointer[Unit]) -> Int32 = "moonfmi_fmi3_enter_step_mode"

///|
extern "C" fn fmi3_enter_event_mode(handle : @c.Pointer[Unit]) -> Int32 = "moonfmi_fmi3_enter_event_mode"

///|
#borrow(need_update, terminate, nominals_changed, states_changed, time_defined, next_event_time)
extern "C" fn fmi3_update_discrete_states(
  handle : @c.Pointer[Unit],
  need_update : FixedArray[Int32],
  terminate : FixedArray[Int32],
  nominals_changed : FixedArray[Int32],
  states_changed : FixedArray[Int32],
  time_defined : FixedArray[Int32],
  next_event_time : FixedArray[Double],
) -> Int32 = "moonfmi_fmi3_update_discrete_states"

///|
extern "C" fn fmi3_set_time(handle : @c.Pointer[Unit], time : Double) -> Int32 = "moonfmi_fmi3_set_time"

///|
#borrow(states)
extern "C" fn fmi3_set_continuous_states(
  handle : @c.Pointer[Unit],
  states : FixedArray[Double],
  count : Int32,
) -> Int32 = "moonfmi_fmi3_set_continuous_states"

///|
#borrow(states)
extern "C" fn fmi3_get_continuous_states(
  handle : @c.Pointer[Unit],
  states : FixedArray[Double],
  count : Int32,
) -> Int32 = "moonfmi_fmi3_get_continuous_states"

///|
#borrow(derivatives)
extern "C" fn fmi3_get_continuous_state_derivatives(
  handle : @c.Pointer[Unit],
  derivatives : FixedArray[Double],
  count : Int32,
) -> Int32 = "moonfmi_fmi3_get_continuous_state_derivatives"

///|
#borrow(indicators)
extern "C" fn fmi3_get_event_indicators(
  handle : @c.Pointer[Unit],
  indicators : FixedArray[Double],
  count : Int32,
) -> Int32 = "moonfmi_fmi3_get_event_indicators"

///|
#borrow(nominals)
extern "C" fn fmi3_get_nominals_of_continuous_states(
  handle : @c.Pointer[Unit],
  nominals : FixedArray[Double],
  count : Int32,
) -> Int32 = "moonfmi_fmi3_get_nominals_of_continuous_states"

///|
extern "C" fn fmi3_enter_continuous_time_mode(
  handle : @c.Pointer[Unit],
) -> Int32 = "moonfmi_fmi3_enter_continuous_time_mode"

///|
#borrow(enter_event_mode, terminate_simulation)
extern "C" fn fmi3_completed_integrator_step(
  handle : @c.Pointer[Unit],
  no_set_fmu_state_prior : Int32,
  enter_event_mode : FixedArray[Int32],
  terminate_simulation : FixedArray[Int32],
) -> Int32 = "moonfmi_fmi3_completed_integrator_step"

///|
#borrow(references, values)
extern "C" fn fmi3_get_float32_as_double(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[Double],
  n_references : Int32,
  n_values : Int32,
) -> Int32 = "moonfmi_fmi3_get_float32_as_double"

///|
#borrow(references, values)
extern "C" fn fmi3_set_float32(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[Double],
  n_references : Int32,
  n_values : Int32,
) -> Int32 = "moonfmi_fmi3_set_float32_from_double"

///|
#borrow(references, values)
extern "C" fn fmi3_get_float64(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[Double],
  n_references : Int32,
  n_values : Int32,
) -> Int32 = "moonfmi_fmi3_get_float64"

///|
#borrow(references, values)
extern "C" fn fmi3_set_float64(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[Double],
  n_references : Int32,
  n_values : Int32,
) -> Int32 = "moonfmi_fmi3_set_float64"

///|
#borrow(references, values)
extern "C" fn fmi3_get_int8_as_int32(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[Int32],
  n_references : Int32,
  n_values : Int32,
) -> Int32 = "moonfmi_fmi3_get_int8_as_int32"

///|
#borrow(references, values)
extern "C" fn fmi3_set_int8_from_int32(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[Int32],
  n_references : Int32,
  n_values : Int32,
) -> Int32 = "moonfmi_fmi3_set_int8_from_int32"

///|
#borrow(references, values)
extern "C" fn fmi3_get_uint8_as_int32(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[Int32],
  n_references : Int32,
  n_values : Int32,
) -> Int32 = "moonfmi_fmi3_get_uint8_as_int32"

///|
#borrow(references, values)
extern "C" fn fmi3_set_uint8_from_int32(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[Int32],
  n_references : Int32,
  n_values : Int32,
) -> Int32 = "moonfmi_fmi3_set_uint8_from_int32"

///|
#borrow(references, values)
extern "C" fn fmi3_get_int16_as_int32(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[Int32],
  n_references : Int32,
  n_values : Int32,
) -> Int32 = "moonfmi_fmi3_get_int16_as_int32"

///|
#borrow(references, values)
extern "C" fn fmi3_set_int16_from_int32(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[Int32],
  n_references : Int32,
  n_values : Int32,
) -> Int32 = "moonfmi_fmi3_set_int16_from_int32"

///|
#borrow(references, values)
extern "C" fn fmi3_get_uint16_as_int32(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[Int32],
  n_references : Int32,
  n_values : Int32,
) -> Int32 = "moonfmi_fmi3_get_uint16_as_int32"

///|
#borrow(references, values)
extern "C" fn fmi3_set_uint16_from_int32(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[Int32],
  n_references : Int32,
  n_values : Int32,
) -> Int32 = "moonfmi_fmi3_set_uint16_from_int32"

///|
#borrow(references, values)
extern "C" fn fmi3_get_int32(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[Int32],
  n_references : Int32,
  n_values : Int32,
) -> Int32 = "moonfmi_fmi3_get_int32"

///|
#borrow(references, values)
extern "C" fn fmi3_set_int32(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[Int32],
  n_references : Int32,
  n_values : Int32,
) -> Int32 = "moonfmi_fmi3_set_int32"

///|
#borrow(references, values)
extern "C" fn fmi3_get_uint32(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[UInt32],
  n_references : Int32,
  n_values : Int32,
) -> Int32 = "moonfmi_fmi3_get_uint32"

///|
#borrow(references, values)
extern "C" fn fmi3_set_uint32(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[UInt32],
  n_references : Int32,
  n_values : Int32,
) -> Int32 = "moonfmi_fmi3_set_uint32"

///|
#borrow(references, values)
extern "C" fn fmi3_get_int64(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[Int64],
  n_references : Int32,
  n_values : Int32,
) -> Int32 = "moonfmi_fmi3_get_int64"

///|
#borrow(references, values)
extern "C" fn fmi3_set_int64(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[Int64],
  n_references : Int32,
  n_values : Int32,
) -> Int32 = "moonfmi_fmi3_set_int64"

///|
#borrow(references, values)
extern "C" fn fmi3_get_uint64(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[UInt64],
  n_references : Int32,
  n_values : Int32,
) -> Int32 = "moonfmi_fmi3_get_uint64"

///|
#borrow(references, values)
extern "C" fn fmi3_set_uint64(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[UInt64],
  n_references : Int32,
  n_values : Int32,
) -> Int32 = "moonfmi_fmi3_set_uint64"

///|
#borrow(references, values)
extern "C" fn fmi3_get_boolean(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[Byte],
  n_references : Int32,
  n_values : Int32,
) -> Int32 = "moonfmi_fmi3_get_boolean"

///|
#borrow(references, values)
extern "C" fn fmi3_set_boolean(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[Byte],
  n_references : Int32,
  n_values : Int32,
) -> Int32 = "moonfmi_fmi3_set_boolean"

///|
#borrow(references, values)
extern "C" fn fmi3_get_clock(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[Byte],
  n_references : Int32,
) -> Int32 = "moonfmi_fmi3_get_clock"

///|
#borrow(references, values)
extern "C" fn fmi3_set_clock(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  values : FixedArray[Byte],
  n_references : Int32,
) -> Int32 = "moonfmi_fmi3_set_clock"

///|
#borrow(status_out)
extern "C" fn fmi3_get_string(
  handle : @c.Pointer[Unit],
  reference : UInt32,
  status_out : FixedArray[Int32],
) -> Bytes = "moonfmi_fmi3_get_string"

///|
#borrow(value)
extern "C" fn fmi3_set_string(
  handle : @c.Pointer[Unit],
  reference : UInt32,
  value : Bytes,
) -> Int32 = "moonfmi_fmi3_set_string"

///|
#borrow(status_out)
extern "C" fn fmi3_get_binary(
  handle : @c.Pointer[Unit],
  reference : UInt32,
  status_out : FixedArray[Int32],
) -> Bytes = "moonfmi_fmi3_get_binary"

///|
#borrow(value)
extern "C" fn fmi3_set_binary(
  handle : @c.Pointer[Unit],
  reference : UInt32,
  value : Bytes,
) -> Int32 = "moonfmi_fmi3_set_binary"

///|
#borrow(status_out)
extern "C" fn fmi3_get_fmu_state(
  handle : @c.Pointer[Unit],
  status_out : FixedArray[Int32],
) -> @c.Pointer[Unit] = "moonfmi_fmi3_get_fmu_state"

///|
extern "C" fn fmi3_set_fmu_state(
  handle : @c.Pointer[Unit],
  state : @c.Pointer[Unit],
) -> Int32 = "moonfmi_fmi3_set_fmu_state"

///|
extern "C" fn fmi3_free_fmu_state(
  handle : @c.Pointer[Unit],
  state : @c.Pointer[Unit],
) -> Unit = "moonfmi_fmi3_free_fmu_state"

///|
fn fmi3_error_text() -> String {
  @utf8.decode_lossy(fmi3_last_error().exact_view())
}

///|
pub fn Fmi3Library::open(path : String) -> Fmi3Library raise Fmi3Error {
  let library = DynamicLibrary::open(path) catch {
    error => raise Fmi3LibraryLoad(error)
  }
  let shim = fmi3_library_new(library.handle)
  if shim.is_null() {
    let detail = fmi3_error_text()
    library.close() catch {
      _ => ()
    }
    raise Fmi3ShimRejected(detail~)
  }
  { library, shim, open_instances: 0, closed: false, }
}

///|
pub fn Fmi3Library::path(self : Fmi3Library) -> String {
  self.library.path()
}

///|
/// The `fmi3GetVersion` string reported by the FMU, normally `"3.0"`.
pub fn Fmi3Library::version(self : Fmi3Library) -> String {
  @utf8.decode_lossy(fmi3_library_version(self.shim).exact_view())
}

///|
pub fn Fmi3Library::is_closed(self : Fmi3Library) -> Bool {
  self.closed
}

///|
/// The number of instances that were created by this library and not freed.
pub fn Fmi3Library::open_instance_count(self : Fmi3Library) -> Int32 {
  self.open_instances
}

///|
/// Unloads the FMU binary. Every instance must be freed first.
pub fn Fmi3Library::close(self : Fmi3Library) -> Unit raise Fmi3Error {
  if self.closed {
    return
  }
  if self.open_instances > 0 {
    raise Fmi3InstancesAlive(count=self.open_instances)
  }
  fmi3_library_free(self.shim)
  self.closed = true
  self.library.close() catch {
    error => raise Fmi3LibraryUnload(error)
  }
}

///|
fn Fmi3Library::instantiate_common(
  self : Fmi3Library,
  instance_name~ : String,
  instantiation_token~ : String,
  resource_path~ : String,
  interface_kind~ : Int32,
  logging_on~ : Bool,
  on_log~ : (Fmi3LogMessage) -> Unit,
  event_mode_used~ : Bool = true,
  early_return_allowed~ : Bool = false,
  on_intermediate_update~ : (Fmi3IntermediateUpdate) -> Bool = fn(_) { false },
) -> Fmi3Instance raise Fmi3Error {
  if self.closed {
    raise Fmi3ShimRejected(detail="the library has already been unloaded")
  }
  let sink : Fmi3LogSink = { callback: on_log, active: true, }
  let intermediate : Fmi3IntermediateSink = {
    callback: on_intermediate_update,
    active: true,
  }
  let handle = fmi3_instance_new(
    self.shim,
    @utf8.encode(instance_name),
    @utf8.encode(instantiation_token),
    @utf8.encode(fmi2_resource_location(resource_path)),
    interface_kind,
    if logging_on {
      1
    } else {
      0
    },
    fn(status, category, message) {
      if sink.active {
        (sink.callback)({
          status: @fmi.FmiStatus::from_int32(status),
          category: @utf8.decode_lossy(category.exact_view()),
          message: @utf8.decode_lossy(message.exact_view()),
        })
      }
    },
    fn(deliver, status, category, message) {
      deliver(status, category, message)
    },
    if event_mode_used {
      1
    } else {
      0
    },
    if early_return_allowed {
      1
    } else {
      0
    },
    fn(time, set_requested, get_allowed, step_finished, can_return_early) {
      if intermediate.active {
        if (intermediate.callback)({
            time,
            set_requested: set_requested != 0,
            get_allowed: get_allowed != 0,
            step_finished: step_finished != 0,
            can_return_early: can_return_early != 0,
          }) {
          1
        } else {
          0
        }
      } else {
        0
      }
    },
    fn(
      deliver,
      time,
      set_requested,
      get_allowed,
      step_finished,
      can_return_early,
    ) {
      deliver(time, set_requested, get_allowed, step_finished, can_return_early)
    },
  )
  if handle.is_null() {
    raise Fmi3InstantiateFailed(instance_name~, detail=fmi3_error_text())
  }
  self.open_instances = self.open_instances + 1
  {
    library: self,
    handle,
    sink,
    intermediate,
    event_mode_used,
    freed: false,
    declared_fmu_state: false,
    declared_serialized: false,
    saved_state: None,
    pending_tolerance: None,
    pending_start: 0.0,
    pending_stop: None,
  }
}

///|
/// Creates a Co-Simulation instance. `event_mode_used` follows the model
/// description by default (FMUs compiled without event support reject
/// `true`, so callers may retry with `false`); `early_return_allowed`
/// enables the intermediate-update negotiation and the FMU's own early
/// returns.
pub fn Fmi3Library::instantiate(
  self : Fmi3Library,
  instance_name~ : String,
  instantiation_token~ : String,
  resource_path~ : String,
  logging_on~ : Bool = true,
  on_log~ : (Fmi3LogMessage) -> Unit = fn(_) {  },
  event_mode_used~ : Bool = true,
  early_return_allowed~ : Bool = false,
  on_intermediate_update~ : (Fmi3IntermediateUpdate) -> Bool = fn(_) { false },
) -> Fmi3Instance raise Fmi3Error {
  self.instantiate_common(
    instance_name~,
    instantiation_token~,
    resource_path~,
    interface_kind=0,
    logging_on~,
    on_log~,
    event_mode_used~,
    early_return_allowed~,
    on_intermediate_update~,
  )
}

///|
/// Creates a Model Exchange instance.
pub fn Fmi3Library::instantiate_me(
  self : Fmi3Library,
  instance_name~ : String,
  instantiation_token~ : String,
  resource_path~ : String,
  logging_on~ : Bool = true,
  on_log~ : (Fmi3LogMessage) -> Unit = fn(_) {  },
) -> Fmi3Instance raise Fmi3Error {
  self.instantiate_common(
    instance_name~,
    instantiation_token~,
    resource_path~,
    interface_kind=1,
    logging_on~,
    on_log~,
  )
}

///|
fn Fmi3Instance::ensure_live(
  self : Fmi3Instance,
  operation : String,
) -> Unit raise Fmi3Error {
  if self.freed || fmi3_instance_is_freed(self.handle) != 0 {
    raise Fmi3InstanceFreed(operation~)
  }
}

///|
fn fmi3_fail_on_failure(
  status : @fmi.FmiStatus,
  operation : String,
) -> Unit raise Fmi3Error {
  if status.is_failure() {
    raise Fmi3StatusFailed(operation~, status~)
  }
}

///|
fn fmi3_require(
  present : Bool,
  operation : String,
  symbol : String,
) -> Unit raise Fmi3Error {
  if !present {
    raise Fmi3CapabilityMissing(
      operation~,
      detail="the FMU does not export \{symbol}",
    )
  }
}

///|
fn fmi3_refs_fixed(references : Array[UInt32]) -> FixedArray[UInt32] {
  let refs = FixedArray::make(references.length(), 0U)
  for index, reference in references {
    refs[index] = reference
  }
  refs
}

///|
fn fmi3_out_flag(values : FixedArray[Int32]) -> Bool {
  values[0] != 0
}

///|
/// FMI 3 has no `setupExperiment`: the start/stop/tolerance values are
/// stored here and applied by `fmi3EnterInitializationMode`.
pub fn Fmi3Instance::setup_experiment(
  self : Fmi3Instance,
  start_time~ : Double,
  stop_time? : Double,
  tolerance? : Double,
) -> Unit raise Fmi3Error {
  self.ensure_live("fmi3SetupExperiment")
  self.pending_start = start_time
  self.pending_stop = stop_time
  self.pending_tolerance = tolerance
}

///|
/// Enters and leaves initialization mode, applying the stored experiment
/// configuration.
pub fn Fmi3Instance::initialize(self : Fmi3Instance) -> Unit raise Fmi3Error {
  self.ensure_live("fmi3EnterInitializationMode")
  let (tolerance_defined, tolerance) = match self.pending_tolerance {
    Some(value) => (1, value)
    None => (0, 0.0)
  }
  let (stop_time_defined, stop_time) = match self.pending_stop {
    Some(value) => (1, value)
    None => (0, 0.0)
  }
  let status = @fmi.FmiStatus::from_int32(
    fmi3_enter_initialization_mode(
      self.handle,
      tolerance_defined,
      tolerance,
      self.pending_start,
      stop_time_defined,
      stop_time,
    ),
  )
  fmi3_fail_on_failure(status, "fmi3EnterInitializationMode")
  let exit_status = @fmi.FmiStatus::from_int32(
    fmi3_exit_initialization_mode(self.handle),
  )
  fmi3_fail_on_failure(exit_status, "fmi3ExitInitializationMode")
}

///|
pub fn Fmi3Instance::terminate(self : Fmi3Instance) -> Unit raise Fmi3Error {
  self.ensure_live("fmi3Terminate")
  let status = @fmi.FmiStatus::from_int32(fmi3_terminate(self.handle))
  fmi3_fail_on_failure(status, "fmi3Terminate")
}

///|
/// Advances one communication step. The status is raised on failure;
/// `Discard` is returned as part of the result for callers that handle it.
pub fn Fmi3Instance::do_step(
  self : Fmi3Instance,
  current_time : Double,
  step_size : Double,
  no_set_fmu_state_prior~ : Bool = true,
) -> Fmi3DoStepResult raise Fmi3Error {
  self.ensure_live("fmi3DoStep")
  let event_needed : FixedArray[Int32] = FixedArray::make(1, 0)
  let terminate : FixedArray[Int32] = FixedArray::make(1, 0)
  let early_return : FixedArray[Int32] = FixedArray::make(1, 0)
  let last_successful_time : FixedArray[Double] = FixedArray::make(1, 0.0)
  let status = @fmi.FmiStatus::from_int32(
    fmi3_do_step(
      self.handle,
      current_time,
      step_size,
      if no_set_fmu_state_prior {
        1
      } else {
        0
      },
      event_needed,
      terminate,
      early_return,
      last_successful_time,
    ),
  )
  fmi3_fail_on_failure(status, "fmi3DoStep")
  {
    status,
    event_handling_needed: fmi3_out_flag(event_needed),
    terminate_simulation: fmi3_out_flag(terminate),
    early_return: fmi3_out_flag(early_return),
    last_successful_time: last_successful_time[0],
  }
}

///|
pub fn Fmi3Instance::enter_step_mode(
  self : Fmi3Instance,
) -> Unit raise Fmi3Error {
  self.ensure_live("fmi3EnterStepMode")
  let status = @fmi.FmiStatus::from_int32(fmi3_enter_step_mode(self.handle))
  fmi3_fail_on_failure(status, "fmi3EnterStepMode")
}

///|
pub fn Fmi3Instance::enter_event_mode(
  self : Fmi3Instance,
) -> Unit raise Fmi3Error {
  self.ensure_live("fmi3EnterEventMode")
  let status = @fmi.FmiStatus::from_int32(fmi3_enter_event_mode(self.handle))
  fmi3_fail_on_failure(status, "fmi3EnterEventMode")
}

///|
/// One `fmi3UpdateDiscreteStates` call.
pub fn Fmi3Instance::update_discrete_states(
  self : Fmi3Instance,
) -> @fmi.EventInfo raise Fmi3Error {
  self.ensure_live("fmi3UpdateDiscreteStates")
  let need_update : FixedArray[Int32] = FixedArray::make(1, 0)
  let terminate : FixedArray[Int32] = FixedArray::make(1, 0)
  let nominals_changed : FixedArray[Int32] = FixedArray::make(1, 0)
  let states_changed : FixedArray[Int32] = FixedArray::make(1, 0)
  let time_defined : FixedArray[Int32] = FixedArray::make(1, 0)
  let next_event_time : FixedArray[Double] = FixedArray::make(1, 0.0)
  let status = @fmi.FmiStatus::from_int32(
    fmi3_update_discrete_states(
      self.handle,
      need_update,
      terminate,
      nominals_changed,
      states_changed,
      time_defined,
      next_event_time,
    ),
  )
  fmi3_fail_on_failure(status, "fmi3UpdateDiscreteStates")
  {
    new_discrete_states_needed: fmi3_out_flag(need_update),
    terminate_simulation: fmi3_out_flag(terminate),
    nominals_changed: fmi3_out_flag(nominals_changed),
    states_changed: fmi3_out_flag(states_changed),
    next_event_time_defined: fmi3_out_flag(time_defined),
    next_event_time: next_event_time[0],
  }
}

///|
pub fn Fmi3Instance::set_time(
  self : Fmi3Instance,
  time : Double,
) -> Unit raise Fmi3Error {
  self.ensure_live("fmi3SetTime")
  let status = @fmi.FmiStatus::from_int32(fmi3_set_time(self.handle, time))
  fmi3_fail_on_failure(status, "fmi3SetTime")
}

///|
pub fn Fmi3Instance::set_continuous_states(
  self : Fmi3Instance,
  states : FixedArray[Double],
) -> Unit raise Fmi3Error {
  self.ensure_live("fmi3SetContinuousStates")
  let status = @fmi.FmiStatus::from_int32(
    fmi3_set_continuous_states(self.handle, states, states.length()),
  )
  fmi3_fail_on_failure(status, "fmi3SetContinuousStates")
}

///|
pub fn Fmi3Instance::get_continuous_states(
  self : Fmi3Instance,
  states : FixedArray[Double],
) -> Unit raise Fmi3Error {
  self.ensure_live("fmi3GetContinuousStates")
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_continuous_states(self.handle, states, states.length()),
  )
  fmi3_fail_on_failure(status, "fmi3GetContinuousStates")
}

///|
pub fn Fmi3Instance::get_continuous_state_derivatives(
  self : Fmi3Instance,
  derivatives : FixedArray[Double],
) -> Unit raise Fmi3Error {
  self.ensure_live("fmi3GetContinuousStateDerivatives")
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_continuous_state_derivatives(
      self.handle,
      derivatives,
      derivatives.length(),
    ),
  )
  fmi3_fail_on_failure(status, "fmi3GetContinuousStateDerivatives")
}

///|
pub fn Fmi3Instance::get_event_indicators(
  self : Fmi3Instance,
  indicators : FixedArray[Double],
) -> Unit raise Fmi3Error {
  self.ensure_live("fmi3GetEventIndicators")
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_event_indicators(self.handle, indicators, indicators.length()),
  )
  fmi3_fail_on_failure(status, "fmi3GetEventIndicators")
}

///|
pub fn Fmi3Instance::get_nominals_of_continuous_states(
  self : Fmi3Instance,
  nominals : FixedArray[Double],
) -> Unit raise Fmi3Error {
  self.ensure_live("fmi3GetNominalsOfContinuousStates")
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_nominals_of_continuous_states(
      self.handle,
      nominals,
      nominals.length(),
    ),
  )
  fmi3_fail_on_failure(status, "fmi3GetNominalsOfContinuousStates")
}

///|
pub fn Fmi3Instance::enter_continuous_time_mode(
  self : Fmi3Instance,
) -> Unit raise Fmi3Error {
  self.ensure_live("fmi3EnterContinuousTimeMode")
  let status = @fmi.FmiStatus::from_int32(
    fmi3_enter_continuous_time_mode(self.handle),
  )
  fmi3_fail_on_failure(status, "fmi3EnterContinuousTimeMode")
}

///|
/// `fmi3CompletedIntegratorStep`; returns
/// `(enter_event_mode, terminate_simulation)`.
pub fn Fmi3Instance::completed_integrator_step(
  self : Fmi3Instance,
  no_set_fmu_state_prior~ : Bool = true,
) -> (Bool, Bool) raise Fmi3Error {
  self.ensure_live("fmi3CompletedIntegratorStep")
  let enter : FixedArray[Int32] = FixedArray::make(1, 0)
  let terminate : FixedArray[Int32] = FixedArray::make(1, 0)
  let status = @fmi.FmiStatus::from_int32(
    fmi3_completed_integrator_step(
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
  fmi3_fail_on_failure(status, "fmi3CompletedIntegratorStep")
  (fmi3_out_flag(enter), fmi3_out_flag(terminate))
}

///|
/// Reads one Float64 value (`fmi3GetFloat64`, scalar form).
pub fn Fmi3Instance::get_float64_one(
  self : Fmi3Instance,
  reference : UInt32,
) -> Double raise Fmi3Error {
  self.get_float64([reference])[0]
}

///|
/// Reads Float64 values for the references, in order.
pub fn Fmi3Instance::get_float64(
  self : Fmi3Instance,
  references : Array[UInt32],
) -> Array[Double] raise Fmi3Error {
  fmi3_require(
    self.library.has_float64_capability(),
    "fmi3GetFloat64",
    "fmi3GetFloat64",
  )
  self.ensure_live("fmi3GetFloat64")
  let refs = fmi3_refs_fixed(references)
  let values : FixedArray[Double] = FixedArray::make(refs.length(), 0.0)
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_float64(self.handle, refs, values, refs.length(), values.length()),
  )
  fmi3_fail_on_failure(status, "fmi3GetFloat64")
  let result = Array(capacity=values.length())
  for value in values {
    result.push(value)
  }
  result
}

///|
/// Reads Float64 values with an explicit value count. Needed for array
/// variables, where one value reference covers {n_values} elements.
pub fn Fmi3Instance::get_float64_values(
  self : Fmi3Instance,
  references : Array[UInt32],
  n_values : Int32,
) -> Array[Double] raise Fmi3Error {
  fmi3_require(
    self.library.has_float64_capability(),
    "fmi3GetFloat64",
    "fmi3GetFloat64",
  )
  self.ensure_live("fmi3GetFloat64")
  if n_values <= 0 {
    return []
  }
  let refs = fmi3_refs_fixed(references)
  let values : FixedArray[Double] = FixedArray::make(n_values, 0.0)
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_float64(self.handle, refs, values, refs.length(), n_values),
  )
  fmi3_fail_on_failure(status, "fmi3GetFloat64")
  let result = Array(capacity=n_values)
  for value in values {
    result.push(value)
  }
  result
}

///|
/// Writes Float64 values for the references (arrays allowed: the number of
/// values may exceed the number of references).
pub fn Fmi3Instance::set_float64(
  self : Fmi3Instance,
  references : Array[UInt32],
  values : Array[Double],
) -> Unit raise Fmi3Error {
  fmi3_require(
    self.library.has_float64_capability(),
    "fmi3SetFloat64",
    "fmi3SetFloat64",
  )
  self.ensure_live("fmi3SetFloat64")
  if references.is_empty() || values.is_empty() {
    raise Fmi3StatusFailed(operation="fmi3SetFloat64", status=Error)
  }
  let refs = fmi3_refs_fixed(references)
  let buffer : FixedArray[Double] = FixedArray::make(values.length(), 0.0)
  for index, value in values {
    buffer[index] = value
  }
  let status = @fmi.FmiStatus::from_int32(
    fmi3_set_float64(self.handle, refs, buffer, refs.length(), buffer.length()),
  )
  fmi3_fail_on_failure(status, "fmi3SetFloat64")
}

///|
pub fn Fmi3Instance::set_float64_one(
  self : Fmi3Instance,
  reference : UInt32,
  value : Double,
) -> Unit raise Fmi3Error {
  self.set_float64([reference], [value])
}

///|
/// Reads Float32 values, widened to Double (exact; Float32 is a subset of
/// Double). Narrowing back happens on set.
pub fn Fmi3Instance::get_float32(
  self : Fmi3Instance,
  references : Array[UInt32],
) -> Array[Double] raise Fmi3Error {
  fmi3_require(
    self.library.has_float32_capability(),
    "fmi3GetFloat32",
    "fmi3GetFloat32",
  )
  self.ensure_live("fmi3GetFloat32")
  let refs = fmi3_refs_fixed(references)
  let values : FixedArray[Double] = FixedArray::make(refs.length(), 0.0)
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_float32_as_double(
      self.handle,
      refs,
      values,
      refs.length(),
      values.length(),
    ),
  )
  fmi3_fail_on_failure(status, "fmi3GetFloat32")
  let result = Array(capacity=values.length())
  for value in values {
    result.push(value)
  }
  result
}

///|
/// Reads Float32 values (widened to Double) with an explicit value count,
/// for array variables where one value reference covers the elements.
pub fn Fmi3Instance::get_float32_values(
  self : Fmi3Instance,
  references : Array[UInt32],
  n_values : Int32,
) -> Array[Double] raise Fmi3Error {
  fmi3_require(
    self.library.has_float32_capability(),
    "fmi3GetFloat32",
    "fmi3GetFloat32",
  )
  self.ensure_live("fmi3GetFloat32")
  if n_values <= 0 {
    return []
  }
  let refs = fmi3_refs_fixed(references)
  let values : FixedArray[Double] = FixedArray::make(n_values, 0.0)
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_float32_as_double(
      self.handle,
      refs,
      values,
      refs.length(),
      n_values,
    ),
  )
  fmi3_fail_on_failure(status, "fmi3GetFloat32")
  let result = Array(capacity=n_values)
  for value in values {
    result.push(value)
  }
  result
}

///|
/// Writes Float32 values (the shim narrows the Double input; arrays
/// allowed: the number of values may exceed the number of references).
pub fn Fmi3Instance::set_float32(
  self : Fmi3Instance,
  references : Array[UInt32],
  values : Array[Double],
) -> Unit raise Fmi3Error {
  fmi3_require(
    self.library.has_float32_capability(),
    "fmi3SetFloat32",
    "fmi3SetFloat32",
  )
  self.ensure_live("fmi3SetFloat32")
  if references.is_empty() || values.is_empty() {
    raise Fmi3StatusFailed(operation="fmi3SetFloat32", status=Error)
  }
  let refs = fmi3_refs_fixed(references)
  let buffer : FixedArray[Double] = FixedArray::make(values.length(), 0.0)
  for index, value in values {
    buffer[index] = value
  }
  let status = @fmi.FmiStatus::from_int32(
    fmi3_set_float32(self.handle, refs, buffer, refs.length(), buffer.length()),
  )
  fmi3_fail_on_failure(status, "fmi3SetFloat32")
}

///|
pub fn Fmi3Instance::set_float32_one(
  self : Fmi3Instance,
  reference : UInt32,
  value : Double,
) -> Unit raise Fmi3Error {
  self.set_float32([reference], [value])
}

///|
/// Reads Int8 values, widened to Int32 (range -128..127).
pub fn Fmi3Instance::get_int8(
  self : Fmi3Instance,
  references : Array[UInt32],
) -> Array[Int32] raise Fmi3Error {
  fmi3_require(self.library.has_int8_capability(), "fmi3GetInt8", "fmi3GetInt8")
  self.ensure_live("fmi3GetInt8")
  let refs = fmi3_refs_fixed(references)
  let values : FixedArray[Int32] = FixedArray::make(refs.length(), 0)
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_int8_as_int32(
      self.handle,
      refs,
      values,
      refs.length(),
      values.length(),
    ),
  )
  fmi3_fail_on_failure(status, "fmi3GetInt8")
  let result = Array(capacity=values.length())
  for value in values {
    result.push(value)
  }
  result
}

///|
/// Reads Int8 values (widened to Int32) with an explicit value count, for
/// array variables where one value reference covers the elements.
pub fn Fmi3Instance::get_int8_values(
  self : Fmi3Instance,
  references : Array[UInt32],
  n_values : Int32,
) -> Array[Int32] raise Fmi3Error {
  fmi3_require(self.library.has_int8_capability(), "fmi3GetInt8", "fmi3GetInt8")
  self.ensure_live("fmi3GetInt8")
  if n_values <= 0 {
    return []
  }
  let refs = fmi3_refs_fixed(references)
  let values : FixedArray[Int32] = FixedArray::make(n_values, 0)
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_int8_as_int32(self.handle, refs, values, refs.length(), n_values),
  )
  fmi3_fail_on_failure(status, "fmi3GetInt8")
  let result = Array(capacity=n_values)
  for value in values {
    result.push(value)
  }
  result
}

///|
/// Writes Int8 values (Int32 in the range -128..127).
pub fn Fmi3Instance::set_int8(
  self : Fmi3Instance,
  references : Array[UInt32],
  values : Array[Int32],
) -> Unit raise Fmi3Error {
  fmi3_require(self.library.has_int8_capability(), "fmi3SetInt8", "fmi3SetInt8")
  self.ensure_live("fmi3SetInt8")
  if references.is_empty() || values.is_empty() {
    raise Fmi3StatusFailed(operation="fmi3SetInt8", status=Error)
  }
  let refs = fmi3_refs_fixed(references)
  let buffer : FixedArray[Int32] = FixedArray::make(values.length(), 0)
  for index, value in values {
    buffer[index] = value
  }
  let status = @fmi.FmiStatus::from_int32(
    fmi3_set_int8_from_int32(
      self.handle,
      refs,
      buffer,
      refs.length(),
      buffer.length(),
    ),
  )
  fmi3_fail_on_failure(status, "fmi3SetInt8")
}

///|
pub fn Fmi3Instance::set_int8_one(
  self : Fmi3Instance,
  reference : UInt32,
  value : Int32,
) -> Unit raise Fmi3Error {
  self.set_int8([reference], [value])
}

///|
/// Reads UInt8 values, widened to Int32 (range 0..255).
pub fn Fmi3Instance::get_uint8(
  self : Fmi3Instance,
  references : Array[UInt32],
) -> Array[Int32] raise Fmi3Error {
  fmi3_require(
    self.library.has_uint8_capability(),
    "fmi3GetUInt8",
    "fmi3GetUInt8",
  )
  self.ensure_live("fmi3GetUInt8")
  let refs = fmi3_refs_fixed(references)
  let values : FixedArray[Int32] = FixedArray::make(refs.length(), 0)
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_uint8_as_int32(
      self.handle,
      refs,
      values,
      refs.length(),
      values.length(),
    ),
  )
  fmi3_fail_on_failure(status, "fmi3GetUInt8")
  let result = Array(capacity=values.length())
  for value in values {
    result.push(value)
  }
  result
}

///|
/// Reads UInt8 values (widened to Int32) with an explicit value count, for
/// array variables where one value reference covers the elements.
pub fn Fmi3Instance::get_uint8_values(
  self : Fmi3Instance,
  references : Array[UInt32],
  n_values : Int32,
) -> Array[Int32] raise Fmi3Error {
  fmi3_require(
    self.library.has_uint8_capability(),
    "fmi3GetUInt8",
    "fmi3GetUInt8",
  )
  self.ensure_live("fmi3GetUInt8")
  if n_values <= 0 {
    return []
  }
  let refs = fmi3_refs_fixed(references)
  let values : FixedArray[Int32] = FixedArray::make(n_values, 0)
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_uint8_as_int32(self.handle, refs, values, refs.length(), n_values),
  )
  fmi3_fail_on_failure(status, "fmi3GetUInt8")
  let result = Array(capacity=n_values)
  for value in values {
    result.push(value)
  }
  result
}

///|
/// Writes UInt8 values (Int32 in the range 0..255).
pub fn Fmi3Instance::set_uint8(
  self : Fmi3Instance,
  references : Array[UInt32],
  values : Array[Int32],
) -> Unit raise Fmi3Error {
  fmi3_require(
    self.library.has_uint8_capability(),
    "fmi3SetUInt8",
    "fmi3SetUInt8",
  )
  self.ensure_live("fmi3SetUInt8")
  if references.is_empty() || values.is_empty() {
    raise Fmi3StatusFailed(operation="fmi3SetUInt8", status=Error)
  }
  let refs = fmi3_refs_fixed(references)
  let buffer : FixedArray[Int32] = FixedArray::make(values.length(), 0)
  for index, value in values {
    buffer[index] = value
  }
  let status = @fmi.FmiStatus::from_int32(
    fmi3_set_uint8_from_int32(
      self.handle,
      refs,
      buffer,
      refs.length(),
      buffer.length(),
    ),
  )
  fmi3_fail_on_failure(status, "fmi3SetUInt8")
}

///|
pub fn Fmi3Instance::set_uint8_one(
  self : Fmi3Instance,
  reference : UInt32,
  value : Int32,
) -> Unit raise Fmi3Error {
  self.set_uint8([reference], [value])
}

///|
/// Reads Int16 values.
pub fn Fmi3Instance::get_int16(
  self : Fmi3Instance,
  references : Array[UInt32],
) -> Array[Int32] raise Fmi3Error {
  fmi3_require(
    self.library.has_int16_capability(),
    "fmi3GetInt16",
    "fmi3GetInt16",
  )
  self.ensure_live("fmi3GetInt16")
  let refs = fmi3_refs_fixed(references)
  let values : FixedArray[Int32] = FixedArray::make(refs.length(), 0)
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_int16_as_int32(
      self.handle,
      refs,
      values,
      refs.length(),
      values.length(),
    ),
  )
  fmi3_fail_on_failure(status, "fmi3GetInt16")
  let result = Array(capacity=values.length())
  for value in values {
    result.push(value)
  }
  result
}

///|
/// Reads Int16 values (widened to Int32) with an explicit value count, for
/// array variables where one value reference covers the elements.
pub fn Fmi3Instance::get_int16_values(
  self : Fmi3Instance,
  references : Array[UInt32],
  n_values : Int32,
) -> Array[Int32] raise Fmi3Error {
  fmi3_require(
    self.library.has_int16_capability(),
    "fmi3GetInt16",
    "fmi3GetInt16",
  )
  self.ensure_live("fmi3GetInt16")
  if n_values <= 0 {
    return []
  }
  let refs = fmi3_refs_fixed(references)
  let values : FixedArray[Int32] = FixedArray::make(n_values, 0)
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_int16_as_int32(self.handle, refs, values, refs.length(), n_values),
  )
  fmi3_fail_on_failure(status, "fmi3GetInt16")
  let result = Array(capacity=n_values)
  for value in values {
    result.push(value)
  }
  result
}

///|
/// Writes Int16 values (Int32 in the range -32768..32767).
pub fn Fmi3Instance::set_int16(
  self : Fmi3Instance,
  references : Array[UInt32],
  values : Array[Int32],
) -> Unit raise Fmi3Error {
  fmi3_require(
    self.library.has_int16_capability(),
    "fmi3SetInt16",
    "fmi3SetInt16",
  )
  self.ensure_live("fmi3SetInt16")
  if references.is_empty() || values.is_empty() {
    raise Fmi3StatusFailed(operation="fmi3SetInt16", status=Error)
  }
  let refs = fmi3_refs_fixed(references)
  let buffer : FixedArray[Int32] = FixedArray::make(values.length(), 0)
  for index, value in values {
    buffer[index] = value
  }
  let status = @fmi.FmiStatus::from_int32(
    fmi3_set_int16_from_int32(
      self.handle,
      refs,
      buffer,
      refs.length(),
      buffer.length(),
    ),
  )
  fmi3_fail_on_failure(status, "fmi3SetInt16")
}

///|
pub fn Fmi3Instance::set_int16_one(
  self : Fmi3Instance,
  reference : UInt32,
  value : Int32,
) -> Unit raise Fmi3Error {
  self.set_int16([reference], [value])
}

///|
/// Reads UInt16 values.
pub fn Fmi3Instance::get_uint16(
  self : Fmi3Instance,
  references : Array[UInt32],
) -> Array[Int32] raise Fmi3Error {
  fmi3_require(
    self.library.has_uint16_capability(),
    "fmi3GetUInt16",
    "fmi3GetUInt16",
  )
  self.ensure_live("fmi3GetUInt16")
  let refs = fmi3_refs_fixed(references)
  let values : FixedArray[Int32] = FixedArray::make(refs.length(), 0)
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_uint16_as_int32(
      self.handle,
      refs,
      values,
      refs.length(),
      values.length(),
    ),
  )
  fmi3_fail_on_failure(status, "fmi3GetUInt16")
  let result = Array(capacity=values.length())
  for value in values {
    result.push(value)
  }
  result
}

///|
/// Reads UInt16 values (widened to Int32) with an explicit value count, for
/// array variables where one value reference covers the elements.
pub fn Fmi3Instance::get_uint16_values(
  self : Fmi3Instance,
  references : Array[UInt32],
  n_values : Int32,
) -> Array[Int32] raise Fmi3Error {
  fmi3_require(
    self.library.has_uint16_capability(),
    "fmi3GetUInt16",
    "fmi3GetUInt16",
  )
  self.ensure_live("fmi3GetUInt16")
  if n_values <= 0 {
    return []
  }
  let refs = fmi3_refs_fixed(references)
  let values : FixedArray[Int32] = FixedArray::make(n_values, 0)
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_uint16_as_int32(self.handle, refs, values, refs.length(), n_values),
  )
  fmi3_fail_on_failure(status, "fmi3GetUInt16")
  let result = Array(capacity=n_values)
  for value in values {
    result.push(value)
  }
  result
}

///|
/// Writes UInt16 values (Int32 in the range 0..65535).
pub fn Fmi3Instance::set_uint16(
  self : Fmi3Instance,
  references : Array[UInt32],
  values : Array[Int32],
) -> Unit raise Fmi3Error {
  fmi3_require(
    self.library.has_uint16_capability(),
    "fmi3SetUInt16",
    "fmi3SetUInt16",
  )
  self.ensure_live("fmi3SetUInt16")
  if references.is_empty() || values.is_empty() {
    raise Fmi3StatusFailed(operation="fmi3SetUInt16", status=Error)
  }
  let refs = fmi3_refs_fixed(references)
  let buffer : FixedArray[Int32] = FixedArray::make(values.length(), 0)
  for index, value in values {
    buffer[index] = value
  }
  let status = @fmi.FmiStatus::from_int32(
    fmi3_set_uint16_from_int32(
      self.handle,
      refs,
      buffer,
      refs.length(),
      buffer.length(),
    ),
  )
  fmi3_fail_on_failure(status, "fmi3SetUInt16")
}

///|
pub fn Fmi3Instance::set_uint16_one(
  self : Fmi3Instance,
  reference : UInt32,
  value : Int32,
) -> Unit raise Fmi3Error {
  self.set_uint16([reference], [value])
}

///|
/// Reads Int32 values.
pub fn Fmi3Instance::get_int32(
  self : Fmi3Instance,
  references : Array[UInt32],
) -> Array[Int32] raise Fmi3Error {
  fmi3_require(
    self.library.has_int32_capability(),
    "fmi3GetInt32",
    "fmi3GetInt32",
  )
  self.ensure_live("fmi3GetInt32")
  let refs = fmi3_refs_fixed(references)
  let values : FixedArray[Int32] = FixedArray::make(refs.length(), 0)
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_int32(self.handle, refs, values, refs.length(), values.length()),
  )
  fmi3_fail_on_failure(status, "fmi3GetInt32")
  let result = Array(capacity=values.length())
  for value in values {
    result.push(value)
  }
  result
}

///|
/// Reads Int32 values with an explicit value count, for array variables
/// where one value reference covers the elements.
pub fn Fmi3Instance::get_int32_values(
  self : Fmi3Instance,
  references : Array[UInt32],
  n_values : Int32,
) -> Array[Int32] raise Fmi3Error {
  fmi3_require(
    self.library.has_int32_capability(),
    "fmi3GetInt32",
    "fmi3GetInt32",
  )
  self.ensure_live("fmi3GetInt32")
  if n_values <= 0 {
    return []
  }
  let refs = fmi3_refs_fixed(references)
  let values : FixedArray[Int32] = FixedArray::make(n_values, 0)
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_int32(self.handle, refs, values, refs.length(), n_values),
  )
  fmi3_fail_on_failure(status, "fmi3GetInt32")
  let result = Array(capacity=n_values)
  for value in values {
    result.push(value)
  }
  result
}

///|
/// Writes Int32 values.
pub fn Fmi3Instance::set_int32(
  self : Fmi3Instance,
  references : Array[UInt32],
  values : Array[Int32],
) -> Unit raise Fmi3Error {
  fmi3_require(
    self.library.has_int32_capability(),
    "fmi3SetInt32",
    "fmi3SetInt32",
  )
  self.ensure_live("fmi3SetInt32")
  if references.is_empty() || values.is_empty() {
    raise Fmi3StatusFailed(operation="fmi3SetInt32", status=Error)
  }
  let refs = fmi3_refs_fixed(references)
  let buffer : FixedArray[Int32] = FixedArray::make(values.length(), 0)
  for index, value in values {
    buffer[index] = value
  }
  let status = @fmi.FmiStatus::from_int32(
    fmi3_set_int32(self.handle, refs, buffer, refs.length(), buffer.length()),
  )
  fmi3_fail_on_failure(status, "fmi3SetInt32")
}

///|
pub fn Fmi3Instance::set_int32_one(
  self : Fmi3Instance,
  reference : UInt32,
  value : Int32,
) -> Unit raise Fmi3Error {
  self.set_int32([reference], [value])
}

///|
/// Reads UInt32 values.
pub fn Fmi3Instance::get_uint32(
  self : Fmi3Instance,
  references : Array[UInt32],
) -> Array[UInt32] raise Fmi3Error {
  fmi3_require(
    self.library.has_uint32_capability(),
    "fmi3GetUInt32",
    "fmi3GetUInt32",
  )
  self.ensure_live("fmi3GetUInt32")
  let refs = fmi3_refs_fixed(references)
  let values : FixedArray[UInt32] = FixedArray::make(refs.length(), 0)
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_uint32(self.handle, refs, values, refs.length(), values.length()),
  )
  fmi3_fail_on_failure(status, "fmi3GetUInt32")
  let result = Array(capacity=values.length())
  for value in values {
    result.push(value)
  }
  result
}

///|
/// Reads UInt32 values with an explicit value count, for array variables
/// where one value reference covers the elements.
pub fn Fmi3Instance::get_uint32_values(
  self : Fmi3Instance,
  references : Array[UInt32],
  n_values : Int32,
) -> Array[UInt32] raise Fmi3Error {
  fmi3_require(
    self.library.has_uint32_capability(),
    "fmi3GetUInt32",
    "fmi3GetUInt32",
  )
  self.ensure_live("fmi3GetUInt32")
  if n_values <= 0 {
    return []
  }
  let refs = fmi3_refs_fixed(references)
  let values : FixedArray[UInt32] = FixedArray::make(n_values, 0U)
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_uint32(self.handle, refs, values, refs.length(), n_values),
  )
  fmi3_fail_on_failure(status, "fmi3GetUInt32")
  let result = Array(capacity=n_values)
  for value in values {
    result.push(value)
  }
  result
}

///|
/// Writes UInt32 values (arrays allowed: the number of values may exceed
/// the number of references).
pub fn Fmi3Instance::set_uint32(
  self : Fmi3Instance,
  references : Array[UInt32],
  values : Array[UInt32],
) -> Unit raise Fmi3Error {
  fmi3_require(
    self.library.has_uint32_capability(),
    "fmi3SetUInt32",
    "fmi3SetUInt32",
  )
  self.ensure_live("fmi3SetUInt32")
  if references.is_empty() || values.is_empty() {
    raise Fmi3StatusFailed(operation="fmi3SetUInt32", status=Error)
  }
  let refs = fmi3_refs_fixed(references)
  let buffer : FixedArray[UInt32] = FixedArray::make(values.length(), 0U)
  for index, value in values {
    buffer[index] = value
  }
  let status = @fmi.FmiStatus::from_int32(
    fmi3_set_uint32(self.handle, refs, buffer, refs.length(), buffer.length()),
  )
  fmi3_fail_on_failure(status, "fmi3SetUInt32")
}

///|
pub fn Fmi3Instance::set_uint32_one(
  self : Fmi3Instance,
  reference : UInt32,
  value : UInt32,
) -> Unit raise Fmi3Error {
  self.set_uint32([reference], [value])
}

///|
/// Reads Int64 values.
pub fn Fmi3Instance::get_int64(
  self : Fmi3Instance,
  references : Array[UInt32],
) -> Array[Int64] raise Fmi3Error {
  fmi3_require(
    self.library.has_int64_capability(),
    "fmi3GetInt64",
    "fmi3GetInt64",
  )
  self.ensure_live("fmi3GetInt64")
  let refs = fmi3_refs_fixed(references)
  let values : FixedArray[Int64] = FixedArray::make(refs.length(), 0L)
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_int64(self.handle, refs, values, refs.length(), values.length()),
  )
  fmi3_fail_on_failure(status, "fmi3GetInt64")
  let result = Array(capacity=values.length())
  for value in values {
    result.push(value)
  }
  result
}

///|
/// Reads Int64 values with an explicit value count, for array variables
/// where one value reference covers the elements.
pub fn Fmi3Instance::get_int64_values(
  self : Fmi3Instance,
  references : Array[UInt32],
  n_values : Int32,
) -> Array[Int64] raise Fmi3Error {
  fmi3_require(
    self.library.has_int64_capability(),
    "fmi3GetInt64",
    "fmi3GetInt64",
  )
  self.ensure_live("fmi3GetInt64")
  if n_values <= 0 {
    return []
  }
  let refs = fmi3_refs_fixed(references)
  let values : FixedArray[Int64] = FixedArray::make(n_values, 0L)
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_int64(self.handle, refs, values, refs.length(), n_values),
  )
  fmi3_fail_on_failure(status, "fmi3GetInt64")
  let result = Array(capacity=n_values)
  for value in values {
    result.push(value)
  }
  result
}

///|
/// Writes Int64 values (arrays allowed: the number of values may exceed
/// the number of references).
pub fn Fmi3Instance::set_int64(
  self : Fmi3Instance,
  references : Array[UInt32],
  values : Array[Int64],
) -> Unit raise Fmi3Error {
  fmi3_require(
    self.library.has_int64_capability(),
    "fmi3SetInt64",
    "fmi3SetInt64",
  )
  self.ensure_live("fmi3SetInt64")
  if references.is_empty() || values.is_empty() {
    raise Fmi3StatusFailed(operation="fmi3SetInt64", status=Error)
  }
  let refs = fmi3_refs_fixed(references)
  let buffer : FixedArray[Int64] = FixedArray::make(values.length(), 0L)
  for index, value in values {
    buffer[index] = value
  }
  let status = @fmi.FmiStatus::from_int32(
    fmi3_set_int64(self.handle, refs, buffer, refs.length(), buffer.length()),
  )
  fmi3_fail_on_failure(status, "fmi3SetInt64")
}

///|
pub fn Fmi3Instance::set_int64_one(
  self : Fmi3Instance,
  reference : UInt32,
  value : Int64,
) -> Unit raise Fmi3Error {
  self.set_int64([reference], [value])
}

///|
/// Writes UInt64 values.
pub fn Fmi3Instance::set_uint64(
  self : Fmi3Instance,
  references : Array[UInt32],
  values : Array[UInt64],
) -> Unit raise Fmi3Error {
  fmi3_require(
    self.library.has_uint64_capability(),
    "fmi3SetUInt64",
    "fmi3SetUInt64",
  )
  self.ensure_live("fmi3SetUInt64")
  if references.is_empty() || values.is_empty() {
    raise Fmi3StatusFailed(operation="fmi3SetUInt64", status=Error)
  }
  let refs = fmi3_refs_fixed(references)
  let buffer : FixedArray[UInt64] = FixedArray::make(values.length(), 0UL)
  for index, value in values {
    buffer[index] = value
  }
  let status = @fmi.FmiStatus::from_int32(
    fmi3_set_uint64(self.handle, refs, buffer, refs.length(), buffer.length()),
  )
  fmi3_fail_on_failure(status, "fmi3SetUInt64")
}

///|
/// Reads UInt64 values.
pub fn Fmi3Instance::get_uint64(
  self : Fmi3Instance,
  references : Array[UInt32],
) -> Array[UInt64] raise Fmi3Error {
  fmi3_require(
    self.library.has_uint64_capability(),
    "fmi3GetUInt64",
    "fmi3GetUInt64",
  )
  self.ensure_live("fmi3GetUInt64")
  let refs = fmi3_refs_fixed(references)
  let values : FixedArray[UInt64] = FixedArray::make(refs.length(), 0UL)
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_uint64(self.handle, refs, values, refs.length(), values.length()),
  )
  fmi3_fail_on_failure(status, "fmi3GetUInt64")
  let result = Array(capacity=values.length())
  for value in values {
    result.push(value)
  }
  result
}

///|
/// Reads UInt64 values with an explicit value count, for array variables
/// where one value reference covers the elements.
pub fn Fmi3Instance::get_uint64_values(
  self : Fmi3Instance,
  references : Array[UInt32],
  n_values : Int32,
) -> Array[UInt64] raise Fmi3Error {
  fmi3_require(
    self.library.has_uint64_capability(),
    "fmi3GetUInt64",
    "fmi3GetUInt64",
  )
  self.ensure_live("fmi3GetUInt64")
  if n_values <= 0 {
    return []
  }
  let refs = fmi3_refs_fixed(references)
  let values : FixedArray[UInt64] = FixedArray::make(n_values, 0UL)
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_uint64(self.handle, refs, values, refs.length(), n_values),
  )
  fmi3_fail_on_failure(status, "fmi3GetUInt64")
  let result = Array(capacity=n_values)
  for value in values {
    result.push(value)
  }
  result
}

///|
/// Reads Boolean values. FMI 3 booleans are one byte on the wire; the shim
/// moves them through an Int8 buffer and this method converts to Bool.
pub fn Fmi3Instance::get_boolean(
  self : Fmi3Instance,
  references : Array[UInt32],
) -> Array[Bool] raise Fmi3Error {
  fmi3_require(
    self.library.has_boolean_capability(),
    "fmi3GetBoolean",
    "fmi3GetBoolean",
  )
  self.ensure_live("fmi3GetBoolean")
  let refs = fmi3_refs_fixed(references)
  let raw : FixedArray[Byte] = FixedArray::make(refs.length(), b'\x00')
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_boolean(self.handle, refs, raw, refs.length(), raw.length()),
  )
  fmi3_fail_on_failure(status, "fmi3GetBoolean")
  let result = Array(capacity=raw.length())
  for value in raw {
    result.push(value.to_int() != 0)
  }
  result
}

///|
/// Reads Boolean values with an explicit value count, for array variables
/// where one value reference covers the elements.
pub fn Fmi3Instance::get_boolean_values(
  self : Fmi3Instance,
  references : Array[UInt32],
  n_values : Int32,
) -> Array[Bool] raise Fmi3Error {
  fmi3_require(
    self.library.has_boolean_capability(),
    "fmi3GetBoolean",
    "fmi3GetBoolean",
  )
  self.ensure_live("fmi3GetBoolean")
  if n_values <= 0 {
    return []
  }
  let refs = fmi3_refs_fixed(references)
  let raw : FixedArray[Byte] = FixedArray::make(n_values, b'\x00')
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_boolean(self.handle, refs, raw, refs.length(), n_values),
  )
  fmi3_fail_on_failure(status, "fmi3GetBoolean")
  let result = Array(capacity=n_values)
  for value in raw {
    result.push(value.to_int() != 0)
  }
  result
}

///|
/// Writes Boolean values (one byte per value on the wire).
pub fn Fmi3Instance::set_boolean(
  self : Fmi3Instance,
  references : Array[UInt32],
  values : Array[Bool],
) -> Unit raise Fmi3Error {
  fmi3_require(
    self.library.has_boolean_capability(),
    "fmi3SetBoolean",
    "fmi3SetBoolean",
  )
  self.ensure_live("fmi3SetBoolean")
  if references.is_empty() || values.is_empty() {
    raise Fmi3StatusFailed(operation="fmi3SetBoolean", status=Error)
  }
  let refs = fmi3_refs_fixed(references)
  let raw : FixedArray[Byte] = FixedArray::make(values.length(), b'\x00')
  for index, value in values {
    raw[index] = (if value { 1 } else { 0 }).to_byte()
  }
  let status = @fmi.FmiStatus::from_int32(
    fmi3_set_boolean(self.handle, refs, raw, refs.length(), raw.length()),
  )
  fmi3_fail_on_failure(status, "fmi3SetBoolean")
}

///|
pub fn Fmi3Instance::set_boolean_one(
  self : Fmi3Instance,
  reference : UInt32,
  value : Bool,
) -> Unit raise Fmi3Error {
  self.set_boolean([reference], [value])
}

///|
/// Reads one string variable.
pub fn Fmi3Instance::get_string_one(
  self : Fmi3Instance,
  reference : UInt32,
) -> String raise Fmi3Error {
  fmi3_require(
    self.library.has_string_capability(),
    "fmi3GetString",
    "fmi3GetString",
  )
  self.ensure_live("fmi3GetString")
  let status_out : FixedArray[Int32] = FixedArray::make(1, 0)
  let bytes = fmi3_get_string(self.handle, reference, status_out)
  fmi3_fail_on_failure(
    @fmi.FmiStatus::from_int32(status_out[0]),
    "fmi3GetString",
  )
  @utf8.decode_lossy(bytes.exact_view())
}

///|
/// Writes one string variable.
pub fn Fmi3Instance::set_string_one(
  self : Fmi3Instance,
  reference : UInt32,
  value : String,
) -> Unit raise Fmi3Error {
  fmi3_require(
    self.library.has_string_capability(),
    "fmi3SetString",
    "fmi3SetString",
  )
  self.ensure_live("fmi3SetString")
  let status = @fmi.FmiStatus::from_int32(
    fmi3_set_string(self.handle, reference, @utf8.encode(value)),
  )
  fmi3_fail_on_failure(status, "fmi3SetString")
}

///|
/// Reads one binary variable.
pub fn Fmi3Instance::get_binary_one(
  self : Fmi3Instance,
  reference : UInt32,
) -> Bytes raise Fmi3Error {
  fmi3_require(
    self.library.has_binary_capability(),
    "fmi3GetBinary",
    "fmi3GetBinary",
  )
  self.ensure_live("fmi3GetBinary")
  let status_out : FixedArray[Int32] = FixedArray::make(1, 0)
  let bytes = fmi3_get_binary(self.handle, reference, status_out)
  fmi3_fail_on_failure(
    @fmi.FmiStatus::from_int32(status_out[0]),
    "fmi3GetBinary",
  )
  bytes
}

///|
/// Writes one binary variable.
pub fn Fmi3Instance::set_binary_one(
  self : Fmi3Instance,
  reference : UInt32,
  value : Bytes,
) -> Unit raise Fmi3Error {
  fmi3_require(
    self.library.has_binary_capability(),
    "fmi3SetBinary",
    "fmi3SetBinary",
  )
  self.ensure_live("fmi3SetBinary")
  let status = @fmi.FmiStatus::from_int32(
    fmi3_set_binary(self.handle, reference, value),
  )
  fmi3_fail_on_failure(status, "fmi3SetBinary")
}

///|
/// Reads String values for the references, one value per reference
/// (`fmi3GetString`; UTF-8 on the wire, decoded into MoonBit Strings).
pub fn Fmi3Instance::get_string(
  self : Fmi3Instance,
  references : Array[UInt32],
) -> Array[String] raise Fmi3Error {
  fmi3_require(
    self.library.has_string_capability(),
    "fmi3GetString",
    "fmi3GetString",
  )
  self.ensure_live("fmi3GetString")
  let result = Array(capacity=references.length())
  for reference in references {
    result.push(self.get_string_one(reference))
  }
  result
}

///|
/// Writes String values, one per reference (`fmi3SetString`; UTF-8 on the
/// wire).
pub fn Fmi3Instance::set_string(
  self : Fmi3Instance,
  references : Array[UInt32],
  values : Array[String],
) -> Unit raise Fmi3Error {
  fmi3_require(
    self.library.has_string_capability(),
    "fmi3SetString",
    "fmi3SetString",
  )
  self.ensure_live("fmi3SetString")
  if references.is_empty() || values.is_empty() {
    raise Fmi3StatusFailed(operation="fmi3SetString", status=Error)
  }
  if references.length() != values.length() {
    raise Fmi3StatusFailed(operation="fmi3SetString", status=Error)
  }
  for index, reference in references {
    self.set_string_one(reference, values[index])
  }
}

///|
/// Reads Binary values for the references, one value per reference
/// (`fmi3GetBinary`; raw bytes, no encoding).
pub fn Fmi3Instance::get_binary(
  self : Fmi3Instance,
  references : Array[UInt32],
) -> Array[Bytes] raise Fmi3Error {
  fmi3_require(
    self.library.has_binary_capability(),
    "fmi3GetBinary",
    "fmi3GetBinary",
  )
  self.ensure_live("fmi3GetBinary")
  let result = Array(capacity=references.length())
  for reference in references {
    result.push(self.get_binary_one(reference))
  }
  result
}

///|
/// Writes Binary values, one per reference (`fmi3SetBinary`; raw bytes, no
/// encoding).
pub fn Fmi3Instance::set_binary(
  self : Fmi3Instance,
  references : Array[UInt32],
  values : Array[Bytes],
) -> Unit raise Fmi3Error {
  fmi3_require(
    self.library.has_binary_capability(),
    "fmi3SetBinary",
    "fmi3SetBinary",
  )
  self.ensure_live("fmi3SetBinary")
  if references.is_empty() || values.is_empty() {
    raise Fmi3StatusFailed(operation="fmi3SetBinary", status=Error)
  }
  if references.length() != values.length() {
    raise Fmi3StatusFailed(operation="fmi3SetBinary", status=Error)
  }
  for index, reference in references {
    self.set_binary_one(reference, values[index])
  }
}

///|
/// Reads one clock state.
pub fn Fmi3Instance::get_clock_one(
  self : Fmi3Instance,
  reference : UInt32,
) -> Bool raise Fmi3Error {
  fmi3_require(
    self.library.has_clock_capability(),
    "fmi3GetClock",
    "fmi3GetClock",
  )
  self.ensure_live("fmi3GetClock")
  let refs : FixedArray[UInt32] = FixedArray::make(1, reference)
  let raw : FixedArray[Byte] = FixedArray::make(1, b'\x00')
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_clock(self.handle, refs, raw, 1),
  )
  fmi3_fail_on_failure(status, "fmi3GetClock")
  raw[0].to_int() != 0
}

///|
/// Writes one clock state.
pub fn Fmi3Instance::set_clock_one(
  self : Fmi3Instance,
  reference : UInt32,
  value : Bool,
) -> Unit raise Fmi3Error {
  fmi3_require(
    self.library.has_clock_capability(),
    "fmi3SetClock",
    "fmi3SetClock",
  )
  self.ensure_live("fmi3SetClock")
  let refs : FixedArray[UInt32] = FixedArray::make(1, reference)
  let raw : FixedArray[Byte] = FixedArray::make(
    1,
    (if value { 1 } else { 0 }).to_byte(),
  )
  let status = @fmi.FmiStatus::from_int32(
    fmi3_set_clock(self.handle, refs, raw, 1),
  )
  fmi3_fail_on_failure(status, "fmi3SetClock")
}

///|
/// Whether the FMU exports the `fmi3*FMUState` group.
pub fn Fmi3Instance::supports_fmu_state(self : Fmi3Instance) -> Bool {
  self.declared_fmu_state && self.library.has_fmu_state_capability()
}

///|
/// Records the model description's canGetAndSetFMUstate declaration.
pub fn Fmi3Instance::declare_fmu_state(
  self : Fmi3Instance,
  declared : Bool,
) -> Unit {
  self.declared_fmu_state = declared
}

///|
/// Records the canSerializeFMUstate declaration.
pub fn Fmi3Instance::declare_serialized_fmu_state(
  self : Fmi3Instance,
  declared : Bool,
) -> Unit {
  self.declared_serialized = declared
}

///|
/// Captures the FMU state (`fmi3GetFMUState`). The state must be released
/// with `free_fmu_state`. Raises `Fmi3CapabilityMissing` when the FMU does
/// not support state capture.
pub fn Fmi3Instance::get_fmu_state(
  self : Fmi3Instance,
) -> @c.Pointer[Unit] raise Fmi3Error {
  fmi3_require(self.supports_fmu_state(), "fmi3GetFMUState", "fmi3GetFMUState")
  self.ensure_live("fmi3GetFMUState")
  let status_out : FixedArray[Int32] = FixedArray::make(1, 0)
  let state = fmi3_get_fmu_state(self.handle, status_out)
  fmi3_fail_on_failure(
    @fmi.FmiStatus::from_int32(status_out[0]),
    "fmi3GetFMUState",
  )
  state
}

///|
/// Restores a previously captured FMU state.
pub fn Fmi3Instance::set_fmu_state(
  self : Fmi3Instance,
  state : @c.Pointer[Unit],
) -> Unit raise Fmi3Error {
  fmi3_require(self.supports_fmu_state(), "fmi3SetFMUState", "fmi3SetFMUState")
  self.ensure_live("fmi3SetFMUState")
  let status = @fmi.FmiStatus::from_int32(
    fmi3_set_fmu_state(self.handle, state),
  )
  fmi3_fail_on_failure(status, "fmi3SetFMUState")
}

///|
/// Releases a captured FMU state.
pub fn Fmi3Instance::free_fmu_state(
  self : Fmi3Instance,
  state : @c.Pointer[Unit],
) -> Unit raise Fmi3Error {
  fmi3_require(
    self.supports_fmu_state(),
    "fmi3FreeFMUState",
    "fmi3FreeFMUState",
  )
  self.ensure_live("fmi3FreeFMUState")
  fmi3_free_fmu_state(self.handle, state)
}

///|
/// The number of log messages that reached the shim.
pub fn Fmi3Instance::log_count(self : Fmi3Instance) -> UInt64 {
  fmi3_instance_log_count(self.handle)
}

///|
pub fn Fmi3Instance::is_freed(self : Fmi3Instance) -> Bool {
  self.freed
}

///|
/// Releases the FMU instance.
pub fn Fmi3Instance::free(self : Fmi3Instance) -> Unit {
  if self.freed {
    return
  }
  // Release an armed rollback state (C-11) before the instance dies; the
  // run is tearing down either way, so this is best effort.
  match self.saved_state {
    Some(state) => {
      fmi3_free_fmu_state(self.handle, state)
      self.saved_state = None
    }
    None => ()
  }
  self.sink.active = false
  fmi3_instance_free(self.handle)
  self.freed = true
  self.library.open_instances = self.library.open_instances - 1
}

///|
fn Fmi3Library::has_float32_capability(self : Fmi3Library) -> Bool {
  shim_has_flag(self.shim, flag_float32)
}

///|
fn Fmi3Library::has_float64_capability(self : Fmi3Library) -> Bool {
  shim_has_flag(self.shim, flag_float64)
}

///|
fn Fmi3Library::has_int8_capability(self : Fmi3Library) -> Bool {
  shim_has_flag(self.shim, flag_int8)
}

///|
fn Fmi3Library::has_uint8_capability(self : Fmi3Library) -> Bool {
  shim_has_flag(self.shim, flag_uint8)
}

///|
fn Fmi3Library::has_int16_capability(self : Fmi3Library) -> Bool {
  shim_has_flag(self.shim, flag_int16)
}

///|
fn Fmi3Library::has_uint16_capability(self : Fmi3Library) -> Bool {
  shim_has_flag(self.shim, flag_uint16)
}

///|
fn Fmi3Library::has_int32_capability(self : Fmi3Library) -> Bool {
  shim_has_flag(self.shim, flag_int32)
}

///|
fn Fmi3Library::has_uint32_capability(self : Fmi3Library) -> Bool {
  shim_has_flag(self.shim, flag_uint32)
}

///|
fn Fmi3Library::has_int64_capability(self : Fmi3Library) -> Bool {
  shim_has_flag(self.shim, flag_int64)
}

///|
fn Fmi3Library::has_uint64_capability(self : Fmi3Library) -> Bool {
  shim_has_flag(self.shim, flag_uint64)
}

///|
fn Fmi3Library::has_boolean_capability(self : Fmi3Library) -> Bool {
  shim_has_flag(self.shim, flag_boolean)
}

///|
fn Fmi3Library::has_string_capability(self : Fmi3Library) -> Bool {
  shim_has_flag(self.shim, flag_string)
}

///|
fn Fmi3Library::has_binary_capability(self : Fmi3Library) -> Bool {
  shim_has_flag(self.shim, flag_binary)
}

///|
fn Fmi3Library::has_clock_capability(self : Fmi3Library) -> Bool {
  shim_has_flag(self.shim, flag_clock)
}

///|
fn Fmi3Library::has_fmu_state_capability(self : Fmi3Library) -> Bool {
  shim_has_flag(self.shim, flag_fmu_state)
}

///|
let flag_scheduled_execution : Int32 = 17

///|
/// `fmi3ActivateModelPartition` resolves independently of the Scheduled
/// Execution instantiate: a clocked CS/ME-only FMU exports it too.
let flag_model_partition : Int32 = 18

///|
/// `fmi3GetIntervalDecimal`, resolved independently like the partition
/// call.
let flag_interval_decimal : Int32 = 19

///|
extern "C" fn fmi3_activate_model_partition(
  handle : @c.Pointer[Unit],
  clock_reference : UInt32,
  activation_time : Double,
) -> Int32 = "moonfmi_fmi3_activate_model_partition"

///|
#borrow(references, intervals, qualifiers)
extern "C" fn fmi3_get_interval_decimal(
  handle : @c.Pointer[Unit],
  references : FixedArray[UInt32],
  intervals : FixedArray[Double],
  qualifiers : FixedArray[Int32],
  count : Int32,
) -> Int32 = "moonfmi_fmi3_get_interval_decimal"

///|
extern "C" fn fmi3_clock_update_count(handle : @c.Pointer[Unit]) -> Int64 = "moonfmi_fmi3_clock_update_count"

///|
extern "C" fn fmi3_intermediate_update_count(
  handle : @c.Pointer[Unit],
) -> Int64 = "moonfmi_fmi3_intermediate_update_count"

///|
/// Whether the FMU exports the Scheduled Execution group.
pub fn Fmi3Instance::supports_scheduled_execution(self : Fmi3Instance) -> Bool {
  shim_has_flag(self.library.shim, flag_scheduled_execution)
}

///|
/// Creates a Scheduled Execution instance.
pub fn Fmi3Library::instantiate_se(
  self : Fmi3Library,
  instance_name~ : String,
  instantiation_token~ : String,
  resource_path~ : String,
  logging_on~ : Bool = true,
  on_log~ : (Fmi3LogMessage) -> Unit = fn(_) {  },
) -> Fmi3Instance raise Fmi3Error {
  self.instantiate_common(
    instance_name~,
    instantiation_token~,
    resource_path~,
    interface_kind=2,
    logging_on~,
    on_log~,
  )
}

///|
/// Activates the model partition of one clock
/// (`fmi3ActivateModelPartition`). `activation_time` is the absolute
/// simulation time of the clock tick.
pub fn Fmi3Instance::activate_model_partition(
  self : Fmi3Instance,
  clock_reference : UInt32,
  activation_time : Double,
) -> Unit raise Fmi3Error {
  fmi3_require(
    self.library.has_model_partition_capability(),
    "fmi3ActivateModelPartition",
    "fmi3ActivateModelPartition",
  )
  self.ensure_live("fmi3ActivateModelPartition")
  let status = @fmi.FmiStatus::from_int32(
    fmi3_activate_model_partition(self.handle, clock_reference, activation_time),
  )
  fmi3_fail_on_failure(status, "fmi3ActivateModelPartition")
}

///|
/// Reads the remaining interval of one clock together with its qualifier
/// (`fmi3GetIntervalDecimal`). Returns `None` when the FMU reports
/// `NotYetKnown`, i.e. the interval is not decidable yet.
pub fn Fmi3Instance::get_interval_decimal(
  self : Fmi3Instance,
  reference : UInt32,
) -> (Double, @fmi.IntervalQualifier)? raise Fmi3Error {
  fmi3_require(
    self.library.has_interval_decimal_capability(),
    "fmi3GetIntervalDecimal",
    "fmi3GetIntervalDecimal",
  )
  self.ensure_live("fmi3GetIntervalDecimal")
  let refs : FixedArray[UInt32] = FixedArray::make(1, reference)
  let intervals : FixedArray[Double] = FixedArray::make(1, 0.0)
  let raw : FixedArray[Int32] = FixedArray::make(1, 0)
  let status = @fmi.FmiStatus::from_int32(
    fmi3_get_interval_decimal(self.handle, refs, intervals, raw, 1),
  )
  fmi3_fail_on_failure(status, "fmi3GetIntervalDecimal")
  match @fmi.IntervalQualifier::from_int32(raw[0]) {
    Some(qualifier) =>
      if qualifier is @fmi.IntervalQualifier::NotYetKnown {
        None
      } else {
        Some((intervals[0], qualifier))
      }
    None =>
      raise Fmi3StatusFailed(operation="fmi3GetIntervalDecimal", status=Error)
  }
}

///|
/// How many output-clock notifications the FMU sent through the
/// clockUpdate callback so far.
pub fn Fmi3Instance::clock_update_count(self : Fmi3Instance) -> Int64 {
  fmi3_clock_update_count(self.handle)
}

///|
/// How many intermediate updates the FMU raised through the
/// `fmi3IntermediateUpdateCallback` so far (one per internal solver step
/// for the Reference-FMUs implementation).
pub fn Fmi3Instance::intermediate_update_count(self : Fmi3Instance) -> Int64 {
  fmi3_intermediate_update_count(self.handle)
}

///|
/// Whether the FMU exports `fmi3ActivateModelPartition` on its own
/// (clocked partitions under CS/ME, or Scheduled Execution).
fn Fmi3Library::has_model_partition_capability(self : Fmi3Library) -> Bool {
  shim_has_flag(self.shim, flag_model_partition)
}

///|
/// Whether the FMU exports `fmi3GetIntervalDecimal` on its own.
fn Fmi3Library::has_interval_decimal_capability(self : Fmi3Library) -> Bool {
  shim_has_flag(self.shim, flag_interval_decimal)
}
