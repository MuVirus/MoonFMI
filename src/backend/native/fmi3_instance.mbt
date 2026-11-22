///|
/// `Fmi3Instance` as a co-simulation `CsInstance` (task C-17). Unlike FMI 2,
/// the FMU may ask for event handling (`eventHandlingNeeded`) and may return
/// early; the impl handles both internally so the master algorithm stays
/// version-agnostic (master-algorithm.md §3.3/§3.4).
pub impl @fmi.CsInstance for Fmi3Instance with fn setup_experiment(
  self,
  start~,
  stop~,
) {
  match stop {
    Some(value) =>
      Fmi3Instance::setup_experiment(self, start_time=start, stop_time=value) catch {
        error =>
          raise @fmi.FmiCall(
            operation="fmi3SetupExperiment",
            detail=error.message(),
          )
      }
    None =>
      Fmi3Instance::setup_experiment(self, start_time=start) catch {
        error =>
          raise @fmi.FmiCall(
            operation="fmi3SetupExperiment",
            detail=error.message(),
          )
      }
  }
}

///|
/// Tolerance for "reached the target time" comparisons (mirrors the
/// master algorithm epsilon; kept local because the sim package is private
/// about its constant).
let fmi3_time_epsilon : Double = 0.000000001

///|
let fmi3_max_step_retries : Int32 = 100

///|
let fmi3_max_event_iterations : Int32 = 100

///|
pub impl @fmi.CsInstance for Fmi3Instance with fn initialize(self) {
  Fmi3Instance::initialize(self) catch {
    error =>
      raise @fmi.FmiCall(
        operation="fmi3EnterInitializationMode",
        detail=error.message(),
      )
  }
  // With `eventModeUsed = true` the FMU is in event mode right after
  // initialization: settle the initial event, then enter step mode
  // (master-algorithm.md §3.1/§3.3).
  let mut iterations = 0
  while true {
    let info = Fmi3Instance::update_discrete_states(self) catch {
      error =>
        raise @fmi.FmiCall(
          operation="fmi3UpdateDiscreteStates",
          detail=error.message(),
        )
    }
    if info.terminate_simulation {
      return
    }
    if !info.new_discrete_states_needed {
      break
    }
    iterations += 1
    if iterations > fmi3_max_event_iterations {
      raise @fmi.FmiCall(
        operation="fmi3UpdateDiscreteStates",
        detail="initial event iteration limit (\{fmi3_max_event_iterations}) exceeded",
      )
    }
  }
  Fmi3Instance::enter_step_mode(self) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi3EnterStepMode", detail=error.message())
  }
}

