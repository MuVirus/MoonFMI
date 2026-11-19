///|
/// Mock participant for the coupling tests: named channels with current
/// values; `transfer` runs at every step and returns the channel updates
/// (t, h) -> (vr, value) list; every written input is logged. Integer and
/// Boolean signals share the same Double channels — Int32 values are exact
/// in Double and booleans are stored as 1.0 / 0.0 — with the typed methods
/// converting at the boundary, so a wrongly-routed Real value (e.g. 5.5
/// through an Integer connection) stays visible to the tests.
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
impl @fmi.CsInstance for MockNode with fn read_integer(self, value_reference) {
  match self.channels.get(value_reference) {
    Some(value) => value.to_int()
    None => 0
  }
}

///|
impl @fmi.CsInstance for MockNode with fn write_integer(
  self,
  value_reference,
  value,
) {
  self.channels[value_reference] = value.to_double()
}

///|
impl @fmi.CsInstance for MockNode with fn read_boolean(self, value_reference) {
  match self.channels.get(value_reference) {
    Some(value) => value != 0.0
    None => false
  }
}

///|
impl @fmi.CsInstance for MockNode with fn write_boolean(
  self,
  value_reference,
  value,
) {
  self.channels[value_reference] = if value { 1.0 } else { 0.0 }
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

///|
test "coordinated rollback halves the whole grid and rolls back everyone" {
  // Both participants can capture FMU state, so the coupled run switches
  // to coordinated mode: one discard rolls EVERY participant back and the
  // whole grid step is halved — no participant is halved on its own.
  let a = DiscardMock::make(discards=1, capture=true)
  let b = DiscardMock::make(discards=0, capture=true)
  let config = CoupledConfig::new(
    start_time=0.0,
    stop_time=1.0,
    step_size=0.5,
    participants=[
      CoupledParticipant::new(name="a", instance=a, record=[1U]),
      CoupledParticipant::new(name="b", instance=b, record=[1U]),
    ],
    connections=[Coupling::new(from="a", out_vr=1U, to="b", in_vr=1U)],
  )
  let result = run_coupled_simulation(config~)
  // The discarded first point is retried with the halved step; the grid
  // becomes 0, 0.25, 0.75, 1.0 (the next points use the full step again).
  assert_eq(result.steps(), 3)
  assert_eq(result.times().length(), 4)
  assert_eq(result.times()[1], 0.25)
  assert_eq(result.times()[2], 0.75)
  assert_eq(result.times()[3], 1.0)
  // One begin per attempt (2 for the retried point, 1 for the other two),
  // one rollback on EACH participant for the discard, one commit per
  // settled point.
  assert_eq(a.begins, 4)
  assert_eq(b.begins, 4)
  assert_eq(a.rollbacks, 1)
  assert_eq(b.rollbacks, 1)
  assert_eq(a.commits, 3)
  assert_eq(b.commits, 3)
  assert_false(a.armed)
  assert_false(b.armed)
}

///|
test "coordinated rollback requires capture on every participant" {
  // a cannot capture: coordinated mode stays off, so the discard surfaces
  // through a's own step semantics, aborts the run, and the capture
  // protocol is never touched.
  let a = DiscardMock::make(discards=1, capture=false)
  let b = DiscardMock::make(discards=0, capture=true)
  let config = CoupledConfig::new(
    start_time=0.0,
    stop_time=1.0,
    step_size=0.5,
    participants=[
      CoupledParticipant::new(name="a", instance=a, record=[1U]),
      CoupledParticipant::new(name="b", instance=b, record=[1U]),
    ],
    connections=[Coupling::new(from="a", out_vr=1U, to="b", in_vr=1U)],
  )
  let result = run_coupled_simulation(config~) catch {
    error => {
      assert_true(error.message().contains("discard"))
      { times: [], series: [], steps: -1, events: 0, }
    }
  }
  assert_eq(result.steps(), -1)
  // No coordinated protocol ran: b was never armed, never finished.
  assert_eq(b.begins, 0)
  assert_eq(b.rollbacks, 0)
  assert_eq(b.commits, 0)
  assert_false(b.finished)
}

///|
test "typed Integer/Boolean connections roundtrip through the typed surface" {
  // a carries a Real channel value that is not representable as an Int32
  // (5.5) and one that is not a wire boolean (2.0). The coupling must
  // route them through read_integer/write_integer (5.5 truncates to 5)
  // and read_boolean/write_boolean (2.0 reads as true, writes back 1.0);
  // a Real-typed leak would leave 5.5 / 2.0 on b's side.
  let a = MockNode::make(initial=[(1U, 5.5), (2U, 2.0)], transfer=fn(_t, _h) {
    []
  })
  let b = MockNode::make(initial=[(1U, 0.0), (2U, 0.0), (3U, 0.0)], transfer=fn(
    _t,
    _h,
  ) {
    [(3U, 7.0)]
  })
  let config = CoupledConfig::new(
    start_time=0.0,
    stop_time=0.1,
    step_size=0.1,
    participants=[
      // Typed connections observe their outputs through the typed surface
      // directly; the source does not need the vr in its record list.
      CoupledParticipant::new(name="a", instance=a, record=[]),
      CoupledParticipant::new(name="b", instance=b, record=[3U]),
    ],
    connections=[
      Coupling::new(from="a", out_vr=1U, to="b", in_vr=1U, signal=Integer),
      Coupling::new(from="a", out_vr=2U, to="b", in_vr=2U, signal=Boolean),
    ],
  )
  let result = run_coupled_simulation(config~)
  assert_eq(result.steps(), 1)
  assert_eq(b.channels.get(1U).unwrap(), 5.0)
  assert_eq(b.channels.get(2U).unwrap(), 1.0)
  // b's Real output still flows through the record list untouched.
  assert_eq(result.series()[0][0], 0.0)
  assert_eq(result.series()[0][1], 7.0)
}

///|
test "loop solving converges a direct-feedthrough algebraic loop" {
  // a.out = 1 + 0.5 * b.out and b.out = 1 + 0.5 * a.out: a two-node
  // algebraic loop with the unique fixed point 2. With loop solving on,
  // the Jacobi iteration converges geometrically instead of the cycle
  // being rejected.
  let b_holder : Array[MockNode] = []
  let a = MockNode::make(initial=[(1U, 0.0)], transfer=fn(_t, _h) {
    [(1U, 1.0 + 0.5 * b_holder[0].channels.get(2U).unwrap())]
  })
  let b = MockNode::make(initial=[(2U, 0.0)], transfer=fn(_t, _h) {
    [(2U, 1.0 + 0.5 * a.channels.get(1U).unwrap())]
  })
  b_holder.push(b)
  let config = CoupledConfig::new(
    start_time=0.0,
    stop_time=0.1,
    step_size=0.1,
    participants=[
      CoupledParticipant::new(name="a", instance=a, record=[1U]),
      CoupledParticipant::new(name="b", instance=b, record=[2U]),
    ],
    connections=[
      Coupling::new(from="a", out_vr=1U, to="b", in_vr=2U),
      Coupling::new(from="b", out_vr=2U, to="a", in_vr=1U),
    ],
    max_loop_iterations=Some(100),
    loop_tolerance=0.000000001,
  )
  let result = run_coupled_simulation(config~)
  assert_eq(result.steps(), 1)
  // Both outputs settled on the fixed point 2 within the tolerance.
  assert_true((result.series()[0][1] - 2.0).abs() < 0.00000001)
  assert_true((result.series()[1][1] - 2.0).abs() < 0.00000001)
  // The block actually iterated: far more step calls than grid points.
  assert_true(a.stepped.length() > 10)
}

///|
test "loop solving reports non-convergence with iterations and residual" {
  // out = -2 * in amplifies every pass: the Jacobi iteration oscillates
  // and diverges, so the run must fail with the iteration count and the
  // last residual instead of recording unfixed outputs.
  let b_holder : Array[MockNode] = []
  let a = MockNode::make(initial=[(1U, 1.0)], transfer=fn(_t, _h) {
    [(1U, -2.0 * b_holder[0].channels.get(2U).unwrap())]
  })
  let b = MockNode::make(initial=[(2U, 1.0)], transfer=fn(_t, _h) {
    [(2U, -2.0 * a.channels.get(1U).unwrap())]
  })
  b_holder.push(b)
  let config = CoupledConfig::new(
    start_time=0.0,
    stop_time=0.1,
    step_size=0.1,
    participants=[
      CoupledParticipant::new(name="a", instance=a, record=[1U]),
      CoupledParticipant::new(name="b", instance=b, record=[2U]),
    ],
    connections=[
      Coupling::new(from="a", out_vr=1U, to="b", in_vr=2U),
      Coupling::new(from="b", out_vr=2U, to="a", in_vr=1U),
    ],
    max_loop_iterations=Some(10),
    loop_tolerance=0.000000001,
  )
  let result = run_coupled_simulation(config~) catch {
    error => {
      assert_true(error is Config(_))
      assert_true(
        error.message().contains("did not converge within 10 iterations"),
      )
      assert_true(error.message().contains("residual"))
      { times: [], series: [], steps: -1, events: 0, }
    }
  }
  assert_eq(result.steps(), -1)
}

///|
test "loop solving stays off by default (None rejects cycles)" {
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
    max_loop_iterations=None,
  )
  let mut rejected = false
  let result = run_coupled_simulation(config~) catch {
    error => {
      assert_true(error.message().contains("cycle"))
      rejected = true
      { times: [], series: [], steps: -1, events: 0, }
    }
  }
  assert_eq(result.steps(), -1)
  assert_true(rejected)
}

