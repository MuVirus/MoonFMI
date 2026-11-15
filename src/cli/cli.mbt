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
  "  moonfmi simulate <file.fmu> [--interface cs|me] [--solver euler|rk4] [--start-time T] [--stop-time T] [--step-size H] [--output out.csv] [--json]\n" +
  "  moonfmi version\n" +
  "\n" +
  "Commands:\n" +
  "  validate   Parse and semantically validate the model description (rules MD-001..MD-063)\n" +
  "  info       Print a summary of the model description\n" +
  "  simulate   Run a co-simulation (cs) or model-exchange (me) simulation\n" +
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
  if command == "simulate" {
    return run_simulate(argv, 1, read_file)
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
      arg == "--solver" {
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
      } else if arg == "--interface" {
        if value != "cs" && value != "me" {
          return (
            options,
            Some("'--interface' accepts cs or me, not '" + value + "'"),
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
/// Render the whole result as CSV with a header row.
fn result_csv(
  model : @schema.Fmi2ModelDescription,
  result : @sim.SimulationResult,
) -> String {
  let outputs = real_outputs(model)
  let names : Array[String] = []
  for output in outputs {
    names.push(output.1)
  }
  result_csv_named(names, result)
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
      return 1
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
        LoadFailed(message) => {
          println("moonfmi: \{message}")
          return 1
        }
        RunFailed(message) => {
          println("moonfmi: simulation failed: \{message}")
          return 1
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
  builder.write_string("{\n  \"file\": ")
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
/// Simulation failures, split into load and run so the exit path can
/// phrase them differently.
suberror SimulateFailure {
  LoadFailed(String)
  RunFailed(String)
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
          error => raise LoadFailed(error.message())
        }
      None =>
        @native.load_fmi2_me_fmu(data, host~, temp_directory=directory) catch {
          error => raise LoadFailed(error.message())
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
    )
    let result = @sim.run_me_simulation(loaded.instance(), config~) catch {
      error => {
        loaded.dispose()
        raise RunFailed(error.message())
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
          error => raise LoadFailed(error.message())
        }
      None =>
        @native.load_fmi2_fmu(data, host~, temp_directory=directory) catch {
          error => raise LoadFailed(error.message())
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
    )
    let result = @sim.run_cs_simulation(loaded.instance(), config~) catch {
      error => {
        loaded.dispose()
        raise RunFailed(error.message())
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
          error => raise LoadFailed(error.message())
        }
      None =>
        @native.load_fmi3_me_fmu(data, host~, temp_directory=directory) catch {
          error => raise LoadFailed(error.message())
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
    )
    let result = @sim.run_me_simulation(loaded.instance(), config~) catch {
      error => {
        loaded.dispose()
        raise RunFailed(error.message())
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
          error => raise LoadFailed(error.message())
        }
      None =>
        @native.load_fmi3_fmu(data, host~, temp_directory=directory) catch {
          error => raise LoadFailed(error.message())
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
    )
    let result = @sim.run_cs_simulation(loaded.instance(), config~) catch {
      error => {
        loaded.dispose()
        raise RunFailed(error.message())
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
