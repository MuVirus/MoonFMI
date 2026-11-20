///|
/// CLI 配置层：配置文件与环境变量，按键合并后回填到命令行选项。
///
/// 配置文件由 `--config <path>` 显式指定，格式按后缀与内容判定（JSON / INI /
/// dotenv，三种都在 moonfig core 内，不引入额外依赖）。环境变量用 `MOONFMI_`
/// 前缀、双下划线分层：`MOONFMI_SIMULATE__STOP_TIME` 对应 `simulate.stop_time`。
///
/// 优先级：命令行 > 环境变量 > 配置文件。命令行已经给出的值不被配置覆盖。
/// 键名内部统一 snake_case；配置文件里的 kebab-case 写法（`stop-time`）同样接受。
///

///|
/// 配置层错误。`Io` 对应退出码 1（文件读不到），`Usage` 对应退出码 2（内容非法）。

///|
priv suberror ConfigLoadError {
  Io(String)
  Usage(String)
}

///|
/// 环境变量前缀。

///|
let env_prefix : String = "MOONFMI_"

///|
/// 环境变量的层级分隔符：双下划线分层，单个下划线留在键名里。

///|
let env_separator : String = "__"

///|
/// `simulate` 段的合法键。

///|
let simulate_keys : Array[String] = [
  "start_time", "stop_time", "step_size", "output", "platform", "interface", "solver",
  "backend", "timeout", "sha256", "set",
]

///|
/// `couple` 段的合法键。

///|
let couple_keys : Array[String] = [
  "start_time", "stop_time", "step_size", "output", "timeout", "sha256", "loop_iterations",
  "loop_tolerance", "connect",
]

///|
/// 允许的接口取值。命令行与配置共用这一份，避免两处校验漂移。

///|
let interface_values : Array[String] = ["cs", "me", "se"]

///|
/// 允许的求解器取值。

///|
let solver_values : Array[String] = ["euler", "rk4"]

///|
/// 允许的后端取值。

///|
let backend_values : Array[String] = ["native", "wasm"]

///|
/// 配置文件格式探测器：JSON、INI、dotenv 都在 moonfig core 内。

///|
fn config_detector() -> @detect.Detector raise @config.ConfigError {
  @detect.Detector::new([
    @jsonfmt.JsonFormat::new(),
    @inifmt.IniFormat::new(),
    @dotenvfmt.DotenvFormat::new(),
  ])
}

///|
/// 加载配置：配置文件（可选）在前，环境变量在后，按键合并，后加入的覆盖同名键。

///|
fn load_config(path : String?) -> @config.Config raise ConfigLoadError {
  let mut builder = @config.Config::new()
  match path {
    Some(file) => {
      let detector = config_detector() catch {
        error => raise map_config_error(error)
      }
      builder = builder.add(@filesrc.FileSource::auto(file, detector))
    }
    None => ()
  }
  builder = builder.add(
    @envsrc.EnvSource::new(env_prefix).with_separator(env_separator),
  )
  builder.build() catch {
    error => raise map_config_error(error)
  }
}

///|
/// 把 moonfig 的配置错误翻译成 MoonFMI 的错误类型。

///|
fn map_config_error(error : @config.ConfigError) -> ConfigLoadError {
  match error {
    @config.ConfigError::IoError(message) => ConfigLoadError::Io(message)
    @config.ConfigError::MissingKey(path) =>
      ConfigLoadError::Usage("missing key '" + path + "'")
    @config.ConfigError::TypeMismatch(path, expected, actual) =>
      ConfigLoadError::Usage(
        "key '" + path + "': expected " + expected + ", got " + actual,
      )
    @config.ConfigError::ParseError(message) =>
      ConfigLoadError::Usage("parse error: " + message)
    @config.ConfigError::MergeConflict(path, left, right) =>
      ConfigLoadError::Usage(
        "merge conflict at '" + path + "': " + left + " vs " + right,
      )
    @config.ConfigError::InvalidValue(path, expected, actual) =>
      ConfigLoadError::Usage(
        "invalid value for '" +
        path +
        "': expected " +
        expected +
        ", got " +
        actual,
      )
    @config.ConfigError::UnknownKey(path) =>
      ConfigLoadError::Usage("key '" + path + "' is not allowed")
    @config.ConfigError::UnknownFormat(name, suffixes) => {
      let mut message = "unknown format for '" + name + "'"
      if !suffixes.is_empty() {
        message = message + "; supported suffixes: " + suffixes.join(" / ")
      }
      ConfigLoadError::Usage(message)
    }
  }
}

