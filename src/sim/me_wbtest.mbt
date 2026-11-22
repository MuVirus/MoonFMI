///|
/// Mock model-exchange instance for testing the ME master algorithm
/// without an FMU. It simulates one continuous state with two selectable
/// ODEs (`-x` decay or `+1`), one optional event indicator `1 - t`, and a
/// scriptable event behaviour (reinit value, demanded event iterations,
/// terminate request).
struct MockMe {
  mut state : Double
  mut time : Double
  /// 0: dx/dt = -x, 1: dx/dt = 1.
  derivative_kind : Int32
  indicator_count : Int32
  /// State value the FMU adopts when a (mid-run) event settles.
  reinit_value : Double?
  /// `newDiscreteStatesNeeded` rounds demanded per event before settling.
  mut demand_iterations : Int32
  terminate_at_event : Bool
  mut in_event_mode : Bool
  /// Becomes true after the initial `enterContinuousTimeMode`, so the
  /// initial event settlement does not count as a mid-run event.
  mut initial_done : Bool
  mut settles : Int32
  mut reinits : Int32
  /// Derivative evaluations performed by this mock (test instrumentation).
  mut deriv_evals : Int32
  /// Scheduled time events in rising order. Every settled event reports
  /// the next one via `nextEventTime` until the list is exhausted.
  time_events : Array[Double]
  mut time_event_index : Int32
  /// Settled events that landed exactly on their scheduled time.
  mut time_event_hits : Int32
  /// True once a derivative was evaluated strictly beyond the pending
  /// time event — the master must never cross one.
  mut crossed_time_event : Bool
  mut finished : Bool
}

///|
fn MockMe::make(
  derivative_kind~ : Int32,
  indicator_count~ : Int32,
  reinit_value? : Double,
  demand_iterations~ : Int32 = 0,
  terminate_at_event~ : Bool = false,
  time_events~ : Array[Double] = [],
) -> MockMe {
  {
    state: 0.0,
    time: 0.0,
    derivative_kind,
    indicator_count,
    reinit_value,
    demand_iterations,
    terminate_at_event,
    in_event_mode: false,
    initial_done: false,
    settles: 0,
    reinits: 0,
    deriv_evals: 0,
    time_events,
    time_event_index: 0,
    time_event_hits: 0,
    crossed_time_event: false,
    finished: false,
  }
}

///|
fn close(actual : Double, expected : Double, tolerance : Double) -> Bool {
  (actual - expected).abs() <= tolerance
}

///|
impl @fmi.MeInstance for MockMe with fn setup_experiment(_self, start~, stop~) {
  let _ = start
  let _ = stop
}

///|
impl @fmi.MeInstance for MockMe with fn initialize(self) {
  // After exitInitializationMode the FMU is in event mode.
  self.in_event_mode = true
}

///|
impl @fmi.MeInstance for MockMe with fn set_time(self, time) {
  self.time = time
}

///|
impl @fmi.MeInstance for MockMe with fn set_continuous_states(self, states) {
  self.state = states[0]
}

///|
impl @fmi.MeInstance for MockMe with fn get_continuous_states(self, states) {
  states[0] = self.state
}

///|
impl @fmi.MeInstance for MockMe with fn get_derivatives(self, derivatives) {
  self.deriv_evals += 1
  derivatives[0] = if self.derivative_kind == 0 { -self.state } else { 1.0 }
  if self.time_event_index < self.time_events.length() {
    let pending = self.time_events[self.time_event_index]
    if self.time > pending + event_time_epsilon {
      self.crossed_time_event = true
    }
  }
}

///|
impl @fmi.MeInstance for MockMe with fn get_event_indicators(self, indicators) {
  if self.indicator_count > 0 {
    indicators[0] = 1.0 - self.time
  }
}

///|
impl @fmi.MeInstance for MockMe with fn get_nominals_of_continuous_states(
  _self,
  nominals,
) {
  nominals[0] = 1.0
}