///|
test "loop solving turns a self connection into a one-member loop block" {
  // out = 1 + 0.5 * in fed back into itself: the same fixed point 2, now
  // reached by iterating the single-member block instead of rejecting the
  // self connection.
  let holder : Array[MockNode] = []
  let a = MockNode::make(initial=[(10U, 0.0), (1U, 0.0)], transfer=fn(_t, _h) {
    [(1U, 1.0 + 0.5 * holder[0].channels.get(10U).unwrap())]
  })
  holder.push(a)
  let config = CoupledConfig::new(
    start_time=0.0,
    stop_time=0.1,
    step_size=0.1,
    participants=[CoupledParticipant::new(name="a", instance=a, record=[1U])],
    connections=[Coupling::new(from="a", out_vr=1U, to="a", in_vr=10U)],
    max_loop_iterations=Some(100),
  )
  let result = run_coupled_simulation(config~)
  assert_eq(result.steps(), 1)
  assert_true((result.series()[0][1] - 2.0).abs() < 0.00000001)
}

///|
/// A feedthrough mock whose transfer reads the value written to its own
/// input (not the producer's channel), so a state-restored Jacobi
/// iteration converges the same way a real feedthrough FMU does. Carries
/// capture counters for the inter-iteration restore assertions.
struct CaptureLoopMock {
  input_vr : UInt32
  output_vr : UInt32
  mut input_value : Double
  mut output_value : Double
  gain : Double
  offset : Double
  stepped : Array[Double]
  capture : Bool
  mut begins : Int32
  mut rollbacks : Int32
  mut commits : Int32
}

