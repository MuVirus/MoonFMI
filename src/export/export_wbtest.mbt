///|
test "source export starts with an empty archive" {
  let request = ExportRequest::source(@schema.FmiVersion::V3)
  assert_eq(request.version, @schema.FmiVersion::V3)
  assert_eq(request.archive.entry_count(), 0)
  assert_eq(request.target, ExportTarget::Source)
}