///|
/// The FMI 3 co-simulation step body shared by `step` and `try_step`:
/// loop `fmi3DoStep` until the FMU reaches `t + h`, handling event mode
/// requests and early returns on the way (master-algorithm.md §3.3/§3.4).
/// Returns the time the FMU actually reached.
///
/// A `Discard` status is not swallowed: it raises `Discarded` with the
/// FMU-confirmed `lastSuccessfulTime` so the master algorithm can roll
/// back or continue from the confirmed time (master-algorithm.md §3.5,
/// task C-11). While a rollback point is armed, `fmi3DoStep` runs with
/// `noSetFMUStatePrior = fmi3False` because the master may restore the
/// captured state after a discard.
fn Fmi3Instance::fmi3_cs_advance(
  self : Fmi3Instance,
  t : Double,
  h : Double,
) -> Double raise @fmi.SimulationError {
  let target = t + h
  let mut current = t
  let mut attempts = 0
  // A time event the FMU declared while handling events: the next do
  // step must not cross it (master-algorithm.md §4.5). The gate matters:
  // an undefined next event time reads 0.0.
  let mut event_cap : Double? = None
  while current < target - fmi3_time_epsilon {
    attempts += 1
    if attempts > fmi3_max_step_retries {
      raise @fmi.FmiCall(
        operation="fmi3DoStep",
        detail="early return did not converge within \{fmi3_max_step_retries} attempts at t=\{t}",
      )
    }
    let mut step_target = target
    match event_cap {
      Some(cap) => if cap > current && cap < target { step_target = cap }
      None => ()
    }
    let rollback_armed = self.saved_state is Some(_)
    let result = Fmi3Instance::do_step(
      self,
      current,
      step_target - current,
      no_set_fmu_state_prior=!rollback_armed,
    ) catch {
      error =>
        raise @fmi.FmiCall(operation="fmi3DoStep", detail=error.message())
    }
    if result.terminate_simulation {
      // The master treats the step as done; the next read/record reflects
      // the terminated state (FMI 2 behaves the same way).
      return target
    }
    if result.status is Discard {
      // The FMU could not reach the requested time; it confirmed progress
      // up to `lastSuccessfulTime`. Hand the decision to the master
      // (rollback with capture, continue from the confirmed time without)
      // rather than pretending the step completed (master-algorithm.md §3.5).
      raise @fmi.Discarded(
        detail="fmi3DoStep reported Discard at t=\{current}",
        last_successful_time=Some(result.last_successful_time),
      )
    }
    if result.event_handling_needed {
      // Event mode loop: EnterEventMode → UpdateDiscreteStates until
      // settled → EnterStepMode (master-algorithm.md §3.3).
      Fmi3Instance::enter_event_mode(self) catch {
        error =>
          raise @fmi.FmiCall(
            operation="fmi3EnterEventMode",
            detail=error.message(),
          )
      }
      let mut iterations = 0
      let mut settled : @fmi.EventInfo? = None
      while true {
        let info = Fmi3Instance::update_discrete_states(self) catch {
          error =>
            raise @fmi.FmiCall(
              operation="fmi3UpdateDiscreteStates",
              detail=error.message(),
            )
        }
        if info.terminate_simulation {
          return target
        }
        if !info.new_discrete_states_needed {
          settled = Some(info)
          break
        }
        iterations += 1
        if iterations > fmi3_max_event_iterations {
          raise @fmi.FmiCall(
            operation="fmi3UpdateDiscreteStates",
            detail="event iteration limit (\{fmi3_max_event_iterations}) exceeded at t=\{current}",
          )
        }
      }
      Fmi3Instance::enter_step_mode(self) catch {
        error =>
          raise @fmi.FmiCall(
            operation="fmi3EnterStepMode",
            detail=error.message(),
          )
      }
      match settled {
        Some(info) =>
          event_cap = if info.next_event_time_defined {
            Some(info.next_event_time)
          } else {
            None
          }
        None => ()
      }
    }
    if result.early_return {
      let resumed = result.last_successful_time
      if !(resumed > current) {
        raise @fmi.FmiCall(
          operation="fmi3DoStep",
          detail="early return reported no progress: lastSuccessfulTime=\{resumed} at t=\{current}",
        )
      }
      current = resumed
    } else {
      current = step_target
    }
  }
  target
}

///|
pub impl @fmi.CsInstance for Fmi3Instance with fn step(self, t, h) {
  let _ = Fmi3Instance::fmi3_cs_advance(self, t, h)
}

///|
/// `try_step` runs the same step body but reports the reached time, and
/// surfaces a `Discard` status as `Discarded` with the FMU-confirmed
/// progress instead of treating the step as complete (C-11).
pub impl @fmi.CsInstance for Fmi3Instance with fn try_step(self, t, h) -> Double raise @fmi.SimulationError {
  Fmi3Instance::fmi3_cs_advance(self, t, h)
}

///|
pub impl @fmi.CsInstance for Fmi3Instance with fn supports_state_capture(self) -> Bool {
  Fmi3Instance::supports_fmu_state(self)
}

///|
pub impl @fmi.CsInstance for Fmi3Instance with fn begin_rollback_point(self) -> Unit raise @fmi.SimulationError {
  let state = Fmi3Instance::get_fmu_state(self) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi3GetFMUState", detail=error.message())
  }
  self.saved_state = Some(state)
}

