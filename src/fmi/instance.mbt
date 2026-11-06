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
}

///|
pub fn SimulationError::message(self : SimulationError) -> String {
  match self {
    Config(detail~) => "invalid simulation configuration: \{detail}"
    FmiCall(operation~, detail~) => "\{operation} failed: \{detail}"
  }
}
