///|
/// P4 integration: FMI 3 CS/ME on the real Reference-FMUs (tasks C-15…C-18).
/// The FMI 2 and FMI 3 BouncingBall FMUs are built from the same model
/// source, so the P2 C reference host trajectory doubles as the FMI 3
/// reference.

///|
fn load_fmi3(relative : String, tag : String) -> @native_backend.LoadedFmu3 {
  let data = @fs.read_file_to_bytes(fmu_path(relative)) catch {
    error => abort("reading " + relative + " failed: " + io_message(error))
  }
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let directory = absolute_path(".moonfmi-tmp/" + tag + "-\{@env.now()}")
  let host = match
    @fmi.parse_host_platform(@native_backend.host_platform_name()) {
    Some(host) => host
    None => abort("unknown host platform")
  }
  @native_backend.load_fmi3_fmu(data, host~, temp_directory=directory) catch {
    error => abort("loading " + relative + " failed: " + error.message())
  }
}

///|
/// Initialize through the co-simulation trait so the FMI 3 event-mode
/// settlement (UpdateDiscreteStates + EnterStepMode) runs, which the plain
/// inherent  does not do.
fn init_fmi3_cs(instance : &@fmi.CsInstance) -> Unit raise @fmi.SimulationError {
  instance.initialize()
}

///|
test "fmi3 bouncingball cs matches the c reference host trajectory" {
  let loaded = load_fmi3("fmi3/BouncingBall.fmu", "fmi3-bb")
  // The FMI 2 FMU reproduces these values with the C host at 1e-9; the FMI 3
  // FMU is generated from the same model source.
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
  for position, sample in bouncing_ball_reference() {
    let index = (sample.0 * 100.0).to_int()
    let h = result.series()[0][index]
    let v = result.series()[1][index]
    let tolerance : Double = 0.000000001
    let is_last = position == bouncing_ball_reference().length() - 1
    let h_close = if is_last {
      h.abs() < 0.000000000001
    } else {
      (h - sample.1).abs() <= tolerance
    }
    let v_close = if is_last {
      v.abs() < 0.000000000001
    } else {
      (v - sample.2).abs() <= tolerance
    }
    assert_true(h_close, msg="t=\{sample.0}: h=\{h} vs \{sample.1}")
    assert_true(v_close, msg="t=\{sample.0}: v=\{v} vs \{sample.2}")
  }
  loaded.dispose()
}

///|
test "fmi3 feedthrough roundtrips every value type" {
  let loaded = load_fmi3("fmi3/Feedthrough.fmu", "fmi3-ft")
  let instance = loaded.instance()
  instance.setup_experiment(start_time=0.0, stop_time=1.0)
  init_fmi3_cs(instance)
  // The feedthrough model copies every input to its output.
  instance.set_float64_one(7U, 1.5)
  instance.set_int32_one(19U, 42)
  instance.set_boolean_one(27U, true)
  instance.set_string_one(29U, "hello moonfmi")
  instance.step(0.0, 0.1)
  assert_true(
    close_enough(instance.get_float64_one(8U), 1.5, 0.000000000001),
    msg="Float64 output: \{instance.get_float64_one(8U)}",
  )
  assert_eq(instance.get_int32([20U])[0], 42)
  assert_eq(instance.get_boolean([28U])[0], true)
  assert_eq(instance.get_string_one(30U), "hello moonfmi")
  // UInt64 roundtrip with a value that exceeds Int32.
  instance.set_uint64([25U], [9007199254740993UL])
  instance.step(0.1, 0.1)
  assert_eq(instance.get_uint64([26U])[0], 9007199254740993UL)
  // Every narrow integer type roundtrips through the shim's widening.
  instance.set_int8_one(11U, -100)
  instance.set_uint8_one(13U, 200)
  instance.set_int16_one(15U, -30000)
  instance.set_uint16_one(17U, 60000)
  instance.set_uint32_one(21U, 4000000000U)
  instance.set_int64_one(23U, 9007199254740993L)
  instance.set_float32_one(1U, 2.5)
  instance.step(0.2, 0.1)
  assert_eq(instance.get_int8([12U])[0], -100)
  assert_eq(instance.get_uint8([14U])[0], 200)
  assert_eq(instance.get_int16([16U])[0], -30000)
  assert_eq(instance.get_uint16([18U])[0], 60000)
  assert_eq(instance.get_uint32([22U])[0], 4000000000U)
  assert_eq(instance.get_int64([24U])[0], 9007199254740993L)
  // Float32 output, widened to Double by the shim (2.5 is exact).
  let wide = instance.get_float32([2U])
  assert_eq(wide.length(), 1)
  assert_true(
    close_enough(wide[0], 2.5, 0.000000000001),
    msg="Float32 output: \{wide[0]}",
  )
  instance.terminate()
  loaded.dispose()
}

