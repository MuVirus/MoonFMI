///|
/// Corpus samples that had no dedicated integration test yet (0.8.1): the
/// Stair models under CS and Roberts under ME. Stair's `counter` output is
/// an Integer, which the Real-based recorder does not cover, so the tests
/// read it through the typed integer channel while stepping directly.
/// Roberts' CS rejection was a binary/XML mismatch (its sources ship
/// without `EVENT_UPDATE`, so the hardcoded `eventModeUsed = true` was
/// rejected); since 0.8.2 the loader retries without event mode and the
/// CS path runs below — see docs/reports/crosscheck.md for the corrected
/// attribution.

///|
/// Stair counts the seconds: `counter` (vr 1, Integer) starts at 1 and
/// increments at every whole second (counter = k + 1 at t = k). The FMU
/// handles its internal time events during the communication step, so the
/// master only steps.
test "fmi2 stair cs counts the seconds" {
  let data = @fs.read_file_to_bytes(fmu_path("fmi2/Stair.fmu")) catch {
    error => abort("reading Stair failed: " + io_message(error))
  }
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let directory = absolute_path(".moonfmi-tmp/fmi2-stair-\{@env.now()}")
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
    error => abort("loading Stair failed: " + error.message())
  }
  let instance = loaded.instance()
  instance.setup_experiment(start_time=0.0, stop_time=3.0)
  instance.initialize()
  assert_eq(instance.get_integer_one(1U), 1)
  let mut t = 0.0
  for k in 1..<=3 {
    instance.step(t, 1.0) catch {
      error => abort("step to \{t + 1.0} failed: " + error.message())
    }
    t = t + 1.0
    assert_eq(instance.get_integer_one(1U), k + 1, msg="counter at t=\{t}")
  }
  instance.finish()
  loaded.dispose()
}

///|
test "fmi3 stair cs counts the seconds" {
  let data = @fs.read_file_to_bytes(fmu_path("fmi3/Stair.fmu")) catch {
    error => abort("reading Stair failed: " + io_message(error))
  }
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let directory = absolute_path(".moonfmi-tmp/fmi3-stair-\{@env.now()}")
  let host = match
    @fmi.parse_host_platform(@native_backend.host_platform_name()) {
    Some(host) => host
    None => abort("unknown host platform")
  }
  let loaded = @native_backend.load_fmi3_fmu(
    data,
    host~,
    temp_directory=directory,
  ) catch {
    error => abort("loading Stair failed: " + error.message())
  }
  let instance = loaded.instance()
  instance.setup_experiment(start_time=0.0, stop_time=3.0)
  // Initialize through the trait: with eventModeUsed=true the FMU settles
  // its initial event and enters step mode (the plain inherent
  // initialize only enters and exits initialization mode).
  init_fmi3_cs(instance)
  assert_eq(instance.get_int32([1U])[0], 1)
  let mut t = 0.0
  for k in 1..<=3 {
    instance.step(t, 1.0) catch {
      error => abort("step to \{t + 1.0} failed: " + error.message())
    }
    t = t + 1.0
    assert_eq(instance.get_int32([1U])[0], k + 1, msg="counter at t=\{t}")
  }
  instance.finish()
  loaded.dispose()
}