///|
/// 键名别名：`simulate.stop_time` 的 kebab-case 写法是 `simulate.stop-time`。

///|
fn kebab_alias(path : String) -> String {
  path.replace(old="_", new="-")
}

///|
/// 按路径取可选字符串：先试 snake_case 键，再试 kebab-case 别名。

///|
fn config_opt_string(
  config : @config.Config,
  path : String,
) -> String? raise ConfigLoadError {
  let value = config.get_opt_string(path) catch {
    error => raise map_config_error(error)
  }
  match value {
    Some(text) => Some(text)
    None => {
      let alias_path = kebab_alias(path)
      if alias_path == path {
        None
      } else {
        config.get_opt_string(alias_path) catch {
          error => raise map_config_error(error)
        }
      }
    }
  }
}

///|
/// 按路径取可选浮点数：先试 snake_case 键，再试 kebab-case 别名。

///|
fn config_opt_float(
  config : @config.Config,
  path : String,
) -> Double? raise ConfigLoadError {
  let value = config.get_opt_float(path) catch {
    error => raise map_config_error(error)
  }
  match value {
    Some(number) => Some(number)
    None => {
      let alias_path = kebab_alias(path)
      if alias_path == path {
        None
      } else {
        config.get_opt_float(alias_path) catch {
          error => raise map_config_error(error)
        }
      }
    }
  }
}

///|
/// 按路径取可选 32 位整数：先试 snake_case 键，再试 kebab-case 别名。

///|
fn config_opt_int32(
  config : @config.Config,
  path : String,
) -> Int32? raise ConfigLoadError {
  let value = config.get_opt_int32(path) catch {
    error => raise map_config_error(error)
  }
  match value {
    Some(number) => Some(number)
    None => {
      let alias_path = kebab_alias(path)
      if alias_path == path {
        None
      } else {
        config.get_opt_int32(alias_path) catch {
          error => raise map_config_error(error)
        }
      }
    }
  }
}

///|
/// 按路径取字符串数组：缺失返回空数组，类型不符报错。

///|
fn config_string_array(
  config : @config.Config,
  path : String,
) -> Array[String] raise ConfigLoadError {
  let value = config.get_value(path) catch {
    error =>
      match error {
        @config.ConfigError::MissingKey(_) => return []
        error => raise map_config_error(error)
      }
  }
  match value.kind {
    @config.ValueKind::Array(items) => {
      let out : Array[String] = []
      for item in items {
        match item.kind {
          @config.ValueKind::Str(text) => out.push(text)
          kind =>
            raise ConfigLoadError::Usage(
              "key '" + path + "': expected Str, got " + kind.name(),
            )
        }
      }
      out
    }
    kind =>
      raise ConfigLoadError::Usage(
        "key '" + path + "': expected Array, got " + kind.name(),
      )
  }
}

///|
/// 校验枚举取值：缺失返回 None，非法时抛错。

///|
fn check_enum_value(
  value : String?,
  allowed : Array[String],
  path : String,
) -> String? raise ConfigLoadError {
  match value {
    None => None
    Some(text) =>
      if allowed.contains(text) {
        Some(text)
      } else {
        raise ConfigLoadError::Usage(
          "key '" +
          path +
          "': expected " +
          allowed.join(" / ") +
          ", got '" +
          text +
          "'",
        )
      }
  }
}

///|
/// 校验 sha256：缺失返回 None，非法时抛错。

///|
fn check_sha256(
  value : String?,
  path : String,
) -> String? raise ConfigLoadError {
  match value {
    None => None
    Some(text) =>
      match normalize_sha256(text) {
        Some(normalized) => Some(normalized)
        None =>
          raise ConfigLoadError::Usage(
            "key '" +
            path +
            "': needs a 64-digit hex digest, not '" +
            text +
            "'",
          )
      }
  }
}

///|
/// `simulate` 段的配置值。字段全可空：None 表示"这一层没给"。

///|
priv struct SimulateConfig {
  start_time : Double?
  stop_time : Double?
  step_size : Double?
  output : String?
  platform : String?
  interface : String?
  solver : String?
  backend : String?
  timeout : Double?
  sha256 : String?
  sets : Array[String]
}

///|
/// 读 `simulate` 段的配置值。

