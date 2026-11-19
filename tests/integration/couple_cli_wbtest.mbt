///|
/// CLI level end-to-end tests for `moonfmi couple` (task D-02). They call
/// the CLI entry point directly instead of spawning a subprocess. The
/// generator/gain FMUs are compiled from exported sources with clang, see
/// coupling_wbtest.mbt for the same pipeline.

///|
/// Builds the generator and gain FMUs used by the couple CLI tests and
/// writes them to `directory`. Returns the two paths.
fn couple_fixtures(directory : String) -> (String, String) {
  let generator_path = directory + "/generator.fmu"
  let gain_path = directory + "/gain.fmu"
  let (generator_bytes, _) = build_source_fmu(
    @schema.FmiVersion::V2,
    "cli-couple-gen",
  )
  let gain_bytes = build_gain_fmu("cli-couple-gain")
  @fs.write_bytes_to_file(generator_path, generator_bytes) catch {
    error => abort("writing generator FMU failed: " + io_message(error))
  }
  @fs.write_bytes_to_file(gain_path, gain_bytes) catch {
    error => abort("writing gain FMU failed: " + io_message(error))
  }
  (generator_path, gain_path)
}

///|
/// Runs the couple command on the generator/gain fixtures and asserts the
/// coupled CSV: `time,generator.x,generator.y,gain.y` with `gain.y[n] ==
/// 2 * generator.x[n]` (no one-step lag, because the coupled master steps
/// the producer before the consumer).
test "moonfmi couple runs generator and gain end to end" {
  match compiler_probe_skip() {
    Some(reason) => {
      println("SKIP: " + reason)
      return
    }
    None => ()
  }
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let directory = absolute_path(
    ".moonfmi-tmp/couple-cli-" + @env.now().to_string(),
  )
  ensure_test_dir(directory)
  let (generator_path, gain_path) = couple_fixtures(directory)
  let output = directory + "/coupled.csv"
  let code = @cli.run(
    [
      "couple", generator_path, gain_path, "--connect", "generator.y=gain.u", "--start-time",
      "0", "--stop-time", "1", "--step-size", "0.1", "--output", output,
    ],
    fn(path) { @fs.read_file_to_bytes(path) catch { _ => b"" } },
  )
  assert_eq(code, 0)
  let csv = @fs.read_file_to_bytes(output) catch {
    error => abort("reading coupled CSV failed: " + io_message(error))
  }
  let text = @utf8.decode(csv)
  let lines = Array::from_iter(text.split("\n"))
  // Drop a possible trailing empty line.
  let mut line_count = 0
  for _ in lines {
    line_count = line_count + 1
  }
  if line_count > 0 && lines[line_count - 1].is_empty() {
    line_count = line_count - 1
  }
  assert_eq(
    line_count,
    12,
    msg="expected header + 11 rows, got " + line_count.to_string(),
  )
  assert_eq(lines[0], "time,generator.x,generator.y,gain.y")
  let mut x = 1.0
  for n in 0..<=10 {
    let fields = Array::from_iter(lines[n + 1].split(","))
    let t = @string.parse_double(fields[0].to_owned())
    assert_true(
      (t - n.to_double() * 0.1).abs() < 0.000001,
      msg="t[" + n.to_string() + "] = " + t.to_string(),
    )
    let gain_y = @string.parse_double(fields[3].to_owned())
    assert_true(
      (gain_y - 2.0 * x).abs() < 0.000001,
      msg="gain.y[" +
        n.to_string() +
        "] = " +
        gain_y.to_string() +
        ", expected " +
        (2.0 * x).to_string(),
    )
    x = x * 0.9
  }
}

///|
/// An unknown connection variable is reported with the FMU path and the
/// variable name and exits with code 1.
test "moonfmi couple rejects a missing connection variable" {
  match compiler_probe_skip() {
    Some(reason) => {
      println("SKIP: " + reason)
      return
    }
    None => ()
  }
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let directory = absolute_path(
    ".moonfmi-tmp/couple-cli-missing-" + @env.now().to_string(),
  )
  ensure_test_dir(directory)
  let (generator_path, gain_path) = couple_fixtures(directory)
  let code = @cli.run(
    [
      "couple", generator_path, gain_path, "--connect", "generator.nope=gain.u",
      "--stop-time", "1", "--step-size", "0.1",
    ],
    fn(path) { @fs.read_file_to_bytes(path) catch { _ => b"" } },
  )
  assert_eq(code, 1)
}