///|
/// Roberts (the Robertson kinetics problem) under ME: two continuous
/// states, two event indicators. Short-horizon fixed-step run — the full
/// default experiment reaches t=1e8, far beyond a fixed-step master's
/// reach. y1 decays from 1 only slowly (rate k1 = 0.04), y2 and y3 grow
/// from 0; the run must complete on the grid without state blowup.
test "fmi3 roberts me runs the kinetics on a short horizon" {
  let data = @fs.read_file_to_bytes(fmu_path("fmi3/Roberts.fmu")) catch {
    error => abort("reading Roberts failed: " + io_message(error))
  }
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let directory = absolute_path(".moonfmi-tmp/fmi3-roberts-\{@env.now()}")
  let host = match
    @fmi.parse_host_platform(@native_backend.host_platform_name()) {
    Some(host) => host
    None => abort("unknown host platform")
  }
  let loaded = @native_backend.load_fmi3_me_fmu(
    data,
    host~,
    temp_directory=directory,
  ) catch {
    error => abort("loading Roberts ME failed: " + error.message())
  }
  let config = @sim.MeConfig::new(
    start_time=0.0,
    stop_time=0.02,
    step_size=0.0001,
    record=[2U, 4U, 6U],
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
  assert_eq(result.times().length(), 201)
  assert_true(
    close_enough(result.times()[200], 0.02, 0.000000001),
    msg="final time \{result.times()[200]}",
  )
  // y1 decays from 1; y2 and y3 grow from 0 but stay far below y1.
  let y1_end = result.series()[0][200]
  let y2_end = result.series()[1][200]
  let y3_end = result.series()[2][200]
  assert_true(
    y1_end > 0.998 && y1_end < 1.0,
    msg="y1(0.02)=\{y1_end} outside (0.998, 1.0)",
  )
  assert_true(
    y2_end > 0.0 && y2_end < 0.001,
    msg="y2(0.02)=\{y2_end} outside (0, 0.001)",
  )
  assert_true(
    y3_end > 0.0 && y3_end < 0.01,
    msg="y3(0.02)=\{y3_end} outside (0, 0.01)",
  )
  assert_true(y1_end > y2_end && y1_end > y3_end)
  loaded.dispose()
}

///|
/// Roberts under CS: the loader honors the declared event mode first and
/// retries without it when the FMU's binaries reject `eventModeUsed=true`
/// (its sources ship without EVENT_UPDATE), so the CS interface loads.
/// The FMU raises one intermediate update per internal solver step
/// (1e-6), which exercises the intermediate-update channel end to end.
test "fmi3 roberts cs runs via the event-mode fallback" {
  let data = @fs.read_file_to_bytes(fmu_path("fmi3/Roberts.fmu")) catch {
    error => abort("reading Roberts failed: " + io_message(error))
  }
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let directory = absolute_path(".moonfmi-tmp/fmi3-roberts-cs-\{@env.now()}")
  let host = match
    @fmi.parse_host_platform(@native_backend.host_platform_name()) {
    Some(host) => host
    None => abort("unknown host platform")
  }
  let loaded = @native_backend.load_fmi3_fmu(
    data,
    host~,
    temp_directory=directory,
  ) catch {
    error => abort("loading Roberts CS failed: " + error.message())
  }
  let config = @sim.CsConfig::new(
    start_time=0.0,
    stop_time=0.02,
    step_size=0.001,
    record=[2U, 4U, 6U],
  )
  let result = @sim.run_cs_simulation(loaded.instance(), config~) catch {
    error => {
      let detail = error.message()
      loaded.dispose()
      abort("simulation failed: " + detail)
    }
  }
  assert_eq(result.steps(), 20)
  assert_eq(result.times().length(), 21)
  assert_true(
    close_enough(result.times()[20], 0.02, 0.000000001),
    msg="final time \{result.times()[20]}",
  )
  // Same kinetic bounds as the ME run: y1 decays slowly from 1, y2 and
  // y3 grow from 0 but stay orders of magnitude below y1.
  let y1_end = result.series()[0][20]
  let y2_end = result.series()[1][20]
  let y3_end = result.series()[2][20]
  assert_true(
    y1_end > 0.998 && y1_end < 1.0,
    msg="y1(0.02)=\{y1_end} outside (0.998, 1.0)",
  )
  assert_true(
    y2_end > 0.0 && y2_end < 0.001,
    msg="y2(0.02)=\{y2_end} outside (0, 0.001)",
  )
  assert_true(
    y3_end > 0.0 && y3_end < 0.01,
    msg="y3(0.02)=\{y3_end} outside (0, 0.01)",
  )
  // The intermediate-update channel is live: one callback per internal
  // Euler step of 1e-6 over 0.02 s means ~20000 reports.
  assert_true(
    loaded.instance().intermediate_update_count() > 1000,
    msg="intermediate updates=\{loaded.instance().intermediate_update_count()}",
  )
  loaded.dispose()
}