///|
fn read_simulate_config(
  config : @config.Config,
) -> SimulateConfig raise ConfigLoadError {
  let base = "simulate."
  {
    start_time: config_opt_float(config, base + "start_time"),
    stop_time: config_opt_float(config, base + "stop_time"),
    step_size: config_opt_float(config, base + "step_size"),
    output: config_opt_string(config, base + "output"),
    platform: config_opt_string(config, base + "platform"),
    interface: check_enum_value(
      config_opt_string(config, base + "interface"),
      interface_values,
      base + "interface",
    ),
    solver: check_enum_value(
      config_opt_string(config, base + "solver"),
      solver_values,
      base + "solver",
    ),
    backend: check_enum_value(
      config_opt_string(config, base + "backend"),
      backend_values,
      base + "backend",
    ),
    timeout: config_opt_float(config, base + "timeout"),
    sha256: check_sha256(
      config_opt_string(config, base + "sha256"),
      base + "sha256",
    ),
    sets: config_string_array(config, base + "set"),
  }
}

///|
/// `couple` 段的配置值。字段全可空：None 表示"这一层没给"。

///|
priv struct CoupleConfig {
  start_time : Double?
  stop_time : Double?
  step_size : Double?
  output : String?
  timeout : Double?
  sha256 : String?
  loop_iterations : Int32?
  loop_tolerance : Double?
  connects : Array[String]
}

///|
/// 读 `couple` 段的配置值。

///|
fn read_couple_config(
  config : @config.Config,
) -> CoupleConfig raise ConfigLoadError {
  let base = "couple."
  let loop_iterations = config_opt_int32(config, base + "loop_iterations")
  let loop_tolerance = config_opt_float(config, base + "loop_tolerance")
  {
    start_time: config_opt_float(config, base + "start_time"),
    stop_time: config_opt_float(config, base + "stop_time"),
    step_size: config_opt_float(config, base + "step_size"),
    output: config_opt_string(config, base + "output"),
    timeout: config_opt_float(config, base + "timeout"),
    sha256: check_sha256(
      config_opt_string(config, base + "sha256"),
      base + "sha256",
    ),
    loop_iterations: match loop_iterations {
      Some(count) =>
        if count <= 0 {
          raise ConfigLoadError::Usage(
            "key '" + base + "loop_iterations': needs a positive integer",
          )
        } else {
          Some(count)
        }
      None => None
    },
    loop_tolerance: match loop_tolerance {
      Some(tolerance) =>
        if tolerance < 0.0 {
          raise ConfigLoadError::Usage(
            "key '" + base + "loop_tolerance': must not be negative",
          )
        } else {
          Some(tolerance)
        }
      None => None
    },
    connects: config_string_array(config, base + "connect"),
  }
}

///|
/// 秒 → 绝对截止时间（毫秒）。与命令行 `--timeout` 的换算保持一致。

///|
fn deadline_in_seconds(seconds : Double) -> UInt64 {
  @env.now() + seconds.to_uint64() * 1_000UL
}

///|
/// 把 `simulate` 段的配置值回填到命令行选项。命令行已经给出的值优先。

///|
fn apply_simulate_config(
  options : SimulateOptions,
  config : SimulateConfig,
) -> SimulateOptions raise ConfigLoadError {
  if options.start_time is None {
    options.start_time = config.start_time
  }
  if options.stop_time is None {
    options.stop_time = config.stop_time
  }
  if options.step_size is None {
    options.step_size = config.step_size
  }
  if options.output is None {
    options.output = config.output
  }
  if options.platform_override is None {
    options.platform_override = config.platform
  }
  if options.interface is None {
    options.interface = config.interface
  }
  if options.solver is None {
    options.solver = config.solver
  }
  if options.backend is None {
    options.backend = config.backend
  }
  if options.timeout_seconds is None {
    options.timeout_seconds = match config.timeout {
      Some(seconds) => Some(deadline_in_seconds(seconds))
      None => None
    }
  }
  if options.sha256 is None {
    options.sha256 = config.sha256
  }
  if !config.sets.is_empty() {
    let pairs : Array[(String, String)] = []
    for entry in config.sets {
      match split_set_override(entry) {
        Some(pair) => pairs.push(pair)
        None =>
          raise ConfigLoadError::Usage(
            "key 'simulate.set': needs 'name=value', got '" + entry + "'",
          )
      }
    }
    // 配置文件里的在前，命令行的在后：后写的覆盖先写的。
    let merged : Array[(String, String)] = []
    for pair in pairs {
      merged.push(pair)
    }
    for pair in options.sets {
      merged.push(pair)
    }
    options.sets = merged
  }
  options
}

///|
/// 把 `couple` 段的配置值回填到命令行选项。命令行已经给出的值优先。

