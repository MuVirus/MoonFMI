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

///|
/// The exit code matrix of cli-and-testing.md §4, exercised through the
/// dispatch entry point. Not every code is reachable from pure inputs
/// (5 and 6 need a running FMU; those paths are covered by the integration
/// suite), so the matrix here pins the pure mappings.
test "exit code matrix" {
  let missing : (String) -> Bytes raise ReadError = fn(_path) {
    raise ReadError::Failed("no such file")
  }
  // 0 success paths
  assert_eq(run(["version"], missing), 0)
  assert_eq(run(["help"], missing), 0)
  assert_eq(run(["validate", "--help"], missing), 0)
  assert_eq(run(["info", "--help"], missing), 0)
  assert_eq(run(["simulate", "--help"], missing), 0)
  assert_eq(run(["package", "--help"], missing), 0)
  assert_eq(run(["completion", "bash"], missing), 0)
  assert_eq(run(["completion", "tcsh"], missing), 2)
  // 2 usage errors
  assert_eq(run(["frobnicate"], missing), 2)
  assert_eq(run(["validate"], missing), 2)
  assert_eq(run(["simulate", "x.fmu", "--interface", "nope"], missing), 2)
  assert_eq(run(["simulate", "x.fmu", "--solver", "nope"], missing), 2)
  assert_eq(run(["simulate", "x.fmu", "--backend", "nope"], missing), 2)
  assert_eq(run(["completion"], missing), 2)
  // 3 unreadable file
  assert_eq(run(["validate", "missing.fmu"], missing), 3)
  assert_eq(run(["info", "missing.fmu"], missing), 3)
  assert_eq(run(["simulate", "missing.fmu"], missing), 3)
}

///|
test "wasm backend is rejected as unsupported" {
  // The gate fires before the file is read, so the reader is never called.
  let code = run(["simulate", "whatever.fmu", "--backend", "wasm"], _path => {
    abort("reader must not be called")
  })
  assert_eq(code, 4)
}

///|
test "completion scripts are non-empty for known shells" {
  assert_true(completion_script("bash").contains("moonfmi"))
  assert_true(completion_script("zsh").contains("moonfmi"))
  assert_true(completion_script("pwsh").contains("moonfmi"))
  assert_true(completion_script("tcsh").contains("unknown shell"))
}

///|
test "json outputs carry their schema versions" {
  let report = @schema.ValidationReport::new()
  assert_true(
    report_json("model.fmu", None, report).contains("moonfmi.validate/v1"),
  )
}

///|
test "doctor reports a healthy environment" {
  assert_eq(run(["doctor"], _path => b""), 0)
}