///|
pub impl @fmi.CsInstance for Fmi3Instance with fn rollback(self) -> Unit raise @fmi.SimulationError {
  match self.saved_state {
    Some(state) =>
      Fmi3Instance::set_fmu_state(self, state) catch {
        error =>
          raise @fmi.FmiCall(
            operation="fmi3SetFMUState",
            detail=error.message(),
          )
      }
    None =>
      raise @fmi.Config(
        detail="rollback requested but no FMU state was captured",
      )
  }
}

///|
pub impl @fmi.CsInstance for Fmi3Instance with fn commit_rollback_point(self) -> Unit raise @fmi.SimulationError {
  match self.saved_state {
    Some(state) => {
      Fmi3Instance::free_fmu_state(self, state) catch {
        error =>
          raise @fmi.FmiCall(
            operation="fmi3FreeFMUState",
            detail=error.message(),
          )
      }
      self.saved_state = None
    }
    None => ()
  }
}

///|
pub impl @fmi.CsInstance for Fmi3Instance with fn read_real(
  self,
  value_reference,
) {
  Fmi3Instance::get_float64_one(self, value_reference) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi3GetFloat64", detail=error.message())
  }
}

///|
pub impl @fmi.CsInstance for Fmi3Instance with fn read_real_values(
  self,
  value_reference,
  n_values,
) -> Array[Double] raise @fmi.SimulationError {
  // One value reference covers all the elements of an FMI 3 array.
  Fmi3Instance::get_float64_values(self, [value_reference], n_values) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi3GetFloat64", detail=error.message())
  }
}

///|
pub impl @fmi.CsInstance for Fmi3Instance with fn write_real(
  self,
  value_reference,
  value,
) {
  Fmi3Instance::set_float64_one(self, value_reference, value) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi3SetFloat64", detail=error.message())
  }
}

///|
pub impl @fmi.CsInstance for Fmi3Instance with fn finish(self) {
  Fmi3Instance::terminate(self) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi3Terminate", detail=error.message())
  }
}

///|
/// Typed Int32 signal access over the existing `fmi3GetInt32` /
/// `fmi3SetInt32` channels (C-20 follow-up).
pub impl @fmi.CsInstance for Fmi3Instance with fn read_integer(
  self,
  value_reference,
) {
  let values = Fmi3Instance::get_int32(self, [value_reference]) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi3GetInt32", detail=error.message())
  }
  values[0]
}

///|
pub impl @fmi.CsInstance for Fmi3Instance with fn write_integer(
  self,
  value_reference,
  value,
) {
  Fmi3Instance::set_int32_one(self, value_reference, value) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi3SetInt32", detail=error.message())
  }
}

///|
/// Typed Boolean signal access over the existing `fmi3GetBoolean` /
/// `fmi3SetBoolean` channels.
pub impl @fmi.CsInstance for Fmi3Instance with fn read_boolean(
  self,
  value_reference,
) {
  let values = Fmi3Instance::get_boolean(self, [value_reference]) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi3GetBoolean", detail=error.message())
  }
  values[0]
}

///|
pub impl @fmi.CsInstance for Fmi3Instance with fn write_boolean(
  self,
  value_reference,
  value,
) {
  Fmi3Instance::set_boolean_one(self, value_reference, value) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi3SetBoolean", detail=error.message())
  }
}

///|
/// `Fmi3Instance` as a model-exchange `MeInstance` (task C-18). The
/// operations map one to one onto the FMI 3 continuous-time functions.
pub impl @fmi.MeInstance for Fmi3Instance with fn setup_experiment(
  self,
  start~,
  stop~,
) {
  match stop {
    Some(value) =>
      Fmi3Instance::setup_experiment(self, start_time=start, stop_time=value) catch {
        error =>
          raise @fmi.FmiCall(
            operation="fmi3SetupExperiment",
            detail=error.message(),
          )
      }
    None =>
      Fmi3Instance::setup_experiment(self, start_time=start) catch {
        error =>
          raise @fmi.FmiCall(
            operation="fmi3SetupExperiment",
            detail=error.message(),
          )
      }
  }
}

///|
pub impl @fmi.MeInstance for Fmi3Instance with fn initialize(self) {
  Fmi3Instance::initialize(self) catch {
    error =>
      raise @fmi.FmiCall(
        operation="fmi3EnterInitializationMode",
        detail=error.message(),
      )
  }
}

