///|
/// Integration schemes of the model-exchange master algorithm (task C-13).
/// Euler and RK4 are fixed-step; RKF45 (Fehlberg 4(5)) is available through
/// `MeConfig.adaptive` and adapts its step size to a local error tolerance.
/// MoonFMI is not a general-purpose ME solver (see master-algorithm.md §4.1).
pub(all) enum MeSolver {
  Euler
  Rk4
}

///|
/// Configuration of one model-exchange run. The recording grid is
/// `start_time + k * step_size`, like the CS master; an event may move the
/// integrator to an earlier point, but the remaining interval of the step is
/// still integrated so recording stays on the grid.
///
/// `state_count` is the number of continuous states (the `Derivatives`
/// entries of the model structure); `event_indicator_count` is the declared
/// `numberOfEventIndicators`. Both size the master's internal buffers.
pub struct MeConfig {
  start_time : Double
  stop_time : Double
  step_size : Double
  record : Array[UInt32]
  /// Array outputs to record element by element (FMI 2: consecutive
  /// references; FMI 3: one reference with an element count).
  record_arrays : Array[RecordedArray]
  /// When `Some`, the master runs SE-style clock activation rounds while
  /// in event mode — after the initial event and after every settled
  /// event — and observes the output clocks (FMI 3 clocked partitions,
  /// 0.8.1).
  clocks : ClockScheduling?
  solver : MeSolver
  state_count : Int32
  event_indicator_count : Int32
  /// Upper bound on `newDiscreteStates` iterations per event; guards
  /// against chattering loops.
  max_event_iterations : Int32
  /// Wall-clock deadline in the same unit as `@env.now()`; the loop
  /// aborts with `SimulationError::Timeout` once it is passed.
  deadline : UInt64?
  /// When `true`, the integrator uses the adaptive RKF45 (Fehlberg 4(5))
  /// controller instead of the fixed-step `solver`. `step_size` is then the
  /// initial step; the step grows after accepted steps (up to `max_step`)
  /// and shrinks after rejected ones. `solver` is still used for event
  /// location bisection. Euler/RK4 fixed-step behavior is unchanged.
  adaptive : Bool
  /// Local error tolerance for the adaptive controller. A step is accepted
  /// when `max |y5 - y4| <= tolerance * (|nominal| + |y5|)` for every
  /// state. Must be positive when `adaptive` is true.
  tolerance : Double
  /// Upper bound on the adaptive step size; `None` means unbounded (only
  /// bounded by the remaining interval). Must be positive when `Some`.
  max_step : Double?
}

///|
pub fn MeConfig::new(
  start_time~ : Double,
  stop_time~ : Double,
  step_size~ : Double,
  record~ : Array[UInt32],
  record_arrays~ : Array[RecordedArray] = [],
  clocks~ : ClockScheduling? = None,
  solver~ : MeSolver = Rk4,
  state_count~ : Int32,
  event_indicator_count~ : Int32,
  max_event_iterations~ : Int32 = 100,
  deadline~ : UInt64? = None,
  adaptive~ : Bool = false,
  tolerance~ : Double = 0.000001,
  max_step~ : Double? = None,
) -> MeConfig {
  {
    start_time,
    stop_time,
    step_size,
    record,
    record_arrays,
    clocks,
    solver,
    state_count,
    event_indicator_count,
    max_event_iterations,
    deadline,
    adaptive,
    tolerance,
    max_step,
  }
}

///|
/// An event happens at most this often inside one communication step
/// before the master gives up instead of looping forever.
let max_step_event_count : Int32 = 100

///|
/// Bisection precision for locating an event time inside a step.
let event_time_epsilon : Double = 0.000000000001

///|
/// Upper bound on bisection iterations; 2^-64 of any step is far below
/// `event_time_epsilon`.
let max_bisection_iterations : Int32 = 64

