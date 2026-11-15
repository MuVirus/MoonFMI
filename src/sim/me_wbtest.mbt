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
  mut completed_calls : Int32
  mut nominals_calls : Int32
  mut finished : Bool
}

///|
fn MockMe::make(
  derivative_kind~ : Int32,
  indicator_count~ : Int32,
  reinit_value? : Double,
  demand_iterations~ : Int32 = 0,
  terminate_at_event~ : Bool = false,
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
    completed_calls: 0,
    nominals_calls: 0,
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
  derivatives[0] = if self.derivative_kind == 0 { -self.state } else { 1.0 }
}

///|
impl @fmi.MeInstance for MockMe with fn get_event_indicators(self, indicators) {
  if self.indicator_count > 0 {
    indicators[0] = 1.0 - self.time
  }
}

///|
impl @fmi.MeInstance for MockMe with fn get_nominals_of_continuous_states(
  self,
  nominals,
) {
  nominals[0] = 1.0
  self.nominals_calls += 1
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
  if !self.initial_done {
    // Initial settlement: no reinit.
    return {
      new_discrete_states_needed: false,
      terminate_simulation: false,
      nominals_changed: false,
      states_changed: false,
      next_event_time_defined: false,
      next_event_time: 0.0,
    }
  }
  match self.reinit_value {
    Some(value) => {
      self.state = value
      self.reinits += 1
    }
    None => ()
  }
  {
    new_discrete_states_needed: false,
    terminate_simulation: false,
    nominals_changed: false,
    states_changed: true,
    next_event_time_defined: false,
    next_event_time: 0.0,
  }
}

///|
impl @fmi.MeInstance for MockMe with fn enter_continuous_time_mode(self) {
  self.in_event_mode = false
  self.initial_done = true
}

///|
impl @fmi.MeInstance for MockMe with fn completed_integrator_step(
  self,
  no_set_fmu_state_prior~,
) {
  let _ = no_set_fmu_state_prior
  self.completed_calls += 1
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
        FmiCall(..) => { times: [], series: [], steps: -2, events: 0, }
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
