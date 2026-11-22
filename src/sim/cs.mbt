///|
/// One recorded array output: a single value reference covers
/// `element_count` elements, each recorded as its own series named
/// `<name>[i]` (1-based, like the model description).
pub(all) struct RecordedArray {
  value_reference : UInt32
  name : String
  element_count : Int32
}

///|
/// Configuration of one co-simulation run (task C-10). Times follow the
/// master-algorithm design: the grid is `start_time + k * step_size`, the
/// final step is truncated to `stop_time`.
pub struct CsConfig {
  start_time : Double
  stop_time : Double
  step_size : Double
  /// Value references to record after every communication point.
  record : Array[UInt32]
  /// Array outputs to record element by element (FMI 2: consecutive
  /// references; FMI 3: one reference with an element count).
  record_arrays : Array[RecordedArray]
  /// When `Some`, the master runs SE-style clock activation rounds at
  /// every communication point and observes the output clocks (FMI 3
  /// clocked partitions; 0.8.1).
  clocks : ClockScheduling?
  /// Wall-clock deadline in the same unit as `@env.now()`; the loop
  /// aborts with `SimulationError::Timeout` once it is passed.
  deadline : UInt64?
}

///|
pub fn CsConfig::new(
  start_time~ : Double,
  stop_time~ : Double,
  step_size~ : Double,
  record~ : Array[UInt32],
  record_arrays~ : Array[RecordedArray] = [],
  clocks~ : ClockScheduling? = None,
  deadline~ : UInt64? = None,
) -> CsConfig {
  { start_time, stop_time, step_size, record, record_arrays, clocks, deadline, }
}

///|
/// Recorded samples: one timestamp per row, one value series per recorded
/// variable (task C-12). `events` counts the mid-run events the master
/// handled; co-simulation masters report 0 because FMI 2 CS events stay
/// inside the FMU.
pub(all) struct SimulationResult {
  times : Array[Double]
  series : Array[Array[Double]]
  steps : Int32
  events : Int32
}

///|
pub fn SimulationResult::times(self : SimulationResult) -> Array[Double] {
  self.times
}

///|
pub fn SimulationResult::series(
  self : SimulationResult,
) -> Array[Array[Double]] {
  self.series
}

///|
pub fn SimulationResult::steps(self : SimulationResult) -> Int32 {
  self.steps
}

///|
pub fn SimulationResult::events(self : SimulationResult) -> Int32 {
  self.events
}

///|
/// Tolerance for "reached stop_time" comparisons; communication points
/// accumulate floating point error, so exact equality is wrong here.
let time_epsilon : Double = 0.000000001

///|
/// How often a discarded communication step may be retried before the run
/// is aborted (master-algorithm.md §3.5). The retry halves the step, so
/// the cap bounds the work to a constant factor of the original grid.
let max_discard_retries : Int32 = 5

///|
/// A retried step never shrinks below this size. Below it the numbers are
/// numerically meaningless and retrying would only burn the attempt cap.
let min_retry_step : Double = 0.000000000001