///|
fn CaptureLoopMock::make(
  input_vr~ : UInt32,
  output_vr~ : UInt32,
  initial~ : Double,
  gain~ : Double,
  offset~ : Double,
  capture~ : Bool,
) -> CaptureLoopMock {
  {
    input_vr,
    output_vr,
    input_value: initial,
    output_value: initial,
    gain,
    offset,
    stepped: [],
    capture,
    begins: 0,
    rollbacks: 0,
    commits: 0,
  }
}

///|
impl @fmi.CsInstance for CaptureLoopMock with fn setup_experiment(
  _self,
  start~,
  stop~,
) {
  let _ = start
  let _ = stop
}

///|
impl @fmi.CsInstance for CaptureLoopMock with fn initialize(_self) {
  // no experiment state
}

///|
impl @fmi.CsInstance for CaptureLoopMock with fn step(self, t, _h) {
  self.stepped.push(t)
  self.output_value = self.offset + self.gain * self.input_value
}

///|
impl @fmi.CsInstance for CaptureLoopMock with fn read_real(
  self,
  value_reference,
) {
  if value_reference == self.output_vr {
    self.output_value
  } else if value_reference == self.input_vr {
    self.input_value
  } else {
    0.0
  }
}

///|
impl @fmi.CsInstance for CaptureLoopMock with fn write_real(
  self,
  value_reference,
  value,
) {
  if value_reference == self.input_vr {
    self.input_value = value
  }
}

