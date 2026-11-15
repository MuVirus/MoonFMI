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
pub impl @fmi.CsInstance for Fmi3Instance with fn step(self, t, h) {
  let target = t + h
  let mut current = t
  let mut attempts = 0
  while current < target - fmi3_time_epsilon {
    attempts += 1
    if attempts > fmi3_max_step_retries {
      raise @fmi.FmiCall(
        operation="fmi3DoStep",
        detail="early return did not converge within \{fmi3_max_step_retries} attempts at t=\{t}",
      )
    }
    let result = Fmi3Instance::do_step(self, current, target - current) catch {
      error =>
        raise @fmi.FmiCall(operation="fmi3DoStep", detail=error.message())
    }
    if result.terminate_simulation {
      // The master treats the step as done; the next read/record reflects
      // the terminated state (FMI 2 behaves the same way).
      return
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
      current = target
    }
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
