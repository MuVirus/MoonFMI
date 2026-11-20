///|
/// Configuration layer tests: file formats, environment overrides, the
/// command-line-wins backfill, and the error mapping.
///

///|
/// Write a config file into a private temp directory and return its path.

///|
fn write_config(name : String, content : String) -> String {
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let path = ".moonfmi-tmp/config-\{temp_dir_suffix()}-\{name}"
  @fs.write_string_to_file(path, content) catch {
    _ => ()
  }
  path
}

///|
/// Drop the config-related environment variables so a test starts from a
/// known state. The sandbox guard variable is left alone.

///|
fn clear_config_env() -> Unit {
  for name, _ in @env.get_env_vars() {
    if name.has_prefix("MOONFMI_SIMULATE__") ||
      name.has_prefix("MOONFMI_COUPLE__") {
      @env.unset_env_var(name)
    }
  }
}

///|
/// `simulate` options with nothing set, as if no flag was given.

///|
fn empty_simulate_options() -> SimulateOptions {
  {
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
}

///|
/// `couple` options with nothing set, as if no flag was given.

///|
fn empty_couple_options() -> CoupleOptions {
  {
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
}

///|
/// Load a config and capture the failure, if there is one.

///|
fn load_config_error(path : String?) -> ConfigLoadError? {
  let _ = load_config(path) catch { error => return Some(error) }
  None
}

///|
/// Read the simulate section and capture the failure, if there is one.

///|
fn read_simulate_error(path : String) -> ConfigLoadError? {
  let config = load_config(Some(path)) catch { error => return Some(error) }
  let _ = read_simulate_config(config) catch { error => return Some(error) }
  None
}

///|
/// A JSON config file supplies the simulate section.

///|
test "json config file is read" {
  clear_config_env()
  let path = write_config(
    "a.json", "{\"simulate\": {\"stop_time\": 2.5, \"interface\": \"me\", \"set\": [\"a=1\"]}}",
  )
  let values = read_simulate_config(load_config(Some(path)))
  assert_eq(values.stop_time, Some(2.5))
  assert_eq(values.interface, Some("me"))
  assert_eq(values.sets, ["a=1"])
}

///|
/// An INI config file maps sections to the same key space.

///|
test "ini config file is read" {
  clear_config_env()
  let path = write_config(
    "b.ini", "[simulate]\nstop_time = 3.5\nsolver = euler\n",
  )
  let values = read_simulate_config(load_config(Some(path)))
  assert_eq(values.stop_time, Some(3.5))
  assert_eq(values.solver, Some("euler"))
}

///|
/// A .env config file uses dotted keys for the same key space.

///|
test "dotenv config file is read" {
  clear_config_env()
  let path = write_config(
    "c.env", "simulate.stop_time=4.5\nsimulate.backend=native\n",
  )
  let values = read_simulate_config(load_config(Some(path)))
  assert_eq(values.stop_time, Some(4.5))
  assert_eq(values.backend, Some("native"))
}

///|
/// The kebab-case spelling of a key is accepted as well.

///|
test "kebab-case key alias is accepted" {
  clear_config_env()
  let path = write_config(
    "d.json", "{\"simulate\": {\"stop-time\": 5.5, \"step-size\": 0.25}}",
  )
  let values = read_simulate_config(load_config(Some(path)))
  assert_eq(values.stop_time, Some(5.5))
  assert_eq(values.step_size, Some(0.25))
}

///|
/// The environment overrides the file: `MOONFMI_SIMULATE__STOP_TIME` maps to
/// `simulate.stop_time` because the separator is a double underscore.

///|
test "environment overrides the config file" {
  clear_config_env()
  let path = write_config("e.json", "{\"simulate\": {\"stop_time\": 1.0}}")
  @env.set_env_var("MOONFMI_SIMULATE__STOP_TIME", "9.0")
  let values = read_simulate_config(load_config(Some(path)))
  @env.unset_env_var("MOONFMI_SIMULATE__STOP_TIME")
  assert_eq(values.stop_time, Some(9.0))
}

///|
/// The command line wins over both the file and the environment.

///|
test "command line wins over the config" {
  clear_config_env()
  let path = write_config(
    "f.json", "{\"simulate\": {\"stop_time\": 1.0, \"interface\": \"me\"}}",
  )
  let options = empty_simulate_options()
  options.stop_time = Some(7.0)
  options.interface = Some("cs")
  options.config_path = Some(path)
  let merged = configure_simulate(options)
  assert_eq(merged.stop_time, Some(7.0))
  assert_eq(merged.interface, Some("cs"))
}

///|
/// A value only the config file has still reaches the options.

///|
test "config fills the values the command line left out" {
  clear_config_env()
  let path = write_config(
    "g.json", "{\"simulate\": {\"stop_time\": 1.0, \"interface\": \"me\", \"step_size\": 0.5}}",
  )
  let options = empty_simulate_options()
  options.config_path = Some(path)
  let merged = configure_simulate(options)
  assert_eq(merged.stop_time, Some(1.0))
  assert_eq(merged.interface, Some("me"))
  assert_eq(merged.step_size, Some(0.5))
}

///|
/// Configured `--set` entries come first, the command line's after them.

///|
test "configured sets are merged before the command line sets" {
  clear_config_env()
  let path = write_config("h.json", "{\"simulate\": {\"set\": [\"a=1\"]}}")
  let options = empty_simulate_options()
  options.sets.push(("b", "2"))
  options.config_path = Some(path)
  let merged = configure_simulate(options)
  assert_eq(merged.sets.length(), 2)
  assert_eq(merged.sets[0], ("a", "1"))
  assert_eq(merged.sets[1], ("b", "2"))
}

///|
/// The couple section is read from its own keys.

///|
test "couple config file is read" {
  clear_config_env()
  let path = write_config(
    "i.json", "{\"couple\": {\"stop_time\": 2.0, \"loop_iterations\": 20, \"connect\": [\"a.y=b.u\"]}}",
  )
  let values = read_couple_config(load_config(Some(path)))
  assert_eq(values.stop_time, Some(2.0))
  assert_eq(values.loop_iterations, Some(20))
  assert_eq(values.connects, ["a.y=b.u"])
}

///|
/// The couple command fills the options the command line left out, and the
/// command line still wins.

///|
test "couple options are filled from the config file" {
  clear_config_env()
  let path = write_config(
    "i2.json", "{\"couple\": {\"stop_time\": 2.0, \"loop_iterations\": 20, \"connect\": [\"a.y=b.u\"]}}",
  )
  let options = empty_couple_options()
  options.config_path = Some(path)
  let merged = configure_couple(options)
  assert_eq(merged.stop_time, Some(2.0))
  assert_eq(merged.loop_iterations, Some(20))
  assert_eq(merged.connects.length(), 1)
  assert_eq(merged.connects[0], ("a", "y", "b", "u"))
}

///|
/// Configured connects come first, the command line's after them; a value
/// given on the command line is not overwritten.

///|
test "configured connects are merged before the command line connects" {
  clear_config_env()
  let path = write_config(
    "i3.json", "{\"couple\": {\"stop_time\": 2.0, \"connect\": [\"a.y=b.u\"]}}",
  )
  let options = empty_couple_options()
  options.stop_time = Some(9.0)
  options.connects.push(("c", "z", "d", "w"))
  options.config_path = Some(path)
  let merged = configure_couple(options)
  assert_eq(merged.stop_time, Some(9.0))
  assert_eq(merged.connects.length(), 2)
  assert_eq(merged.connects[0], ("a", "y", "b", "u"))
  assert_eq(merged.connects[1], ("c", "z", "d", "w"))
}

///|
/// An illegal enum value in the config is a usage error.

///|
test "illegal enum value in the config is rejected" {
  clear_config_env()
  let path = write_config("j.json", "{\"simulate\": {\"interface\": \"nope\"}}")
  match read_simulate_error(path) {
    Some(ConfigLoadError::Usage(message)) =>
      assert_true(message.contains("simulate.interface"))
    _ => assert_true(false)
  }
}

///|
/// A wrong value type in the config is a usage error too.

///|
test "wrong value type in the config is rejected" {
  clear_config_env()
  let path = write_config("k.json", "{\"simulate\": {\"stop_time\": \"soon\"}}")
  match read_simulate_error(path) {
    Some(ConfigLoadError::Usage(message)) =>
      assert_true(message.contains("simulate.stop_time"))
    _ => assert_true(false)
  }
}

///|
/// A missing config file is an I/O error, not a usage error.

///|
test "missing config file is an io error" {
  clear_config_env()
  match load_config_error(Some(".moonfmi-tmp/does-not-exist.json")) {
    Some(ConfigLoadError::Io(_)) => ()
    _ => assert_true(false)
  }
}

///|
/// A file whose format cannot be decided is a usage error.

///|
test "undecidable config format is a usage error" {
  clear_config_env()
  let path = write_config("l.unknownext", "not a config at all")
  match load_config_error(Some(path)) {
    Some(ConfigLoadError::Usage(message)) =>
      assert_true(message.contains("unknown format"))
    _ => assert_true(false)
  }
}

///|
/// Keys outside the simulate and couple sections are not reported: they
/// belong to other tools that share the MOONFMI_ prefix.

///|
test "unknown keys are reported only inside the simulate and couple sections" {
  clear_config_env()
  let path = write_config(
    "m.json", "{\"simulate\": {\"stop_time\": 1.0, \"typo\": 2}, \"other\": {\"x\": 1}}",
  )
  let unknown = unknown_config_keys(load_config(Some(path)))
  assert_eq(unknown.length(), 1)
  assert_true(unknown[0].contains("typo"))
}

///|
/// The default values apply when neither the command line nor the config
/// file says anything.

///|
test "defaults apply without a config file" {
  clear_config_env()
  let options = configure_simulate(empty_simulate_options())
  assert_eq(effective_interface(options), "cs")
  assert_eq(effective_solver(options), "rk4")
  assert_eq(effective_backend(options), "native")
}

///|
/// A configured value overrides the default but not the command line.

///|
test "config overrides the default value" {
  clear_config_env()
  let path = write_config("n.json", "{\"simulate\": {\"solver\": \"euler\"}}")
  let options = empty_simulate_options()
  options.config_path = Some(path)
  let merged = configure_simulate(options)
  assert_eq(effective_solver(merged), "euler")
}