///|
impl @fmi.CsInstance for CaptureLoopMock with fn finish(_self) {
  // nothing to terminate
}

///|
impl @fmi.CsInstance for CaptureLoopMock with fn supports_state_capture(self) -> Bool {
  self.capture
}

///|
impl @fmi.CsInstance for CaptureLoopMock with fn begin_rollback_point(self) -> Unit raise @fmi.SimulationError {
  self.begins += 1
}

///|
impl @fmi.CsInstance for CaptureLoopMock with fn rollback(self) -> Unit raise @fmi.SimulationError {
  self.rollbacks += 1
}

///|
impl @fmi.CsInstance for CaptureLoopMock with fn commit_rollback_point(self) -> Unit raise @fmi.SimulationError {
  self.commits += 1
}

///|
/// Minimal SCC loop blocks (0.7.0): a two-node algebraic loop with a
/// downstream consumer produces ONE loop block over the cycle members
/// only; the consumer runs as a plain Single unit after the block, stepped
/// once per grid point. The block members support capture, so every
/// Jacobi iteration after the first rolls them back to the grid-point
/// state — block-local begin/commit because the non-capturable consumer
/// makes the run non-coordinated.
test "loop blocks are minimal SCCs and iterations restore state" {
  let a = CaptureLoopMock::make(
    input_vr=10U,
    output_vr=1U,
    initial=0.0,
    gain=0.5,
    offset=1.0,
    capture=true,
  )
  let b = CaptureLoopMock::make(
    input_vr=20U,
    output_vr=2U,
    initial=0.0,
    gain=0.5,
    offset=1.0,
    capture=true,
  )
  let c = CaptureLoopMock::make(
    input_vr=30U,
    output_vr=3U,
    initial=0.0,
    gain=10.0,
    offset=0.0,
    capture=false,
  )
  let participants = [
    CoupledParticipant::new(name="a", instance=a, record=[1U]),
    CoupledParticipant::new(name="b", instance=b, record=[2U]),
    CoupledParticipant::new(name="c", instance=c, record=[3U]),
  ]
  let connections = [
    Coupling::new(from="a", out_vr=1U, to="b", in_vr=20U),
    Coupling::new(from="b", out_vr=2U, to="a", in_vr=10U),
    Coupling::new(from="b", out_vr=2U, to="c", in_vr=30U),
  ]
  // Schedule shape: the cycle {a, b} is one LoopBlock, c is a Single
  // scheduled after the block (dependencies first).
  let schedule = build_schedule(participants, connections, Some(100))
  assert_eq(schedule.length(), 2)
  assert_true(
    match schedule[0] {
      LoopBlock(members) => members.length() == 2
      _ => false
    },
    msg="the cycle must be one two-member loop block",
  )
  assert_true(
    match schedule[1] {
      Single(index) => index == 2
      _ => false
    },
    msg="the downstream consumer must be a plain Single unit",
  )
  let config = CoupledConfig::new(
    start_time=0.0,
    stop_time=0.1,
    step_size=0.1,
    participants~,
    connections~,
    max_loop_iterations=Some(100),
    loop_tolerance=0.000000001,
  )
  let result = run_coupled_simulation(config~)
  assert_eq(result.steps(), 1)
  // The loop settles on the fixed point 2; the downstream consumer sees
  // the settled output (10 * 2 = 20), not an intermediate iteration.
  assert_true((result.series()[0][1] - 2.0).abs() < 0.00000001)
  assert_true((result.series()[1][1] - 2.0).abs() < 0.00000001)
  assert_true((result.series()[2][1] - 20.0).abs() < 0.00000001)
  // The loop iterated; the consumer did not.
  assert_true(a.stepped.length() > 10)
  assert_eq(c.stepped.length(), 1)
  // Block-local capture lifecycle: one begin and one commit per member,
  // one rollback per extra iteration.
  assert_eq(a.begins, 1)
  assert_eq(a.commits, 1)
  assert_true(a.rollbacks >= 5, msg="iterations after the first must restore")
  assert_eq(b.begins, 1)
  assert_eq(b.commits, 1)
  assert_true(b.rollbacks >= 5)
}
