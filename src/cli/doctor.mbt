///|
/// `moonfmi doctor` (task D-03): check the local environment and report
/// what works, what fails, and what was skipped.
///
/// Exit codes: 0 all required checks pass, 7 a required check failed.

///|
priv enum CheckStatus {
  Ok_
  Fail
  Skip
}

///|
priv struct Check {
  name : String
  status : CheckStatus
  detail : String
  /// Required checks fail the doctor; optional ones just report.
  required : Bool
}

///|
fn check_status_text(status : CheckStatus) -> String {
  match status {
    Ok_ => "ok"
    Fail => "fail"
    Skip => "skip"
  }
}

///|
fn doctor_json(checks : Array[Check]) -> String {
  let builder = StringBuilder()
  builder.write_string(
    "{\n  \"schema\": \"moonfmi.doctor/v1\",\n  \"checks\": [",
  )
  for index, check in checks {
    if index > 0 {
      builder.write_string(",")
    }
    builder.write_string("\n    {\"name\": ")
    builder.write_string(json_string(check.name))
    builder.write_string(", \"status\": ")
    builder.write_string(json_string(check_status_text(check.status)))
    builder.write_string(", \"detail\": ")
    builder.write_string(json_string(check.detail))
    builder.write_string(", \"required\": ")
    builder.write_string(if check.required { "true" } else { "false" })
    builder.write_string("}")
  }
  builder.write_string("\n  ]\n}")
  builder.to_string()
}

///|
fn run_doctor(argv : Array[String], skip : Int32) -> Int32 {
  let mut json = false
  let mut index = skip
  while index < argv.length() {
    let arg = argv[index]
    if arg == "--json" {
      json = true
      index += 1
    } else {
      println("moonfmi doctor: unknown argument '\{arg}'\n")
      println(usage())
      return 2
    }
  }
  let checks : Array[Check] = []
  // Version: always known.
  checks.push({
    name: "moonfmi-version",
    status: Ok_,
    detail: moonfmi_version,
    required: true,
  })
  // Platform mapping: the CS/ME loaders depend on it.
  let host_name = @native.host_platform_name()
  match @fmi.parse_host_platform(host_name) {
    Some(_) =>
      checks.push({
        name: "platform-mapping",
        status: Ok_,
        detail: host_name,
        required: true,
      })
    None =>
      checks.push({
        name: "platform-mapping",
        status: Fail,
        detail: "unknown host platform '\{host_name}'",
        required: true,
      })
  }
  // Working directory: must exist and be writable for temp extraction.
  let cwd = match @env.current_dir() {
    Some(directory) => directory
    None => "."
  }
  checks.push({
    name: "working-directory",
    status: Ok_,
    detail: cwd,
    required: true,
  })
  // A fresh checkout has no .moonfmi-tmp yet, and dir_creatable uses the
  // non-recursive create_dir, so the parent must exist first.
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let temp_dir = ".moonfmi-tmp/doctor-\{temp_dir_suffix()}"
  let temp_ok = dir_creatable(temp_dir)
  if temp_ok {
    checks.push({
      name: "temp-directory",
      status: Ok_,
      detail: "created and removed " + temp_dir,
      required: true,
    })
  } else {
    checks.push({
      name: "temp-directory",
      status: Fail,
      detail: "could not create " + temp_dir,
      required: true,
    })
  }
  // Test corpus: optional, needed for the integration tests only.
  let corpus = "tests/data/.cache/fmi2/BouncingBall.fmu"
  let corpus_present = @fs.is_file(corpus) catch { _ => false }
  if corpus_present {
    checks.push({
      name: "test-corpus",
      status: Ok_,
      detail: "tests/data/.cache present (run `moon run tests/data/fetch-fmus.mbtx --target native` to refresh)",
      required: false,
    })
  } else {
    checks.push({
      name: "test-corpus",
      status: Skip,
      detail: "tests/data/.cache missing: run `moon run tests/data/fetch-fmus.mbtx --target native`",
      required: false,
    })
  }
  // Optional external tools on PATH: xmllint / python / cc. Missing tools
  // are skipped, never fatal: MoonFMI does not shell out to them.
  for tool in ["xmllint", "python", "python3", "cc", "gcc"] {
    if find_on_path(tool).is_empty() {
      checks.push({
        name: "tool-\{tool}",
        status: Skip,
        detail: "not on PATH",
        required: false,
      })
    } else {
      checks.push({
        name: "tool-\{tool}",
        status: Ok_,
        detail: "found on PATH",
        required: false,
      })
    }
  }
  if json {
    println(doctor_json(checks))
  } else {
    for check in checks {
      println(
        "\{check_status_text(check.status)}  \{check.name}: \{check.detail}",
      )
    }
  }
  let mut failed = false
  for check in checks {
    if check.required && check.status is Fail {
      failed = true
    }
  }
  if failed {
    7
  } else {
    0
  }
}

///|
/// Whether a directory can be created at `path` (best effort).
fn dir_creatable(path : String) -> Bool {
  @fs.create_dir(path) catch {
    _ => return false
  }
  @fs.remove_dir(path) catch {
    _ => ()
  }
  true
}

///|
/// Directories listed in PATH; separators differ per host.
fn path_directories() -> Array[String] {
  let raw = @env.get_env_var("PATH").unwrap_or("")
  let separator = if @native.host_platform_name().has_prefix("windows") {
    ";"
  } else {
    ":"
  }
  let parts : Array[String] = []
  let mut current = StringBuilder()
  for ch in raw {
    if ch.to_string() == separator {
      parts.push(current.to_string())
      current = StringBuilder()
    } else {
      current.write_char(ch)
    }
  }
  parts.push(current.to_string())
  parts
}

///|
/// Candidates under which `tool` may live on PATH for this host.
fn find_on_path(tool : String) -> Array[String] {
  let suffixes = if @native.host_platform_name().has_prefix("windows") {
    [".exe", ".cmd", ".bat", ""]
  } else {
    [""]
  }
  let found : Array[String] = []
  for directory in path_directories() {
    for suffix in suffixes {
      let candidate = directory + "/" + tool + suffix
      let exists = @fs.is_file(candidate) catch { _ => false }
      if exists {
        found.push(candidate)
      }
    }
  }
  found
}
