///|
/// Mock participant for the coupling tests: named channels with current
/// values; `transfer` runs at every step and returns the channel updates
/// (t, h) -> (vr, value) list; every written input is logged.
struct MockNode {
  channels : Map[UInt32, Double]
  stepped : Array[Double]
  transfer : (Double, Double) -> Array[(UInt32, Double)]
}

///|
fn MockNode::make(
  initial~ : Array[(UInt32, Double)],
  transfer~ : (Double, Double) -> Array[(UInt32, Double)],
) -> MockNode {
  let channels : Map[UInt32, Double] = Map([])
  for entry in initial {
    channels[entry.0] = entry.1
  }
  { channels, stepped: [], transfer, }
}

///|
impl @fmi.CsInstance for MockNode with fn setup_experiment(_self, start~, stop~) {
  let _ = start
  let _ = stop
}

///|
impl @fmi.CsInstance for MockNode with fn initialize(_self) {
  // no experiment state
}

///|
impl @fmi.CsInstance for MockNode with fn step(self, t, h) {
  self.stepped.push(t + h)
  for entry in (self.transfer)(t, h) {
    self.channels[entry.0] = entry.1
  }
}

///|
impl @fmi.CsInstance for MockNode with fn read_real(self, value_reference) {
  match self.channels.get(value_reference) {
    Some(value) => value
    None => 0.0
  }
}

///|
impl @fmi.CsInstance for MockNode with fn write_real(
  self,
  value_reference,
  value,
) {
  self.channels[value_reference] = value
}

///|
impl @fmi.CsInstance for MockNode with fn finish(_self) {
  // nothing to terminate
}

///|
test "coupled run propagates signals without a one-step lag" {
  // A produces its current time on channel 1; B doubles its input 1 on
  // output 2. With topological stepping B must see A's output from the
  // same communication point.
  let a = MockNode::make(initial=[(1U, 0.0)], transfer=fn(t, h) {
    [(1U, t + h)]
  })
  let b = MockNode::make(initial=[(1U, 0.0), (2U, 0.0)], transfer=fn(_t, _h) {
    [(2U, a.channels.get(1U).unwrap() * 2.0)]
  })
  let config = CoupledConfig::new(
    start_time=0.0,
    stop_time=0.4,
    step_size=0.2,
    participants=[
      CoupledParticipant::new(name="a", instance=a, record=[1U]),
      CoupledParticipant::new(name="b", instance=b, record=[2U]),
    ],
    connections=[Coupling::new(from="a", out_vr=1U, to="b", in_vr=1U)],
  )
  let result = run_coupled_simulation(config~)
  assert_eq(result.steps(), 2)
  assert_eq(result.times().length(), 3)
  // A's recorded output: 0, 0.2, 0.4.
  assert_eq(result.series()[0][0], 0.0)
  assert_eq(result.series()[0][1], 0.2)
  assert_eq(result.series()[0][2], 0.4)
  // B's output must reflect A's same-point output (0.4 = 2 * 0.2, not
  // 2 * 0.0 — the no-lag property of topological stepping).
  assert_eq(result.series()[1][0], 0.0)
  assert_eq(result.series()[1][1], 0.4)
  assert_eq(result.series()[1][2], 0.8)
}

///|
test "coupled run topologically orders a diamond" {
  // a -> b -> d and a -> c -> d: Kahn's order must interleave so d steps
  // last, and the run must not flag a cycle.
  let a = MockNode::make(initial=[(1U, 1.0)], transfer=fn(_t, _h) {
    [(1U, 2.0)]
  })
  let pass = fn() -> Array[(UInt32, Double)] { [(1U, 1.0)] }
  let b = MockNode::make(initial=[(1U, 0.0)], transfer=fn(_t, _h) { pass() })
  let c = MockNode::make(initial=[(1U, 0.0)], transfer=fn(_t, _h) { pass() })
  let d = MockNode::make(initial=[(1U, 0.0), (2U, 0.0), (3U, 0.0)], transfer=fn(
    _t,
    _h,
  ) {
    [
      (
        3U,
        a.channels.get(1U).unwrap() +
        b.channels.get(1U).unwrap() +
        c.channels.get(1U).unwrap(),
      ),
    ]
  })
  let config = CoupledConfig::new(
    start_time=0.0,
    stop_time=0.1,
    step_size=0.1,
    participants=[
      CoupledParticipant::new(name="a", instance=a, record=[1U]),
      CoupledParticipant::new(name="b", instance=b, record=[1U]),
      CoupledParticipant::new(name="c", instance=c, record=[1U]),
      CoupledParticipant::new(name="d", instance=d, record=[3U]),
    ],
    connections=[
      Coupling::new(from="a", out_vr=1U, to="b", in_vr=1U),
      Coupling::new(from="a", out_vr=1U, to="c", in_vr=1U),
      Coupling::new(from="b", out_vr=1U, to="d", in_vr=1U),
      Coupling::new(from="c", out_vr=1U, to="d", in_vr=2U),
    ],
  )
  let result = run_coupled_simulation(config~)
  assert_eq(result.steps(), 1)
  // d sums a + b + c from the same grid point: 2 + 1 + 1 = 4.
  assert_eq(result.series()[3][1], 4.0)
}

