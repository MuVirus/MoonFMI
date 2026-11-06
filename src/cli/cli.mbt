///|
/// `moonfmi` command line (task B-18 / D-02). Exit codes are stable for
/// CI use:
///
/// - `0` valid (no errors; warnings allowed unless `--strict`)
/// - `1` invalid (errors found, or warnings under `--strict`)
/// - `2` usage error
/// - `3` file could not be read
/// Failure carried through the `read_file` callback.
pub(all) suberror ReadError {
  Failed(String)
}

///|
/// Print the one-page usage text.
pub fn usage() -> String {
  "moonfmi — FMI model description tool\n" +
  "\n" +
  "Usage:\n" +
  "  moonfmi validate <file.fmu | modelDescription.xml> [--json] [--strict]\n" +
  "  moonfmi info <file.fmu | modelDescription.xml> [--json]\n" +
  "  moonfmi version\n" +
  "\n" +
  "Commands:\n" +
  "  validate   Parse and semantically validate the model description (rules MD-001..MD-063)\n" +
  "  info       Print a summary of the model description\n" +
  "\n" +
  "Exit codes: 0 valid, 1 invalid, 2 usage, 3 unreadable file\n"
}

///|
let moonfmi_version : String = "0.1.0"

///|
/// JSON string escaping for the stable `--json` output.
fn json_escape(text : String) -> String {
  let builder = StringBuilder()
  for ch in text {
    if ch == '"' {
      builder.write_string("\\\"")
    } else if ch == Int32::unsafe_to_char(92) {
      builder.write_string("\\\\")
    } else if ch == '\n' {
      builder.write_string("\\n")
    } else if ch == '\r' {
      builder.write_string("\\r")
    } else if ch == '\t' {
      builder.write_string("\\t")
    } else if ch < ' ' {
      builder.write_string("\\u00")
      let code = ch.to_int()
      let hex = "0123456789abcdef"
      builder.write_char(UInt16::unsafe_to_char(hex[(code / 16) & 0xF]))
      builder.write_char(UInt16::unsafe_to_char(hex[code & 0xF]))
    } else {
      builder.write_char(ch)
    }
  }
  builder.to_string()
}

///|
fn json_string(text : String) -> String {
  "\"" + json_escape(text) + "\""
}

///|
fn json_optional_string(value : String?) -> String {
  match value {
    Some(text) => json_string(text)
    None => "null"
  }
}

///|
fn json_optional_int(value : Int32?) -> String {
  match value {
    Some(number) => number.to_string()
    None => "null"
  }
}

///|
fn severity_text(severity : @schema.Severity) -> String {
  match severity {
    Error => "error"
    Warning => "warning"
    Info => "info"
  }
}

///|
/// Stable JSON schema for the diagnostics report. Bump only with a
/// changelog entry; CI relies on it staying compatible.
fn report_json(
  file : String,
  model : @schema.ModelDescription?,
  report : @schema.ValidationReport,
) -> String {
  let builder = StringBuilder()
  builder.write_string("{\n  \"file\": ")
  builder.write_string(json_string(file))
  builder.write_string(",\n  \"fmiVersion\": ")
  builder.write_string(
    json_optional_string(
      match model {
        Some(m) => Some(m.fmi_version_text())
        None => None
      },
    ),
  )
  builder.write_string(",\n  \"model\": ")
  builder.write_string(
    match model {
      Some(m) => json_string(m.model_name())
      None => "null"
    },
  )
  builder.write_string(",\n  \"valid\": ")
  builder.write_string(if report.is_valid() { "true" } else { "false" })
  builder.write_string(",\n  \"errors\": ")
  builder.write_string(report.error_count().to_string())
  builder.write_string(",\n  \"warnings\": ")
  builder.write_string(report.warning_count().to_string())
  builder.write_string(",\n  \"diagnostics\": [")
  for index, diagnostic in report.diagnostics() {
    if index > 0 {
      builder.write_string(",")
    }
    builder.write_string("\n    {\"code\": ")
    builder.write_string(json_string(diagnostic.code()))
    builder.write_string(", \"severity\": ")
    builder.write_string(json_string(severity_text(diagnostic.severity())))
    builder.write_string(", \"message\": ")
    builder.write_string(json_string(diagnostic.message()))
    builder.write_string(", \"path\": ")
    builder.write_string(json_string(diagnostic.path()))
    builder.write_string(", \"line\": ")
    builder.write_string(json_optional_int(diagnostic.line()))
    builder.write_string(", \"column\": ")
    builder.write_string(json_optional_int(diagnostic.column()))
    builder.write_string(", \"hint\": ")
    builder.write_string(json_optional_string(diagnostic.hint()))
    builder.write_string("}")
  }
  builder.write_string("\n  ]\n}")
  builder.to_string()
}

///|
/// Render the report as stable text lines.
fn report_text(report : @schema.ValidationReport) -> Array[String] {
  let lines : Array[String] = []
  for diagnostic in report.diagnostics() {
    let line = diagnostic.render()
    lines.push(
      match diagnostic.hint() {
        Some(hint) => line + "\n  hint: " + hint
        None => line
      },
    )
  }
  lines.push(
    "\{report.error_count()} error(s), \{report.warning_count()} warning(s)",
  )
  lines
}