///|
/// Fehlberg's embedded RKF4(5) pair.
/// Source: E. Fehlberg, "Low-Order Classical Runge-Kutta Formulas with
/// Stepsize Control", NASA TR R-287, 1969 (also Computing 6(1-2), 1970).
/// Butcher tableau (nodes c, matrix A, 4th-order weights b4, 5th-order b5):
///
/// c = [0, 1/4, 3/8, 12/13, 1, 1/2]
/// b4 = [25/216, 0, 1408/2565, 2197/4104, -1/5, 0]
/// b5 = [16/135, 0, 6656/12825, 28561/56430, -9/50, 2/55]
///
/// The 5th-order state is advanced; the componentwise difference between the
/// two solutions estimates the local truncation error.
let rkf45_a21 : Double = 0.25

///|
let rkf45_a31 : Double = 3.0 / 32.0

///|
let rkf45_a32 : Double = 9.0 / 32.0

///|
let rkf45_a41 : Double = 1932.0 / 2197.0

///|
let rkf45_a42 : Double = -7200.0 / 2197.0

///|
let rkf45_a43 : Double = 7296.0 / 2197.0

///|
let rkf45_a51 : Double = 439.0 / 216.0

///|
let rkf45_a52 : Double = -8.0

///|
let rkf45_a53 : Double = 3680.0 / 513.0

///|
let rkf45_a54 : Double = -845.0 / 4104.0

///|
let rkf45_a61 : Double = -8.0 / 27.0

///|
let rkf45_a62 : Double = 2.0

///|
let rkf45_a63 : Double = -3544.0 / 2565.0

///|
let rkf45_a64 : Double = 1859.0 / 4104.0

///|
let rkf45_a65 : Double = -11.0 / 40.0

///|
let rkf45_b4_1 : Double = 25.0 / 216.0

///|
let rkf45_b4_3 : Double = 1408.0 / 2565.0

///|
let rkf45_b4_4 : Double = 2197.0 / 4104.0

///|
let rkf45_b4_5 : Double = -1.0 / 5.0

///|
let rkf45_b5_1 : Double = 16.0 / 135.0

///|
let rkf45_b5_3 : Double = 6656.0 / 12825.0

///|
let rkf45_b5_4 : Double = 28561.0 / 56430.0

///|
let rkf45_b5_5 : Double = -9.0 / 50.0

///|
let rkf45_b5_6 : Double = 2.0 / 55.0

///|
/// Relative step growth after an accepted step, clamped to [1.5, 2].
fn rkf45_grow_factor(err : Double, tolerance : Double) -> Double {
  if err <= 0.0 {
    2.0
  } else {
    let r = err / tolerance
    let mut f = 0.9 * @math.pow(r, -0.2)
    if f < 1.5 {
      f = 1.5
    }
    if f > 2.0 {
      f = 2.0
    }
    f
  }
}

