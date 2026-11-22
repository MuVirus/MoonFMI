///|
/// Black-box integration tests (0.8.2): the four-quadrant Reference-FMUs
/// matrix — FMI 2/3 × CS/ME — driven exclusively through the public API of
/// `src/backend/native` + `src/sim` (`_test.mbt`, no wbtest helpers).
/// Assertions are invariants, not recorded trajectories: the deep
/// comparisons live in the whitebox integration files.
/// Everything skips when the corpus is absent (fetch-fmus not run, or the
/// platform has no FMU binaries).

///|
fn blackbox_corpus(relative : String) -> Bytes? {
  match @env.get_env_var("MOONFMI_TEST_SKIP_PLATFORM_BINARIES") {
    Some("1") => return None
    _ => ()
  }
  let path = "tests/data/.cache/" + relative
  if !@fs.path_exists(path) {
    return None
  }
  let data = @fs.read_file_to_bytes(path) catch { _ => return None }
  Some(data)
}

///|
fn blackbox_skip(reason : String) -> Unit {
  println("SKIP: \{reason}")
}

///|
/// Absolute path under the current working directory (repo root when moon
/// runs the tests) — loaders want absolute temp directories.
fn blackbox_absolute(path : String) -> String {
  match @env.current_dir() {
    Some(directory) => directory + "/" + path
    None => path
  }
}

///|
/// Parses the host platform the way every loader call needs; aborts only
/// when the runtime reports an unknown platform, which nothing below can
/// work around.
fn blackbox_host() -> @fmi.HostPlatform {
  match @fmi.parse_host_platform(@native_backend.host_platform_name()) {
    Some(host) => host
    None => abort("unknown host platform")
  }
}

///|
/// True black-box Co-Simulation of the FMI 2 BouncingBall: 300 fixed
/// steps of 0.01 s, every recorded height on or above the ground, the
/// ball settled (h = v = 0) at t = 3 like the C reference host.
test "blackbox fmi2 cs bouncingball settles after three seconds" {
  let data = match blackbox_corpus("fmi2/BouncingBall.fmu") {
    Some(data) => data
    None => {
      blackbox_skip("corpus BouncingBall.fmu not available")
      return
    }
  }
  let loaded = @native_backend.load_fmi2_fmu(
    data,
    host=blackbox_host(),
    temp_directory=blackbox_absolute(".moonfmi-tmp/bb-cs-\{@env.now()}"),
  ) catch {
    error => abort("loading BouncingBall failed: " + error.message())
  }
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
  for row in 0..<301 {
    assert_true(
      result.series()[0][row] >= -0.000000001,
      msg="h below ground at row \{row}",
    )
  }
  assert_true(
    result.series()[0][300].abs() <= 0.000000001,
    msg="h(3)=\{result.series()[0][300]}",
  )
  assert_true(
    result.series()[1][300].abs() <= 0.000000001,
    msg="v(3)=\{result.series()[1][300]}",
  )
  loaded.dispose()
}

///|
/// True black-box Model Exchange of the FMI 2 Van der Pol oscillator with
/// RK4: 200 accepted steps on the grid, both states inside the limit
/// cycle's amplitude, no spurious events.
test "blackbox fmi2 me vanderpol stays on its limit cycle" {
  let data = match blackbox_corpus("fmi2/VanDerPol.fmu") {
    Some(data) => data
    None => {
      blackbox_skip("corpus VanDerPol.fmu not available")
      return
    }
  }
  let loaded = @native_backend.load_fmi2_me_fmu(
    data,
    host=blackbox_host(),
    temp_directory=blackbox_absolute(".moonfmi-tmp/vdp-me-\{@env.now()}"),
  ) catch {
    error => abort("loading VanDerPol failed: " + error.message())
  }
  let config = @sim.MeConfig::new(
    start_time=0.0,
    stop_time=2.0,
    step_size=0.01,
    record=[1U, 3U],
    solver=Rk4,
    state_count=loaded.state_count,
    event_indicator_count=loaded.event_indicator_count,
  )
  let result = @sim.run_me_simulation(loaded.instance(), config~) catch {
    error => {
      let detail = error.message()
      loaded.dispose()
      abort("simulation failed: " + detail)
    }
  }
  assert_eq(result.steps(), 200)
  assert_eq(result.events(), 0)
  for row in 0..<=200 {
    for channel in 0..<2 {
      assert_true(
        result.series()[channel][row].abs() <= 3.0,
        msg="state outside the limit cycle at row \{row}",
      )
    }
  }
  loaded.dispose()
}

///|
/// True black-box Co-Simulation of the FMI 3 BouncingBall: same physical
/// invariants as the FMI 2 run, on the FMI 3 backend path.
test "blackbox fmi3 cs bouncingball keeps the ball above ground" {
  let data = match blackbox_corpus("fmi3/BouncingBall.fmu") {
    Some(data) => data
    None => {
      blackbox_skip("corpus fmi3 BouncingBall.fmu not available")
      return
    }
  }
  let loaded = @native_backend.load_fmi3_fmu(
    data,
    host=blackbox_host(),
    temp_directory=blackbox_absolute(".moonfmi-tmp/fmi3-bb-cs-\{@env.now()}"),
  ) catch {
    error => abort("loading fmi3 BouncingBall failed: " + error.message())
  }
  let config = @sim.CsConfig::new(
    start_time=0.0,
    stop_time=1.0,
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
  assert_eq(result.steps(), 100)
  for row in 0..<=100 {
    assert_true(
      result.series()[0][row] >= -0.000000001,
      msg="h below ground at row \{row}",
    )
    assert_true(
      result.series()[1][row].abs() <= 10.0,
      msg="v out of range at row \{row}",
    )
  }
  loaded.dispose()
}

///|
/// True black-box Model Exchange of the FMI 3 BouncingBall: bounces stay
/// above ground and the ball is settled at t = 1 (its bounces die out
/// well inside one second), mirroring the FMI 2 ME behavior.
test "blackbox fmi3 me bouncingball bounces and settles" {
  let data = match blackbox_corpus("fmi3/BouncingBall.fmu") {
    Some(data) => data
    None => {
      blackbox_skip("corpus fmi3 BouncingBall.fmu not available")
      return
    }
  }
  let loaded = @native_backend.load_fmi3_me_fmu(
    data,
    host=blackbox_host(),
    temp_directory=blackbox_absolute(".moonfmi-tmp/fmi3-bb-me2-\{@env.now()}"),
  ) catch {
    error => abort("loading fmi3 BouncingBall ME failed: " + error.message())
  }
  let config = @sim.MeConfig::new(
    start_time=0.0,
    stop_time=3.0,
    step_size=0.001,
    record=[1U, 3U],
    solver=Rk4,
    state_count=loaded.state_count,
    event_indicator_count=loaded.event_indicator_count,
  )
  let result = @sim.run_me_simulation(loaded.instance(), config~) catch {
    error => {
      let detail = error.message()
      loaded.dispose()
      abort("simulation failed: " + detail)
    }
  }
  for row in 0..<=3000 {
    assert_true(
      result.series()[0][row] >= -0.000000001,
      msg="h below ground at row \{row}",
    )
  }
  // Three seconds settle the bounces (same horizon as the whitebox run).
  assert_true(
    result.series()[0][3000].abs() <= 0.0001,
    msg="h(3)=\{result.series()[0][3000]}",
  )
  assert_true(
    result.series()[1][3000].abs() <= 0.0001,
    msg="v(3)=\{result.series()[1][3000]}",
  )
  loaded.dispose()
}
