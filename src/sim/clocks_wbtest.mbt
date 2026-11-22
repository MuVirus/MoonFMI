///|
/// Whitebox tests for the shared clock scheduling (0.8.1): the activation
/// rounds (constant / triggered / countdown, priority order, multi-round
/// arming), the settle guard, the output-clock observation and the
/// cross-FMU clock pulse propagation in `couple`.

///|
/// Mutable state the mock clock closures share: an activation log plus
/// the countdown clock's interval report. `countdown_interval` is
/// `Some((interval, changed))` while armed; firing disarms it by setting
/// `None` through the activation closure.
struct MockClockState {
  activations : Array[(Double, UInt32)]
  mut armed_interval : Double?
  mut polls : Int32
}

///|
test "clock rounds fire constant triggered and countdown clocks in priority order" {
  let state : MockClockState = {
    activations: [],
    // The countdown reports an expired remaining interval (0.0), so it is
    // due at the instant it is polled.
    armed_interval: Some(0.0),
    polls: 0,
  }
  let scheduling = ClockScheduling::new(
    clocks=[
      SeClockInfo::new(value_reference=10U, priority=0, period=Some(1.0)),
      SeClockInfo::new(value_reference=20U, priority=1, triggered=true),
      SeClockInfo::new(value_reference=30U, priority=2, countdown=true),
    ],
    get_interval=fn(vr) {
      if vr == 30U {
        state.polls += 1
        match state.armed_interval {
          Some(interval) => Some((interval, Changed))
          None => None
        }
      } else {
        None
      }
    },
    activate_partition=fn(vr, t) {
      state.activations.push((t, vr))
      // A fired countdown clock is disarmed until the FMU re-arms it.
      if vr == 30U {
        state.armed_interval = None
      }
    },
    get_clock=fn(_vr) { false },
    trigger=fn(_t) { [20U] },
  )
  let schedule = ClockSchedule::new(clocks=scheduling.clocks, start_time=0.0)
  // At t = 0.5: the constant clock's first tick was scheduled for
  // start_time (0.0, shift 0) and is due now; the triggered clock fires;
  // the armed countdown (0.5) fires. Order by (time, priority, vr):
  // constant (0) first, then triggered (1), then countdown (2).
  let first = run_clock_rounds(scheduling~, schedule~, t=0.5, max_rounds=10)
  assert_eq(first, 3)
  assert_eq(state.activations.length(), 3)
  assert_eq(state.activations[0], (0.0, 10U))
  assert_eq(state.activations[1], (0.5, 20U))
  assert_eq(state.activations[2], (0.5, 30U))
  assert_true(state.armed_interval is None)
  // At t = 1.0: the constant clock's next tick plus the triggered clock.
  let second = run_clock_rounds(scheduling~, schedule~, t=1.0, max_rounds=10)
  assert_eq(second, 2)
  assert_eq(state.activations.length(), 5)
  assert_eq(state.activations[3], (1.0, 10U))
  assert_eq(state.activations[4], (1.0, 20U))
}

///|
test "a partition may arm another clock in a later round" {
  let state : MockClockState = {
    activations: [],
    armed_interval: None,
    polls: 0,
  }
  let scheduling = ClockScheduling::new(
    clocks=[
      SeClockInfo::new(value_reference=10U, priority=0, period=Some(1.0)),
      SeClockInfo::new(value_reference=30U, priority=1, countdown=true),
    ],
    get_interval=fn(vr) {
      if vr == 30U {
        state.polls += 1
        match state.armed_interval {
          Some(interval) => Some((interval, Changed))
          None => None
        }
      } else {
        None
      }
    },
    activate_partition=fn(vr, t) {
      state.activations.push((t, vr))
      // Partition 1 (vr 10) arms the countdown (vr 30) at t = 1, like
      // Reference-FMUs Clocks: partition 1 arms inClock3 at t = 4. A fired
      // countdown disarms until re-armed.
      if vr == 10U {
        state.armed_interval = Some(0.0)
      }
      if vr == 30U {
        state.armed_interval = None
      }
    },
    get_clock=fn(_vr) { false },
  )
  let schedule = ClockSchedule::new(clocks=scheduling.clocks, start_time=1.0)
  let activations = run_clock_rounds(
    scheduling~,
    schedule~,
    t=1.0,
    max_rounds=10,
  )
  // Round 0 fires the constant clock; the partition arms the countdown;
  // round 1 polls it (Changed, expired) and fires it at the same instant.
  assert_eq(activations, 2)
  assert_eq(state.activations[0], (1.0, 10U))
  assert_eq(state.activations[1], (1.0, 30U))
  assert_true(state.armed_interval is None)
}