///|
test "coupled run rejects cycles as algebraic loops" {
  let a = MockNode::make(initial=[(1U, 0.0)], transfer=fn(_t, _h) {
    [(1U, 0.0)]
  })
  let b = MockNode::make(initial=[(1U, 0.0)], transfer=fn(_t, _h) {
    [(1U, 0.0)]
  })
  let config = CoupledConfig::new(
    start_time=0.0,
    stop_time=0.1,
    step_size=0.1,
    participants=[
      CoupledParticipant::new(name="a", instance=a, record=[1U]),
      CoupledParticipant::new(name="b", instance=b, record=[1U]),
    ],
    connections=[
      Coupling::new(from="a", out_vr=1U, to="b", in_vr=1U),
      Coupling::new(from="b", out_vr=1U, to="a", in_vr=1U),
    ],
  )
  let mut rejected = false
  let result = run_coupled_simulation(config~) catch {
    error => {
      assert_true(error is Config(_))
      assert_true(error.message().contains("cycle"))
      rejected = true
      { times: [], series: [], steps: -1, events: 0, }
    }
  }
  assert_eq(result.steps(), -1)
  assert_true(rejected)
}

///|
test "coupled run rejects self connections and unknown endpoints" {
  let a = MockNode::make(initial=[(1U, 0.0)], transfer=fn(_t, _h) {
    [(1U, 0.0)]
  })
  let self_loop = CoupledConfig::new(
    start_time=0.0,
    stop_time=0.1,
    step_size=0.1,
    participants=[CoupledParticipant::new(name="a", instance=a, record=[1U])],
    connections=[Coupling::new(from="a", out_vr=1U, to="a", in_vr=1U)],
  )
  let mut rejected = false
  let _ = run_coupled_simulation(config=self_loop) catch {
    error => {
      assert_true(error.message().contains("algebraic loop"))
      rejected = true
      { times: [], series: [], steps: -1, events: 0, }
    }
  }
  assert_true(rejected)
  let ghost = CoupledConfig::new(
    start_time=0.0,
    stop_time=0.1,
    step_size=0.1,
    participants=[CoupledParticipant::new(name="a", instance=a, record=[1U])],
    connections=[Coupling::new(from="ghost", out_vr=1U, to="a", in_vr=1U)],
  )
  let mut rejected_ghost = false
  let _ = run_coupled_simulation(config=ghost) catch {
    error => {
      assert_true(error.message().contains("not a participant"))
      rejected_ghost = true
      { times: [], series: [], steps: -1, events: 0, }
    }
  }
  assert_true(rejected_ghost)
}

///|
test "coupled run rejects duplicate names and unobservable sources" {
  let a = MockNode::make(initial=[(1U, 0.0)], transfer=fn(_t, _h) {
    [(1U, 0.0)]
  })
  let duplicate = CoupledConfig::new(
    start_time=0.0,
    stop_time=0.1,
    step_size=0.1,
    participants=[
      CoupledParticipant::new(name="x", instance=a, record=[1U]),
      CoupledParticipant::new(name="x", instance=a, record=[1U]),
    ],
    connections=[],
  )
  let mut rejected = false
  let _ = run_coupled_simulation(config=duplicate) catch {
    error => {
      assert_true(error.message().contains("duplicate"))
      rejected = true
      { times: [], series: [], steps: -1, events: 0, }
    }
  }
  assert_true(rejected)
  // A connection sourcing a vr the producer does not record cannot be
  // observed, so the run refuses it instead of feeding stale values.
  let unobservable = CoupledConfig::new(
    start_time=0.0,
    stop_time=0.1,
    step_size=0.1,
    participants=[
      CoupledParticipant::new(name="src", instance=a, record=[1U]),
      CoupledParticipant::new(name="dst", instance=a, record=[1U]),
    ],
    connections=[Coupling::new(from="src", out_vr=9U, to="dst", in_vr=1U)],
  )
  let mut rejected_unobservable = false
  let _ = run_coupled_simulation(config=unobservable) catch {
    error => {
      assert_true(error.message().contains("cannot observe"))
      rejected_unobservable = true
      { times: [], series: [], steps: -1, events: 0, }
    }
  }
  assert_true(rejected_unobservable)
}

///|
test "coupled run rejects invalid grids and truncates the final step" {
  let a = MockNode::make(initial=[(1U, 0.0)], transfer=fn(t, h) {
    [(1U, t + h)]
  })
  let bad_grid = CoupledConfig::new(
    start_time=1.0,
    stop_time=1.0,
    step_size=0.1,
    participants=[CoupledParticipant::new(name="a", instance=a, record=[1U])],
    connections=[],
  )
  let mut rejected = false
  let _ = run_coupled_simulation(config=bad_grid) catch {
    error => {
      assert_true(error is Config(_))
      rejected = true
      { times: [], series: [], steps: -1, events: 0, }
    }
  }
  assert_true(rejected)
  // Final step truncation: stop 0.5 with step 0.2 records 0, 0.2, 0.4, 0.5.
  let truncated = CoupledConfig::new(
    start_time=0.0,
    stop_time=0.5,
    step_size=0.2,
    participants=[CoupledParticipant::new(name="a", instance=a, record=[1U])],
    connections=[],
  )
  let result = run_coupled_simulation(config=truncated)
  assert_eq(result.steps(), 3)
  assert_eq(result.times()[3], 0.5)
  assert_eq(result.series()[0][3], 0.5)
}