///|
pub impl @fmi.MeInstance for Fmi3Instance with fn set_time(self, time) {
  Fmi3Instance::set_time(self, time) catch {
    error => raise @fmi.FmiCall(operation="fmi3SetTime", detail=error.message())
  }
}

///|
pub impl @fmi.MeInstance for Fmi3Instance with fn set_continuous_states(
  self,
  states,
) {
  Fmi3Instance::set_continuous_states(self, states) catch {
    error =>
      raise @fmi.FmiCall(
        operation="fmi3SetContinuousStates",
        detail=error.message(),
      )
  }
}

///|
pub impl @fmi.MeInstance for Fmi3Instance with fn get_continuous_states(
  self,
  states,
) {
  Fmi3Instance::get_continuous_states(self, states) catch {
    error =>
      raise @fmi.FmiCall(
        operation="fmi3GetContinuousStates",
        detail=error.message(),
      )
  }
}

///|
pub impl @fmi.MeInstance for Fmi3Instance with fn get_derivatives(
  self,
  derivatives,
) {
  Fmi3Instance::get_continuous_state_derivatives(self, derivatives) catch {
    error =>
      raise @fmi.FmiCall(
        operation="fmi3GetContinuousStateDerivatives",
        detail=error.message(),
      )
  }
}

///|
pub impl @fmi.MeInstance for Fmi3Instance with fn get_event_indicators(
  self,
  indicators,
) {
  Fmi3Instance::get_event_indicators(self, indicators) catch {
    error =>
      raise @fmi.FmiCall(
        operation="fmi3GetEventIndicators",
        detail=error.message(),
      )
  }
}

///|
pub impl @fmi.MeInstance for Fmi3Instance with fn get_nominals_of_continuous_states(
  self,
  nominals,
) {
  Fmi3Instance::get_nominals_of_continuous_states(self, nominals) catch {
    error =>
      raise @fmi.FmiCall(
        operation="fmi3GetNominalsOfContinuousStates",
        detail=error.message(),
      )
  }
}

///|
pub impl @fmi.MeInstance for Fmi3Instance with fn enter_event_mode(self) {
  Fmi3Instance::enter_event_mode(self) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi3EnterEventMode", detail=error.message())
  }
}

///|
pub impl @fmi.MeInstance for Fmi3Instance with fn new_discrete_states(self) {
  Fmi3Instance::update_discrete_states(self) catch {
    error =>
      raise @fmi.FmiCall(
        operation="fmi3UpdateDiscreteStates",
        detail=error.message(),
      )
  }
}

///|
pub impl @fmi.MeInstance for Fmi3Instance with fn enter_continuous_time_mode(
  self,
) {
  Fmi3Instance::enter_continuous_time_mode(self) catch {
    error =>
      raise @fmi.FmiCall(
        operation="fmi3EnterContinuousTimeMode",
        detail=error.message(),
      )
  }
}

///|
pub impl @fmi.MeInstance for Fmi3Instance with fn completed_integrator_step(
  self,
  no_set_fmu_state_prior~,
) {
  Fmi3Instance::completed_integrator_step(self, no_set_fmu_state_prior~) catch {
    error =>
      raise @fmi.FmiCall(
        operation="fmi3CompletedIntegratorStep",
        detail=error.message(),
      )
  }
}

///|
pub impl @fmi.MeInstance for Fmi3Instance with fn read_real(
  self,
  value_reference,
) {
  Fmi3Instance::get_float64_one(self, value_reference) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi3GetFloat64", detail=error.message())
  }
}

///|
pub impl @fmi.MeInstance for Fmi3Instance with fn read_real_values(
  self,
  value_reference,
  n_values,
) -> Array[Double] raise @fmi.SimulationError {
  // One value reference covers all the elements of an FMI 3 array.
  Fmi3Instance::get_float64_values(self, [value_reference], n_values) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi3GetFloat64", detail=error.message())
  }
}

///|
pub impl @fmi.MeInstance for Fmi3Instance with fn write_real(
  self,
  value_reference,
  value,
) {
  Fmi3Instance::set_float64_one(self, value_reference, value) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi3SetFloat64", detail=error.message())
  }
}