///|
/// The FMI 2 co-simulation master algorithm:
/// `setup → initialize → record(t0) → loop { doStep; record(t+h) } → finish`.
/// The final step is truncated to `stop_time`; errors abort the run.
///
/// A `Discard` from the FMU is not treated as success (master-algorithm.md
/// §3.5): with FMU state capture available the step is rolled back and
/// retried with a halved step size (capped at `max_discard_retries`);
/// without capture, an FMI 3 FMU that confirms `lastSuccessfulTime`
/// progress lets the run continue from there, and anything else aborts
/// with a diagnostic instead of recording a fictitious time.
pub fn run_cs_simulation(
  instance : &@fmi.CsInstance,
  config~ : CsConfig,
) -> SimulationResult raise @fmi.SimulationError {
  if !(config.stop_time > config.start_time) {
    raise @fmi.Config(
      detail="stop_time (\{config.stop_time}) must be greater than start_time (\{config.start_time})",
    )
  }
  if !(config.step_size > 0.0) {
    raise @fmi.Config(detail="step_size must be positive")
  }
  instance.setup_experiment(
    start=config.start_time,
    stop=Some(config.stop_time),
  )
  instance.initialize()
  let times : Array[Double] = []
  let series : Array[Array[Double]] = []
  for _ in config.record {
    series.push([])
  }
  for array_output in config.record_arrays {
    for _i = 0; _i < array_output.element_count; _i = _i + 1 {
      series.push([])
    }
  }
  let record = fn(t) raise @fmi.SimulationError {
    times.push(t)
    for index, value_reference in config.record {
      series[index].push(instance.read_real(value_reference))
    }
    let mut offset = config.record.length()
    for array_output in config.record_arrays {
      let values = instance.read_real_values(
        array_output.value_reference,
        array_output.element_count,
      )
      for index, value in values {
        series[offset + index].push(value)
      }
      offset += values.length()
    }
  }
  record(config.start_time)
  // Clock scheduling (FMI 3 clocked partitions, 0.8.1): SE-style
  // activation rounds at every communication point. The schedule carries
  // the mutable per-run state across grid points.
  let clock_state : (ClockScheduling, ClockSchedule)? = match config.clocks {
    Some(scheduling) =>
      Some(
        (
          scheduling,
          ClockSchedule::new(
            clocks=scheduling.clocks,
            start_time=config.start_time,
          ),
        ),
      )
    None => None
  }
  // Any error below aborts the run; finish best-effort first so the FMU
  // releases its state before the error propagates.
  errdefer finish_best_effort(instance)
  let mut t = config.start_time
  let mut steps = 0
  while t < config.stop_time - time_epsilon {
    match config.deadline {
      Some(deadline) =>
        if @env.now() > deadline {
          raise @fmi.Timeout(detail="t=\{t}")
        }
      None => ()
    }
    if clock_state is Some(pair) {
      let (scheduling, schedule) = pair
      let activations = run_clock_rounds(
        scheduling~,
        schedule~,
        t~,
        max_rounds=scheduling.max_rounds,
      )
      let _ = activations
      let _ = observe_output_clocks(scheduling~)
    }
    let mut h = config.step_size
    if t + h > config.stop_time {
      h = config.stop_time - t
    }
    // Rollback state is armed once per grid point and reused for every
    // retry of that point (master-algorithm.md §3.5 strategy 1).
    let can_capture = instance.supports_state_capture()
    let mut attempts = 0
    let mut reached = t
    while true {
      attempts += 1
      if attempts > max_discard_retries {
        raise @fmi.Config(
          detail="the step at t=\{t} was discarded \{max_discard_retries} times without converging",
        )
      }
      if can_capture {
        instance.begin_rollback_point()
      }
      let mut discarded = false
      let outcome = instance.try_step(t, h) catch {
        error =>
          match error {
            Discarded(detail~, last_successful_time~) => {
              discarded = true
              if can_capture {
                instance.rollback()
                let retried = h / 2.0
                if !(retried >= min_retry_step) {
                  raise @fmi.Config(
                    detail="discarded step at t=\{t}: halved step \{retried} is below the \{min_retry_step} retry floor",
                  )
                }
                h = retried
              } else {
                match last_successful_time {
                  Some(confirmed) =>
                    if confirmed > t + time_epsilon {
                      // FMI 3 confirmed real progress; continue the run
                      // from there instead of recording a fictitious
                      // t + h. The next grid point uses the full
                      // configured step again.
                      reached = confirmed
                    } else {
                      raise @fmi.Config(
                        detail="the FMU discarded the step at t=\{t}, confirmed no progress, and FMU state capture is unavailable: \{detail}",
                      )
                    }
                  None =>
                    raise @fmi.Config(
                      detail="the FMU discarded the step at t=\{t} and FMU state capture is unavailable: \{detail}",
                    )
                }
              }
              t
            }
            other => {
              // The run aborts; release the armed capture so the FMU
              // state handle does not outlive the step (backends also
              // free an armed state when the instance is torn down).
              if can_capture {
                instance.commit_rollback_point() catch {
                  _ => ()
                }
              }
              raise other
            }
          }
      }
      if discarded {
        if reached > t + time_epsilon {
          break
        }
        // capture path: retry this grid point with the halved step
        continue
      }
      if can_capture {
        instance.commit_rollback_point()
      }
      reached = outcome
      break
    }
    t = reached
    record(t)
    steps += 1
  }
  instance.finish()
  { times, series, steps, events: 0, }
}