///|
impl @fmi.MeInstance for MockMe with fn enter_event_mode(self) {
  self.in_event_mode = true
}

///|
impl @fmi.MeInstance for MockMe with fn new_discrete_states(self) {
  if !self.in_event_mode {
    abort("new_discrete_states outside event mode")
  }
  if self.demand_iterations > 0 {
    self.demand_iterations -= 1
    // As long as iterations are demanded, the FMU keeps asking for more.
    self.state = self.state + 1.0
    return {
      new_discrete_states_needed: true,
      terminate_simulation: false,
      nominals_changed: false,
      states_changed: false,
      next_event_time_defined: false,
      next_event_time: 0.0,
    }
  }
  self.settles += 1
  if self.terminate_at_event && self.initial_done {
    return {
      new_discrete_states_needed: false,
      terminate_simulation: true,
      nominals_changed: false,
      states_changed: false,
      next_event_time_defined: false,
      next_event_time: 0.0,
    }
  }
  let initial = !self.initial_done
  if !initial {
    match self.reinit_value {
      Some(value) => {
        self.state = value
        self.reinits += 1
      }
      None => ()
    }
  }
  // Report the pending time event; consume it when the settlement lands
  // exactly on its scheduled time. The initial settlement reports it too.
  let (defined, next) = if self.time_event_index < self.time_events.length() {
    let scheduled = self.time_events[self.time_event_index]
    if (self.time - scheduled).abs() <= event_time_epsilon {
      self.time_event_index += 1
      self.time_event_hits += 1
      match self.time_events.get(self.time_event_index) {
        Some(following) => (true, following)
        None => (false, 0.0)
      }
    } else {
      (true, scheduled)
    }
  } else {
    (false, 0.0)
  }
  {
    new_discrete_states_needed: false,
    terminate_simulation: false,
    nominals_changed: false,
    states_changed: !initial,
    next_event_time_defined: defined,
    next_event_time: next,
  }
}

///|
impl @fmi.MeInstance for MockMe with fn enter_continuous_time_mode(self) {
  self.in_event_mode = false
  self.initial_done = true
}

///|
impl @fmi.MeInstance for MockMe with fn completed_integrator_step(
  _self,
  no_set_fmu_state_prior~,
) {
  let _ = no_set_fmu_state_prior
  (false, false)
}

///|
impl @fmi.MeInstance for MockMe with fn read_real(_self, value_reference) {
  let _ = value_reference
  _self.state
}

///|
impl @fmi.MeInstance for MockMe with fn write_real(self, value_reference, value) {
  let _ = value_reference
  let _ = value
  let _ = self
}

///|
impl @fmi.MeInstance for MockMe with fn finish(self) {
  self.finished = true
}

///|
test "me euler decays exactly on the grid" {
  // dx/dt = -x, x(0) = 1: Euler gives x_n = (1 - h)^n exactly.
  let mock = MockMe::make(derivative_kind=0, indicator_count=0)
  mock.state = 1.0
  let config = MeConfig::new(
    start_time=0.0,
    stop_time=1.0,
    step_size=0.25,
    record=[1U],
    solver=Euler,
    state_count=1,
    event_indicator_count=0,
  )
  let result = run_me_simulation(mock, config~)
  assert_eq(result.steps(), 4)
  assert_eq(result.times().length(), 5)
  let mut expected = 1.0
  for index in 0..<=4 {
    assert_true(
      close(result.series()[0][index], expected, 0.000000000001),
      msg="x[\{index}]=\{result.series()[0][index]} vs \{expected}",
    )
    expected = expected * 0.75
  }
  assert_true(mock.finished)
}