///|
/// A connection target must be an input: `gain.k` is a Real parameter, so
/// wiring `generator.y=gain.k` is a configuration error, exit code 1.
test "moonfmi couple rejects a non-input connection target" {
  match compiler_probe_skip() {
    Some(reason) => {
      println("SKIP: " + reason)
      return
    }
    None => ()
  }
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let directory = absolute_path(
    ".moonfmi-tmp/couple-cli-causality-" + @env.now().to_string(),
  )
  ensure_test_dir(directory)
  let (generator_path, gain_path) = couple_fixtures(directory)
  let code = @cli.run(
    [
      "couple", generator_path, gain_path, "--connect", "generator.y=gain.k", "--stop-time",
      "1", "--step-size", "0.1",
    ],
    fn(path) { @fs.read_file_to_bytes(path) catch { _ => b"" } },
  )
  assert_eq(code, 1)
}

///|
/// Two FMUs with the same stem are named `gain` and `gain-2`; wiring them
/// in a circle forms an algebraic loop, which the master rejects.
test "moonfmi couple rejects a connection cycle" {
  match compiler_probe_skip() {
    Some(reason) => {
      println("SKIP: " + reason)
      return
    }
    None => ()
  }
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let directory = absolute_path(
    ".moonfmi-tmp/couple-cli-cycle-" + @env.now().to_string(),
  )
  ensure_test_dir(directory)
  let (_generator_path, gain_path) = couple_fixtures(directory)
  let code = @cli.run(
    [
      "couple", gain_path, gain_path, "--connect", "gain.y=gain-2.u", "--connect",
      "gain-2.y=gain.u", "--stop-time", "1", "--step-size", "0.1",
    ],
    fn(path) { @fs.read_file_to_bytes(path) catch { _ => b"" } },
  )
  assert_eq(code, 1)
}

///|
/// Signal-type inference on real FMUs (0.7.0): the Feedthrough corpus FMU
/// loaded twice — a cross-type connection (`Float64` output → `Int32`
/// input) is rejected up front, while the same-type `Int32` connection
/// runs the typed write path end to end.
test "couple infers signal types and rejects cross-type connections" {
  match corpus_skip() {
    Some(reason) => {
      println("SKIP: " + reason)
      return
    }
    None => ()
  }
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let directory = absolute_path(".moonfmi-tmp/couple-typed-\{@env.now()}")
  ensure_test_dir(directory)
  let feedthrough = fmu_path("fmi2/Feedthrough.fmu")
  // Real output wired to an Integer input: rejected before anything steps.
  let cross_type = @cli.run(
    [
      "couple", feedthrough, feedthrough, "--connect", "Feedthrough.Float64_continuous_output=Feedthrough-2.Int32_input",
      "--stop-time", "0.02", "--step-size", "0.01",
    ],
    fn(path) { @fs.read_file_to_bytes(path) catch { _ => b"" } },
  )
  assert_eq(cross_type, 1)
  // Same-type Integer connection: the typed write path runs on real FMUs.
  let output = directory + "/typed.csv"
  let typed = @cli.run(
    [
      "couple", feedthrough, feedthrough, "--connect", "Feedthrough.Int32_output=Feedthrough-2.Int32_input",
      "--stop-time", "0.02", "--step-size", "0.01", "--output", output,
    ],
    fn(path) { @fs.read_file_to_bytes(path) catch { _ => b"" } },
  )
  assert_eq(typed, 0)
  let csv = @fs.read_file_to_bytes(output) catch {
    error => abort("reading typed couple CSV failed: " + io_message(error))
  }
  let text = @utf8.decode(csv)
  // The Real record columns are still present (Real outputs only); the
  // Integer connection itself carries no recorded column.
  assert_true(
    text.contains("time,Feedthrough.Float64_continuous_output"),
    msg="coupled CSV header missing Real record columns: " + text,
  )
}

///|
/// The loop-solving flags reach the coupled master: a self-connection,
/// which is rejected as an algebraic loop by default, is accepted with
/// `--loop-iterations` on the corpus Feedthrough (direct feedthrough
/// converges in one iteration).
test "couple --loop-iterations enables self-connection solving" {
  match corpus_skip() {
    Some(reason) => {
      println("SKIP: " + reason)
      return
    }
    None => ()
  }
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let feedthrough = fmu_path("fmi2/Feedthrough.fmu")
  let rejected = @cli.run(
    [
      "couple", feedthrough, "--connect", "Feedthrough.Float64_continuous_output=Feedthrough.Float64_continuous_input",
      "--stop-time", "0.01", "--step-size", "0.01",
    ],
    fn(path) { @fs.read_file_to_bytes(path) catch { _ => b"" } },
  )
  assert_eq(rejected, 1)
  let solved = @cli.run(
    [
      "couple", feedthrough, "--connect", "Feedthrough.Float64_continuous_output=Feedthrough.Float64_continuous_input",
      "--stop-time", "0.01", "--step-size", "0.01", "--loop-iterations", "3",
    ],
    fn(path) { @fs.read_file_to_bytes(path) catch { _ => b"" } },
  )
  assert_eq(solved, 0)
}