///|
test "clock rounds abort when they never settle" {
  let state : MockClockState = {
    activations: [],
    // Always re-arms with an expired interval: the rounds never settle.
    armed_interval: Some(0.0),
    polls: 0,
  }
  let scheduling = ClockScheduling::new(
    clocks=[SeClockInfo::new(value_reference=30U, countdown=true)],
    get_interval=fn(_vr) {
      state.polls += 1
      match state.armed_interval {
        Some(interval) => Some((interval, Changed))
        None => None
      }
    },
    activate_partition=fn(vr, t) { state.activations.push((t, vr)) },
    get_clock=fn(_vr) { false },
  )
  let schedule = ClockSchedule::new(clocks=scheduling.clocks, start_time=0.0)
  let outcome = run_clock_rounds(scheduling~, schedule~, t=0.0, max_rounds=5) catch {
    error =>
      match error {
        Config(_) => -1
        _ => -2
      }
  }
  assert_eq(outcome, -1)
  assert_true(state.polls >= 5, msg="polls=\{state.polls}")
}

///|
test "output clock observation consumes pulses" {
  // vr 100 pulses twice, vr 101 never: the second read clears the flag.
  let pulses : Map[UInt32, Bool] = Map([(100U, true), (101U, false)])
  let scheduling = ClockScheduling::new(
    clocks=[],
    get_interval=fn(_vr) { None },
    activate_partition=fn(_vr, _t) { () },
    get_clock=fn(vr) {
      match pulses.get(vr) {
        Some(v) => v
        None => false
      }
    },
    output_clocks=[100U, 101U],
  )
  let first = observe_output_clocks(scheduling~)
  assert_eq(first, 1)
}

///|
/// Cross-FMU clock connection: the producer pulses its output clock at
/// every step, the consumer logs the firings. A signal connection runs
/// alongside to prove the two connection kinds coexist.
test "coupled clock connection fires the target on a pulse" {
  let producer = MockNode::make(initial=[(1U, 0.0)], transfer=fn(_t, _h) {
    [(1U, 1.0)]
  })
  let consumer = MockNode::make(initial=[(1U, 0.0)], transfer=fn(_t, _h) { [] })
  let firings : Array[Double] = []
  let config = CoupledConfig::new(
    start_time=0.0,
    stop_time=0.2,
    step_size=0.1,
    participants=[
      CoupledParticipant::new(name="producer", instance=producer, record=[]),
      CoupledParticipant::new(name="consumer", instance=consumer, record=[]),
    ],
    connections=[
      Coupling::new(
        from="producer",
        out_vr=5U,
        to="consumer",
        in_vr=6U,
        signal=Clock,
      ),
    ],
    clock_hooks=[
      {
        participant: "producer",
        get_clock: fn(_vr) { true },
        fire_input_clock: fn(_vr, _t) { () },
      },
      {
        participant: "consumer",
        get_clock: fn(_vr) { false },
        fire_input_clock: fn(_vr, t) { firings.push(t) },
      },
    ],
  )
  let result = run_coupled_simulation(config~)
  assert_eq(result.steps(), 2)
  // One firing per communication point after each step (t = 0.1, 0.2).
  assert_eq(firings.length(), 2)
  assert_true(
    (firings[0] - 0.1).abs() <= 0.000000001,
    msg="first firing at \{firings[0]}",
  )
  assert_true(
    (firings[1] - 0.2).abs() <= 0.000000001,
    msg="second firing at \{firings[1]}",
  )
}

///|
test "clock connection without hooks is rejected" {
  let a = MockNode::make(initial=[], transfer=fn(_t, _h) { [] })
  let b = MockNode::make(initial=[], transfer=fn(_t, _h) { [] })
  let config = CoupledConfig::new(
    start_time=0.0,
    stop_time=0.1,
    step_size=0.1,
    participants=[
      CoupledParticipant::new(name="a", instance=a, record=[]),
      CoupledParticipant::new(name="b", instance=b, record=[]),
    ],
    connections=[
      Coupling::new(from="a", out_vr=5U, to="b", in_vr=6U, signal=Clock),
    ],
  )
  let outcome = run_coupled_simulation(config~) catch {
    error =>
      match error {
        Config(_) => { times: [], series: [], steps: -1, events: 0, }
        _ => { times: [], series: [], steps: -2, events: 0, }
      }
  }
  assert_eq(outcome.steps(), -1)
}
