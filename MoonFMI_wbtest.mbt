// Whitebox tests run within the package scope.
// Use them to validate internal helpers or invariants.
// Keep them focused; public behavior belongs in `_test.mbt`.

///|
/// The CLI version string must stay in sync with the `version` field of
/// `moon.mod`: releases always take the smallest possible increment, and a
/// mismatch here means one of the two constants was bumped alone.
test "cli version matches moon.mod" {
  // The root package runs from the repository root, so `moon.mod` resolves
  // directly; a missing file raises and fails the test loudly.
  let content = @fs.read_file_to_string("moon.mod")
  let mut declared : String? = None
  for line in content.split("\n") {
    let fields = line.trim().to_string().split("\"").collect()
    if fields.length() >= 2 && fields[0].to_owned() == "version = " {
      declared = Some(fields[1].to_owned())
      break
    }
  }
  // No `version = "…"` line means the moon.mod layout changed; fail loudly.
  guard! declared is Some(declared)
  assert_eq(declared, @cli.version_string())
}