///|
pub impl @fmi.MeInstance for Fmi3Instance with fn finish(self) {
  Fmi3Instance::terminate(self) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi3Terminate", detail=error.message())
  }
}

// Trait methods are no longer promoted implicitly; declare the promotions
// explicitly so `Fmi3Instance` keeps its regular methods. The overlapping
// names (read_real, finish, write_real) are promoted once from the
// co-simulation trait: both impls delegate to the same concrete methods.

///|
pub extend Fmi3Instance with @fmi.CsInstance::{
  read_real,
  finish,
  step,
  write_real,
}

///|
pub extend Fmi3Instance with @fmi.MeInstance::{
  get_derivatives,
  new_discrete_states,
}

///|
pub impl @fmi.SeInstance for Fmi3Instance with fn setup_experiment(
  self,
  start~,
  stop~,
) {
  match stop {
    Some(value) =>
      Fmi3Instance::setup_experiment(self, start_time=start, stop_time=value) catch {
        error =>
          raise @fmi.FmiCall(
            operation="fmi3SetupExperiment",
            detail=error.message(),
          )
      }
    None =>
      Fmi3Instance::setup_experiment(self, start_time=start) catch {
        error =>
          raise @fmi.FmiCall(
            operation="fmi3SetupExperiment",
            detail=error.message(),
          )
      }
  }
}

///|
pub impl @fmi.SeInstance for Fmi3Instance with fn initialize(self) {
  Fmi3Instance::initialize(self) catch {
    error =>
      raise @fmi.FmiCall(
        operation="fmi3ExitInitializationMode",
        detail=error.message(),
      )
  }
}

///|
pub impl @fmi.SeInstance for Fmi3Instance with fn activate_partition(
  self,
  clock_reference,
  activation_time,
) {
  Fmi3Instance::activate_model_partition(self, clock_reference, activation_time) catch {
    error =>
      raise @fmi.FmiCall(
        operation="fmi3ActivateModelPartition",
        detail=error.message(),
      )
  }
}

///|
pub impl @fmi.SeInstance for Fmi3Instance with fn set_clock(
  self,
  reference,
  active,
) {
  Fmi3Instance::set_clock_one(self, reference, active) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi3SetClock", detail=error.message())
  }
}

///|
pub impl @fmi.SeInstance for Fmi3Instance with fn get_clock(self, reference) {
  Fmi3Instance::get_clock_one(self, reference) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi3GetClock", detail=error.message())
  }
}

///|
pub impl @fmi.SeInstance for Fmi3Instance with fn get_interval(self, reference) {
  Fmi3Instance::get_interval_decimal(self, reference) catch {
    error =>
      raise @fmi.FmiCall(
        operation="fmi3GetIntervalDecimal",
        detail=error.message(),
      )
  }
}

///|
pub impl @fmi.SeInstance for Fmi3Instance with fn read_real(
  self,
  value_reference,
) {
  Fmi3Instance::get_float64_one(self, value_reference) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi3GetFloat64", detail=error.message())
  }
}

///|
pub impl @fmi.SeInstance for Fmi3Instance with fn read_real_values(
  self,
  value_reference,
  n_values,
) -> Array[Double] raise @fmi.SimulationError {
  // One value reference covers all the elements of an FMI 3 array.
  Fmi3Instance::get_float64_values(self, [value_reference], n_values) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi3GetFloat64", detail=error.message())
  }
}

///|
pub impl @fmi.SeInstance for Fmi3Instance with fn write_real(
  self,
  value_reference,
  value,
) {
  Fmi3Instance::set_float64_one(self, value_reference, value) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi3SetFloat64", detail=error.message())
  }
}

///|
pub impl @fmi.SeInstance for Fmi3Instance with fn finish(self) {
  Fmi3Instance::terminate(self) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi3Terminate", detail=error.message())
  }
}

///|
pub extend Fmi3Instance with @fmi.SeInstance::{
  set_clock,
  activate_partition,
  get_clock,
  get_interval,
}
