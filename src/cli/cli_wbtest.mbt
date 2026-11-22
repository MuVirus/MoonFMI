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
  let missing : (String) -> Bytes raise ReadError = _path => {
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

///|
test "couple help and usage" {
  assert_eq(run(["couple", "--help"], _path => b""), 0)
  assert_true(usage().contains("couple"))
  assert_true(usage().contains("--connect"))
  assert_true(command_help("couple").contains("moonfmi.couple/v1"))
}

///|
test "couple missing fmu is a usage error" {
  assert_eq(run(["couple"], _path => b""), 2)
  assert_eq(run(["couple", "--connect", "a.x=b.y"], _path => b""), 2)
}

///|
/// `--config` without a value is a usage error, and a config file that
/// cannot be read is a general error (exit 1).

///|
test "config flag errors map to the exit code matrix" {
  let missing : (String) -> Bytes raise ReadError = _path => {
    raise ReadError::Failed("no such file")
  }
  assert_eq(run(["simulate", "x.fmu", "--config"], missing), 2)
  assert_eq(run(["couple", "x.fmu", "--config"], missing), 2)
  assert_eq(
    run(
      ["simulate", "x.fmu", "--config", ".moonfmi-tmp/no-such-config.json"],
      missing,
    ),
    1,
  )
}

///|
/// `resolve_typed_scalar` is pure, so it can be unit-tested without loading
/// any FMU.
test "resolve_typed_scalar infers signal types and rejects the rest" {
  let xml = b"<?xml version=\"1.0\" encoding=\"UTF-8\"?><fmiModelDescription fmiVersion=\"2.0\" modelName=\"T\" guid=\"{11111111-1111-1111-1111-111111111111}\"><CoSimulation modelIdentifier=\"T\"/><ModelVariables><ScalarVariable name=\"out\" valueReference=\"7\" causality=\"output\"><Real start=\"0\"/></ScalarVariable><ScalarVariable name=\"inp\" valueReference=\"8\" causality=\"input\"><Real start=\"0\"/></ScalarVariable><ScalarVariable name=\"num\" valueReference=\"9\" causality=\"output\"><Integer start=\"0\"/></ScalarVariable><ScalarVariable name=\"flag\" valueReference=\"10\" causality=\"output\"><Boolean start=\"false\"/></ScalarVariable><ScalarVariable name=\"label\" valueReference=\"11\" causality=\"output\"><String start=\"x\"/></ScalarVariable></ModelVariables><ModelStructure/></fmiModelDescription>"
  let (model, report) = @schema.parse_and_validate(xml)
  assert_true(
    model is Some(_),
    msg="fixture model description failed to parse: " +
      report.diagnostics().map(fn(d) { d.render() }).join(" | "),
  )
  let model = match model {
    Some(model) => model
    None => abort("unreachable: fixture model description is valid")
  }
  match resolve_typed_scalar(model, "out", Output) {
    Ok((reference, signal)) => {
      assert_eq(reference, 7U)
      assert_true(signal is Real)
    }
    Err(message) => abort("expected to resolve 'out', got: " + message)
  }
  match resolve_typed_scalar(model, "inp", Input) {
    Ok((reference, signal)) => {
      assert_eq(reference, 8U)
      assert_true(signal is Real)
    }
    Err(message) => abort("expected to resolve 'inp', got: " + message)
  }
  // An Integer output is connectable and carries its signal type.
  match resolve_typed_scalar(model, "num", Output) {
    Ok((reference, signal)) => {
      assert_eq(reference, 9U)
      assert_true(signal is Integer)
    }
    Err(message) => abort("expected to resolve 'num', got: " + message)
  }
  match resolve_typed_scalar(model, "flag", Output) {
    Ok((reference, signal)) => {
      assert_eq(reference, 10U)
      assert_true(signal is Boolean)
    }
    Err(message) => abort("expected to resolve 'flag', got: " + message)
  }
  // A String output exists but cannot be coupled.
  match resolve_typed_scalar(model, "label", Output) {
    Err(_) => ()
    Ok((reference, _)) =>
      abort(
        "'label' is a String output, expected an error, got " +
        reference.to_string(),
      )
  }
  // Wrong causality is rejected in both directions.
  match resolve_typed_scalar(model, "out", Input) {
    Err(_) => ()
    Ok(_) => abort("'out' is an output, expected an error for input")
  }
  match resolve_typed_scalar(model, "inp", Output) {
    Err(_) => ()
    Ok(_) => abort("'inp' is an input, expected an error for output")
  }
  match resolve_typed_scalar(model, "missing", Output) {
    Err(_) => ()
    Ok((reference, _)) =>
      abort(
        "'missing' is undeclared, expected an error, got " +
        reference.to_string(),
      )
  }
}

///|
test "normalize_sha256 accepts hex and normalizes case" {
  match
    normalize_sha256(
      "1C7A40AB239C03E4795B230C6FE414A673030D0CE9F26A160301DADCA7FF30B7",
    ) {
    Some(normalized) =>
      assert_eq(
        normalized, "1c7a40ab239c03e4795b230c6fe414a673030d0ce9f26a160301dadca7ff30b7",
      )
    None => abort("expected uppercase hex to normalize")
  }
  // Wrong length, non-hex characters, empty.
  match normalize_sha256("abc") {
    Some(_) => abort("expected a short digest to be rejected")
    None => ()
  }
  match
    normalize_sha256(
      "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz",
    ) {
    Some(_) => abort("expected non-hex characters to be rejected")
    None => ()
  }
  match normalize_sha256("") {
    Some(_) => abort("expected an empty digest to be rejected")
    None => ()
  }
}

///|
test "temp_dir_suffix yields distinct hex strings" {
  let first = temp_dir_suffix()
  assert_eq(first.char_length(), 16)
  let mut all_hex = true
  for ch in first {
    let code = ch.to_int()
    let ok = (code >= 0x30 && code <= 0x39) || (code >= 0x61 && code <= 0x66)
    if !ok {
      all_hex = false
    }
  }
  assert_true(all_hex, msg="suffix must be lowercase hex")
  // Two calls must differ with overwhelming probability; the entropy
  // fallback (sha256 of the wall clock) also changes between calls.
  let second = temp_dir_suffix()
  assert_true(first != second, msg="suffixes must differ between calls")
}

///|
test "parse_nonnegative_int accepts digits only" {
  assert_eq(parse_nonnegative_int("0"), Some(0))
  assert_eq(parse_nonnegative_int("5"), Some(5))
  assert_eq(parse_nonnegative_int("12"), Some(12))
  assert_true(parse_nonnegative_int("") is None)
  assert_true(parse_nonnegative_int("-1") is None)
  assert_true(parse_nonnegative_int("3x") is None)
  assert_true(parse_nonnegative_int("999999999999") is None)
}

///|
/// The CLI version string must stay in sync with the `version` field of
/// `moon.mod`: releases always take the smallest possible increment, and a
/// mismatch here means one of the two constants was bumped alone. The test
/// resolves `moon.mod` from the package directory or the repository root,
/// whichever the runner's working directory lands on.
test "cli version matches moon.mod" {
  let path = if @fs.path_exists("../../moon.mod") {
    "../../moon.mod"
  } else if @fs.path_exists("moon.mod") {
    "moon.mod"
  } else {
    abort("moon.mod not found from the runner working directory")
  }
  let content = @fs.read_file_to_string(path)
  let mut declared : String? = None
  for line in content.split("\n") {
    let fields = line.trim().to_owned().split("\"").collect()
    if fields.length() >= 2 && fields[0].to_owned() == "version = " {
      declared = Some(fields[1].to_owned())
      break
    }
  }
  // No `version = "…"` line means the moon.mod layout changed; fail loudly.
  guard! declared is Some(declared)
  assert_eq(declared, version_string())
}
