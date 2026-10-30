///|
test "default simulation config stops at ten seconds" {
  let config = SimulationConfig::default()
  assert_eq(config.stop_time, 10.0)
  assert_eq(config.fmu.name(), "placeholder")
}
