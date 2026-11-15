///|
/// Integration scheme of the model-exchange master algorithm (task C-13).
/// Fixed-step only; MoonFMI is not a general-purpose ME solver (see
/// master-algorithm.md §4.1).
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
  solver : MeSolver
  state_count : Int32
  event_indicator_count : Int32
  /// Upper bound on `newDiscreteStates` iterations per event; guards
  /// against chattering loops.
  max_event_iterations : Int32
  /// Wall-clock deadline in the same unit as `@env.now()`; the loop
  /// aborts with `SimulationError::Timeout` once it is passed.
  deadline : UInt64?
}

///|
pub fn MeConfig::new(
  start_time~ : Double,
  stop_time~ : Double,
  step_size~ : Double,
  record~ : Array[UInt32],
  solver~ : MeSolver = Rk4,
  state_count~ : Int32,
  event_indicator_count~ : Int32,
  max_event_iterations~ : Int32 = 100,
  deadline~ : UInt64? = None,
) -> MeConfig {
  {
    start_time,
    stop_time,
    step_size,
    record,
    solver,
    state_count,
    event_indicator_count,
    max_event_iterations,
    deadline,
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
/// Returns `true` when the FMU asked to terminate. The caller decides
/// whether to enter event mode first (mid-run) or rely on the FMU already
/// being in event mode (right after initialization).
fn me_event_iteration(
  instance : &@fmi.MeInstance,
  max_iterations : Int32,
  time : Double,
) -> Bool raise @fmi.SimulationError {
  let mut iterations = 0
  while true {
    let info = instance.new_discrete_states()
    if info.terminate_simulation {
      return true
    }
    if !info.new_discrete_states_needed {
      return false
    }
    iterations += 1
    if iterations > max_iterations {
      raise @fmi.FmiCall(
        operation="fmi2NewDiscreteStates",
        detail="event iteration limit (\{max_iterations}) exceeded at t=\{time}",
      )
    }
  }
  false
}

///|
/// Handle an event detected at `time`: enter event mode, settle the
/// discrete states, return to continuous-time mode, and re-read the
/// nominals (nominal changes, P3 exit criterion 3; the caller re-reads the
/// continuous states afterwards). Returns `true` when the FMU asked to
/// terminate.
fn me_settle_event(
  instance : &@fmi.MeInstance,
  max_iterations : Int32,
  time : Double,
  nominals : FixedArray[Double],
) -> Bool raise @fmi.SimulationError {
  instance.enter_event_mode()
  if me_event_iteration(instance, max_iterations, time) {
    return true
  }
  instance.enter_continuous_time_mode()
  // Re-read the nominals unconditionally: `nominalsOfContinuousStatesChanged`
  // is advisory, and re-reading keeps the master's copy authoritative.
  instance.get_nominals_of_continuous_states(nominals)
  false
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
  instance.setup_experiment(
    start=config.start_time,
    stop=Some(config.stop_time),
  )
  instance.initialize()
  // After `exitInitializationMode` the FMU is already in event mode:
  // settle the initial event, then switch to continuous time.
  if me_event_iteration(
      instance,
      config.max_event_iterations,
      config.start_time,
    ) {
    raise @fmi.FmiCall(
      operation="fmi2NewDiscreteStates",
      detail="the FMU asked to terminate during the initial event",
    )
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
  let record = fn(time) raise @fmi.SimulationError {
    times.push(time)
    for index, value_reference in config.record {
      series[index].push(instance.read_real(value_reference))
    }
  }
  record(config.start_time)
  let mut time = config.start_time
  let mut steps = 0
  let mut events = 0
  let mut terminated = false
  while time < config.stop_time - time_epsilon && !terminated {
    match config.deadline {
      Some(deadline) =>
        if @env.now() > deadline {
          raise @fmi.Timeout(detail="t=\{time}")
        }
      None => ()
    }
    steps += 1
    let target = if time + config.step_size > config.stop_time {
      config.stop_time
    } else {
      time + config.step_size
    }
    let mut event_count = 0
    while time < target - time_epsilon {
      event_count += 1
      if event_count > max_step_event_count {
        raise @fmi.FmiCall(
          operation="fmi2GetEventIndicators",
          detail="more than \{max_step_event_count} events inside one step at t=\{time}",
        )
      }
      let h = target - time
      let before = me_indicators(
        instance,
        config.event_indicator_count,
        time,
        states,
      )
      let proposed = me_integrate(instance, config.solver, time, states, h)
      let after = if config.event_indicator_count > 0 {
        me_indicators(instance, config.event_indicator_count, target, proposed)
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
          if me_settle_event(
              instance,
              config.max_event_iterations,
              time,
              nominals,
            ) {
            terminated = true
            break
          }
          events += 1
          // The event may have reinit the states; adopt the FMU's values.
          instance.get_continuous_states(states)
        }
        None => {
          states = proposed
          time = target
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
          if enter_event_mode {
            if me_settle_event(
                instance,
                config.max_event_iterations,
                time,
                nominals,
              ) {
              terminated = true
              break
            }
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
  instance.finish()
  { times, series, steps, events, }
}
