///|
/// Mock for the C-11 master rollback tests. Discards the first N `doStep`
/// attempts, optionally reporting FMI 3 style confirmed progress, and
/// records every rollback-surface call so tests can verify the protocol
/// (master-algorithm.md §3.5).
struct DiscardMock {
  /// Remaining attempts to discard before stepping normally.
  mut discards_left : Int32
  /// Whether the mock reports a `last_successful_time` with a discard
  /// (FMI 3 behaviour). FMI 2 has no such report (`None`).
  confirm_progress : Bool
  /// Whether the mock implements FMU state capture.
  capture : Bool
  mut begins : Int32
  mut rollbacks : Int32
  mut commits : Int32
  mut armed : Bool
  mut finished : Bool
}

///|
fn DiscardMock::make(
  discards~ : Int32,
  confirm_progress~ : Bool = false,
  capture~ : Bool = false,
) -> DiscardMock {
  {
    discards_left: discards,
    confirm_progress,
    capture,
    begins: 0,
    rollbacks: 0,
    commits: 0,
    armed: false,
    finished: false,
  }
}

///|
impl @fmi.CsInstance for DiscardMock with fn setup_experiment(
  _self,
  start~,
  stop~,
) {
  let _ = start
  let _ = stop
}

///|
impl @fmi.CsInstance for DiscardMock with fn initialize(_self) {
  // no experiment state to reset
}

///|
/// One mock step attempt: raises `Discarded` while attempts remain, then
/// behaves like a normal step reaching `t + h`.
fn DiscardMock::attempt(
  self : DiscardMock,
  t : Double,
  h : Double,
) -> Double raise @fmi.SimulationError {
  if self.discards_left > 0 {
    self.discards_left -= 1
    let confirmed = if self.confirm_progress { Some(t + h / 2.0) } else { None }
    raise @fmi.Discarded(detail="mock discard", last_successful_time=confirmed)
  }
  t + h
}

///|
impl @fmi.CsInstance for DiscardMock with fn step(self, t, h) {
  let _ = DiscardMock::attempt(self, t, h)
}

///|
impl @fmi.CsInstance for DiscardMock with fn try_step(self, t, h) -> Double raise @fmi.SimulationError {
  DiscardMock::attempt(self, t, h)
}

///|
impl @fmi.CsInstance for DiscardMock with fn supports_state_capture(self) -> Bool {
  self.capture
}

///|
impl @fmi.CsInstance for DiscardMock with fn begin_rollback_point(self) -> Unit raise @fmi.SimulationError {
  self.begins += 1
  self.armed = true
}

///|
impl @fmi.CsInstance for DiscardMock with fn rollback(self) -> Unit raise @fmi.SimulationError {
  self.rollbacks += 1
  self.armed = false
}

///|
impl @fmi.CsInstance for DiscardMock with fn commit_rollback_point(self) -> Unit raise @fmi.SimulationError {
  self.commits += 1
  self.armed = false
}

///|
impl @fmi.CsInstance for DiscardMock with fn read_real(self, value_reference) {
  let _ = self
  value_reference.to_double() * 2.0
}

///|
impl @fmi.CsInstance for DiscardMock with fn write_real(
  self,
  value_reference,
  value,
) {
  let _ = self
  let _ = value_reference
  let _ = value
}

///|
impl @fmi.CsInstance for DiscardMock with fn finish(self) {
  self.finished = true
}

///|
test "discarded step rolls back and retries with a halved step" {
  // One discard on the very first attempt; capture available.
  let mock = DiscardMock::make(discards=1, capture=true)
  let config = CsConfig::new(start_time=0.0, stop_time=1.0, step_size=0.25, record=[
    1,
  ])
  let result = run_cs_simulation(mock, config~)
  // The grid becomes 0, 0.125, 0.375, 0.625, 0.875, 1.0: the first point
  // advances by the halved step, the rest use the full step again.
  assert_eq(result.times().length(), 6)
  assert_eq(result.times()[1], 0.125)
  assert_eq(result.times()[2], 0.375)
  assert_eq(result.times()[5], 1.0)
  assert_eq(result.steps(), 5)
  assert_true(mock.finished)
  // One begin per attempt: the first point needs two (discard + retry),
  // the other four points one each.
  assert_eq(mock.begins, 6)
  assert_eq(mock.rollbacks, 1)
  assert_eq(mock.commits, 5)
  assert_false(mock.armed)
}

///|
test "discard without capture aborts with a diagnostic (FMI 2 shape)" {
  let mock = DiscardMock::make(
    discards=3,
    confirm_progress=false,
    capture=false,
  )
  let config = CsConfig::new(start_time=0.0, stop_time=1.0, step_size=0.25, record=[
    1,
  ])
  let result = run_cs_simulation(mock, config~) catch {
    error => {
      assert_true(error is Config(_))
      assert_true(error.message().contains("state capture is unavailable"))
      { times: [], series: [], steps: -1, events: 0, }
    }
  }
  assert_eq(result.steps(), -1)
}

///|
test "discard with confirmed progress continues from that time (FMI 3 shape)" {
  // No capture, but the FMU reports lastSuccessfulTime = t + h/2.
  let mock = DiscardMock::make(discards=1, confirm_progress=true, capture=false)
  let config = CsConfig::new(start_time=0.0, stop_time=1.0, step_size=0.25, record=[
    1,
  ])
  let result = run_cs_simulation(mock, config~)
  // Same grid as the rollback path: continue from the confirmed time and
  // use the full step from the next point on.
  assert_eq(result.times().length(), 6)
  assert_eq(result.times()[1], 0.125)
  assert_eq(result.times()[5], 1.0)
  assert_eq(result.steps(), 5)
  // No capture surface was touched.
  assert_eq(mock.begins, 0)
  assert_eq(mock.rollbacks, 0)
  assert_eq(mock.commits, 0)
}

///|
test "persistent discards hit the retry cap" {
  let mock = DiscardMock::make(discards=100, capture=true)
  let config = CsConfig::new(start_time=0.0, stop_time=1.0, step_size=0.25, record=[
    1,
  ])
  let result = run_cs_simulation(mock, config~) catch {
    error => {
      assert_true(error is Config(_))
      assert_true(error.message().contains("without converging"))
      { times: [], series: [], steps: -1, events: 0, }
    }
  }
  assert_eq(result.steps(), -1)
  // Five retries were attempted, each rolled back; the capture never
  // stayed armed.
  assert_eq(mock.rollbacks, 5)
  assert_eq(mock.begins, 5)
  assert_false(mock.armed)
}

///|
test "clean run arms and commits one capture per step" {
  let mock = DiscardMock::make(discards=0, capture=true)
  let config = CsConfig::new(start_time=0.0, stop_time=1.0, step_size=0.25, record=[
    1,
  ])
  let result = run_cs_simulation(mock, config~)
  assert_eq(result.steps(), 4)
  assert_eq(mock.begins, 4)
  assert_eq(mock.commits, 4)
  assert_eq(mock.rollbacks, 0)
  assert_false(mock.armed)
}