///|
/// One RKF45 trial step of size `h` from `(time, states)`.
/// Returns the 4th-order state, the 5th-order state (candidate for
/// acceptance), and the scaled local error norm
/// `max |y5[i] - y4[i]| / (|nominals[i]| + |y5[i]|)`. Nominals guard states
/// near zero; a zero scale with a non-zero difference is infinite error.
/// Non-finite results raise instead of silently diverging.
fn me_rkf45_step(
  instance : &@fmi.MeInstance,
  time : Double,
  states : FixedArray[Double],
  h : Double,
  nominals : FixedArray[Double],
) -> (FixedArray[Double], FixedArray[Double], Double) raise @fmi.SimulationError {
  let n = states.length()
  let k1 = me_derivative(instance, time, states)
  let tmp : FixedArray[Double] = FixedArray::make(n, 0.0)
  for i in 0..<n {
    tmp[i] = states[i] + h * rkf45_a21 * k1[i]
  }
  let k2 = me_derivative(instance, time + h * 0.25, tmp)
  for i in 0..<n {
    tmp[i] = states[i] + h * (rkf45_a31 * k1[i] + rkf45_a32 * k2[i])
  }
  let k3 = me_derivative(instance, time + h * 0.375, tmp)
  for i in 0..<n {
    tmp[i] = states[i] +
      h * (rkf45_a41 * k1[i] + rkf45_a42 * k2[i] + rkf45_a43 * k3[i])
  }
  let k4 = me_derivative(instance, time + h * (12.0 / 13.0), tmp)
  for i in 0..<n {
    tmp[i] = states[i] +
      h *
      (
        rkf45_a51 * k1[i] +
        rkf45_a52 * k2[i] +
        rkf45_a53 * k3[i] +
        rkf45_a54 * k4[i]
      )
  }
  let k5 = me_derivative(instance, time + h, tmp)
  for i in 0..<n {
    tmp[i] = states[i] +
      h *
      (
        rkf45_a62 * k2[i] +
        rkf45_a61 * k1[i] +
        rkf45_a63 * k3[i] +
        rkf45_a64 * k4[i] +
        rkf45_a65 * k5[i]
      )
  }
  let k6 = me_derivative(instance, time + h * 0.5, tmp)
  let y4 : FixedArray[Double] = FixedArray::make(n, 0.0)
  let y5 : FixedArray[Double] = FixedArray::make(n, 0.0)
  // Finite guard without `Double::is_infinite`: NaN fails `v == v`; values
  // beyond 1e300 are treated as non-finite.
  let finite = fn(v : Double) -> Bool { v == v && v.abs() < 1.0e300 }
  let huge = 1.0e300 // stands for +infinity in the error norm
  for i in 0..<n {
    y4[i] = states[i] +
      h *
      (
        rkf45_b4_1 * k1[i] +
        rkf45_b4_3 * k3[i] +
        rkf45_b4_4 * k4[i] +
        rkf45_b4_5 * k5[i]
      )
    y5[i] = states[i] +
      h *
      (
        rkf45_b5_1 * k1[i] +
        rkf45_b5_3 * k3[i] +
        rkf45_b5_4 * k4[i] +
        rkf45_b5_5 * k5[i] +
        rkf45_b5_6 * k6[i]
      )
    if !finite(y4[i]) || !finite(y5[i]) {
      raise @fmi.FmiCall(
        operation="fmi2GetDerivatives",
        detail="non-finite state in the RKF45 step at t=\{time}",
      )
    }
  }
  let mut err : Double = 0.0
  for i in 0..<n {
    let scale = nominals[i].abs() + y5[i].abs()
    let e = if scale == 0.0 {
      if (y5[i] - y4[i]).abs() == 0.0 {
        0.0
      } else {
        huge
      }
    } else {
      (y5[i] - y4[i]).abs() / scale
    }
    if e > err {
      err = e
    }
  }
  (y4, y5, err)
}

///|
/// One derivative evaluation: `setTime` → `setContinuousStates` →
/// `getDerivatives` into a fresh buffer.
fn me_derivative(
  instance : &@fmi.MeInstance,
  time : Double,
  states : FixedArray[Double],
) -> FixedArray[Double] raise @fmi.SimulationError {
  instance.set_time(time)
  instance.set_continuous_states(states)
  let derivatives : FixedArray[Double] = FixedArray::make(states.length(), 0.0)
  instance.get_derivatives(derivatives)
  derivatives
}

///|
/// Advance `states` from `time` by `h` with the configured solver.
fn me_integrate(
  instance : &@fmi.MeInstance,
  solver : MeSolver,
  time : Double,
  states : FixedArray[Double],
  h : Double,
) -> FixedArray[Double] raise @fmi.SimulationError {
  match solver {
    Euler => {
      let k = me_derivative(instance, time, states)
      let next : FixedArray[Double] = FixedArray::make(states.length(), 0.0)
      for index in 0..<states.length() {
        next[index] = states[index] + h * k[index]
      }
      next
    }
    Rk4 => {
      let half = h * 0.5
      let k1 = me_derivative(instance, time, states)
      let shifted : FixedArray[Double] = FixedArray::make(states.length(), 0.0)
      for index in 0..<states.length() {
        shifted[index] = states[index] + half * k1[index]
      }
      let k2 = me_derivative(instance, time + half, shifted)
      for index in 0..<states.length() {
        shifted[index] = states[index] + half * k2[index]
      }
      let k3 = me_derivative(instance, time + half, shifted)
      for index in 0..<states.length() {
        shifted[index] = states[index] + h * k3[index]
      }
      let k4 = me_derivative(instance, time + h, shifted)
      let next : FixedArray[Double] = FixedArray::make(states.length(), 0.0)
      for index in 0..<states.length() {
        next[index] = states[index] +
          h *
          0.16666666666666666 *
          (k1[index] + 2.0 * k2[index] + 2.0 * k3[index] + k4[index])
      }
      next
    }
  }
}

