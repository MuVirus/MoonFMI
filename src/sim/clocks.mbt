///|
/// Clock scheduling shared by the SE master and the CS/ME masters
/// (0.8.1). The surface is closure based like `SeConfig.trigger`, so any
/// loaded FMI 3 instance can bind itself without a trait-object field.
/// FMI 2 has no clocks; CS/ME runs without a `ClockScheduling` behave
/// exactly as before.

///|
/// Clock scheduling surface for one loaded FMI 3 instance. The closures
/// bind the clock calls of that instance; `clocks` carries the input-clock
/// metadata (interval variability, priority); `trigger` is the host policy
/// for triggered clocks; `output_clocks` are observed after every
/// activation round (a read consumes the pulse).
pub(all) struct ClockScheduling {
  clocks : Array[SeClockInfo]
  trigger : (Double) -> Array[UInt32]
  output_clocks : Array[UInt32]
  /// Upper bound on activation rounds per point; guards against clock
  /// cascades that never settle.
  max_rounds : Int32
  get_interval : (UInt32) -> (Double, @fmi.IntervalQualifier)? raise @fmi.SimulationError
  activate_partition : (UInt32, Double) -> Unit raise @fmi.SimulationError
  get_clock : (UInt32) -> Bool raise @fmi.SimulationError
}

///|
pub fn ClockScheduling::new(
  clocks~ : Array[SeClockInfo],
  get_interval~ : (UInt32) -> (Double, @fmi.IntervalQualifier)? raise @fmi.SimulationError,
  activate_partition~ : (UInt32, Double) -> Unit raise @fmi.SimulationError,
  get_clock~ : (UInt32) -> Bool raise @fmi.SimulationError,
  trigger~ : (Double) -> Array[UInt32] = fn(_) { [] },
  output_clocks~ : Array[UInt32] = [],
  max_rounds~ : Int32 = 100,
) -> ClockScheduling {
  {
    clocks,
    trigger,
    output_clocks,
    max_rounds,
    get_interval,
    activate_partition,
    get_clock,
  }
}

///|
/// Host policy that fires every triggered input clock at every point (the
/// deterministic default when the user has no finer policy). The same
/// default the SE master uses.
pub fn ClockScheduling::trigger_all_each_step(
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
/// Per-run mutable bookkeeping for a clock schedule: the next due time per
/// interval clock and the countdown arming state. Both persist across
/// grid points / event points.
pub struct ClockSchedule {
  clocks : Array[SeClockInfo]
  next_activation : Array[Double]
  countdown_due : Array[Double?]
}

///|
pub fn ClockSchedule::new(
  clocks~ : Array[SeClockInfo],
  start_time~ : Double,
) -> ClockSchedule {
  let next_activation : Array[Double] = []
  for clock in clocks {
    next_activation.push(start_time + clock.shift)
  }
  let countdown_due : Array[Double?] = []
  for _ in clocks {
    countdown_due.push(None)
  }
  { clocks, next_activation, countdown_due, }
}

///|
/// Activation rounds at one instant `t`. Round 0 collects what the
/// environment owes: constant-interval ticks, triggered policy hits and
/// armed countdowns. Later rounds only re-poll countdown/dynamic clocks
/// because a partition may arm another (Reference-FMUs Clocks: partition 1
/// arms inClock3 at t=4). Triggered clocks fire once per point — repeating
/// them every round would never settle. Due entries are ordered by
/// (time, priority, value reference). Returns the number of activations;
/// raises `Config` when the rounds never settle within `max_rounds`.
pub fn run_clock_rounds(
  scheduling~ : ClockScheduling,
  schedule~ : ClockSchedule,
  t~ : Double,
  max_rounds~ : Int32,
) -> Int32 raise @fmi.SimulationError {
  let mut activations = 0
  let mut round = 0
  while round < max_rounds {
    let due : Array[(Double, UInt32, UInt32)] = []
    let mut index = 0
    for clock in schedule.clocks {
      if clock.triggered {
        if round == 0 && (scheduling.trigger)(t).contains(clock.value_reference) {
          due.push((t, clock.priority, clock.value_reference))
        }
      } else if clock.countdown {
        match (scheduling.get_interval)(clock.value_reference) {
          Some((interval, qualifier)) =>
            if qualifier is @fmi.IntervalQualifier::Changed {
              schedule.countdown_due[index] = Some(t + interval)
            }
          None => ()
        }
        match schedule.countdown_due[index] {
          Some(due_time) =>
            if due_time <= t + time_epsilon {
              due.push((t, clock.priority, clock.value_reference))
            }
          None => ()
        }
      } else {
        match clock.period {
          Some(period) =>
            while schedule.next_activation[index] <= t + time_epsilon {
              due.push(
                (
                  schedule.next_activation[index],
                  clock.priority,
                  clock.value_reference,
                ),
              )
              schedule.next_activation[index] = schedule.next_activation[index] +
                period
            }
          None =>
            // Dynamic interval without countdown semantics: poll once per
            // round and activate on a known, expired interval.
            match (scheduling.get_interval)(clock.value_reference) {
              Some((interval, qualifier)) =>
                if qualifier is @fmi.IntervalQualifier::Changed &&
                  interval <= time_epsilon {
                  due.push((t, clock.priority, clock.value_reference))
                }
              None => ()
            }
        }
      }
      index += 1
    }
    if due.is_empty() {
      return activations
    }
    due.sort_by(se_due_key)
    for entry in due {
      (scheduling.activate_partition)(entry.2, entry.0)
      activations += 1
      // A fired countdown clock is disarmed until the FMU re-arms it.
      let mut disarm = 0
      for clock in schedule.clocks {
        if clock.countdown && clock.value_reference == entry.2 {
          schedule.countdown_due[disarm] = None
        }
        disarm += 1
      }
    }
    round += 1
  }
  raise @fmi.SimulationError::Config(
    detail="clock activations did not settle within max_rounds at t=\{t}",
  )
}

///|
/// Observe the output clocks after the rounds settled. Reference
/// implementations clear the pulse on read, so each `true` consumes one
/// tick. Returns how many output clocks reported a pulse.
pub fn observe_output_clocks(
  scheduling~ : ClockScheduling,
) -> Int32 raise @fmi.SimulationError {
  let mut ticks = 0
  for vr in scheduling.output_clocks {
    if (scheduling.get_clock)(vr) {
      ticks += 1
    }
  }
  ticks
}

///|
/// Best-effort finish for abort paths: the FMU releases its state before
/// the error propagates; finish failures are swallowed. Used as an
/// `errdefer` body in the CS/SE masters.
fn finish_best_effort(instance : &@fmi.CsInstance) -> Unit {
  instance.finish() catch {
    _ => ()
  }
}
