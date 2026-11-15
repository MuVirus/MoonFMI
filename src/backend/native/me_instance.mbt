///|
/// `Fmi2Instance` as a model-exchange `MeInstance` (task C-13). Status
/// failures are normalized into the master algorithm's `SimulationError`.
pub impl @fmi.MeInstance for Fmi2Instance with fn setup_experiment(
  self,
  start~,
  stop~,
) {
  match stop {
    Some(value) =>
      Fmi2Instance::setup_experiment(self, start_time=start, stop_time=value) catch {
        error =>
          raise @fmi.FmiCall(
            operation="fmi2SetupExperiment",
            detail=error.message(),
          )
      }
    None =>
      Fmi2Instance::setup_experiment(self, start_time=start) catch {
        error =>
          raise @fmi.FmiCall(
            operation="fmi2SetupExperiment",
            detail=error.message(),
          )
      }
  }
}

///|
pub impl @fmi.MeInstance for Fmi2Instance with fn initialize(self) {
  Fmi2Instance::enter_initialization_mode(self) catch {
    error =>
      raise @fmi.FmiCall(
        operation="fmi2EnterInitializationMode",
        detail=error.message(),
      )
  }
  Fmi2Instance::exit_initialization_mode(self) catch {
    error =>
      raise @fmi.FmiCall(
        operation="fmi2ExitInitializationMode",
        detail=error.message(),
      )
  }
}

///|
pub impl @fmi.MeInstance for Fmi2Instance with fn set_time(self, time) {
  Fmi2Instance::set_time(self, time) catch {
    error => raise @fmi.FmiCall(operation="fmi2SetTime", detail=error.message())
  }
}

///|
pub impl @fmi.MeInstance for Fmi2Instance with fn set_continuous_states(
  self,
  states,
) {
  Fmi2Instance::set_continuous_states(self, states) catch {
    error =>
      raise @fmi.FmiCall(
        operation="fmi2SetContinuousStates",
        detail=error.message(),
      )
  }
}

///|
pub impl @fmi.MeInstance for Fmi2Instance with fn get_continuous_states(
  self,
  states,
) {
  Fmi2Instance::get_continuous_states(self, states) catch {
    error =>
      raise @fmi.FmiCall(
        operation="fmi2GetContinuousStates",
        detail=error.message(),
      )
  }
}

///|
pub impl @fmi.MeInstance for Fmi2Instance with fn get_derivatives(
  self,
  derivatives,
) {
  Fmi2Instance::get_derivatives(self, derivatives) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi2GetDerivatives", detail=error.message())
  }
}

///|
pub impl @fmi.MeInstance for Fmi2Instance with fn get_event_indicators(
  self,
  indicators,
) {
  Fmi2Instance::get_event_indicators(self, indicators) catch {
    error =>
      raise @fmi.FmiCall(
        operation="fmi2GetEventIndicators",
        detail=error.message(),
      )
  }
}

///|
pub impl @fmi.MeInstance for Fmi2Instance with fn get_nominals_of_continuous_states(
  self,
  nominals,
) {
  Fmi2Instance::get_nominals_of_continuous_states(self, nominals) catch {
    error =>
      raise @fmi.FmiCall(
        operation="fmi2GetNominalsOfContinuousStates",
        detail=error.message(),
      )
  }
}

///|
pub impl @fmi.MeInstance for Fmi2Instance with fn enter_event_mode(self) {
  Fmi2Instance::enter_event_mode(self) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi2EnterEventMode", detail=error.message())
  }
}

///|
pub impl @fmi.MeInstance for Fmi2Instance with fn new_discrete_states(self) {
  Fmi2Instance::new_discrete_states(self) catch {
    error =>
      raise @fmi.FmiCall(
        operation="fmi2NewDiscreteStates",
        detail=error.message(),
      )
  }
}

///|
pub impl @fmi.MeInstance for Fmi2Instance with fn enter_continuous_time_mode(
  self,
) {
  Fmi2Instance::enter_continuous_time_mode(self) catch {
    error =>
      raise @fmi.FmiCall(
        operation="fmi2EnterContinuousTimeMode",
        detail=error.message(),
      )
  }
}

///|
pub impl @fmi.MeInstance for Fmi2Instance with fn completed_integrator_step(
  self,
  no_set_fmu_state_prior~,
) {
  Fmi2Instance::completed_integrator_step(self, no_set_fmu_state_prior~) catch {
    error =>
      raise @fmi.FmiCall(
        operation="fmi2CompletedIntegratorStep",
        detail=error.message(),
      )
  }
}

///|
pub impl @fmi.MeInstance for Fmi2Instance with fn read_real(
  self,
  value_reference,
) {
  Fmi2Instance::get_real_one(self, value_reference) catch {
    error => raise @fmi.FmiCall(operation="fmi2GetReal", detail=error.message())
  }
}

///|
pub impl @fmi.MeInstance for Fmi2Instance with fn write_real(
  self,
  value_reference,
  value,
) {
  Fmi2Instance::set_real_one(self, value_reference, value) catch {
    error => raise @fmi.FmiCall(operation="fmi2SetReal", detail=error.message())
  }
}

///|
pub impl @fmi.MeInstance for Fmi2Instance with fn finish(self) {
  Fmi2Instance::terminate(self) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi2Terminate", detail=error.message())
  }
}