///|
/// The Resource FMU loads its value from `resources/y.txt` during
/// initialization, so it only works when the FMI 3 resource path reaches
/// the FMU as a native directory path (FMI 3.0.2 §2.3): a `file://` URI
/// makes the FMU fail in `fmi3ExitInitializationMode`.
test "fmi3 resource fmu reads its resource file" {
  let loaded = load_fmi3("fmi3/Resource.fmu", "fmi3-res")
  let instance = loaded.instance()
  instance.setup_experiment(start_time=0.0, stop_time=1.0)
  init_fmi3_cs(instance)
  instance.step(0.0, 0.1)
  // `resources/y.txt` starts with 'a' (ASCII 97); the FMU assigns that
  // character to the Int32 output `y` (value reference 1).
  assert_eq(instance.get_int32([1U])[0], 97)
  instance.terminate()
  loaded.dispose()
}

///|
test "fmi3 statespace reads and writes array variables" {
  let loaded = load_fmi3("fmi3/StateSpace.fmu", "fmi3-ss")
  let instance = loaded.instance()
  instance.setup_experiment(start_time=0.0, stop_time=1.0)
  init_fmi3_cs(instance)
  // u = vr 9, y = vr 10; the sizes are structural parameters (m/n/r,
  // value references 1..3), so the element count is read at runtime.
  // Defaults: A=B=C=D=I, x0=0, all sizes 3.
  let r = instance.get_uint64([3U])[0].to_int()
  assert_eq(r, 3)
  instance.set_float64([9U], [1.0, 2.0, 3.0])
  instance.step(0.0, 0.1)
  let y = instance.get_float64_values([10U], r)
  assert_eq(y.length(), 3)
  // y = C*x + D*u with identity A/B/C/D and x(0)=0, u constant:
  // x(0.1) = (e^0.1 - 1)*u, so y(0.1) = e^0.1*u. The FMU integrates
  // internally with fixed steps, so the observed value differs from the
  // analytic one by ~5.5e-5 at t=0.1; the tolerance covers that
  // discretization error, not the array read/write path (exact).
  assert_true(
    close_enough(y[0], 1.1051709180756477, 0.0005),
    msg="y[0]=\{y[0]} vs e^0.1",
  )
  assert_true(
    close_enough(y[2], 3.315512754226943, 0.0005),
    msg="y[2]=\{y[2]} vs 3*e^0.1",
  )
  instance.terminate()
  loaded.dispose()
}

///|
test "fmi3 bouncingball me bounces and settles like fmi2" {
  let data = @fs.read_file_to_bytes(fmu_path("fmi3/BouncingBall.fmu")) catch {
    error => abort("reading BouncingBall failed: " + io_message(error))
  }
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let directory = absolute_path(".moonfmi-tmp/fmi3-bb-me-\{@env.now()}")
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
    error => abort("loading BouncingBall ME failed: " + error.message())
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
}

///|
test "fmi3 fmu state save and restore if the fmu supports it" {
  let loaded = load_fmi3("fmi3/BouncingBall.fmu", "fmi3-bb-state")
  let instance = loaded.instance()
  instance.setup_experiment(start_time=0.0, stop_time=2.0)
  init_fmi3_cs(instance)
  instance.step(0.0, 0.5)
  if instance.supports_fmu_state() {
    let state = instance.get_fmu_state() catch {
      error => abort("get_fmu_state failed: " + error.message())
    }
    instance.step(0.5, 0.5)
    let forward = instance.get_float64_one(1U)
    // Restore and redo the same step: the trajectory must repeat exactly.
    instance.set_fmu_state(state) catch {
      error => abort("set_fmu_state failed: " + error.message())
    }
    instance.step(0.5, 0.5)
    let redone = instance.get_float64_one(1U)
    assert_true(
      close_enough(forward, redone, 0.0),
      msg="restore mismatch: \{forward} vs \{redone}",
    )
    instance.free_fmu_state(state) catch {
      error => abort("free_fmu_state failed: " + error.message())
    }
  }
  instance.terminate()
  loaded.dispose()
}

///|
test "fmi3 cs records array outputs as per-element series" {
  let loaded = load_fmi3("fmi3/StateSpace.fmu", "fmi3-ss-rec")
  // u = vr 9, y = vr 10; A=B=C=D=I, x(0)=0, so y(0) = u(0) = [1, 2, 3]
  // exactly. The recorder splits the 3-element array into its own series.
  // The input is written in the instantiated state; the master runs its
  // own setup and initialization afterwards.
  let instance = loaded.instance()
  instance.set_float64([9U], [1.0, 2.0, 3.0])
  let config = @sim.CsConfig::new(
    start_time=0.0,
    stop_time=0.2,
    step_size=0.1,
    record=[],
    record_arrays=[{ value_reference: 10U, name: "y", element_count: 3, }],
  )
  let result = @sim.run_cs_simulation(instance, config~) catch {
    error => {
      let detail = error.message()
      loaded.dispose()
      abort("simulation failed: " + detail)
    }
  }
  assert_eq(result.series().length(), 3)
  assert_eq(result.times().length(), 3)
  assert_true(
    close_enough(result.series()[0][0], 1.0, 0.000000000001),
    msg="y[1](0)=\{result.series()[0][0]}",
  )
  assert_true(
    close_enough(result.series()[1][0], 2.0, 0.000000000001),
    msg="y[2](0)=\{result.series()[1][0]}",
  )
  assert_true(
    close_enough(result.series()[2][0], 3.0, 0.000000000001),
    msg="y[3](0)=\{result.series()[2][0]}",
  )
  loaded.dispose()
}
