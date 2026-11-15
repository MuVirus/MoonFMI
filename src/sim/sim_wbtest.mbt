///|
/// Mock instance for testing the master algorithm without an FMU.
struct MockInstance {
  mut finished : Bool
  mut steps : Int32
}

///|
impl @fmi.CsInstance for MockInstance with fn setup_experiment(
  _self,
  start~,
  stop~,
) {
  let _ = start
  let _ = stop
}

///|
impl @fmi.CsInstance for MockInstance with fn initialize(self) {
  self.finished = false
  let _ = self.steps
}

///|
impl @fmi.CsInstance for MockInstance with fn step(self, t, h) {
  let _ = t
  let _ = h
  self.steps += 1
}

///|
impl @fmi.CsInstance for MockInstance with fn read_real(self, value_reference) {
  // Record values double every step: vr 1 grows 1, 2, 4, ...
  let _ = self
  value_reference.to_double() * 2.0
}

///|
impl @fmi.CsInstance for MockInstance with fn write_real(
  self,
  value_reference,
  value,
) {
  let _ = self
  let _ = value_reference
  let _ = value
}

///|
impl @fmi.CsInstance for MockInstance with fn finish(self) {
  self.finished = true
}

///|
test "cs master algorithm records every communication point" {
  let mock : MockInstance = { finished: false, steps: 0, }
  let config = CsConfig::new(start_time=0.0, stop_time=1.0, step_size=0.25, record=[
    1, 2,
  ])
  let result = run_cs_simulation(mock, config~)
  assert_eq(result.steps(), 4)
  assert_eq(result.times().length(), 5)
  assert_eq(result.times()[4], 1.0)
  assert_eq(result.series()[0][1], 2.0)
  assert_true(mock.finished)
}

///|
test "cs master algorithm rejects bad configurations" {
  let mock : MockInstance = { finished: false, steps: 0, }
  let bad = CsConfig::new(start_time=1.0, stop_time=1.0, step_size=0.1, record=[])
  let result = run_cs_simulation(mock, config=bad) catch {
    error => {
      assert_true(error is Config(_))
      { times: [], series: [], steps: -1, events: 0, }
    }
  }
  assert_eq(result.steps(), -1)
}
