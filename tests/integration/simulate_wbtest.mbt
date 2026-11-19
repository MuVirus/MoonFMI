///|
/// P2 integration: the CS master algorithm on the real BouncingBall FMU.
/// Reference values come from the C reference host used in P0 (see
/// tests/abi/fmi2_host.c and the P0 report §3).
/// BouncingBall from t=0 to t=3 with a fixed 10 ms step, sampled every
/// 50 steps: `(time, h, v)` rows produced by the C reference host.

///|
/// Simulate the BouncingBall with the master algorithm and compare the
/// trajectory against the C reference host at the sample points.
test "cs master algorithm matches the C reference host" {
  let data = @fs.read_file_to_bytes(fmu_path("fmi2/BouncingBall.fmu")) catch {
    error => abort("reading BouncingBall failed: " + io_message(error))
  }
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let directory = absolute_path(".moonfmi-tmp/test-\{@env.now()}")
  let host = match
    @fmi.parse_host_platform(@native_backend.host_platform_name()) {
    Some(host) => host
    None => abort("unknown host platform")
  }
  let loaded = @native_backend.load_fmi2_fmu(
    data,
    host~,
    temp_directory=directory,
  ) catch {
    error => abort("loading BouncingBall failed: " + error.message())
  }
  // The two outputs: h = valueReference 1, v = valueReference 3.
  let config = @sim.CsConfig::new(
    start_time=0.0,
    stop_time=3.0,
    step_size=0.01,
    record=[1U, 3U],
  )
  let result = @sim.run_cs_simulation(loaded.instance(), config~) catch {
    error => {
      let detail = error.message()
      loaded.dispose()
      abort("simulation failed: " + detail)
    }
  }
  assert_eq(result.steps(), 300)
  assert_eq(result.times().length(), 301)
  // Sample the master-algorithm trajectory at the reference times
  // (t=0.5 is step 50, and so on) and require the P0 tolerances.
  for position, sample in bouncing_ball_reference() {
    let index = (sample.0 * 100.0).to_int()
    let h = result.series()[0][index]
    let v = result.series()[1][index]
    let tolerance : Double = 0.000000001
    let reference_h = sample.1
    let reference_v = sample.2
    let is_last = position == bouncing_ball_reference().length() - 1
    // At t=3 the reference host reports denormalised zeros; the FMU may
    // return exactly 0 or the denormalised value depending on rounding.
    let h_close = if is_last {
      h.abs() < 0.000000000001
    } else {
      (h - reference_h).abs() <= tolerance
    }
    let v_close = if is_last {
      v.abs() < 0.000000000001
    } else {
      (v - reference_v).abs() <= tolerance
    }
    assert_true(
      h_close,
      msg="t=\{sample.0}: h=\{h} vs reference \{reference_h}",
    )
    assert_true(
      v_close,
      msg="t=\{sample.0}: v=\{v} vs reference \{reference_v}",
    )
  }
  loaded.dispose()
}

///|
/// `--set` end to end (0.7.0): typed input overrides on the Feedthrough
/// corpus FMU. The recorded columns are the Real outputs in document
/// order — Float64_continuous_output, then Float64_discrete_output — so
/// the first row shows the feedthrough of the overridden Real input.
test "simulate --set drives Real, Integer, Boolean and String inputs" {
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
  let directory = absolute_path(".moonfmi-tmp/set-cli-\{@env.now()}")
  ensure_test_dir(directory)
  let output = directory + "/feedthrough.csv"
  let code = @cli.run(
    [
      "simulate",
      fmu_path("fmi2/Feedthrough.fmu"),
      "--stop-time",
      "0.02",
      "--step-size",
      "0.01",
      "--set",
      "Float64_continuous_input=3.5",
      "--set",
      "Int32_input=7",
      "--set",
      "Boolean_input=true",
      "--set",
      "String_input=hello",
      "--output",
      output,
    ],
    fn(path) { @fs.read_file_to_bytes(path) catch { _ => b"" } },
  )
  assert_eq(code, 0)
  let csv = @fs.read_file_to_bytes(output) catch {
    error => abort("reading feedthrough CSV failed: " + io_message(error))
  }
  let text = @utf8.decode(csv)
  let lines = Array::from_iter(text.split("\n"))
  assert_eq(lines[0], "time,Float64_continuous_output,Float64_discrete_output")
  let fields = Array::from_iter(lines[1].split(","))
  assert_eq(fields[1], "3.5")
}

///|
/// `--set` rejections are exit 1 with a diagnostic naming the variable:
/// unknown name, wrong causality and a value that does not parse.
test "simulate --set rejects unknown, non-settable and malformed values" {
  match corpus_skip() {
    Some(reason) => {
      println("SKIP: " + reason)
      return
    }
    None => ()
  }
  // Unknown variable.
  let unknown = @cli.run(
    [
      "simulate",
      fmu_path("fmi2/Feedthrough.fmu"),
      "--stop-time",
      "0.01",
      "--step-size",
      "0.01",
      "--set",
      "Ghost=1",
    ],
    fn(path) { @fs.read_file_to_bytes(path) catch { _ => b"" } },
  )
  assert_eq(unknown, 1)
  // An output is not settable.
  let output = @cli.run(
    [
      "simulate",
      fmu_path("fmi2/Feedthrough.fmu"),
      "--stop-time",
      "0.01",
      "--step-size",
      "0.01",
      "--set",
      "Float64_continuous_output=1.0",
    ],
    fn(path) { @fs.read_file_to_bytes(path) catch { _ => b"" } },
  )
  assert_eq(output, 1)
  // A Real input does not accept a non-number.
  let malformed = @cli.run(
    [
      "simulate",
      fmu_path("fmi2/Feedthrough.fmu"),
      "--stop-time",
      "0.01",
      "--step-size",
      "0.01",
      "--set",
      "Float64_continuous_input=abc",
    ],
    fn(path) { @fs.read_file_to_bytes(path) catch { _ => b"" } },
  )
  assert_eq(malformed, 1)
}