///|
test "me rk4 approximates the analytic decay" {
  // RK4 on dx/dt = -x with h = 0.25 lands within ~1e-4 of e^-2 (the RK4
  // amplification error over 8 steps is about 1.1e-5).
  let mock = MockMe::make(derivative_kind=0, indicator_count=0)
  mock.state = 1.0
  let config = MeConfig::new(
    start_time=0.0,
    stop_time=2.0,
    step_size=0.25,
    record=[1U],
    solver=Rk4,
    state_count=1,
    event_indicator_count=0,
  )
  let result = run_me_simulation(mock, config~)
  let final_value = result.series()[0][8]
  assert_true(
    close(final_value, 0.1353352832366127, 0.0001),
    msg="rk4 x(2)=\{final_value} vs e^-2=0.1353352832366127",
  )
}

///|
test "me detects the event, reinits, and keeps the grid" {
  // dx/dt = 1 from x(0) = 0, indicator 1 - t crosses zero at t = 1.
  // The event reinits the state to -5; integration then continues from
  // there, while recording stays on the 0.25 grid.
  let mock = MockMe::make(
    derivative_kind=1,
    indicator_count=1,
    reinit_value=-5.0,
  )
  let config = MeConfig::new(
    start_time=0.0,
    stop_time=2.0,
    step_size=0.25,
    record=[1U],
    solver=Rk4,
    state_count=1,
    event_indicator_count=1,
  )
  let result = run_me_simulation(mock, config~)
  // One settlement during initialization, one mid-run event.
  assert_eq(mock.settles, 2)
  assert_eq(mock.reinits, 1)
  assert_eq(result.events(), 1)
  assert_eq(result.steps(), 8)
  assert_eq(result.times().length(), 9)
  // The grid is preserved despite the event at t = 1.
  for index in 0..<=8 {
    let expected = index.to_double() * 0.25
    assert_true(
      close(result.times()[index], expected, 0.000000001),
      msg="grid drift at \{index}: \{result.times()[index]}",
    )
  }
  // Records before the event follow x = t.
  assert_true(close(result.series()[0][3], 0.75, 0.000000001))
  // At the event point the state was reinit to -5.
  assert_true(close(result.series()[0][4], -5.0, 0.000000001))
  // After the event x = -5 + (t - 1).
  assert_true(
    close(result.series()[0][5], -4.75, 0.000000001),
    msg="after-event x=\{result.series()[0][5]} vs -4.75",
  )
  assert_true(close(result.series()[0][8], -4.0, 0.000000001))
}

///|
test "me event iteration limit aborts the run" {
  let mock = MockMe::make(
    derivative_kind=1,
    indicator_count=1,
    demand_iterations=1000,
  )
  let config = MeConfig::new(
    start_time=0.0,
    stop_time=2.0,
    step_size=0.25,
    record=[],
    solver=Rk4,
    state_count=1,
    event_indicator_count=1,
    max_event_iterations=100,
  )
  let result = run_me_simulation(mock, config~) catch {
    error => {
      assert_true(error is FmiCall(_))
      assert_true(
        error.message().contains("event iteration limit"),
        msg="unexpected message: \{error.message()}",
      )
      { times: [], series: [], steps: -1, events: 0, }
    }
  }
  assert_eq(result.steps(), -1)
}

///|
test "me stops when the fmu asks to terminate" {
  let mock = MockMe::make(
    derivative_kind=1,
    indicator_count=1,
    terminate_at_event=true,
  )
  let config = MeConfig::new(
    start_time=0.0,
    stop_time=2.0,
    step_size=0.25,
    record=[1U],
    solver=Rk4,
    state_count=1,
    event_indicator_count=1,
  )
  let result = run_me_simulation(mock, config~)
  // Steps 0..0.75 were recorded; the event at t = 1 terminates the run
  // before the record at t = 1.
  assert_eq(result.times().length(), 4)
  assert_eq(result.steps(), 4)
  assert_true(mock.finished)
}

