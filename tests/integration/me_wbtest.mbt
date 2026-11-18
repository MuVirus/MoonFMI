///|
/// P3 integration: the ME master algorithm on real FMUs (tasks C-13/C-14).
///
/// Reference trajectory: VanDerPol has no events, so a fine-step RK4 run is
/// the reference for a coarse-step run; the coarse error scales with h^4,
/// which makes 1e-5 a meaningful but not brittle tolerance.

///|
/// Run VanDerPol ME over [0, 5] and return the series for x0/x1 (vr 1, 3).
/// `step_size` is the fixed step or the initial step when `adaptive` is
/// true; `tolerance` drives the RKF45 controller in that case.
fn run_vanderpol(
  step_size : Double,
  adaptive~ : Bool = false,
  tolerance~ : Double = 0.000001,
) -> @sim.SimulationResult {
  let data = @fs.read_file_to_bytes(fmu_path("fmi2/VanDerPol.fmu")) catch {
    error => abort("reading VanDerPol failed: " + io_message(error))
  }
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let directory = absolute_path(".moonfmi-tmp/vanderpol-\{@env.now()}")
  let host = match
    @fmi.parse_host_platform(@native_backend.host_platform_name()) {
    Some(host) => host
    None => abort("unknown host platform")
  }
  let loaded = @native_backend.load_fmi2_me_fmu(
    data,
    host~,
    temp_directory=directory,
  ) catch {
    error => abort("loading VanDerPol failed: " + error.message())
  }
  // Outputs x0 = vr 1, x1 = vr 3 (mu = vr 5).
  let config = @sim.MeConfig::new(
    start_time=0.0,
    stop_time=5.0,
    step_size~,
    record=[1U, 3U],
    solver=Rk4,
    state_count=loaded.state_count,
    event_indicator_count=loaded.event_indicator_count,
    adaptive~,
    tolerance~,
  )
  let result = @sim.run_me_simulation(loaded.instance(), config~) catch {
    error => {
      let detail = error.message()
      loaded.dispose()
      abort("simulation failed: " + detail)
    }
  }
  loaded.dispose()
  result
}

///|
test "vanderpol me matches a fine-step rk4 reference" {
  let coarse = run_vanderpol(0.01)
  let fine = run_vanderpol(0.001)
  assert_eq(coarse.steps(), 500)
  assert_eq(fine.steps(), 5000)
  assert_eq(coarse.events(), 0)
  // Compare both states at t = 1, 2, 5. The coarse grid samples at index
  // t/0.01, the fine grid at t/0.001.
  for (coarse_index, fine_index) in [(100, 1000), (200, 2000), (500, 5000)] {
    for channel in 0..<2 {
      let difference = coarse.series()[channel][coarse_index] -
        fine.series()[channel][fine_index]
      assert_true(
        difference.abs() <= 0.00001,
        msg="t=\{coarse.times()[coarse_index]}: coarse=\{coarse.series()[channel][coarse_index]} fine=\{fine.series()[channel][fine_index]}",
      )
    }
  }
}

///|
test "bouncingball me keeps the ball above ground and bounces" {
  let data = @fs.read_file_to_bytes(fmu_path("fmi2/BouncingBall.fmu")) catch {
    error => abort("reading BouncingBall failed: " + io_message(error))
  }
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let directory = absolute_path(".moonfmi-tmp/bb-me-\{@env.now()}")
  let host = match
    @fmi.parse_host_platform(@native_backend.host_platform_name()) {
    Some(host) => host
    None => abort("unknown host platform")
  }
  let loaded = @native_backend.load_fmi2_me_fmu(
    data,
    host~,
    temp_directory=directory,
  ) catch {
    error => abort("loading BouncingBall failed: " + error.message())
  }
  assert_eq(loaded.event_indicator_count, 1)
  // h = vr 1, v = vr 3.
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
  loaded.dispose()
  // The ball bounces several times before settling; each bounce is one
  // event. The exact count depends on where the events land, so this is a
  // sanity range, not an exact value.
  assert_true(
    result.events() >= 3 && result.events() <= 20,
    msg="unexpected event count: \{result.events()}",
  )
  // Event detection must keep the height non-negative at every record.
  for index, time in result.times() {
    let height = result.series()[0][index]
    assert_true(
      height >= -0.000000001,
      msg="ball below ground at t=\{time}: h=\{height}",
    )
  }
  // After 3 s the ball has come to rest on the ground.
  let final_height = result.series()[0][result.times().length() - 1]
  assert_true(
    final_height.abs() <= 0.0001,
    msg="final height \{final_height} is not ~0",
  )
}

