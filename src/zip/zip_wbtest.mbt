///|
test "new archive has no entries" {
  let archive = ZipArchive::new()
  assert_eq(archive.entry_count(), 0)
}