///|
/// Runs the simulation and reports whether it failed with `Config`
/// (steps = -1 marks the `Config` branch of the catch).
fn me_config_rejected(mock : MockMe, config : MeConfig) -> Bool {
  let result = run_me_simulation(mock, config~) catch {
    error =>
      match error {
        Config(_) => { times: [], series: [], steps: -1, events: 0, }
        Timeout(_) => { times: [], series: [], steps: -2, events: 0, }
        FmiCall(..) => { times: [], series: [], steps: -2, events: 0, }
        Discarded(..) => { times: [], series: [], steps: -2, events: 0, }
      }
  }
  result.steps() == -1
}

///|
test "me rejects bad configurations" {
  let mock = MockMe::make(derivative_kind=0, indicator_count=0)
  let empty_state = MeConfig::new(
    start_time=0.0,
    stop_time=1.0,
    step_size=0.1,
    record=[],
    state_count=0,
    event_indicator_count=0,
  )
  assert_true(me_config_rejected(mock, empty_state))
  let backwards = MeConfig::new(
    start_time=1.0,
    stop_time=1.0,
    step_size=0.1,
    record=[],
    state_count=1,
    event_indicator_count=0,
  )
  assert_true(me_config_rejected(mock, backwards))
}

///|
/// dx/dt = -x, x(0) = 1: exact solution x(t) = e^-t. With tolerance 1e-6
/// the adaptive run must land within tolerance magnitude of the analytic
/// solution while using fewer derivative evaluations than fixed-step RK4
/// at h = 0.01 (100 steps x 4 evals = 400).
test "me adaptive integrates the exponential within tolerance" {
  let mock = MockMe::make(derivative_kind=0, indicator_count=0)
  mock.state = 1.0
  let config = MeConfig::new(
    start_time=0.0,
    stop_time=1.0,
    step_size=0.1,
    record=[1U],
    solver=Rk4,
    state_count=1,
    event_indicator_count=0,
    adaptive=true,
    tolerance=0.000001,
  )
  let result = run_me_simulation(mock, config~)
  assert_true(mock.finished)
  let last = result.times().length() - 1
  // The last accepted step lands exactly on stop_time.
  assert_true(
    close(result.times()[last], 1.0, 0.000000001),
    msg="final time \{result.times()[last]}",
  )
  assert_true(
    close(result.series()[0][last], 0.36787944117144233, 0.0001),
    msg="x(1)=\{result.series()[0][last]} vs e^-1=0.36787944117144233",
  )
  assert_true(mock.deriv_evals < 400, msg="deriv_evals=\{mock.deriv_evals}")
  assert_true(result.steps() < 100, msg="steps=\{result.steps()}")
}

///|
/// dx/dt = 1, indicator 1 - t crosses at t = 1, reinit to -5. The adaptive
/// step must locate the event instead of crossing it, and the run ends at
/// stop_time with x(2) = -4.
test "me adaptive locates the event and keeps integrating after it" {
  let mock = MockMe::make(
    derivative_kind=1,
    indicator_count=1,
    reinit_value=-5.0,
  )
  let config = MeConfig::new(
    start_time=0.0,
    stop_time=2.0,
    step_size=0.1,
    record=[1U],
    solver=Rk4,
    state_count=1,
    event_indicator_count=1,
    adaptive=true,
    tolerance=0.000001,
  )
  let result = run_me_simulation(mock, config~)
  assert_eq(mock.settles, 2)
  assert_eq(mock.reinits, 1)
  assert_eq(result.events(), 1)
  let last = result.times().length() - 1
  assert_true(
    close(result.times()[last], 2.0, 0.000000001),
    msg="final time \{result.times()[last]}",
  )
  assert_true(
    close(result.series()[0][last], -4.0, 0.000000001),
    msg="x(2)=\{result.series()[0][last]} vs -4",
  )
}