///|
/// VanDerPol with RKF45 at tolerance 1e-6 must agree with the fine-step
/// RK4 reference and use fewer accepted steps than the 5000-step reference.
test "vanderpol me adaptive matches the fine-step rk4 reference" {
  let fine = run_vanderpol(0.001)
  let adaptive = run_vanderpol(0.01, adaptive=true, tolerance=0.000001)
  assert_eq(adaptive.events(), 0)
  assert_true(
    adaptive.steps() < fine.steps(),
    msg="adaptive steps=\{adaptive.steps()} fine steps=\{fine.steps()}",
  )
  // Both runs record exactly at stop_time, so the endpoints can be compared
  // without interpolating the irregular adaptive grid. The error is on the
  // order of the tolerance (about 2e-6 at tolerance 1e-6).
  let last = adaptive.times().length() - 1
  assert_true(close(adaptive.times()[last], 5.0, 0.000000001))
  for channel in 0..<2 {
    let difference = adaptive.series()[channel][last] -
      fine.series()[channel][fine.times().length() - 1]
    assert_true(
      difference.abs() <= 0.0001,
      msg="t=5 ch=\{channel} error=\{difference.abs()}",
    )
  }
}

///|
/// Close-enough comparison for double series.
fn close(actual : Double, expected : Double, tolerance : Double) -> Bool {
  (actual - expected).abs() <= tolerance
}

///|
/// BouncingBall with RKF45: the same event invariants as the fixed-step run
/// (h never below ground, bounce count in the same range), stepping on an
/// irregular, recorded grid.
test "bouncingball me adaptive keeps the ball above ground and bounces" {
  let data = @fs.read_file_to_bytes(fmu_path("fmi2/BouncingBall.fmu")) catch {
    error => abort("reading BouncingBall failed: " + io_message(error))
  }
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let directory = absolute_path(".moonfmi-tmp/bb-me-adaptive-\{@env.now()}")
  let host = match
    @fmi.parse_host_platform(@native_backend.host_platform_name()) {
    Some(host) => host
    None => abort("unknown host platform")
  }
  let loaded = @native_backend.load_fmi2_me_fmu(
    data,
    host~,
    temp_directory=directory,
  ) catch {
    error => abort("loading BouncingBall failed: " + error.message())
  }
  assert_eq(loaded.event_indicator_count, 1)
  // h = vr 1, v = vr 3. Cap the adaptive step at the fixed-test resolution
  // so no step can step over a bounce.
  let config = @sim.MeConfig::new(
    start_time=0.0,
    stop_time=3.0,
    step_size=0.001,
    record=[1U, 3U],
    solver=Rk4,
    state_count=loaded.state_count,
    event_indicator_count=loaded.event_indicator_count,
    adaptive=true,
    tolerance=0.000001,
    max_step=Some(0.001),
  )
  let result = @sim.run_me_simulation(loaded.instance(), config~) catch {
    error => {
      let detail = error.message()
      loaded.dispose()
      abort("simulation failed: " + detail)
    }
  }
  loaded.dispose()
  assert_true(
    result.events() >= 3 && result.events() <= 20,
    msg="unexpected event count: \{result.events()}",
  )
  for index, time in result.times() {
    let height = result.series()[0][index]
    assert_true(
      height >= -0.000000001,
      msg="ball below ground at t=\{time}: h=\{height}",
    )
  }
  let final_height = result.series()[0][result.times().length() - 1]
  assert_true(
    final_height.abs() <= 0.0001,
    msg="final height \{final_height} is not ~0",
  )
  assert_true(
    result.steps() <= 3500,
    msg="unexpected step count: \{result.steps()}",
  )
}
