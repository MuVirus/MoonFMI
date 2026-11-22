// Scheduled Execution scheduler (roadmap: FMI 3 SE).
//
// The environment drives model partitions: interval clocks fire at
// `start + shift + k*period` (constant periods from the model description;
// dynamic intervals are polled via fmi3GetIntervalDecimal), triggered
// clocks fire when the host policy (`SeConfig.trigger`) says so, and
// countdown clocks fire when the FMU reports an expired interval. When
// several partitions are due at the same instant they run in ascending
// `priority` order (lower value first, matching Reference-FMUs' Clocks
// where priority 0 is the highest priority partition). Output clocks are
// activated by the FMU itself and observed via fmi3GetClock — Reference
// implementations clear the flag on read, so the scheduler counts observed
// pulses in `SimulationResult.events` together with the partition
// activations; the clockUpdate notification count stays available through
// the backend (`Fmi3Instance::clock_update_count`).

///|
/// Scheduler view of one input clock. `period` is the known interval for
/// constant-style clocks; countdown/dynamic clocks leave it `None` and are
/// polled via `SeInstance::get_interval` instead.
pub struct SeClockInfo {
  value_reference : UInt32
  priority : UInt32
  period : Double?
  shift : Double
  triggered : Bool
  countdown : Bool
}

///|
pub fn SeClockInfo::new(
  value_reference~ : UInt32,
  priority~ : UInt32 = 0,
  period~ : Double? = None,
  shift~ : Double = 0.0,
  triggered~ : Bool = false,
  countdown~ : Bool = false,
) -> SeClockInfo {
  { value_reference, priority, period, shift, triggered, countdown, }
}

///|
pub struct SeConfig {
  start_time : Double
  stop_time : Double
  step_size : Double
  record : Array[UInt32]
  /// Array outputs to record element by element (FMI 3: one reference
  /// with an element count).
  record_arrays : Array[RecordedArray]
  deadline : UInt64?
  /// Upper bound on activation rounds per grid point; guards against
  /// clock cascades that never settle.
  max_rounds : Int32
  /// Host policy for triggered input clocks: returns the value references
  /// to fire at simulation time `t`.
  trigger : (Double) -> Array[UInt32]
  /// Output clocks to poll after every activation round.
  output_clocks : Array[UInt32]
}

///|
pub fn SeConfig::new(
  start_time~ : Double,
  stop_time~ : Double,
  step_size~ : Double,
  record~ : Array[UInt32],
  record_arrays~ : Array[RecordedArray] = [],
  deadline~ : UInt64? = None,
  max_rounds~ : Int32 = 100,
  trigger~ : (Double) -> Array[UInt32] = fn(_) { [] },
  output_clocks~ : Array[UInt32] = [],
) -> SeConfig {
  {
    start_time,
    stop_time,
    step_size,
    record,
    record_arrays,
    deadline,
    max_rounds,
    trigger,
    output_clocks,
  }
}

///|
/// Trigger policy that fires every triggered input clock at every grid
/// point (the deterministic default when the user has no finer policy).
pub fn SeConfig::trigger_all_each_step(
  clocks~ : Array[SeClockInfo],
) -> (Double) -> Array[UInt32] {
  let triggered = clocks
    .iter()
    .filter(fn(c) { c.triggered })
    .map(fn(c) { c.value_reference })
    .collect()
  fn(_t) { triggered }
}

///|
let se_time_epsilon : Double = 0.000000001

///|
fn se_fail(operation~ : String, detail~ : String) -> @fmi.SimulationError {
  @fmi.SimulationError::FmiCall(operation~, detail~)
}

///|
/// One due activation: (activation time, priority, clock value reference).
/// The lexicographic order of that triple is the activation order.
fn se_due_key(
  a : (Double, UInt32, UInt32),
  b : (Double, UInt32, UInt32),
) -> Int32 {
  if a.0 < b.0 {
    -1
  } else if a.0 > b.0 {
    1
  } else if a.1 < b.1 {
    -1
  } else if a.1 > b.1 {
    1
  } else if a.2 < b.2 {
    -1
  } else if a.2 > b.2 {
    1
  } else {
    0
  }
}

///|
/// Runs a Scheduled Execution simulation on the grid `start..stop` with
/// `step_size`. Partition activations happen at grid points in priority
/// order; the result records the `record` variables at every grid point
/// and `events` counts total partition activations.
pub fn run_se_simulation(
  instance : &@fmi.SeInstance,
  clocks~ : Array[SeClockInfo],
  config~ : SeConfig,
) -> SimulationResult raise @fmi.SimulationError {
  if config.step_size <= 0.0 {
    raise @fmi.SimulationError::Config(detail="step_size must be positive")
  }
  if config.stop_time < config.start_time {
    raise @fmi.SimulationError::Config(
      detail="stop_time must not be before start_time",
    )
  }
  // Mutable per-run clock bookkeeping (next due times, countdown arming),
  // shared with the CS/ME clock scheduling.
  let schedule = ClockSchedule::new(clocks~, start_time=config.start_time)
  let scheduling : ClockScheduling = ClockScheduling::new(
    clocks~,
    get_interval=vr => instance.get_interval(vr),
    activate_partition=(vr, activation_time) => {
      instance.activate_partition(vr, activation_time)
    },
    get_clock=vr => instance.get_clock(vr),
    trigger=config.trigger,
    output_clocks=config.output_clocks,
  )
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
  // One recording pass: scalars, then every array element as its own
  // series. Used at every grid point and once more at stop_time.
  let record_values = fn() raise @fmi.SimulationError {
    for k, vr in config.record {
      let value = instance.read_real(vr) catch {
        error => raise se_fail(operation="fmi3GetReal", detail=error.message())
      }
      series[k].push(value)
    }
    let mut offset = config.record.length()
    for array_output in config.record_arrays {
      let values = instance.read_real_values(
        array_output.value_reference,
        array_output.element_count,
      ) catch {
        error => raise se_fail(operation="fmi3GetReal", detail=error.message())
      }
      for index, value in values {
        series[offset + index].push(value)
      }
      offset += values.length()
    }
  }
  // Any error below aborts the run; finish best-effort first so the FMU
  // releases its state before the error propagates.
  errdefer se_finish_best_effort(instance)
  let mut activations = 0
  let mut t = config.start_time
  while t < config.stop_time - se_time_epsilon {
    match config.deadline {
      Some(deadline) =>
        if @env.now() > deadline {
          raise @fmi.SimulationError::Timeout(
            detail="simulation timed out at t=\{t}",
          )
        }
      None => ()
    }
    // Activation rounds (shared with the CS/ME clock scheduling): round 0
    // collects everything the environment owes at this grid point, later
    // rounds re-poll countdown/dynamic clocks until settled.
    activations += run_clock_rounds(
      scheduling~,
      schedule~,
      t~,
      max_rounds=config.max_rounds,
    )
    // Observe output clocks (Reference implementations clear the flag on
    // read, so each true observation consumes one pulse).
    let _ = observe_output_clocks(scheduling~)
    // Record the grid point.
    times.push(t)
    record_values()
    t = t + config.step_size
  }
  times.push(config.stop_time)
  record_values()
  instance.finish()
  let steps : Int32 = times.length() - 1
  { times, series, steps, events: activations, }
}

///|
/// Best-effort finish for abort paths (SeInstance flavor of the CS
/// helper); finish failures are swallowed.
fn se_finish_best_effort(instance : &@fmi.SeInstance) -> Unit {
  instance.finish() catch {
    _ => ()
  }
}
