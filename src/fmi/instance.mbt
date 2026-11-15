///|
/// The co-simulation instance surface the master algorithm needs
/// (task C-01). Keeping the master algorithm behind this trait means it
/// can be tested with mocks and swapped between FMI 2 / FMI 3 backends.
/// Errors are normalized into `SimulationError` by the implementors.
pub(open) trait CsInstance {
  /// Configure the experiment (`fmi2SetupExperiment`).
  fn setup_experiment(self : Self, start~ : Double, stop~ : Double?) -> Unit raise SimulationError

  /// Enter and leave initialization mode.
  fn initialize(self : Self) -> Unit raise SimulationError

  /// Advance one communication step from `t` by `h`.
  fn step(self : Self, t : Double, h : Double) -> Unit raise SimulationError

  /// Read one real output by value reference.
  fn read_real(self : Self, value_reference : UInt32) -> Double raise SimulationError

  /// Write one real input by value reference.
  fn write_real(self : Self, value_reference : UInt32, value : Double) -> Unit raise SimulationError

  /// Terminate the instance before freeing it.
  fn finish(self : Self) -> Unit raise SimulationError
}

///|
/// Master-algorithm failures, normalized across backends.
pub(all) suberror SimulationError {
  Config(detail~ : String)
  FmiCall(operation~ : String, detail~ : String)
  /// The run exceeded its wall-clock deadline.
  Timeout(detail~ : String)
}

///|
pub fn SimulationError::message(self : SimulationError) -> String {
  match self {
    Config(detail~) => "invalid simulation configuration: \{detail}"
    FmiCall(operation~, detail~) => "\{operation} failed: \{detail}"
    Timeout(detail~) => "simulation timed out: \{detail}"
  }
}

///|
/// Result of one `newDiscreteStates` iteration (FMI 2 `fmi2EventInfo`).
pub(all) struct EventInfo {
  new_discrete_states_needed : Bool
  terminate_simulation : Bool
  nominals_changed : Bool
  states_changed : Bool
  next_event_time_defined : Bool
  next_event_time : Double
}

///|
/// The model-exchange instance surface the ME master algorithm needs.
/// `states`/`derivatives`/`indicators`/`nominals` buffers are sized by the
/// caller: states and nominals use the model's state count, indicators the
/// declared `numberOfEventIndicators`. Errors are normalized into
/// `SimulationError` by the implementors.
pub(open) trait MeInstance {
  /// Configure the experiment (`fmi2SetupExperiment`).
  fn setup_experiment(self : Self, start~ : Double, stop~ : Double?) -> Unit raise SimulationError

  /// Enter and leave initialization mode.
  fn initialize(self : Self) -> Unit raise SimulationError

  /// `fmi2SetTime`.
  fn set_time(self : Self, time : Double) -> Unit raise SimulationError

  /// `fmi2SetContinuousStates`; buffer length must equal the state count.
  fn set_continuous_states(self : Self, states : FixedArray[Double]) -> Unit raise SimulationError

  /// `fmi2GetContinuousStates`; fills `states` (length = state count).
  fn get_continuous_states(self : Self, states : FixedArray[Double]) -> Unit raise SimulationError

  /// `fmi2GetDerivatives`; fills `derivatives` (length = state count).
  fn get_derivatives(self : Self, derivatives : FixedArray[Double]) -> Unit raise SimulationError

  /// `fmi2GetEventIndicators`; fills `indicators`.
  fn get_event_indicators(self : Self, indicators : FixedArray[Double]) -> Unit raise SimulationError

  /// `fmi2GetNominalsOfContinuousStates`; fills `nominals`.
  fn get_nominals_of_continuous_states(
    self : Self,
    nominals : FixedArray[Double],
  ) -> Unit raise SimulationError

  /// `fmi2EnterEventMode`.
  fn enter_event_mode(self : Self) -> Unit raise SimulationError

  /// One `fmi2NewDiscreteStates` iteration.
  fn new_discrete_states(self : Self) -> EventInfo raise SimulationError

  /// `fmi2EnterContinuousTimeMode`.
  fn enter_continuous_time_mode(self : Self) -> Unit raise SimulationError

  /// `fmi2CompletedIntegratorStep`; returns `(enter_event_mode, terminate_simulation)`.
  fn completed_integrator_step(self : Self, no_set_fmu_state_prior~ : Bool) -> (
    Bool,
    Bool,
  ) raise SimulationError

  /// Read one real value by value reference (outputs, and states reinit).
  fn read_real(self : Self, value_reference : UInt32) -> Double raise SimulationError

  /// Write one real value by value reference (inputs before stepping).
  fn write_real(self : Self, value_reference : UInt32, value : Double) -> Unit raise SimulationError

  /// Terminate the instance before freeing it.
  fn finish(self : Self) -> Unit raise SimulationError
}