///|
/// Read the event indicators at `(time, states)`.
fn me_indicators(
  instance : &@fmi.MeInstance,
  count : Int32,
  time : Double,
  states : FixedArray[Double],
) -> FixedArray[Double] raise @fmi.SimulationError {
  instance.set_time(time)
  instance.set_continuous_states(states)
  let indicators : FixedArray[Double] = FixedArray::make(count, 0.0)
  instance.get_event_indicators(indicators)
  indicators
}

///|
/// True when indicator `before` moved across zero to `after`. An indicator
/// resting on zero stays eventless.
fn me_crossed(before : Double, after : Double) -> Bool {
  (before > 0.0 && after <= 0.0) || (before < 0.0 && after >= 0.0)
}

///|
/// Locate the earliest event time in `(time, time + h]` by bisecting every
/// crossing indicator. Returns the offset from `time`, or `None`.
fn me_locate_event(
  instance : &@fmi.MeInstance,
  solver : MeSolver,
  time : Double,
  states : FixedArray[Double],
  h : Double,
  indicators_before : FixedArray[Double],
  indicators_after : FixedArray[Double],
  indicator_count : Int32,
) -> Double? raise @fmi.SimulationError {
  let mut earliest : Double? = None
  for index in 0..<indicator_count {
    if !me_crossed(indicators_before[index], indicators_after[index]) {
      continue
    }
    let mut lo = 0.0
    let mut hi = h
    let mut iterations = 0
    while hi - lo > event_time_epsilon && iterations < max_bisection_iterations {
      let mid = lo + (hi - lo) * 0.5
      let states_mid = me_integrate(instance, solver, time, states, mid)
      let indicators_mid = me_indicators(
        instance,
        indicator_count,
        time + mid,
        states_mid,
      )
      if me_crossed(indicators_before[index], indicators_mid[index]) {
        hi = mid
      } else {
        lo = mid
      }
      iterations += 1
    }
    match earliest {
      Some(current) => if hi < current { earliest = Some(hi) }
      None => earliest = Some(hi)
    }
  }
  earliest
}

///|
/// Run the `newDiscreteStates` iteration until the FMU is settled.
/// Returns the final `EventInfo`: its `terminate_simulation` field asks
/// for termination, its `nextEventTime` fields schedule the next time
/// event (the master must not integrate past it — master-algorithm §4.5).
/// The caller decides whether to enter event mode first (mid-run) or rely
/// on the FMU already being in event mode (right after initialization).
fn me_event_iteration(
  instance : &@fmi.MeInstance,
  max_iterations : Int32,
  time : Double,
) -> @fmi.EventInfo raise @fmi.SimulationError {
  let mut iterations = 0
  while true {
    let info = instance.new_discrete_states()
    if info.terminate_simulation || !info.new_discrete_states_needed {
      return info
    }
    iterations += 1
    if iterations > max_iterations {
      raise @fmi.FmiCall(
        operation="fmi2NewDiscreteStates",
        detail="event iteration limit (\{max_iterations}) exceeded at t=\{time}",
      )
    }
  }
  {
    new_discrete_states_needed: false,
    terminate_simulation: false,
    nominals_changed: false,
    states_changed: false,
    next_event_time_defined: false,
    next_event_time: 0.0,
  }
}

