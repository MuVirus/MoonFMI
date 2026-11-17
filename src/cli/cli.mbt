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
  "moonfmi — FMI co-simulation tool\n" +
  "\n" +
  "Usage:\n" +
  "  moonfmi validate <fmu | modelDescription.xml> [--json] [--strict]\n" +
  "  moonfmi info <fmu | modelDescription.xml> [--json]\n" +
  "  moonfmi simulate <fmu> [--interface cs|me|se] [--solver euler|rk4]\n" +
  "                  [--start-time T] [--stop-time T] [--step-size H]\n" +
  "                  [--output out.csv] [--timeout SEC] [--backend native|wasm]\n" +
  "                  [--platform DIR] [--json]\n" +
  "  moonfmi package <dir> [--output model.fmu] [--platform DIR] [--json]\n" +
  "  moonfmi doctor [--json]\n" +
  "  moonfmi completion <bash|zsh|pwsh>\n" +
  "  moonfmi version\n" +
  "\n" +
  "Commands:\n" +
  "  validate     Static model description checks, rules MD-001..MD-063 (no FMU execution)\n" +
  "  info         Model summary: interfaces, variables, type distribution, binaries\n" +
  "  simulate     Run a co-simulation (cs) or model-exchange (me) simulation\n" +
  "  package      Build a deterministic FMU archive from a directory\n" +
  "  doctor       Check the local environment\n" +
  "\n" +
  "Examples:\n" +
  "  moonfmi validate BouncingBall.fmu --strict\n" +
  "  moonfmi info BouncingBall.fmu --json\n" +
  "  moonfmi simulate BouncingBall.fmu --stop-time 3 --step-size 0.01 --output ball.csv\n" +
  "  moonfmi simulate VanDerPol.fmu --interface me --solver rk4 --stop-time 5\n" +
  "  moonfmi package build/MyModel --output dist/MyModel.fmu\n" +
  "\n" +
  "Exit codes:\n" +
  "  0 success  1 general error / invalid  2 usage error  3 unreadable file\n" +
  "  4 unsupported (version/interface/platform/backend)  5 simulation failure\n" +
  "  6 timeout  7 environment missing\n"
}

