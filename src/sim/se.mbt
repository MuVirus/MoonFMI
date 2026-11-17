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
  // Next due time per interval clock (start + shift for the first tick).
  let next_activation : Array[Double] = []
  for clock in clocks {
    next_activation.push(config.start_time + clock.shift)
  }
  // Countdown state per clock, persisted across grid points:
  // `None` = not armed, `Some(due_time)` = absolute time it must fire.
  // A `Changed` qualifier re-arms; after firing the clock is disarmed until
  // the FMU reports `Changed` again.
  let countdown_due : Array[Double?] = []
  for _ in clocks {
    countdown_due.push(None)
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
  let mut activations = 0
  let mut t = config.start_time
  while t < config.stop_time - se_time_epsilon {
    match config.deadline {
      Some(deadline) =>
        if @env.now() > deadline {
          instance.finish() catch {
            _ => ()
          }
          raise @fmi.SimulationError::Timeout(
            detail="simulation timed out at t=\{t}",
          )
        }
      None => ()
    }
    // Activation rounds. Round 0 collects everything the environment owes
    // at this grid point: constant intervals, triggered policy hits and
    // armed countdowns. Later rounds only re-poll countdown/dynamic clocks
    // because a partition may arm one (Reference-FMUs Clocks: partition 1
    // arms inClock3 at t=4). Triggered clocks fire once per grid point —
    // repeating them every round would never settle.
    let mut round = 0
    while round < config.max_rounds {
      let due : Array[(Double, UInt32, UInt32)] = []
      let mut index = 0
      for clock in clocks {
        if clock.triggered {
          if round == 0 && (config.trigger)(t).contains(clock.value_reference) {
            due.push((t, clock.priority, clock.value_reference))
          }
        } else if clock.countdown {
          match instance.get_interval(clock.value_reference) {
            Some((interval, qualifier)) =>
              if qualifier is @fmi.IntervalQualifier::Changed {
                countdown_due[index] = Some(t + interval)
              }
            None => ()
          }
          match countdown_due[index] {
            Some(due_time) =>
              if due_time <= t + se_time_epsilon {
                due.push((t, clock.priority, clock.value_reference))
              }
            None => ()
          }
        } else {
          match clock.period {
            Some(period) =>
              while next_activation[index] <= t + se_time_epsilon {
                due.push(
                  (
                    next_activation[index],
                    clock.priority,
                    clock.value_reference,
                  ),
                )
                next_activation[index] = next_activation[index] + period
              }
            None =>
              // Dynamic interval without countdown semantics: poll once
              // per round and activate on a known, expired interval.
              match instance.get_interval(clock.value_reference) {
                Some((interval, qualifier)) =>
                  if qualifier is @fmi.IntervalQualifier::Changed &&
                    interval <= se_time_epsilon {
                    due.push((t, clock.priority, clock.value_reference))
                  }
                None => ()
              }
          }
        }
        index += 1
      }
      if due.is_empty() {
        break
      }
      due.sort_by(se_due_key)
      for entry in due {
        instance.activate_partition(entry.2, entry.0) catch {
          error => {
            instance.finish() catch {
              _ => ()
            }
            raise se_fail(
              operation="fmi3ActivateModelPartition",
              detail=error.message(),
            )
          }
        }
        activations += 1
        // A fired countdown clock is disarmed until the FMU re-arms it.
        let mut disarm = 0
        for clock in clocks {
          if clock.countdown && clock.value_reference == entry.2 {
            countdown_due[disarm] = None
          }
          disarm += 1
        }
      }
      round += 1
    }
    if round >= config.max_rounds {
      instance.finish() catch {
        _ => ()
      }
      raise @fmi.SimulationError::Config(
        detail="clock activations did not settle within max_rounds at t=\{t}",
      )
    }
    // Observe output clocks (Reference implementations clear the flag on
    // read, so each true observation consumes one pulse).
    for vr in config.output_clocks {
      let _ = instance.get_clock(vr)
    }
    // Record the grid point.
    times.push(t)
    for k, vr in config.record {
      let value = instance.read_real(vr) catch {
        error => {
          instance.finish() catch {
            _ => ()
          }
          raise se_fail(operation="fmi3GetReal", detail=error.message())
        }
      }
      series[k].push(value)
    }
    t = t + config.step_size
  }
  times.push(config.stop_time)
  for k, vr in config.record {
    let value = instance.read_real(vr) catch {
      error => raise se_fail(operation="fmi3GetReal", detail=error.message())
    }
    series[k].push(value)
  }
  instance.finish()
  let steps : Int32 = times.length() - 1
  { times, series, steps, events: activations, }
}