///|
/// Adaptive configuration errors surface as `Config`.
test "me rejects adaptive configurations" {
  let mock = MockMe::make(derivative_kind=0, indicator_count=0)
  mock.state = 1.0
  let bad_tol = MeConfig::new(
    start_time=0.0,
    stop_time=1.0,
    step_size=0.1,
    record=[],
    solver=Rk4,
    state_count=1,
    event_indicator_count=0,
    adaptive=true,
    tolerance=0.0,
  )
  assert_true(me_config_rejected(mock, bad_tol))
  let bad_max = MeConfig::new(
    start_time=0.0,
    stop_time=1.0,
    step_size=0.1,
    record=[],
    solver=Rk4,
    state_count=1,
    event_indicator_count=0,
    adaptive=true,
    max_step=Some(-1.0),
  )
  assert_true(me_config_rejected(mock, bad_max))
}

///|
/// dx/dt = 1 with a declared time event at t = 0.6, off the 0.25 grid.
/// The integrator must stop at the event, settle it, and continue — while
/// recording stays on the 0.25 grid.
test "me honors a declared time event off the grid" {
  let mock = MockMe::make(derivative_kind=1, indicator_count=0, time_events=[
    0.6,
  ])
  let config = MeConfig::new(
    start_time=0.0,
    stop_time=1.0,
    step_size=0.25,
    record=[1U],
    solver=Rk4,
    state_count=1,
    event_indicator_count=0,
  )
  let result = run_me_simulation(mock, config~)
  assert_true(
    !mock.crossed_time_event,
    msg="the master integrated past the declared time event",
  )
  assert_eq(mock.time_event_hits, 1)
  assert_eq(result.events(), 1)
  assert_eq(result.steps(), 4)
  assert_eq(result.times().length(), 5)
  for index in 0..<=4 {
    let expected = index.to_double() * 0.25
    assert_true(
      close(result.times()[index], expected, 0.000000001),
      msg="grid drift at \{index}: \{result.times()[index]}",
    )
  }
  assert_true(mock.finished)
}

///|
/// Periodic time events on the grid: every second grid point declares the
/// next event; the master settles at each without freezing or drifting.
test "me honors periodic time events on the grid" {
  let mock = MockMe::make(derivative_kind=1, indicator_count=0, time_events=[
    0.5, 1.0, 1.5,
  ])
  let config = MeConfig::new(
    start_time=0.0,
    stop_time=2.0,
    step_size=0.25,
    record=[1U],
    solver=Rk4,
    state_count=1,
    event_indicator_count=0,
  )
  let result = run_me_simulation(mock, config~)
  assert_true(
    !mock.crossed_time_event,
    msg="the master integrated past a declared time event",
  )
  assert_eq(mock.time_event_hits, 3)
  assert_eq(result.events(), 3)
  assert_eq(result.steps(), 8)
  assert_eq(result.times().length(), 9)
  for index in 0..<=8 {
    let expected = index.to_double() * 0.25
    assert_true(
      close(result.times()[index], expected, 0.000000001),
      msg="grid drift at \{index}: \{result.times()[index]}",
    )
  }
}

///|
/// Adaptive stepping must also stop at a declared time event and record
/// the accepted step that ends exactly on it.
test "me adaptive honors a declared time event" {
  let mock = MockMe::make(derivative_kind=1, indicator_count=0, time_events=[
    0.6,
  ])
  let config = MeConfig::new(
    start_time=0.0,
    stop_time=1.0,
    step_size=0.1,
    record=[1U],
    solver=Rk4,
    state_count=1,
    event_indicator_count=0,
    adaptive=true,
    tolerance=0.000001,
  )
  let result = run_me_simulation(mock, config~)
  assert_true(
    !mock.crossed_time_event,
    msg="the master integrated past the declared time event",
  )
  assert_eq(mock.time_event_hits, 1)
  assert_eq(result.events(), 1)
  let mut saw_event_time = false
  for t in result.times() {
    if (t - 0.6).abs() <= 0.000000001 {
      saw_event_time = true
    }
  }
  assert_true(
    saw_event_time,
    msg="the accepted step ending at the time event was not recorded",
  )
  assert_true(mock.finished)
}