///|
/// Per-command help text (exit 0 on `moonfmi <command> --help`).
fn command_help(command : String) -> String {
  match command {
    "validate" =>
      "moonfmi validate — validate a model description (static, never loads the FMU binary)\n" +
      "\n" +
      "Usage:\n" +
      "  moonfmi validate <file.fmu | modelDescription.xml> [--json] [--strict]\n" +
      "\n" +
      "Options:\n" +
      "  --json     Stable JSON report (schema moonfmi.validate/v1)\n" +
      "  --strict   Treat warnings as errors\n" +
      "\n" +
      "Example:\n" +
      "  moonfmi validate BouncingBall.fmu --strict\n" +
      "\n" +
      "Exit codes: 0 valid, 1 invalid (or warnings under --strict), 2 usage, 3 unreadable file\n"
    "info" =>
      "moonfmi info — print a model description summary\n" +
      "\n" +
      "Usage:\n" +
      "  moonfmi info <file.fmu | modelDescription.xml> [--json]\n" +
      "\n" +
      "Options:\n" +
      "  --json     Stable JSON report (schema moonfmi.info/v1)\n" +
      "\n" +
      "Example:\n" +
      "  moonfmi info BouncingBall.fmu --json\n" +
      "\n" +
      "Exit codes: 0 success, 1 invalid model description, 2 usage, 3 unreadable file\n"
    "simulate" =>
      "moonfmi simulate — run a co-simulation or model-exchange simulation\n" +
      "\n" +
      "Usage:\n" +
      "  moonfmi simulate <file.fmu> [options]\n" +
      "\n" +
      "Options:\n" +
      "  --interface cs|me|se Co-simulation, model exchange or scheduled execution (default cs)\n" +
      "  --solver euler|rk4   ME integrator (default rk4; ignored for cs)\n" +
      "  --start-time T       Start time (default 0 or the model's DefaultExperiment)\n" +
      "  --stop-time T        Stop time (default 1.0 or the model's DefaultExperiment)\n" +
      "  --step-size H        Step size (default 0.01 or the model's DefaultExperiment)\n" +
      "  --output FILE        Write CSV to FILE instead of stdout\n" +
      "  --timeout SEC        Abort when the run exceeds SEC seconds of wall clock\n" +
      "  --backend NAME       native (default) or wasm; wasm is not supported yet\n" +
      "  --platform DIR       Force a binaries/ platform directory\n" +
      "  --json               Stable JSON summary (schema moonfmi.simulate/v1)\n" +
      "\n" +
      "Examples:\n" +
      "  moonfmi simulate BouncingBall.fmu --stop-time 3 --step-size 0.01 --output ball.csv\n" +
      "  moonfmi simulate VanDerPol.fmu --interface me --solver rk4 --stop-time 5\n" +
      "\n" +
      "Exit codes: 0 success, 1 load error, 2 usage, 3 unreadable file, 4 unsupported,\n" +
      "5 simulation failure, 6 timeout\n"
    "package" =>
      "moonfmi package — build a deterministic FMU archive from a directory\n" +
      "\n" +
      "Usage:\n" +
      "  moonfmi package <dir> [--output FILE.fmu] [--platform DIR] [--json]\n" +
      "\n" +
      "Options:\n" +
      "  --output FILE   Archive path (default <modelName>.fmu in the working directory)\n" +
      "  --platform DIR  Require binaries/DIR to exist (exit 4 when missing)\n" +
      "  --json          Stable JSON report (schema moonfmi.package/v1)\n" +
      "\n" +
      "The archive is built deterministically: entries sorted by name, fixed\n" +
      "timestamp, fixed attributes — the same input always yields the same bytes.\n" +
      "\n" +
      "Example:\n" +
      "  moonfmi package build/MyModel --output dist/MyModel.fmu\n" +
      "\n" +
      "Exit codes: 0 success, 1 invalid, 2 usage, 3 unreadable input, 4 platform missing\n"
    _ => "moonfmi: no help for '" + command + "'\n"
  }
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
  builder.write_string(
    "{\n  \"schema\": \"moonfmi.validate/v1\",\n  \"file\": ",
  )
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
    if argv.length() > 1 && (argv[1] == "--help" || argv[1] == "-h") {
      println(command_help("validate"))
      return 0
    }
    return run_validate(argv, 1, read_file)
  }
  if command == "info" {
    if argv.length() > 1 && (argv[1] == "--help" || argv[1] == "-h") {
      println(command_help("info"))
      return 0
    }
    return run_info(argv, 1, read_file)
  }
  if command == "simulate" {
    if argv.length() > 1 && (argv[1] == "--help" || argv[1] == "-h") {
      println(command_help("simulate"))
      return 0
    }
    return run_simulate(argv, 1, read_file)
  }
  if command == "package" {
    if argv.length() > 1 && (argv[1] == "--help" || argv[1] == "-h") {
      println(command_help("package"))
      return 0
    }
    return run_package(argv, 1)
  }
  if command == "doctor" {
    return run_doctor(argv, 1)
  }
  if command == "completion" {
    if argv.length() < 2 {
      println(
        "moonfmi completion: missing shell argument (bash, zsh or pwsh)\n",
      )
      println(usage())
      return 2
    }
    let shell = argv[1]
    if shell != "bash" && shell != "zsh" && shell != "pwsh" {
      println(
        "moonfmi completion: unknown shell '\{shell}' (use bash, zsh or pwsh)\n",
      )
      println(usage())
      return 2
    }
    println(completion_script(shell))
    return 0
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
        println(info_json(model, data))
      } else {
        for line in info_text(model, data) {
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
/// Distinct platform directories under `binaries/`, in archive order.
fn platform_directories(data : Bytes) -> Array[String] {
  let found : Array[String] = []
  let archive = @zip.ZipArchive::open(data) catch { _ => return found }
  for entry in archive.entries() {
    let name = entry.name()
    if name.has_prefix("binaries/") {
      let rest = name[9:]
      // Manual scan for the first '/' (String has no indexOf here).
      let mut slash = -1
      for index, ch in rest {
        if ch == '/' {
          slash = index
          break
        }
      }
      if slash > 0 {
        let directory = rest[:slash].to_owned()
        let mut seen = false
        for existing in found {
          if existing == directory {
            seen = true
          }
        }
        if !seen {
          found.push(directory)
        }
      }
    }
  }
  found
}

///|
/// Variable type distribution in document order, rendered as
/// `name count` pairs.
fn type_distribution(
  model : @schema.ModelDescription,
) -> Array[(String, Int32)] {
  let distribution : Array[(String, Int32)] = []
  let bump = fn(name : String) {
    let mut seen = false
    for index, entry in distribution {
      if entry.0 == name {
        distribution[index] = (entry.0, entry.1 + 1)
        seen = true
      }
    }
    if !seen {
      distribution.push((name, 1))
    }
  }
  match model {
    V2(m) =>
      for variable in m.variables {
        bump(
          match variable.payload {
            Real(_) => "real"
            Integer(_) => "integer"
            Boolean(_) => "boolean"
            Str(_) => "string"
            Enumeration(_) => "enumeration"
          },
        )
      }
    V3(m) =>
      for variable in m.variables {
        bump(variable.type_kind.name())
      }
  }
  distribution
}

///|
fn info_text(model : @schema.ModelDescription, data : Bytes) -> Array[String] {
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
  let distribution = type_distribution(model)
  if distribution.length() > 0 {
    let rendered : Array[String] = []
    for entry in distribution {
      rendered.push("\{entry.0} \{entry.1}")
    }
    lines.push("variableTypes: \{rendered.join(", ")}")
  }
  let platforms = platform_directories(data)
  if platforms.length() > 0 {
    lines.push("platforms: \{platforms.join(", ")}")
  } else {
    lines.push("platforms: none (source or description only)")
  }
  lines.push("sha256: \{sha256_hex(data)}")
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
fn info_json(model : @schema.ModelDescription, data : Bytes) -> String {
  let builder = StringBuilder()
  builder.write_string("{\n  \"schema\": \"moonfmi.info/v1\"")
  builder.write_string(",\n  \"modelName\": ")
  builder.write_string(json_string(model.model_name()))
  builder.write_string(",\n  \"fmiVersion\": ")
  builder.write_string(json_string(model.fmi_version_text()))
  builder.write_string(",\n  \"variables\": ")
  builder.write_string(model.variable_count().to_string())
  builder.write_string(",\n  \"variableTypes\": {")
  let distribution = type_distribution(model)
  for index, entry in distribution {
    if index > 0 {
      builder.write_string(", ")
    }
    builder.write_string(json_string(entry.0))
    builder.write_string(": ")
    builder.write_string(entry.1.to_string())
  }
  builder.write_string("}")
  builder.write_string(",\n  \"platforms\": [")
  let platforms = platform_directories(data)
  for index, platform in platforms {
    if index > 0 {
      builder.write_string(", ")
    }
    builder.write_string(json_string(platform))
  }
  builder.write_string("]")
  builder.write_string(",\n  \"sha256\": ")
  builder.write_string(json_string(sha256_hex(data)))
  builder.write_string("\n}")
  builder.to_string()
}

///|
/// Parsed value flags of the simulate command. Missing values fall back
/// to the model's DefaultExperiment, then to hard defaults.
priv struct SimulateOptions {
  mut start_time : Double?
  mut stop_time : Double?
  mut step_size : Double?
  mut output : String?
  mut platform_override : String?
  mut interface : String
  mut solver : String
  mut backend : String
  mut timeout_seconds : UInt64?
  mut json : Bool
}

///|
/// Parse `--name value` pairs; a missing value is a usage error.
fn parse_simulate_options(
  args : Array[String],
  skip : Int32,
) -> (SimulateOptions, String?) {
  let options : SimulateOptions = {
    start_time: None,
    stop_time: None,
    step_size: None,
    output: None,
    platform_override: None,
    interface: "cs",
    solver: "rk4",
    backend: "native",
    timeout_seconds: None,
    json: false,
  }
  let mut index = skip
  while index < args.length() {
    let arg = args[index]
    if arg == "--json" {
      options.json = true
      index += 1
    } else if arg == "--start-time" ||
      arg == "--stop-time" ||
      arg == "--step-size" ||
      arg == "--output" ||
      arg == "--platform" ||
      arg == "--interface" ||
      arg == "--solver" ||
      arg == "--backend" ||
      arg == "--timeout" {
      if index + 1 >= args.length() {
        return (options, Some("flag '" + arg + "' needs a value"))
      }
      let value = args[index + 1]
      if arg == "--start-time" || arg == "--stop-time" || arg == "--step-size" {
        let number = parse_simulation_double(value)
        match number {
          Some(number) =>
            if arg == "--start-time" {
              options.start_time = Some(number)
            } else if arg == "--stop-time" {
              options.stop_time = Some(number)
            } else {
              options.step_size = Some(number)
            }
          None => return (options, Some("'" + value + "' is not a number"))
        }
      } else if arg == "--output" {
        options.output = Some(value)
      } else if arg == "--platform" {
        options.platform_override = Some(value)
      } else if arg == "--backend" {
        if value != "native" && value != "wasm" {
          return (
            options,
            Some("'--backend' accepts native or wasm, not '" + value + "'"),
          )
        }
        options.backend = value
      } else if arg == "--timeout" {
        let seconds = parse_simulation_double(value)
        match seconds {
          Some(seconds) =>
            if seconds <= 0.0 {
              return (
                options,
                Some("'--timeout' needs a positive number of seconds"),
              )
            } else {
              options.timeout_seconds = Some(@env.now() + seconds.to_uint64())
            }
          None => return (options, Some("'" + value + "' is not a number"))
        }
      } else if arg == "--interface" {
        if value != "cs" && value != "me" && value != "se" {
          return (
            options,
            Some("'--interface' accepts cs, me or se, not '" + value + "'"),
          )
        }
        options.interface = value
      } else {
        if value != "euler" && value != "rk4" {
          return (
            options,
            Some("'--solver' accepts euler or rk4, not '" + value + "'"),
          )
        }
        options.solver = value
      }
      index += 2
    } else {
      return (options, Some("unknown argument '" + arg + "'"))
    }
  }
  (options, None)
}

///|
/// Parse a `--start-time` style value; accepts plain numbers only.
fn parse_simulation_double(text : String) -> Double? {
  Some(@string.parse_double(text) catch { _ => return None })
}

///|
/// Value references and names of all FMI 2 Real outputs, in document
/// order. These are the recorded series of a simulation.
fn real_outputs(
  model : @schema.Fmi2ModelDescription,
) -> Array[(UInt32, String)] {
  let outputs : Array[(UInt32, String)] = []
  for variable in model.variables {
    if variable.effective_causality() == Output {
      match variable.payload {
        Real(_attrs) => outputs.push((variable.value_reference, variable.name))
        _ => ()
      }
    }
  }
  outputs
}

///|
/// Render one double for CSV output. Uses shortest round-trip form.
fn csv_double(value : Double) -> String {
  value.to_string()
}

///|
/// Value references and names of all FMI 3 Float64 outputs, in document
/// order. Float32 outputs are skipped (the recorder is Double based).
fn real_outputs_fmi3(
  model : @schema.Fmi3ModelDescription,
) -> Array[(UInt32, String)] {
  let outputs : Array[(UInt32, String)] = []
  for variable in model.variables {
    if variable.effective_causality() == Output {
      if variable.type_kind is Float64 && variable.dimensions.is_empty() {
        // Array outputs need an explicit element count at read time and are
        // not part of the scalar recorder yet.
        outputs.push((variable.value_reference, variable.name))
      }
    }
  }
  outputs
}

///|
/// Render the result as CSV using explicit output names.
fn result_csv_named(
  names : Array[String],
  result : @sim.SimulationResult,
) -> String {
  let builder = StringBuilder()
  builder.write_string("time")
  for name in names {
    builder.write_string(",")
    builder.write_string(name)
  }
  builder.write_string("\n")
  for row, time in result.times() {
    builder.write_string(csv_double(time))
    for index = 0; index < names.length(); index = index + 1 {
      builder.write_string(",")
      builder.write_string(csv_double(result.series()[index][row]))
    }
    builder.write_string("\n")
  }
  builder.to_string()
}

///|
fn run_simulate(
  argv : Array[String],
  skip : Int32,
  read_file : (String) -> Bytes raise ReadError,
) -> Int32 {
  if skip >= argv.length() {
    println("moonfmi simulate: missing file argument\n")
    println(usage())
    return 2
  }
  let (options, error) = parse_simulate_options(argv, skip + 1)
  if error is Some(message) {
    println("moonfmi simulate: \{message}\n")
    println(usage())
    return 2
  }
  if options.backend == "wasm" {
    println(
      "moonfmi: the wasm backend is not implemented yet (experimental status)",
    )
    return 4
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
  let host_name = @native.host_platform_name()
  let host = match @fmi.parse_host_platform(host_name) {
    Some(host) => host
    None => {
      println("moonfmi: unknown host platform '\{host_name}'")
      return 7
    }
  }
  // Private working directory, created fresh for every run.
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let directory = ".moonfmi-tmp/run-\{@env.now()}"
  let start_time = options.start_time.unwrap_or(0.0)
  // Detect the FMI version so the right backend family loads. A failing
  // probe is fine here: the loader below reports a precise error.
  let (probe, _probe_report) = @fmi.validate_fmu_bytes(data)
  let is_fmi3 = match probe {
    Some(@schema.V3(_)) => true
    _ => false
  }
  let outcome = try {
    if is_fmi3 {
      simulate_fmi3(options, data, host~, directory~, start_time~)
    } else {
      simulate_fmi2(options, data, host~, directory~, start_time~)
    }
  } catch {
    failure =>
      match failure {
        Unsupported(message) => {
          println("moonfmi: \{message}")
          return 4
        }
        LoadFailed(message) => {
          println("moonfmi: \{message}")
          return 1
        }
        RunFailed(message) => {
          println("moonfmi: simulation failed: \{message}")
          return 5
        }
        TimedOut(message) => {
          println("moonfmi: simulation timed out after \{message}")
          return 6
        }
      }
  }
  let (names, result, step_size, stop_time) = outcome
  let csv = result_csv_named(names, result)
  match options.output {
    Some(file) => {
      @fs.write_string_to_file(file, csv) catch {
        error =>
          match error {
            @fs.IOError(message) => {
              println("moonfmi: cannot write '\{file}': \{message}")
              return 1
            }
          }
      }
      if options.json {
        println(
          simulate_json(path, start_time, stop_time, step_size, names, result),
        )
      } else {
        println(
          "simulated \{path}: \{result.steps()} steps from \{start_time} to \{stop_time}, \{names.length()} output(s), CSV written to \{file}",
        )
      }
    }
    None =>
      // Without --output the CSV goes to stdout so the result is usable
      // in pipes; --json replaces it with a summary object.
      if options.json {
        println(
          simulate_json(path, start_time, stop_time, step_size, names, result),
        )
      } else {
        println(csv)
      }
  }
  0
}

///|
fn simulate_json(
  path : String,
  start_time : Double,
  stop_time : Double,
  step_size : Double,
  names : Array[String],
  result : @sim.SimulationResult,
) -> String {
  let builder = StringBuilder()
  builder.write_string(
    "{\n  \"schema\": \"moonfmi.simulate/v1\",\n  \"file\": ",
  )
  builder.write_string(json_string(path))
  builder.write_string(",\n  \"startTime\": ")
  builder.write_string(csv_double(start_time))
  builder.write_string(",\n  \"stopTime\": ")
  builder.write_string(csv_double(stop_time))
  builder.write_string(",\n  \"stepSize\": ")
  builder.write_string(csv_double(step_size))
  builder.write_string(",\n  \"steps\": ")
  builder.write_string(result.steps().to_string())
  builder.write_string(",\n  \"samples\": ")
  builder.write_string(result.times().length().to_string())
  builder.write_string(",\n  \"outputs\": [")
  for index, name in names {
    if index > 0 {
      builder.write_string(", ")
    }
    builder.write_string(json_string(name))
  }
  builder.write_string("]\n}")
  builder.to_string()
}

///|
/// Simulation failures, split so the exit path can phrase them (and the
/// exit code) differently: 4 unsupported, 1 load, 5 run, 6 timeout.
priv suberror SimulateFailure {
  Unsupported(String)
  LoadFailed(String)
  RunFailed(String)
  TimedOut(String)
}

///|
/// Loader rejections are "unsupported" (exit 4); load/IO failures are
/// general errors (exit 1).
fn map_loader_failure(error : @native.LoaderError) -> SimulateFailure {
  match error {
    Rejected(detail~) => Unsupported(detail)
    LoadFailed(detail~) => LoadFailed(detail)
  }
}

///|
/// The master raised: FMI timeouts become exit 6, everything else exit 5.
fn map_run_failure(error : @fmi.SimulationError) -> SimulateFailure {
  match error {
    @fmi.Timeout(detail~) => TimedOut(detail)
    _ => RunFailed(error.message())
  }
}

///|
/// Load an FMI 2 FMU per the options and run the matching master.
/// Returns the output names, the result and the effective step/stop times.
fn simulate_fmi2(
  options : SimulateOptions,
  data : Bytes,
  host~ : @fmi.HostPlatform,
  directory~ : String,
  start_time~ : Double,
) -> (Array[String], @sim.SimulationResult, Double, Double) raise SimulateFailure {
  if options.interface == "me" {
    let loaded = match options.platform_override {
      Some(requested) =>
        @native.load_fmi2_me_fmu(
          data,
          host~,
          temp_directory=directory,
          platform_override=requested,
        ) catch {
          error => raise map_loader_failure(error)
        }
      None =>
        @native.load_fmi2_me_fmu(data, host~, temp_directory=directory) catch {
          error => raise map_loader_failure(error)
        }
    }
    let outputs = real_outputs(loaded.model())
    let references : Array[UInt32] = []
    for output in outputs {
      references.push(output.0)
    }
    let step_size = match options.step_size {
      Some(value) => value
      None =>
        match loaded.model().default_experiment {
          Some(experiment) => experiment.step_size.unwrap_or(0.01)
          None => 0.01
        }
    }
    let stop_time = match options.stop_time {
      Some(value) => value
      None =>
        match loaded.model().default_experiment {
          Some(experiment) => experiment.stop_time.unwrap_or(1.0)
          None => 1.0
        }
    }
    let solver = if options.solver == "euler" { @sim.Euler } else { @sim.Rk4 }
    let config = @sim.MeConfig::new(
      start_time~,
      stop_time~,
      step_size~,
      record=references,
      solver~,
      state_count=loaded.state_count,
      event_indicator_count=loaded.event_indicator_count,
      deadline=options.timeout_seconds,
    )
    let result = @sim.run_me_simulation(loaded.instance(), config~) catch {
      error => {
        loaded.dispose()
        raise map_run_failure(error)
      }
    }
    let names : Array[String] = []
    for output in outputs {
      names.push(output.1)
    }
    loaded.dispose()
    (names, result, step_size, stop_time)
  } else {
    let loaded = match options.platform_override {
      Some(requested) =>
        @native.load_fmi2_fmu(
          data,
          host~,
          temp_directory=directory,
          platform_override=requested,
        ) catch {
          error => raise map_loader_failure(error)
        }
      None =>
        @native.load_fmi2_fmu(data, host~, temp_directory=directory) catch {
          error => raise map_loader_failure(error)
        }
    }
    let outputs = real_outputs(loaded.model())
    let references : Array[UInt32] = []
    for output in outputs {
      references.push(output.0)
    }
    // Step size: flag first, then the model's default experiment, then 0.01.
    let step_size = match options.step_size {
      Some(value) => value
      None =>
        match loaded.model().default_experiment {
          Some(experiment) => experiment.step_size.unwrap_or(0.01)
          None => 0.01
        }
    }
    let stop_time = match options.stop_time {
      Some(value) => value
      None =>
        match loaded.model().default_experiment {
          Some(experiment) => experiment.stop_time.unwrap_or(1.0)
          None => 1.0
        }
    }
    let config = @sim.CsConfig::new(
      start_time~,
      stop_time~,
      step_size~,
      record=references,
      deadline=options.timeout_seconds,
    )
    let result = @sim.run_cs_simulation(loaded.instance(), config~) catch {
      error => {
        loaded.dispose()
        raise map_run_failure(error)
      }
    }
    let names : Array[String] = []
    for output in outputs {
      names.push(output.1)
    }
    loaded.dispose()
    (names, result, step_size, stop_time)
  }
}

///|
/// Load an FMI 3 FMU per the options and run the matching master.
fn simulate_fmi3(
  options : SimulateOptions,
  data : Bytes,
  host~ : @fmi.HostPlatform,
  directory~ : String,
  start_time~ : Double,
) -> (Array[String], @sim.SimulationResult, Double, Double) raise SimulateFailure {
  if options.interface == "me" {
    let loaded = match options.platform_override {
      Some(requested) =>
        @native.load_fmi3_me_fmu(
          data,
          host~,
          temp_directory=directory,
          platform_override=requested,
        ) catch {
          error => raise map_loader_failure(error)
        }
      None =>
        @native.load_fmi3_me_fmu(data, host~, temp_directory=directory) catch {
          error => raise map_loader_failure(error)
        }
    }
    let outputs = real_outputs_fmi3(loaded.model())
    let references : Array[UInt32] = []
    for output in outputs {
      references.push(output.0)
    }
    let step_size = match options.step_size {
      Some(value) => value
      None =>
        match loaded.model().default_experiment {
          Some(experiment) => experiment.step_size.unwrap_or(0.01)
          None => 0.01
        }
    }
    let stop_time = match options.stop_time {
      Some(value) => value
      None =>
        match loaded.model().default_experiment {
          Some(experiment) => experiment.stop_time.unwrap_or(1.0)
          None => 1.0
        }
    }
    let solver = if options.solver == "euler" { @sim.Euler } else { @sim.Rk4 }
    let config = @sim.MeConfig::new(
      start_time~,
      stop_time~,
      step_size~,
      record=references,
      solver~,
      state_count=loaded.state_count,
      event_indicator_count=loaded.event_indicator_count,
      deadline=options.timeout_seconds,
    )
    let result = @sim.run_me_simulation(loaded.instance(), config~) catch {
      error => {
        loaded.dispose()
        raise map_run_failure(error)
      }
    }
    let names : Array[String] = []
    for output in outputs {
      names.push(output.1)
    }
    loaded.dispose()
    (names, result, step_size, stop_time)
  } else if options.interface == "se" {
    let loaded = match options.platform_override {
      Some(requested) =>
        @native.load_fmi3_se_fmu(
          data,
          host~,
          temp_directory=directory,
          platform_override=requested,
        ) catch {
          error => raise map_loader_failure(error)
        }
      None =>
        @native.load_fmi3_se_fmu(data, host~, temp_directory=directory) catch {
          error => raise map_loader_failure(error)
        }
    }
    let outputs = real_outputs_fmi3(loaded.model())
    let references : Array[UInt32] = []
    for output in outputs {
      references.push(output.0)
    }
    let step_size = match options.step_size {
      Some(value) => value
      None =>
        match loaded.model().default_experiment {
          Some(experiment) => experiment.step_size.unwrap_or(0.01)
          None => 0.01
        }
    }
    let stop_time = match options.stop_time {
      Some(value) => value
      None =>
        match loaded.model().default_experiment {
          Some(experiment) => experiment.stop_time.unwrap_or(1.0)
          None => 1.0
        }
    }
    // Scheduler view of the input clocks: constant intervals come from the
    // model description, countdown clocks are polled, triggered clocks fire
    // through the default policy (every triggered clock at every grid
    // point). The CLI has no scripted trigger channel yet.
    let clocks : Array[@sim.SeClockInfo] = []
    for clock in loaded.clocks {
      let countdown = clock.variability
        is @schema.ClockIntervalVariability::Countdown
      let period : Double? = if countdown || clock.triggered {
        None
      } else {
        clock.interval_decimal
      }
      clocks.push(
        @sim.SeClockInfo::new(
          value_reference=clock.value_reference,
          priority=clock.priority,
          period~,
          shift=clock.shift_decimal.unwrap_or(0.0),
          triggered=clock.triggered,
          countdown~,
        ),
      )
    }
    let trigger = @sim.SeConfig::trigger_all_each_step(clocks~)
    let config = @sim.SeConfig::new(
      start_time~,
      stop_time~,
      step_size~,
      record=references,
      deadline=options.timeout_seconds,
      trigger~,
      output_clocks=loaded.output_clocks,
    )
    let result = @sim.run_se_simulation(loaded.instance(), clocks~, config~) catch {
      error => {
        loaded.dispose()
        raise map_run_failure(error)
      }
    }
    let names : Array[String] = []
    for output in outputs {
      names.push(output.1)
    }
    loaded.dispose()
    (names, result, step_size, stop_time)
  } else {
    let loaded = match options.platform_override {
      Some(requested) =>
        @native.load_fmi3_fmu(
          data,
          host~,
          temp_directory=directory,
          platform_override=requested,
        ) catch {
          error => raise map_loader_failure(error)
        }
      None =>
        @native.load_fmi3_fmu(data, host~, temp_directory=directory) catch {
          error => raise map_loader_failure(error)
        }
    }
    let outputs = real_outputs_fmi3(loaded.model())
    let references : Array[UInt32] = []
    for output in outputs {
      references.push(output.0)
    }
    let step_size = match options.step_size {
      Some(value) => value
      None =>
        match loaded.model().default_experiment {
          Some(experiment) => experiment.step_size.unwrap_or(0.01)
          None => 0.01
        }
    }
    let stop_time = match options.stop_time {
      Some(value) => value
      None =>
        match loaded.model().default_experiment {
          Some(experiment) => experiment.stop_time.unwrap_or(1.0)
          None => 1.0
        }
    }
    let config = @sim.CsConfig::new(
      start_time~,
      stop_time~,
      step_size~,
      record=references,
      deadline=options.timeout_seconds,
    )
    let result = @sim.run_cs_simulation(loaded.instance(), config~) catch {
      error => {
        loaded.dispose()
        raise map_run_failure(error)
      }
    }
    let names : Array[String] = []
    for output in outputs {
      names.push(output.1)
    }
    loaded.dispose()
    (names, result, step_size, stop_time)
  }
}
