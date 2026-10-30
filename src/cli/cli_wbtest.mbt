///|
test "cli exposes the three p0 commands" {
  assert_eq(Command::Validate.name(), "validate")
  assert_eq(Command::Info.name(), "info")
  assert_eq(Command::Simulate.name(), "simulate")
  assert_eq(default_stop_time(), 10.0)
  assert_eq(default_export_target(), @export.ExportTarget::Source)
}
