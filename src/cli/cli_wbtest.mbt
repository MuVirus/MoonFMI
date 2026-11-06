///|
test "usage mentions commands and exit codes" {
  let text = usage()
  assert_true(text.contains("validate"))
  assert_true(text.contains("info"))
  assert_true(text.contains("Exit codes"))
}

///|
test "json escaping is stable" {
  assert_eq(json_escape("a\"b\\c\nd"), "a\\\"b\\\\c\\nd")
}

///|
test "unknown command exits with usage error" {
  let code = run(["frobnicate"], _path => b"")
  assert_eq(code, 2)
}

///|
test "help and version exit zero" {
  assert_eq(run(["help"], _path => b""), 0)
  assert_eq(run(["version"], _path => b""), 0)
}

///|
test "missing file argument is a usage error" {
  assert_eq(run(["validate"], _path => b""), 2)
  assert_eq(run(["info"], _path => b""), 2)
}

///|
test "unreadable file exits with code 3" {
  let code = run(["validate", "missing.fmu"], path => {
    let _ = path
    raise ReadError::Failed("no such file")
  })
  assert_eq(code, 3)
}