///|
fn apply_couple_config(
  options : CoupleOptions,
  config : CoupleConfig,
) -> CoupleOptions raise ConfigLoadError {
  if options.start_time is None {
    options.start_time = config.start_time
  }
  if options.stop_time is None {
    options.stop_time = config.stop_time
  }
  if options.step_size is None {
    options.step_size = config.step_size
  }
  if options.output is None {
    options.output = config.output
  }
  if options.timeout_seconds is None {
    options.timeout_seconds = match config.timeout {
      Some(seconds) => Some(deadline_in_seconds(seconds))
      None => None
    }
  }
  if options.sha256 is None {
    options.sha256 = config.sha256
  }
  if options.loop_iterations is None {
    options.loop_iterations = config.loop_iterations
  }
  if options.loop_tolerance is None {
    options.loop_tolerance = config.loop_tolerance
  }
  if !config.connects.is_empty() {
    let connects : Array[(String, String, String, String)] = []
    for entry in config.connects {
      match parse_connect(entry) {
        Some(connect) => connects.push(connect)
        None =>
          raise ConfigLoadError::Usage(
            "key 'couple.connect': needs 'participant.var=participant.var', got '" +
            entry +
            "'",
          )
      }
    }
    let merged : Array[(String, String, String, String)] = []
    for connect in connects {
      merged.push(connect)
    }
    for connect in options.connects {
      merged.push(connect)
    }
    options.connects = merged
  }
  options
}

///|
/// 找出配置里不被识别的键。只检查 `simulate` 与 `couple` 段——其它根键
/// 属于别的工具（例如 `MOONFMI_SANDBOX_CHILD`），不提示。

///|
fn unknown_config_keys(config : @config.Config) -> Array[String] {
  let unknown : Array[String] = []
  let origins = config.origins() catch { _ => return unknown }
  for origin in origins {
    let segments = origin.path().segments()
    if segments.length() < 2 {
      continue
    }
    let section = segments[0]
    if section != "simulate" && section != "couple" {
      continue
    }
    let allowed = if section == "simulate" {
      simulate_keys
    } else {
      couple_keys
    }
    let leaf = segments[segments.length() - 1].replace(old="-", new="_")
    if !allowed.contains(leaf) {
      unknown.push(origin.path().to_string())
    }
  }
  unknown
}

///|
/// 把不被识别的键报成警告。警告走 stderr，不影响 stdout 的机器可读输出。

///|
fn report_unknown_keys(config : @config.Config) -> Unit {
  for key in unknown_config_keys(config) {
    eprintln("moonfmi: warning: unknown config key '" + key + "'")
  }
}

///|
/// 命令行与配置都没给时的默认接口。

///|
let default_interface : String = "cs"

///|
/// 命令行与配置都没给时的默认求解器。

///|
let default_solver : String = "rk4"

///|
/// 命令行与配置都没给时的默认后端。

///|
let default_backend : String = "native"

///|
/// 生效的接口：命令行优先，其次配置，最后默认协同仿真。

///|
fn effective_interface(options : SimulateOptions) -> String {
  options.interface.unwrap_or(default_interface)
}

///|
/// 生效的求解器：命令行优先，其次配置，最后默认经典 RK4。

///|
fn effective_solver(options : SimulateOptions) -> String {
  options.solver.unwrap_or(default_solver)
}

///|
/// 生效的后端：命令行优先，其次配置，最后默认 native。

///|
fn effective_backend(options : SimulateOptions) -> String {
  options.backend.unwrap_or(default_backend)
}

///|
/// 加载配置并回填到 `simulate` 的选项。

///|
fn configure_simulate(
  options : SimulateOptions,
) -> SimulateOptions raise ConfigLoadError {
  let config = load_config(options.config_path)
  report_unknown_keys(config)
  apply_simulate_config(options, read_simulate_config(config))
}

///|
/// 加载配置并回填到 `couple` 的选项。

///|
fn configure_couple(
  options : CoupleOptions,
) -> CoupleOptions raise ConfigLoadError {
  let config = load_config(options.config_path)
  report_unknown_keys(config)
  apply_couple_config(options, read_couple_config(config))
}

///|
/// 把配置层错误变成退出码与消息。`Io` 是 1，`Usage` 是 2。

///|
fn config_failure_code(
  error : ConfigLoadError,
  command : String,
) -> (Int32, String) {
  match error {
    ConfigLoadError::Io(message) =>
      (1, "moonfmi: cannot load config: " + message)
    ConfigLoadError::Usage(message) =>
      (2, "moonfmi " + command + ": " + message)
  }
}
