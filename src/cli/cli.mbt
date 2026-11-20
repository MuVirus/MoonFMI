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
  "                  [--set name=value ...] [--sha256 HEX]\n" +
  "                  [--output out.csv] [--timeout SEC] [--backend native|wasm]\n" +
  "                  [--platform DIR] [--sandbox] [--json] [--config FILE]\n" +
  "  moonfmi couple <fmu> [...] [--connect p.var=q.var ...]\n" +
  "                  [--start-time T] [--stop-time T] [--step-size H]\n" +
  "                  [--output out.csv] [--json] [--timeout SEC]\n" +
  "                  [--sha256 HEX] [--loop-iterations N] [--loop-tolerance T]\n" +
  "                  [--sandbox] [--config FILE]\n" +
  "  moonfmi package <dir> [--output model.fmu] [--platform DIR] [--json]\n" +
  "  moonfmi doctor [--json]\n" +
  "  moonfmi completion <bash|zsh|pwsh>\n" +
  "  moonfmi version\n" +
  "\n" +
  "Commands:\n" +
  "  validate     Static model description checks, rules MD-001..MD-063 (no FMU execution)\n" +
  "  info         Model summary: interfaces, variables, type distribution, binaries\n" +
  "  simulate     Run a co-simulation (cs) or model-exchange (me) simulation\n" +
  "  couple       Run several FMUs as one coupled co-simulation\n" +
  "  package      Build a deterministic FMU archive from a directory\n" +
  "  doctor       Check the local environment\n" +
  "\n" +
  "Config:\n" +
  "  --config FILE reads settings from FILE (JSON, INI or .env); the 'simulate'\n" +
  "  and 'couple' sections map to the matching command options. Environment\n" +
  "  variables override the file — MOONFMI_SIMULATE__STOP_TIME=10 sets\n" +
  "  simulate.stop_time — and command-line options override both.\n" +
  "\n" +
  "Examples:\n" +
  "  moonfmi validate BouncingBall.fmu --strict\n" +
  "  moonfmi info BouncingBall.fmu --json\n" +
  "  moonfmi simulate BouncingBall.fmu --stop-time 3 --step-size 0.01 --output ball.csv\n" +
  "  moonfmi simulate VanDerPol.fmu --interface me --solver rk4 --stop-time 5\n" +
  "  moonfmi couple generator.fmu gain.fmu --connect generator.y=gain.u --stop-time 1\n" +
  "                  --step-size 0.1 --output coupled.csv\n" +
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
      "  --sha256 HEX         Refuse to run unless the FMU archive hashes to HEX\n" +
      "  --set NAME=VALUE     Set an input or parameter before initialization; the type is\n" +
      "                       inferred from the model description (repeatable)\n" +
      "  --sandbox            Run in a crash-isolated child process with a hard watchdog\n" +
      "                       (not a permission sandbox)\n" +
      "  --backend NAME       native (default) or wasm; wasm is not supported yet\n" +
      "  --platform DIR       Force a binaries/ platform directory\n" +
      "  --json               Stable JSON summary (schema moonfmi.simulate/v1)\n" +
      "  --config FILE        Read settings from FILE (JSON, INI or .env); the\n" +
      "                       'simulate' section maps to these options. Environment\n" +
      "                       variables (MOONFMI_SIMULATE__STOP_TIME) and command-line\n" +
      "                       options override the file in that order\n" +
      "\n" +
      "Examples:\n" +
      "  moonfmi simulate BouncingBall.fmu --stop-time 3 --step-size 0.01 --output ball.csv\n" +
      "  moonfmi simulate VanDerPol.fmu --interface me --solver rk4 --stop-time 5\n" +
      "  moonfmi simulate BouncingBall.fmu --config experiment.json\n" +
      "\n" +
      "Exit codes: 0 success, 1 load error, 2 usage, 3 unreadable file, 4 unsupported,\n" +
      "5 simulation failure, 6 timeout\n"
    "couple" =>
      "moonfmi couple — run several FMUs as one coupled co-simulation\n" +
      "\n" +
      "Usage:\n" +
      "  moonfmi couple <fmu> [...] [--connect p.var=q.var ...]\n" +
      "                  [--start-time T] [--stop-time T] [--step-size H]\n" +
      "                  [--output out.csv] [--json] [--timeout SEC]\n" +
      "\n" +
      "Options:\n" +
      "  --connect p.var=q.var  Drive input q.var of participant q with output p.var\n" +
      "                         of participant p (repeatable); the signal type (Real,\n" +
      "                         Integer, Boolean) is inferred from the producer's\n" +
      "                         variable and both endpoints must agree\n" +
      "  --start-time T         Start time (default 0)\n" +
      "  --stop-time T          Stop time (default 1.0)\n" +
      "  --step-size H          Communication step size (default 0.01)\n" +
      "  --output FILE          Write CSV to FILE instead of stdout\n" +
      "  --timeout SEC          Abort when the run exceeds SEC seconds of wall clock\n" +
      "  --sha256 HEX           Refuse to run unless every FMU archive hashes to HEX\n" +
      "  --loop-iterations N    Solve algebraic loops with at most N Jacobi iterations\n" +
      "                         (default: loops are rejected)\n" +
      "  --loop-tolerance T     Residual tolerance of the loop iteration (default 1e-9)\n" +
      "  --sandbox              Run in a crash-isolated child process with a hard watchdog\n" +
      "                         (not a permission sandbox)\n" +
      "  --json                 Stable JSON summary (schema moonfmi.couple/v1)\n" +
      "  --config FILE          Read settings from FILE (JSON, INI or .env); the\n" +
      "                         'couple' section maps to these options. Environment\n" +
      "                         variables (MOONFMI_COUPLE__STOP_TIME) and command-line\n" +
      "                         options override the file in that order\n" +
      "\n" +
      "Examples:\n" +
      "  moonfmi couple generator.fmu gain.fmu --connect generator.y=gain.u --stop-time 1\n" +
      "                  --step-size 0.1 --output coupled.csv\n" +
      "\n" +
      "Exit codes: 0 success, 1 load or configuration error, 2 usage error,\n" +
      "3 unreadable file, 4 unsupported platform, 5 simulation failure, 6 timeout\n"
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
let moonfmi_version : String = "0.7.0"

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
  if command == "couple" {
    if argv.length() > 1 && (argv[1] == "--help" || argv[1] == "-h") {
      println(command_help("couple"))
      return 0
    }
    return run_couple(argv, 1, read_file)
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
  let (wasm_manifest, wasm_components) = @fmi.ls_wasm_layer(data) catch {
    _ => (false, 0)
  }
  if wasm_manifest || wasm_components > 0 {
    lines.push(
      "lsWasm: manifest=\{if wasm_manifest { "yes" } else { "no" }} components=\{wasm_components}",
    )
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
  let (wasm_manifest, wasm_components) = @fmi.ls_wasm_layer(data) catch {
    _ => (false, 0)
  }
  if wasm_manifest || wasm_components > 0 {
    builder.write_string(
      ",\n  \"lsWasm\": {\"manifest\": \{wasm_manifest}, \"components\": \{wasm_components}}",
    )
  }
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
  /// Interface, solver and backend stay optional until the config layer has
  /// been merged: `None` means "not given on the command line", so the
  /// config file can supply a value the command line did not.
  mut interface : String?
  mut solver : String?
  mut backend : String?
  mut timeout_seconds : UInt64?
  /// Expected sha256 of the FMU archive (`--sha256`), lowercase hex.
  mut sha256 : String?
  /// `--set name=value` input overrides, in command-line order.
  mut sets : Array[(String, String)]
  mut json : Bool
  /// Config file (`--config`), if any.
  mut config_path : String?
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
    interface: None,
    solver: None,
    backend: None,
    timeout_seconds: None,
    sha256: None,
    sets: [],
    json: false,
    config_path: None,
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
      arg == "--timeout" ||
      arg == "--sha256" ||
      arg == "--config" ||
      arg == "--set" {
      if index + 1 >= args.length() {
        return (options, Some("flag '" + arg + "' needs a value"))
      }
      let value = args[index + 1]
      if arg == "--config" {
        options.config_path = Some(value)
      } else if arg == "--start-time" ||
        arg == "--stop-time" ||
        arg == "--step-size" {
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
      } else if arg == "--sha256" {
        match normalize_sha256(value) {
          Some(normalized) => options.sha256 = Some(normalized)
          None =>
            return (
              options,
              Some(
                "'--sha256' needs a 64-digit hex digest, not '" + value + "'",
              ),
            )
        }
      } else if arg == "--set" {
        match split_set_override(value) {
          Some(pair) => options.sets.push(pair)
          None =>
            return (
              options,
              Some("'--set' needs 'name=value', got '" + value + "'"),
            )
        }
      } else if arg == "--platform" {
        options.platform_override = Some(value)
      } else if arg == "--backend" {
        if !backend_values.contains(value) {
          return (
            options,
            Some("'--backend' accepts native or wasm, not '" + value + "'"),
          )
        }
        options.backend = Some(value)
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
              options.timeout_seconds = Some(deadline_in_seconds(seconds))
            }
          None => return (options, Some("'" + value + "' is not a number"))
        }
      } else if arg == "--interface" {
        if !interface_values.contains(value) {
          return (
            options,
            Some("'--interface' accepts cs, me or se, not '" + value + "'"),
          )
        }
        options.interface = Some(value)
      } else {
        if !solver_values.contains(value) {
          return (
            options,
            Some("'--solver' accepts euler or rk4, not '" + value + "'"),
          )
        }
        options.solver = Some(value)
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
/// Parse a plain non-negative integer (`--loop-iterations`).
fn parse_nonnegative_int(text : String) -> Int32? {
  if text.is_empty() {
    return None
  }
  let mut value = 0
  for ch in text {
    let code = ch.to_int()
    if code < 0x30 || code > 0x39 {
      return None
    }
    value = value * 10 + (code - 0x30)
    if value > 0x7FFFFFF {
      return None
    }
  }
  Some(value)
}

///|
/// Split a `--set name=value` operand on the first `=`. The variable name
/// must be non-empty; the value may itself contain `=`.
fn split_set_override(text : String) -> (String, String)? {
  let mut eq = -1
  for index, ch in text {
    if ch == '=' {
      eq = index
      break
    }
  }
  if eq <= 0 {
    None
  } else {
    Some((text[:eq].to_owned(), text[eq + 1:].to_owned()))
  }
}

///|
/// Normalize an expected sha256 digest: lowercase hex, exactly 64 digits.
/// `None` when the value is not a well-formed digest.
fn normalize_sha256(value : String) -> String? {
  if value.char_length() != 64 {
    return None
  }
  let builder = StringBuilder()
  for ch in value {
    let code = ch.to_int()
    let nibble = if code >= 0x30 && code <= 0x39 {
      code - 0x30
    } else if code >= 0x41 && code <= 0x46 {
      code - 0x41 + 10
    } else if code >= 0x61 && code <= 0x66 {
      code - 0x61 + 10
    } else {
      return None
    }
    builder.write_char(UInt16::unsafe_to_char(hex_digits[nibble]))
  }
  Some(builder.to_string())
}

///|
/// Verify the archive digest requested by `--sha256` (R2): the whole
/// archive is hashed before anything is extracted or loaded, so a
/// mismatching archive never reaches `dlopen`. Prints the error and
/// returns `false` on mismatch.
fn verify_archive_sha256(
  path : String,
  expected : String?,
  data : Bytes,
) -> Bool {
  match expected {
    Some(expected) => {
      let actual = sha256_hex(data)
      if actual != expected {
        println(
          "moonfmi: '" +
          path +
          "' sha256 mismatch: expected " +
          expected +
          ", got " +
          actual,
        )
        return false
      }
      true
    }
    None => true
  }
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
  let options = configure_simulate(options) catch {
    error => {
      let (code, message) = config_failure_code(error, "simulate")
      println(message)
      return code
    }
  }
  if effective_backend(options) == "wasm" {
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
  if !verify_archive_sha256(path, options.sha256, data) {
    return 1
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
  let directory = ".moonfmi-tmp/run-\{temp_dir_suffix()}"
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
        Config(message) => {
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
  /// A `--set` override could not be resolved or written (exit 1).
  Config(String)
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
  if effective_interface(options) == "me" {
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
    match
      apply_set_overrides_fmi2(loaded.model, loaded.instance, options.sets) {
      Some(message) => {
        loaded.dispose()
        raise SimulateFailure::Config(message)
      }
      None => ()
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
    let solver = if effective_solver(options) == "euler" {
      @sim.Euler
    } else {
      @sim.Rk4
    }
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
    match
      apply_set_overrides_fmi2(loaded.model(), loaded.instance(), options.sets) {
      Some(message) => {
        loaded.dispose()
        raise SimulateFailure::Config(message)
      }
      None => ()
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
  if effective_interface(options) == "me" {
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
    match
      apply_set_overrides_fmi3(loaded.model(), loaded.instance(), options.sets) {
      Some(message) => {
        loaded.dispose()
        raise SimulateFailure::Config(message)
      }
      None => ()
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
    let solver = if effective_solver(options) == "euler" {
      @sim.Euler
    } else {
      @sim.Rk4
    }
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
  } else if effective_interface(options) == "se" {
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
    if !options.sets.is_empty() {
      loaded.dispose()
      raise SimulateFailure::Config(
        "--set is not supported with --interface se",
      )
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
    match
      apply_set_overrides_fmi3(loaded.model(), loaded.instance(), options.sets) {
      Some(message) => {
        loaded.dispose()
        raise SimulateFailure::Config(message)
      }
      None => ()
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

///|
/// `moonfmi couple` — run several FMUs as one coupled co-simulation.
/// Each FMU is loaded as a co-simulation participant named after its file
/// stem; `--connect` options wire a producer's Real output to a consumer's
/// Real input and the coupled master steps all participants on one shared
/// communication grid. The recorded signals are every participant's Real
/// scalar outputs, in declaration order.

///|
/// Parsed options of the couple command.
priv struct CoupleOptions {
  fmus : Array[String]
  /// `--connect` endpoints: (from participant, from variable, to participant, to variable).
  mut connects : Array[(String, String, String, String)]
  mut start_time : Double?
  mut stop_time : Double?
  mut step_size : Double?
  mut output : String?
  mut timeout_seconds : UInt64?
  /// Expected sha256 of each FMU archive (`--sha256`), lowercase hex.
  mut sha256 : String?
  /// `--loop-iterations`: opt-in Jacobi fixed-point bound for algebraic
  /// loops (`CoupledConfig::max_loop_iterations`).
  mut loop_iterations : Int32?
  /// `--loop-tolerance`: residual tolerance of the fixed-point iteration.
  mut loop_tolerance : Double?
  mut json : Bool
  /// Config file (`--config`), if any.
  mut config_path : String?
}

///|
/// One loaded FMU, either FMI 2 or FMI 3, kept alive for the whole run
/// because participants borrow its instance.
priv enum LoadedFmu {
  Fmu2(@native.LoadedFmu2)
  Fmu3(@native.LoadedFmu3)
}

///|
/// A loaded participant: name, source path, and typed model description
/// used to resolve `--connect` variable names.
priv struct CoupledFmuView {
  name : String
  path : String
  model : @schema.ModelDescription
}

///|
/// The stem of a file path: the final path component without its extension.
/// Empty stems (for example `.fmu`) fall back to `fmu`.
fn stem_of_path(path : String) -> String {
  let mut slash = -1
  for index, ch in path {
    if ch == '/' || ch == '\\' {
      slash = index
    }
  }
  let base = if slash < 0 { path } else { path[slash + 1:].to_owned() }
  let mut dot = -1
  for index, ch in base {
    if ch == '.' {
      dot = index
    }
  }
  let stem = if dot < 0 { base } else { base[:dot].to_owned() }
  if stem.is_empty() {
    "fmu"
  } else {
    stem
  }
}

///|
/// Split `participant.var` on the last dot: FMI variable names never
/// contain dots, so `gain.u` is participant `gain`, variable `u`.
fn split_participant_var(text : String) -> (String, String)? {
  let mut dot = -1
  for index, ch in text {
    if ch == '.' {
      dot = index
    }
  }
  if dot < 0 {
    None
  } else {
    Some((text[:dot].to_owned(), text[dot + 1:].to_owned()))
  }
}

///|
/// Parse one `--connect participant.var=participant.var` argument.
fn parse_connect(text : String) -> (String, String, String, String)? {
  let mut eq = -1
  for index, ch in text {
    if ch == '=' {
      eq = index
      break
    }
  }
  if eq < 0 {
    None
  } else {
    let left = text[:eq].to_owned()
    let right = text[eq + 1:].to_owned()
    match split_participant_var(left) {
      None => None
      Some((from_participant, from_var)) =>
        match split_participant_var(right) {
          None => None
          Some((to_participant, to_var)) =>
            Some((from_participant, from_var, to_participant, to_var))
        }
    }
  }
}

///|
/// Parse the couple command's operands; a missing FMU operand is a usage error.
fn parse_couple_options(
  args : Array[String],
  skip : Int32,
) -> (CoupleOptions, String?) {
  let options : CoupleOptions = {
    fmus: [],
    connects: [],
    start_time: None,
    stop_time: None,
    step_size: None,
    output: None,
    timeout_seconds: None,
    sha256: None,
    loop_iterations: None,
    loop_tolerance: None,
    json: false,
    config_path: None,
  }
  let mut index = skip
  while index < args.length() {
    let arg = args[index]
    if arg == "--connect" {
      if index + 1 >= args.length() {
        return (options, Some("flag '--connect' needs a value"))
      }
      match parse_connect(args[index + 1]) {
        Some(connect) => options.connects.push(connect)
        None =>
          return (
            options,
            Some(
              "flag '--connect' needs 'participant.var=participant.var', got '" +
              args[index + 1] +
              "'",
            ),
          )
      }
      index += 2
    } else if arg == "--start-time" ||
      arg == "--stop-time" ||
      arg == "--step-size" {
      if index + 1 >= args.length() {
        return (options, Some("flag '" + arg + "' needs a value"))
      }
      let number = parse_simulation_double(args[index + 1])
      match number {
        Some(number) =>
          if arg == "--start-time" {
            options.start_time = Some(number)
          } else if arg == "--stop-time" {
            options.stop_time = Some(number)
          } else {
            options.step_size = Some(number)
          }
        None =>
          return (options, Some("'" + args[index + 1] + "' is not a number"))
      }
      index += 2
    } else if arg == "--sha256" {
      if index + 1 >= args.length() {
        return (options, Some("flag '--sha256' needs a value"))
      }
      match normalize_sha256(args[index + 1]) {
        Some(normalized) => options.sha256 = Some(normalized)
        None =>
          return (
            options,
            Some(
              "'--sha256' needs a 64-digit hex digest, not '" +
              args[index + 1] +
              "'",
            ),
          )
      }
      index += 2
    } else if arg == "--loop-iterations" {
      if index + 1 >= args.length() {
        return (options, Some("flag '--loop-iterations' needs a value"))
      }
      match parse_nonnegative_int(args[index + 1]) {
        Some(count) =>
          if count <= 0 {
            return (
              options,
              Some("'--loop-iterations' needs a positive integer"),
            )
          } else {
            options.loop_iterations = Some(count)
          }
        None =>
          return (options, Some("'" + args[index + 1] + "' is not an integer"))
      }
      index += 2
    } else if arg == "--loop-tolerance" {
      if index + 1 >= args.length() {
        return (options, Some("flag '--loop-tolerance' needs a value"))
      }
      match parse_simulation_double(args[index + 1]) {
        Some(tolerance) =>
          if tolerance < 0.0 {
            return (options, Some("'--loop-tolerance' must not be negative"))
          } else {
            options.loop_tolerance = Some(tolerance)
          }
        None =>
          return (options, Some("'" + args[index + 1] + "' is not a number"))
      }
      index += 2
    } else if arg == "--output" {
      if index + 1 >= args.length() {
        return (options, Some("flag '--output' needs a value"))
      }
      options.output = Some(args[index + 1])
      index += 2
    } else if arg == "--config" {
      if index + 1 >= args.length() {
        return (options, Some("flag '--config' needs a value"))
      }
      options.config_path = Some(args[index + 1])
      index += 2
    } else if arg == "--json" {
      options.json = true
      index += 1
    } else if arg == "--timeout" {
      if index + 1 >= args.length() {
        return (options, Some("flag '--timeout' needs a value"))
      }
      let seconds = parse_simulation_double(args[index + 1])
      match seconds {
        Some(seconds) =>
          if seconds <= 0.0 {
            return (
              options,
              Some("'--timeout' needs a positive number of seconds"),
            )
          } else {
            options.timeout_seconds = Some(deadline_in_seconds(seconds))
          }
        None =>
          return (options, Some("'" + args[index + 1] + "' is not a number"))
      }
      index += 2
    } else if arg.has_prefix("--") {
      return (options, Some("unknown argument '" + arg + "'"))
    } else {
      options.fmus.push(arg)
      index += 1
    }
  }
  if options.fmus.is_empty() {
    return (options, Some("missing fmu argument"))
  }
  (options, None)
}

///|
/// Resolve a variable name on a typed model description to the value
/// reference and signal type of a connectable scalar variable (Real,
/// Integer or Boolean) with the required causality. The signal type is
/// inferred from the variable's declared payload so `moonfmi couple
/// --connect` can wire Integer/Boolean signals without extra flags. This
/// is pure so it can be tested without loading any FMU.
fn resolve_typed_scalar(
  model : @schema.ModelDescription,
  name : String,
  want : @schema.Causality,
) -> Result[(UInt32, @sim.SignalType), String] {
  match model {
    V2(m) => {
      let index = @schema.build_fmi2_index(m)
      match index.position_of_name(name) {
        None =>
          Err(
            "variable '" + name + "' is not declared in the model description",
          )
        Some(position) => {
          let variable = m.variables[position - 1]
          let signal : @sim.SignalType? = match variable.payload {
            Real(_) => Some(Real)
            Integer(_) => Some(Integer)
            Boolean(_) => Some(Boolean)
            _ => None
          }
          match signal {
            None =>
              Err(
                "variable '" +
                name +
                "' is not a connectable scalar signal (Real, Integer or Boolean)",
              )
            Some(signal) =>
              if variable.effective_causality() != want {
                Err(
                  causality_mismatch(name, variable.effective_causality(), want),
                )
              } else {
                Ok((variable.value_reference, signal))
              }
          }
        }
      }
    }
    V3(m) => {
      let index = @schema.build_fmi3_index(m)
      match index.position_of_name(name) {
        None =>
          Err(
            "variable '" + name + "' is not declared in the model description",
          )
        Some(position) => {
          let variable = m.variables[position - 1]
          let signal : @sim.SignalType? = if !variable.dimensions.is_empty() {
            None
          } else if variable.type_kind is Float64 {
            Some(Real)
          } else if variable.type_kind is Int32 {
            Some(Integer)
          } else if variable.type_kind is Boolean {
            Some(Boolean)
          } else {
            None
          }
          match signal {
            None =>
              Err(
                "variable '" +
                name +
                "' is not a connectable scalar signal (Real, Integer or Boolean)",
              )
            Some(signal) =>
              if variable.effective_causality() != want {
                Err(
                  causality_mismatch(name, variable.effective_causality(), want),
                )
              } else {
                Ok((variable.value_reference, signal))
              }
          }
        }
      }
    }
  }
}

///|
/// The causality mismatch diagnostic shared by both typed-resolution
/// branches.
fn causality_mismatch(
  name : String,
  got : @schema.Causality,
  want : @schema.Causality,
) -> String {
  "variable '" +
  name +
  "' has causality '" +
  @schema.Causality::name(got) +
  "', expected '" +
  @schema.Causality::name(want) +
  "'"
}

///|
/// Human-readable name of a coupling signal type, used in the
/// type-mismatch diagnostic.
fn signal_type_name(signal : @sim.SignalType) -> String {
  match signal {
    Real => "Real"
    Integer => "Integer"
    Boolean => "Boolean"
  }
}

///|
/// The value references recorded for one participant: every Real scalar
/// output in document order, as `(value_reference, name)` pairs. Arrays and
/// non-Real outputs are skipped; the returned notes describe what was
/// skipped and why.
fn collect_record_outputs(
  model : @schema.ModelDescription,
) -> (Array[(UInt32, String)], Array[String]) {
  let outputs : Array[(UInt32, String)] = []
  let notes : Array[String] = []
  match model {
    V2(m) =>
      for variable in m.variables {
        if variable.effective_causality() == Output {
          match variable.payload {
            Real(_) => outputs.push((variable.value_reference, variable.name))
            _ =>
              notes.push(
                "skipping output '" +
                variable.name +
                "' (not a Real scalar variable)",
              )
          }
        }
      }
    V3(m) =>
      for variable in m.variables {
        if variable.effective_causality() == Output {
          if variable.type_kind is Float64 && variable.dimensions.is_empty() {
            outputs.push((variable.value_reference, variable.name))
          } else if !(variable.type_kind is Float64) {
            notes.push(
              "skipping output '" +
              variable.name +
              "' (not a Real scalar variable)",
            )
          } else {
            notes.push(
              "skipping array output '" +
              variable.name +
              "' (coupling records Real scalars only)",
            )
          }
        }
      }
  }
  (outputs, notes)
}

///|
/// Resolve `participant.var` among the loaded participants, including the
/// signal type inferred from the variable's declared payload. On failure a
/// diagnostic (file path + variable name + problem) is printed and None is
/// returned; the caller then exits with code 1.
fn resolve_endpoint(
  views : Array[CoupledFmuView],
  participant : String,
  variable : String,
  want : @schema.Causality,
) -> (UInt32, @sim.SignalType)? {
  let mut view : CoupledFmuView? = None
  for candidate in views {
    if candidate.name == participant {
      view = Some(candidate)
      break
    }
  }
  match view {
    None => {
      let known = views.map(fn(v) { v.name }).join(", ")
      println(
        "moonfmi couple: endpoint '" +
        participant +
        "." +
        variable +
        "': participant '" +
        participant +
        "' is not loaded (loaded: " +
        known +
        ")",
      )
      None
    }
    Some(view) =>
      match resolve_typed_scalar(view.model, variable, want) {
        Ok((value_reference, signal)) => Some((value_reference, signal))
        Err(message) => {
          println(
            "moonfmi couple: in '" +
            view.path +
            "' ('" +
            participant +
            "'): " +
            message,
          )
          None
        }
      }
  }
}

///|
/// Load one FMU for a coupled run; loader rejections are propagated so the
/// caller can phrase them as exit codes.
fn load_fmu_for_couple(
  _path : String,
  data : Bytes,
  host~ : @fmi.HostPlatform,
  is_fmi3 : Bool,
  directory~ : String,
) -> LoadedFmu raise @native.LoaderError {
  if is_fmi3 {
    let loaded = @native.load_fmi3_fmu(data, host~, temp_directory=directory)
    LoadedFmu::Fmu3(loaded)
  } else {
    let loaded = @native.load_fmi2_fmu(data, host~, temp_directory=directory)
    LoadedFmu::Fmu2(loaded)
  }
}

///|
/// Render the coupled result as CSV: `time,<participant>.<var>` columns.
fn couple_csv(names : Array[String], result : @sim.SimulationResult) -> String {
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
/// Render the coupled result as the `moonfmi.couple/v1` JSON summary.
fn couple_json(
  files : Array[String],
  start_time : Double,
  stop_time : Double,
  step_size : Double,
  result : @sim.SimulationResult,
  slots : Array[(String, String, UInt32)],
) -> String {
  let builder = StringBuilder()
  builder.write_string(
    "{\n  \"schema\": \"moonfmi.couple/v1\",\n  \"files\": [",
  )
  for index, file in files {
    if index > 0 {
      builder.write_string(", ")
    }
    builder.write_string(json_string(file))
  }
  builder.write_string("],\n  \"startTime\": ")
  builder.write_string(csv_double(start_time))
  builder.write_string(",\n  \"stopTime\": ")
  builder.write_string(csv_double(stop_time))
  builder.write_string(",\n  \"stepSize\": ")
  builder.write_string(csv_double(step_size))
  builder.write_string(",\n  \"steps\": ")
  builder.write_string(result.steps().to_string())
  builder.write_string(",\n  \"samples\": ")
  builder.write_string(result.times().length().to_string())
  builder.write_string(",\n  \"time\": [")
  for index, time in result.times() {
    if index > 0 {
      builder.write_string(", ")
    }
    builder.write_string(csv_double(time))
  }
  builder.write_string("],\n  \"outputs\": [")
  for index, slot in slots {
    if index > 0 {
      builder.write_string(", ")
    }
    builder.write_string("\n    {\"participant\": ")
    builder.write_string(json_string(slot.0))
    builder.write_string(", \"varName\": ")
    builder.write_string(json_string(slot.1))
    builder.write_string(", \"valueReference\": ")
    builder.write_string(slot.2.to_string())
    builder.write_string(", \"series\": [")
    let series = result.series()[index]
    for row, value in series {
      if row > 0 {
        builder.write_string(", ")
      }
      builder.write_string(csv_double(value))
    }
    builder.write_string("]\n    }")
  }
  builder.write_string("\n  ]\n}")
  builder.to_string()
}

///|
/// Entry point of `moonfmi couple`.
fn run_couple(
  argv : Array[String],
  skip : Int32,
  read_file : (String) -> Bytes raise ReadError,
) -> Int32 {
  let (options, error) = parse_couple_options(argv, skip)
  if error is Some(message) {
    println("moonfmi couple: " + message + "\n")
    println(usage())
    return 2
  }
  let options = configure_couple(options) catch {
    error => {
      let (code, message) = config_failure_code(error, "couple")
      println(message)
      return code
    }
  }
  let host_name = @native.host_platform_name()
  let host = match @fmi.parse_host_platform(host_name) {
    Some(host) => host
    None => {
      println("moonfmi: unknown host platform '" + host_name + "'")
      return 7
    }
  }
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let views : Array[CoupledFmuView] = []
  let coupled : Array[@sim.CoupledParticipant] = []
  let loaded_fmus : Array[LoadedFmu] = []
  let records : Array[Array[(UInt32, String)]] = []
  let notes : Array[String] = []
  let taken : Map[String, Bool] = Map([])
  for i = 0; i < options.fmus.length(); i = i + 1 {
    let path = options.fmus[i]
    let data = read_file(path) catch {
      error =>
        match error {
          Failed(message) => {
            println("moonfmi: cannot read '" + path + "': " + message)
            return 3
          }
        }
    }
    if !verify_archive_sha256(path, options.sha256, data) {
      return 1
    }
    let (probe, _probe_report) = @fmi.validate_fmu_bytes(data)
    let is_fmi3 = match probe {
      Some(@schema.V3(_)) => true
      _ => false
    }
    let directory = ".moonfmi-tmp/couple-\{i}-\{temp_dir_suffix()}"
    let loaded = match
      (Ok(load_fmu_for_couple(path, data, host~, is_fmi3, directory~)) catch {
        error => Err(error)
      }) {
      Ok(loaded) => loaded
      Err(error) =>
        match error {
          @native.Rejected(detail~) => {
            println("moonfmi: cannot load '" + path + "': " + detail)
            return 4
          }
          @native.LoadFailed(detail~) => {
            println("moonfmi: cannot load '" + path + "': " + detail)
            return 1
          }
        }
    }
    // Participant name: file stem, deduplicated with `-2`, `-3`, ...
    let mut name = stem_of_path(path)
    let mut n = 2
    while taken.contains(name) {
      name = stem_of_path(path) + "-" + n.to_string()
      n = n + 1
    }
    taken[name] = true
    let model_of : @schema.ModelDescription = match loaded {
      LoadedFmu::Fmu2(loaded) => V2(loaded.model())
      LoadedFmu::Fmu3(loaded) => V3(loaded.model())
    }
    let (outputs, new_notes) = collect_record_outputs(model_of)
    for note in new_notes {
      notes.push("participant '" + name + "' ('" + path + "'): " + note)
    }
    match loaded {
      LoadedFmu::Fmu2(loaded) =>
        coupled.push(
          @sim.CoupledParticipant::new(
            name~,
            instance=loaded.instance(),
            record=outputs.map(fn(entry) { entry.0 }),
          ),
        )
      LoadedFmu::Fmu3(loaded) =>
        coupled.push(
          @sim.CoupledParticipant::new(
            name~,
            instance=loaded.instance(),
            record=outputs.map(fn(entry) { entry.0 }),
          ),
        )
    }
    views.push({ name, path, model: model_of, })
    records.push(outputs)
    loaded_fmus.push(loaded)
  }
  // Resolve every `--connect` endpoint before anything is stepped. The
  // signal type comes from the producer's declared payload; a connection
  // whose endpoints disagree on the type is rejected up front instead of
  // surfacing as an FMU read/write error mid-run.
  let connections : Array[@sim.Coupling] = []
  for connect in options.connects {
    let (from_participant, from_var, to_participant, to_var) = connect
    let (from_vr, signal) = match
      resolve_endpoint(views, from_participant, from_var, Output) {
      Some(resolved) => resolved
      None => return 1
    }
    let (to_vr, in_signal) = match
      resolve_endpoint(views, to_participant, to_var, Input) {
      Some(resolved) => resolved
      None => return 1
    }
    if signal != in_signal {
      println(
        "moonfmi couple: connection '" +
        from_participant +
        "." +
        from_var +
        "' -> '" +
        to_participant +
        "." +
        to_var +
        "' connects a " +
        signal_type_name(signal) +
        " output to a " +
        signal_type_name(in_signal) +
        " input",
      )
      return 1
    }
    connections.push(
      @sim.Coupling::new(
        from=from_participant,
        out_vr=from_vr,
        to=to_participant,
        in_vr=to_vr,
        signal~,
      ),
    )
  }
  let start_time = options.start_time.unwrap_or(0.0)
  let stop_time = options.stop_time.unwrap_or(1.0)
  let step_size = options.step_size.unwrap_or(0.01)
  let config = @sim.CoupledConfig::new(
    start_time~,
    stop_time~,
    step_size~,
    participants=coupled,
    connections~,
    deadline=options.timeout_seconds,
    max_loop_iterations=options.loop_iterations,
    loop_tolerance=options.loop_tolerance.unwrap_or(0.000000001),
  )
  let outcome = Ok(@sim.run_coupled_simulation(config~)) catch {
    error => Err(error)
  }
  // Release every loaded FMU before reporting the result or the failure.
  for loaded in loaded_fmus {
    match loaded {
      LoadedFmu::Fmu2(loaded) => loaded.dispose()
      LoadedFmu::Fmu3(loaded) => loaded.dispose()
    }
  }
  match outcome {
    Ok(result) => {
      if !options.json {
        for note in notes {
          println("note: " + note)
        }
      }
      let names : Array[String] = []
      let slots : Array[(String, String, UInt32)] = []
      for index, view in views {
        for entry in records[index] {
          names.push(view.name + "." + entry.1)
          slots.push((view.name, entry.1, entry.0))
        }
      }
      let csv = couple_csv(names, result)
      match options.output {
        Some(file) => {
          @fs.write_string_to_file(file, csv) catch {
            error =>
              match error {
                @fs.IOError(message) => {
                  println("moonfmi: cannot write '" + file + "': " + message)
                  return 1
                }
              }
          }
          if options.json {
            println(
              couple_json(
                options.fmus,
                start_time,
                stop_time,
                step_size,
                result,
                slots,
              ),
            )
          } else {
            println(
              "coupled " +
              options.fmus.length().to_string() +
              " FMUs: " +
              result.steps().to_string() +
              " steps from " +
              start_time.to_string() +
              " to " +
              stop_time.to_string() +
              ", " +
              names.length().to_string() +
              " output(s), CSV written to " +
              file,
            )
          }
        }
        None =>
          if options.json {
            println(
              couple_json(
                options.fmus,
                start_time,
                stop_time,
                step_size,
                result,
                slots,
              ),
            )
          } else {
            println(csv)
          }
      }
      0
    }
    Err(error) =>
      match error {
        @fmi.Timeout(detail~) => {
          println("moonfmi: simulation timed out after " + detail)
          6
        }
        @fmi.Config(detail~) => {
          println("moonfmi: coupling error: " + detail)
          1
        }
        _ => {
          println("moonfmi: simulation failed: " + error.message())
          5
        }
      }
  }
}