///|
/// Parse `--json` / `--strict` style flags starting at `skip`;
/// returns (json, strict, error).
fn parse_flags(
  args : Array[String],
  skip : Int32,
  allowed : Array[String],
) -> (Bool, Bool, String?) {
  let mut json = false
  let mut strict = false
  for index = skip; index < args.length(); index = index + 1 {
    let arg = args[index]
    if arg == "--json" {
      if allowed.contains("--json") {
        json = true
      } else {
        return (false, false, Some("unknown flag --json for this command"))
      }
    } else if arg == "--strict" {
      if allowed.contains("--strict") {
        strict = true
      } else {
        return (false, false, Some("unknown flag --strict for this command"))
      }
    } else {
      return (false, false, Some("unknown argument '" + arg + "'"))
    }
  }
  (json, strict, None)
}

///|
/// Entry point. `read_file` loads the FMU or XML document; failures are
/// reported as text so the CLI can map them to exit code 3.
pub fn run(
  argv : Array[String],
  read_file : (String) -> Bytes raise ReadError,
) -> Int32 {
  if argv.is_empty() ||
    argv[0] == "help" ||
    argv[0] == "--help" ||
    argv[0] == "-h" {
    println(usage())
    return if argv.is_empty() { 2 } else { 0 }
  }
  let command = argv[0]
  if command == "version" || command == "--version" {
    println("moonfmi \{moonfmi_version}")
    return 0
  }
  if command == "validate" {
    return run_validate(argv, 1, read_file)
  }
  if command == "info" {
    return run_info(argv, 1, read_file)
  }
  println("moonfmi: unknown command '" + command + "'\n")
  println(usage())
  2
}

///|
fn run_validate(
  argv : Array[String],
  skip : Int32,
  read_file : (String) -> Bytes raise ReadError,
) -> Int32 {
  if skip >= argv.length() {
    println("moonfmi validate: missing file argument\n")
    println(usage())
    return 2
  }
  let (json, strict, error) = parse_flags(argv, skip + 1, ["--json", "--strict"])
  if error is Some(message) {
    println("moonfmi validate: \{message}\n")
    println(usage())
    return 2
  }
  let path = argv[skip]
  let data = read_file(path) catch {
    error =>
      match error {
        Failed(message) => {
          println("moonfmi: cannot read '" + path + "': " + message)
          return 3
        }
      }
  }
  let (model, report) = @fmi.validate_fmu_bytes(data)
  if json {
    println(report_json(path, model, report))
  } else {
    for line in report_text(report) {
      println(line)
    }
  }
  if !report.is_valid() {
    return 1
  }
  if strict && report.warning_count() > 0 {
    return 1
  }
  0
}

///|
fn run_info(
  argv : Array[String],
  skip : Int32,
  read_file : (String) -> Bytes raise ReadError,
) -> Int32 {
  if skip >= argv.length() {
    println("moonfmi info: missing file argument\n")
    println(usage())
    return 2
  }
  let (json, _strict, error) = parse_flags(argv, skip + 1, ["--json"])
  if error is Some(message) {
    println("moonfmi info: \{message}\n")
    println(usage())
    return 2
  }
  let path = argv[skip]
  let data = read_file(path) catch {
    error =>
      match error {
        Failed(message) => {
          println("moonfmi: cannot read '" + path + "': " + message)
          return 3
        }
      }
  }
  let (model, report) = @fmi.validate_fmu_bytes(data)
  match model {
    Some(model) => {
      if json {
        println(info_json(model))
      } else {
        for line in info_text(model) {
          println(line)
        }
        if !report.is_valid() {
          println(
            "note: the model description has validation errors (run 'moonfmi validate' for details)",
          )
        }
      }
      0
    }
    None => {
      if json {
        println(report_json(path, None, report))
      } else {
        for line in report_text(report) {
          println(line)
        }
      }
      1
    }
  }
}

///|
fn info_text(model : @schema.ModelDescription) -> Array[String] {
  let lines : Array[String] = []
  lines.push("modelName: \{model.model_name()}")
  lines.push("fmiVersion: \{model.fmi_version_text()}")
  match model {
    V2(m) => {
      for interface in m.interfaces() {
        lines.push(
          "interface: \{interface.kind.name()} (\{interface.model_identifier})",
        )
      }
      lines.push("guid: \{m.guid}")
      lines.push("units: \{m.unit_definitions.length()}")
      lines.push("typeDefinitions: \{m.type_definitions.length()}")
      lines.push("variables: \{m.variables.length()}")
      lines.push("defaultExperiment: \{experiment_text(m.default_experiment)}")
    }
    V3(m) => {
      for interface in m.interfaces {
        lines.push(
          "interface: \{interface.kind.name()} (\{interface.model_identifier})",
        )
      }
      lines.push("instantiationToken: \{m.instantiation_token}")
      lines.push("units: \{m.unit_definitions.length()}")
      lines.push("typeDefinitions: \{m.type_definitions.length()}")
      lines.push("variables: \{m.variables.length()}")
      lines.push("defaultExperiment: \{experiment_text(m.default_experiment)}")
    }
  }
  lines
}

///|
fn experiment_text(experiment : @schema.DefaultExperiment?) -> String {
  match experiment {
    Some(experiment) =>
      "startTime=\{show_opt_double(experiment.start_time)} stopTime=\{show_opt_double(experiment.stop_time)}"
    None => "none"
  }
}

///|
fn show_opt_double(value : Double?) -> String {
  match value {
    Some(number) => number.to_string()
    None => "-"
  }
}

///|
fn info_json(model : @schema.ModelDescription) -> String {
  let builder = StringBuilder()
  builder.write_string("{\n  \"modelName\": ")
  builder.write_string(json_string(model.model_name()))
  builder.write_string(",\n  \"fmiVersion\": ")
  builder.write_string(json_string(model.fmi_version_text()))
  builder.write_string(",\n  \"variables\": ")
  builder.write_string(model.variable_count().to_string())
  builder.write_string("\n}")
  builder.to_string()
}
