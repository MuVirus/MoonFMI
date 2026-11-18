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

  /// Advance one communication step from `t` by at most `h` and report the
  /// time the FMU actually reached. Normally that is `t + h`; the method
  /// exists so backends can report a `Discard` precisely instead of
  /// guessing (master-algorithm.md §3.5, task C-11). The default
  /// implementation runs `step` and assumes it reached `t + h`.
  fn try_step(self : Self, t : Double, h : Double) -> Double raise SimulationError = _

  /// Whether the backend can capture and restore FMU state (`C-09`
  /// primitives) so the master can roll back a discarded step. The default
  /// implementation reports `false`.
  fn supports_state_capture(self : Self) -> Bool = _

  /// Capture the FMU state as a rollback point for the step in progress.
  /// The default implementation refuses because `supports_state_capture`
  /// reports `false`.
  fn begin_rollback_point(self : Self) -> Unit raise SimulationError = _

  /// Restore the FMU to the state captured by `begin_rollback_point`.
  fn rollback(self : Self) -> Unit raise SimulationError = _

  /// Release the captured state after the step settled successfully. The
  /// default implementation is a no-op: without capture there is nothing
  /// to release. A backend that overrides `begin_rollback_point` must
  /// override this one as well, or captured state leaks.
  fn commit_rollback_point(self : Self) -> Unit raise SimulationError = _

  /// Read one real output by value reference.
  fn read_real(self : Self, value_reference : UInt32) -> Double raise SimulationError

  /// Write one real input by value reference.
  fn write_real(self : Self, value_reference : UInt32, value : Double) -> Unit raise SimulationError

  /// Terminate the instance before freeing it.
  fn finish(self : Self) -> Unit raise SimulationError
}

///|
/// Default `try_step`: run `step` and report `t + h`. Backends that can
/// observe a `Discard` override this to raise `Discarded` instead.
impl CsInstance with fn try_step(self, t, h) -> Double raise SimulationError {
  self.step(t, h)
  t + h
}

///|
/// Default state-capture surface: unsupported. Backends implementing the
/// `C-09` primitives override all four rollback methods together.
impl CsInstance with fn supports_state_capture(_self) -> Bool {
  false
}

///|
impl CsInstance with fn begin_rollback_point(_self) -> Unit raise SimulationError {
  raise Config(detail="FMU state capture is not supported by this backend")
}

///|
impl CsInstance with fn rollback(_self) -> Unit raise SimulationError {
  raise Config(detail="FMU state capture is not supported by this backend")
}

///|
impl CsInstance with fn commit_rollback_point(_self) -> Unit raise SimulationError {
  // no default capture, nothing to release
}

///|
/// Master-algorithm failures, normalized across backends.
pub(all) suberror SimulationError {
  Config(detail~ : String)
  FmiCall(operation~ : String, detail~ : String)
  /// The run exceeded its wall-clock deadline.
  Timeout(detail~ : String)
  /// The FMU discarded a communication step. `last_successful_time`
  /// carries the progress the FMU confirmed; FMI 3 reports it explicitly,
  /// FMI 2 has no such report and the field is `None`. The master reacts
  /// by rolling back (when state capture is available) or by continuing
  /// from the confirmed time (master-algorithm.md §3.5).
  Discarded(detail~ : String, last_successful_time~ : Double?)
}

///|
pub fn SimulationError::message(self : SimulationError) -> String {
  match self {
    Config(detail~) => "invalid simulation configuration: \{detail}"
    FmiCall(operation~, detail~) => "\{operation} failed: \{detail}"
    Timeout(detail~) => "simulation timed out: \{detail}"
    Discarded(detail~, last_successful_time~) =>
      match last_successful_time {
        Some(confirmed) =>
          "the FMU discarded the step (confirmed up to t=\{confirmed}): \{detail}"
        None => "the FMU discarded the step: \{detail}"
      }
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

///|
/// Qualifier returned with a clock interval by `fmi3GetIntervalDecimal`.
#derive(Eq, Debug)
pub(all) enum IntervalQualifier {
  /// The interval cannot be decided yet.
  NotYetKnown
  /// The interval is unchanged since the previous query.
  Unchanged
  /// The interval changed since the previous query.
  Changed
}

///|
pub extend IntervalQualifier with Eq::{not_equal, equal}

///|
pub extend IntervalQualifier with @debug.Debug::{to_repr}

///|
/// Converts the FMI 3 `fmi3IntervalQualifier` enum value to an IntervalQualifier.
pub fn IntervalQualifier::from_int32(value : Int32) -> IntervalQualifier? {
  match value {
    0 => Some(NotYetKnown)
    1 => Some(Unchanged)
    2 => Some(Changed)
    _ => None
  }
}

///|
/// The Scheduled Execution instance surface the clock scheduler needs
/// (`src/sim/se.mbt`). One clock = one model partition, activated by the
/// environment; output clocks are observed via `get_clock`.
pub(open) trait SeInstance {
  /// Configure the experiment (`fmi3EnterInitializationMode` arguments are
  /// held by the backend; `stop` may be omitted).
  fn setup_experiment(self : Self, start~ : Double, stop~ : Double?) -> Unit raise SimulationError

  /// Enter and leave initialization mode.
  fn initialize(self : Self) -> Unit raise SimulationError

  /// `fmi3ActivateModelPartition` — runs the model partition of one clock.
  fn activate_partition(
    self : Self,
    clock_reference : UInt32,
    activation_time : Double,
  ) -> Unit raise SimulationError

  /// `fmi3SetClock` — activates/deactivates one clock.
  fn set_clock(self : Self, reference : UInt32, active : Bool) -> Unit raise SimulationError

  /// `fmi3GetClock` — reads one clock activation state.
  fn get_clock(self : Self, reference : UInt32) -> Bool raise SimulationError

  /// `fmi3GetIntervalDecimal` for one clock; `None` means NotYetKnown.
  fn get_interval(self : Self, reference : UInt32) -> (
    Double,
    IntervalQualifier,
  )? raise SimulationError

  /// Read one real output by value reference.
  fn read_real(self : Self, value_reference : UInt32) -> Double raise SimulationError

  /// Write one real input by value reference.
  fn write_real(self : Self, value_reference : UInt32, value : Double) -> Unit raise SimulationError

  /// Terminate the instance before freeing it.
  fn finish(self : Self) -> Unit raise SimulationError
}
