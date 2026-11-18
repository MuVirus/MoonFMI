///|
/// `Fmi2Instance` as a co-simulation `CsInstance` (task C-01). Status
/// failures and exceptions are normalized into the master algorithm's
/// `SimulationError`.
pub impl @fmi.CsInstance for Fmi2Instance with fn setup_experiment(
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
pub impl @fmi.CsInstance for Fmi2Instance with fn initialize(self) {
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
pub impl @fmi.CsInstance for Fmi2Instance with fn step(self, t, h) {
  let status = Fmi2Instance::do_step(self, t, h)
  if status.is_failure() {
    raise @fmi.FmiCall(
      operation="fmi2DoStep",
      detail="status \{status.name()} at t=\{t}",
    )
  }
  if status is Discard {
    raise @fmi.FmiCall(
      operation="fmi2DoStep",
      detail="the FMU discarded the step at t=\{t}",
    )
  }
}

///|
pub impl @fmi.CsInstance for Fmi2Instance with fn read_real(
  self,
  value_reference,
) {
  Fmi2Instance::get_real_one(self, value_reference) catch {
    error => raise @fmi.FmiCall(operation="fmi2GetReal", detail=error.message())
  }
}

///|
pub impl @fmi.CsInstance for Fmi2Instance with fn write_real(
  self,
  value_reference,
  value,
) {
  Fmi2Instance::set_real_one(self, value_reference, value) catch {
    error => raise @fmi.FmiCall(operation="fmi2SetReal", detail=error.message())
  }
}

///|
pub impl @fmi.CsInstance for Fmi2Instance with fn finish(self) {
  Fmi2Instance::terminate(self) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi2Terminate", detail=error.message())
  }
}

///|
/// FMI 2 reports `Discard` through the `fmi2DoStep` status, so `try_step`
/// surfaces it as a `Discarded` error instead of pretending the FMU
/// reached `t + h` (master-algorithm.md §3.5, task C-11). FMI 2 has no
/// `lastSuccessfulTime`, so the field is `None`.
pub impl @fmi.CsInstance for Fmi2Instance with fn try_step(self, t, h) -> Double raise @fmi.SimulationError {
  let status = Fmi2Instance::do_step(self, t, h)
  if status is Discard {
    raise @fmi.Discarded(
      detail="fmi2DoStep reported Discard at t=\{t}",
      last_successful_time=None,
    )
  }
  if status.is_failure() {
    raise @fmi.FmiCall(
      operation="fmi2DoStep",
      detail="status \{status.name()} at t=\{t}",
    )
  }
  t + h
}

///|
pub impl @fmi.CsInstance for Fmi2Instance with fn supports_state_capture(self) -> Bool {
  Fmi2Instance::supports_fmu_state(self)
}

///|
pub impl @fmi.CsInstance for Fmi2Instance with fn begin_rollback_point(self) -> Unit raise @fmi.SimulationError {
  let state = Fmi2Instance::get_fmu_state(self) catch {
    error =>
      raise @fmi.FmiCall(operation="fmi2GetFMUstate", detail=error.message())
  }
  self.saved_state = Some(state)
}

///|
pub impl @fmi.CsInstance for Fmi2Instance with fn rollback(self) -> Unit raise @fmi.SimulationError {
  match self.saved_state {
    Some(state) =>
      Fmi2Instance::set_fmu_state(self, state) catch {
        error =>
          raise @fmi.FmiCall(
            operation="fmi2SetFMUstate",
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
pub impl @fmi.CsInstance for Fmi2Instance with fn commit_rollback_point(self) -> Unit raise @fmi.SimulationError {
  match self.saved_state {
    Some(state) => {
      Fmi2Instance::free_fmu_state(self, state) catch {
        error =>
          raise @fmi.FmiCall(
            operation="fmi2FreeFMUstate",
            detail=error.message(),
          )
      }
      self.saved_state = None
    }
    None => ()
  }
}

///|
pub extend Fmi2Instance with @fmi.CsInstance::{
  initialize,
  step,
  read_real,
  write_real,
  finish,
}
