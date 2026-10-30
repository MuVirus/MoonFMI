///|
test "placeholder FMU has a name and an empty archive" {
  let fmu = Fmu::placeholder()
  assert_eq(fmu.name(), "placeholder")
  assert_eq(fmu.version(), @schema.FmiVersion::V2)
  assert_eq(fmu.entry_count(), 0)
}
