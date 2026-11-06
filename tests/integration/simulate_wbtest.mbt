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