///|
/// Handle an event detected at `time`: enter event mode, settle the
/// discrete states, run the clock activation rounds while still in event
/// mode (when the run schedules clocks), return to continuous-time mode,
/// and re-read the nominals (nominal changes, P3 exit criterion 3; the
/// caller re-reads the continuous states afterwards). Returns the final
/// `EventInfo` of the settlement; its `terminate_simulation` field asks
/// for termination and its `nextEventTime` fields schedule the next time
/// event.
fn me_settle_event(
  instance : &@fmi.MeInstance,
  max_iterations : Int32,
  time : Double,
  nominals : FixedArray[Double],
  clocks~ : (ClockScheduling, ClockSchedule)? = None,
) -> @fmi.EventInfo raise @fmi.SimulationError {
  instance.enter_event_mode()
  let info = me_event_iteration(instance, max_iterations, time)
  if info.terminate_simulation {
    return info
  }
  if clocks is Some(pair) {
    let (scheduling, schedule) = pair
    let _ = run_clock_rounds(
      scheduling~,
      schedule~,
      t=time,
      max_rounds=scheduling.max_rounds,
    )
    let _ = observe_output_clocks(scheduling~)
  }
  instance.enter_continuous_time_mode()
  // Re-read the nominals unconditionally: `nominalsOfContinuousStatesChanged`
  // is advisory, and re-reading keeps the master's copy authoritative.
  instance.get_nominals_of_continuous_states(nominals)
  info
}

///|
/// The FMI 2 model-exchange master algorithm (tasks C-13/C-14):
/// initialize → settle the initial event → per grid step
/// `integrate → detect indicator crossings → bisect → event loop → record`.
/// The final step is truncated to `stop_time`; errors abort the run.
pub fn run_me_simulation(
  instance : &@fmi.MeInstance,
  config~ : MeConfig,
) -> SimulationResult raise @fmi.SimulationError {
  if !(config.stop_time > config.start_time) {
    raise @fmi.Config(
      detail="stop_time (\{config.stop_time}) must be greater than start_time (\{config.start_time})",
    )
  }
  if !(config.step_size > 0.0) {
    raise @fmi.Config(detail="step_size must be positive")
  }
  if config.state_count <= 0 {
    raise @fmi.Config(
      detail="state_count must be positive (the model structure declares no derivatives)",
    )
  }
  if config.max_event_iterations <= 0 {
    raise @fmi.Config(detail="max_event_iterations must be positive")
  }
  if config.adaptive {
    if !(config.tolerance > 0.0) {
      raise @fmi.Config(
        detail="tolerance must be positive for adaptive stepping",
      )
    }
    match config.max_step {
      Some(v) =>
        if !(v > 0.0) {
          raise @fmi.Config(detail="max_step must be positive")
        }
      None => ()
    }
  }
  instance.setup_experiment(
    start=config.start_time,
    stop=Some(config.stop_time),
  )
  instance.initialize()
  // After `exitInitializationMode` the FMU is already in event mode:
  // settle the initial event, then switch to continuous time.
  let initial_info = me_event_iteration(
    instance,
    config.max_event_iterations,
    config.start_time,
  )
  if initial_info.terminate_simulation {
    raise @fmi.FmiCall(
      operation="fmi2NewDiscreteStates",
      detail="the FMU asked to terminate during the initial event",
    )
  }
  // The FMU's declared next time event (`nextEventTime`); the integrator
  // must never step past it. `next_event_defined` gates the clamp because
  // an undefined next event time reads 0.0.
  let mut next_event_time = initial_info.next_event_time
  let mut next_event_defined = initial_info.next_event_time_defined
  // Clock scheduling state (FMI 3 clocked partitions, 0.8.1): the rounds
  // run inside event mode, right after each settlement.
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
  if clock_state is Some(pair) {
    let (scheduling, schedule) = pair
    let _ = run_clock_rounds(
      scheduling~,
      schedule~,
      t=config.start_time,
      max_rounds=scheduling.max_rounds,
    )
    let _ = observe_output_clocks(scheduling~)
  }
  instance.enter_continuous_time_mode()
  let nominals : FixedArray[Double] = FixedArray::make(config.state_count, 0.0)
  instance.get_nominals_of_continuous_states(nominals)
  let mut states : FixedArray[Double] = FixedArray::make(
    config.state_count,
    0.0,
  )
  instance.get_continuous_states(states)
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
  let record = fn(time) raise @fmi.SimulationError {
    times.push(time)
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
  let mut time = config.start_time
  let mut steps = 0
  let mut events = 0
  let mut terminated = false
  // Consecutive events without accepted progress (chattering); aborts like
  // `max_step_event_count` inside one fixed step.
  let mut consecutive_events : Int32 = 0
  // Adaptive controller bounds: `step_size` is the initial step, `max_step`
  // (when `Some`) caps growth, `step_size * 1e-6` is the hard floor.
  // `None` means "no configured cap": use a huge stand-in for infinity so
  // only `stop_time` and `max_step` bound the step.
  let max_cap = match config.max_step {
    Some(v) => v
    None => 1.0e300
  }
  let min_step = config.step_size * 0.000001
  let mut pending_h = if max_cap < config.stop_time - config.start_time {
    max_cap
  } else {
    config.stop_time - config.start_time
  }
  while time < config.stop_time - time_epsilon && !terminated {
    match config.deadline {
      Some(deadline) =>
        if @env.now() > deadline {
          raise @fmi.Timeout(detail="t=\{time}")
        }
      None => ()
    }
    // Never integrate past a declared time event: cap the step at the
    // remaining distance to `nextEventTime` (master-algorithm §4.5). The
    // `next_event_defined` gate is essential — an undefined next event
    // time reads 0.0, which would freeze the run at the start.
    let event_cap = if next_event_defined && next_event_time > time {
      next_event_time - time
    } else {
      1.0e300
    }
    if config.adaptive {
      // --- RKF45 adaptive step: never crosses a stop or event boundary ---
      let mut h = if pending_h < config.stop_time - time {
        pending_h
      } else {
        config.stop_time - time
      }
      if event_cap < h {
        h = event_cap
      }
      let n = states.length()
      let mut y5 : FixedArray[Double] = FixedArray::make(n, 0.0)
      while true {
        let (_, proposed, err) = me_rkf45_step(
          instance, time, states, h, nominals,
        )
        if err <= config.tolerance {
          // Accept: grow the step (x1.5-x2), capped by max_step.
          let grown = h * rkf45_grow_factor(err, config.tolerance)
          pending_h = if grown < max_cap { grown } else { max_cap }
          y5 = proposed
          break
        }
        // Reject: halve and retry, guarded by the minimum step.
        let halved = h * 0.5
        if halved < min_step {
          raise @fmi.Config(detail="step size below minimum at t=\{time}")
        }
        h = halved
      }
      let step_end = time + h
      // A step ending exactly on the declared time event mandates event
      // handling even when `completedIntegratorStep` does not ask for it.
      let event_reached = (step_end - next_event_time).abs() <= time_epsilon
      let late_enough = step_end < config.stop_time - time_epsilon
      let at_time_event = next_event_defined && event_reached && late_enough
      let before = me_indicators(
        instance,
        config.event_indicator_count,
        time,
        states,
      )
      let after = if config.event_indicator_count > 0 {
        me_indicators(instance, config.event_indicator_count, step_end, y5)
      } else {
        before
      }
      match
        me_locate_event(
          instance,
          config.solver,
          time,
          states,
          h,
          before,
          after,
          config.event_indicator_count,
        ) {
        Some(offset) => {
          // An event lies inside the accepted step: do not cross it.
          // Integrate to the event point and settle, then continue from
          // there with a fresh step proposal.
          consecutive_events += 1
          if consecutive_events > max_step_event_count {
            raise @fmi.FmiCall(
              operation="fmi2GetEventIndicators",
              detail="more than \{max_step_event_count} events inside one step at t=\{time}",
            )
          }
          states = me_integrate(instance, config.solver, time, states, offset)
          time = time + offset
          instance.set_time(time)
          instance.set_continuous_states(states)
          let info = me_settle_event(
            instance,
            config.max_event_iterations,
            time,
            nominals,
            clocks=clock_state,
          )
          if info.terminate_simulation {
            terminated = true
            break
          }
          next_event_defined = info.next_event_time_defined
          next_event_time = info.next_event_time
          events += 1
          // The event may have reinit the states; adopt the FMU's values.
          instance.get_continuous_states(states)
          if time >= step_end - time_epsilon {
            record(time)
          }
          continue
        }
        None => {
          consecutive_events = 0
          states = y5
          time = step_end
          // The FMU holds a mid-integration state from the last derivative
          // evaluation; bring it to the new point before recording.
          instance.set_time(time)
          instance.set_continuous_states(states)
          let (enter_event_mode, terminate) = instance.completed_integrator_step(
            no_set_fmu_state_prior=true,
          )
          if terminate {
            terminated = true
            break
          }
          if enter_event_mode || at_time_event {
            let info = me_settle_event(
              instance,
              config.max_event_iterations,
              time,
              nominals,
              clocks=clock_state,
            )
            if info.terminate_simulation {
              terminated = true
              break
            }
            next_event_defined = info.next_event_time_defined
            next_event_time = info.next_event_time
            events += 1
            instance.get_continuous_states(states)
          }
          steps += 1
          record(time)
        }
      }
    } else {
      // --- Fixed-step Euler/RK4 path: recording stays on the grid; a
      // declared time event inside the interval pulls the integrator
      // forward to it, and the remainder of the interval follows. ---
      steps += 1
      let grid_target = if time + config.step_size > config.stop_time {
        config.stop_time
      } else {
        time + config.step_size
      }
      let mut event_count = 0
      while time < grid_target - time_epsilon {
        event_count += 1
        if event_count > max_step_event_count {
          raise @fmi.FmiCall(
            operation="fmi2GetEventIndicators",
            detail="more than \{max_step_event_count} events inside one step at t=\{time}",
          )
        }
        // Stop at the next time event when it lies inside this interval.
        let event_pending = next_event_defined && next_event_time > time
        let inside_grid = next_event_time < grid_target - time_epsilon
        let step_end = if event_pending && inside_grid {
          next_event_time
        } else {
          grid_target
        }
        // A step ending on the declared time event mandates event handling
        // even when `completedIntegratorStep` does not ask for it.
        let event_reached = (step_end - next_event_time).abs() <= time_epsilon
        let late_enough = step_end < config.stop_time - time_epsilon
        let at_time_event = next_event_defined && event_reached && late_enough
        let h = step_end - time
        let before = me_indicators(
          instance,
          config.event_indicator_count,
          time,
          states,
        )
        let proposed = me_integrate(instance, config.solver, time, states, h)
        let after = if config.event_indicator_count > 0 {
          me_indicators(
            instance,
            config.event_indicator_count,
            step_end,
            proposed,
          )
        } else {
          before
        }
        match
          me_locate_event(
            instance,
            config.solver,
            time,
            states,
            h,
            before,
            after,
            config.event_indicator_count,
          ) {
          Some(offset) => {
            // Integrate to the event point, make the FMU adopt it (it may
            // still hold a mid-integration state), then settle the event.
            states = me_integrate(instance, config.solver, time, states, offset)
            time = time + offset
            instance.set_time(time)
            instance.set_continuous_states(states)
            let info = me_settle_event(
              instance,
              config.max_event_iterations,
              time,
              nominals,
              clocks=clock_state,
            )
            if info.terminate_simulation {
              terminated = true
              break
            }
            next_event_defined = info.next_event_time_defined
            next_event_time = info.next_event_time
            events += 1
            // The event may have reinit the states; adopt the FMU's values.
            instance.get_continuous_states(states)
          }
          None => {
            states = proposed
            time = step_end
            // The FMU holds a mid-integration state from the last derivative
            // evaluation; bring it to the new point before recording.
            instance.set_time(time)
            instance.set_continuous_states(states)
            let (enter_event_mode, terminate) = instance.completed_integrator_step(
              no_set_fmu_state_prior=true,
            )
            if terminate {
              terminated = true
              break
            }
            if enter_event_mode || at_time_event {
              let info = me_settle_event(
                instance,
                config.max_event_iterations,
                time,
                nominals,
                clocks=clock_state,
              )
              if info.terminate_simulation {
                terminated = true
                break
              }
              next_event_defined = info.next_event_time_defined
              next_event_time = info.next_event_time
              events += 1
              instance.get_continuous_states(states)
            }
          }
        }
      }
      if !terminated {
        record(time)
      }
    }
  }
  instance.finish()
  { times, series, steps, events, }
}
