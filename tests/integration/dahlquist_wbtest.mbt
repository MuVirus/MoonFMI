///|
/// P2 leftovers: the Dahlquist comparison and the multi-instance check
/// (roadmap P2 exit criteria 3 and 6).
///
/// Reference-FMUs' Dahlquist FMU integrates dx/dt = -k*x (x(0) = 1, k = 1)
/// internally with fixed Euler sub-steps of 0.1, so one communication step
/// of h = 0.1 produces exactly x_n = (1 - k*h)^n. That closed form is the
/// analytic reference for this linear problem; it also pins the master
/// algorithm's time grid (no drift over 100 steps).

///|
test "dahlquist cs matches the analytic discrete solution" {
  let data = @fs.read_file_to_bytes(fmu_path("fmi2/Dahlquist.fmu")) catch {
    error => abort("reading Dahlquist failed: " + io_message(error))
  }
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let directory = absolute_path(".moonfmi-tmp/dahlquist-\{@env.now()}")
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
    error => abort("loading Dahlquist failed: " + error.message())
  }
  let config = @sim.CsConfig::new(
    start_time=0.0,
    stop_time=10.0,
    step_size=0.1,
    record=[1U],
  )
  let result = @sim.run_cs_simulation(loaded.instance(), config~) catch {
    error => {
      let detail = error.message()
      loaded.dispose()
      abort("simulation failed: " + detail)
    }
  }
  assert_eq(result.steps(), 100)
  assert_eq(result.times().length(), 101)
  // The time grid must not drift: t_k = k * 0.1 within the master
  // algorithm's epsilon.
  for k in 0..<=100 {
    let t = result.times()[k]
    let expected = k.to_double() * 0.1
    assert_true(
      (t - expected).abs() <= 0.000000001,
      msg="time grid drift at k=\{k}: t=\{t} vs \{expected}",
    )
  }
  // x_n = (1 - k*h)^n with k = 1 and h = 0.1.
  let mut x = 1.0
  for n in 0..<=100 {
    let actual = result.series()[0][n]
    let tolerance = 0.000000001 * (if n == 0 { 1.0 } else { x })
    assert_true(
      (actual - x).abs() <= tolerance,
      msg="x[\{n}]=\{actual} vs (1-k*h)^\{n}=\{x}",
    )
    x = x * 0.9
  }
  loaded.dispose()
}

///|
/// Unpacks the Dahlquist binary into a stable directory and opens one
/// library on it. Returns the library and the absolute resource directory.
fn open_dahlquist() -> (@native_backend.Fmi2Library, String) {
  let root = "tests/abi/.cache/fmu/Dahlquist"
  ensure_dir("tests/abi/.cache/fmu")
  ensure_dir(root)
  ensure_dir(root + "/binaries")
  ensure_dir(root + "/binaries/win64")
  ensure_dir(root + "/binaries/linux64")
  ensure_dir(root + "/resources")
  let archive = open_cached_fmu("fmi2/Dahlquist.fmu")
  let dll = root + "/binaries/win64/Dahlquist.dll"
  let so = root + "/binaries/linux64/Dahlquist.so"
  let have_dll = extract_if_present(
    archive, "binaries/win64/Dahlquist.dll", dll,
  )
  let have_so = extract_if_present(archive, "binaries/linux64/Dahlquist.so", so)
  if !have_dll && !have_so {
    abort("Dahlquist.fmu contains no binary for this platform")
  }
  let resource = absolute_path(root + "/resources")
  if have_dll {
    let loaded = Some(@native_backend.Fmi2Library::open(dll)) catch {
      _ => None
    }
    match loaded {
      Some(library) => return (library, resource)
      None => ()
    }
  }
  if have_so {
    let loaded = Some(@native_backend.Fmi2Library::open(so)) catch { _ => None }
    match loaded {
      Some(library) => return (library, resource)
      None => ()
    }
  }
  abort("Dahlquist binary could not be loaded on this platform")
}

///|
/// Two instances from one library must not share state. Both run the
/// Dahlquist equation with a different parameter k, in interleaved order;
/// each trajectory must follow its own closed form.
test "two instances from one library keep independent state" {
  let (library, resource) = open_dahlquist()
  assert_eq(library.open_instance_count(), 0)
  let instance_a = library.instantiate(
    instance_name="dahlquist-a",
    guid="{221063D2-EF4A-45FE-B954-B5BFEEA9A59B}",
    resource_path=resource,
  )
  let instance_b = library.instantiate(
    instance_name="dahlquist-b",
    guid="{221063D2-EF4A-45FE-B954-B5BFEEA9A59B}",
    resource_path=resource,
  )
  assert_eq(library.open_instance_count(), 2)
  // k starts at 1; instance b raises it to 3 during initialization.
  for instance in [instance_a, instance_b] {
    instance.setup_experiment(start_time=0.0, stop_time=1.0)
    instance.enter_initialization_mode()
  }
  instance_b.set_real_one(3U, 3.0)
  instance_a.exit_initialization_mode()
  instance_b.exit_initialization_mode()
  // Interleaved: one step each, then a re-read of a must not see b's step.
  let mut time_a = 0.0
  let mut time_b = 0.0
  for _ in 0..<5 {
    assert_true(instance_a.do_step(time_a, 0.1) is Ok)
    time_a += 0.1
    assert_true(instance_b.do_step(time_b, 0.1) is Ok)
    time_b += 0.1
  }
  // Five steps in: a = 0.9^5, b = 0.7^5.
  assert_true(
    close_enough(
      instance_a.get_real_one(1U),
      0.5904900000000001,
      0.000000000001,
    ),
    msg="a drifted: \{instance_a.get_real_one(1U)}",
  )
  assert_true(
    close_enough(instance_b.get_real_one(1U), 0.16807, 0.000000000001),
    msg="b drifted: \{instance_b.get_real_one(1U)}",
  )
  // A runs five more steps alone; b's value must stay where it was.
  for _ in 0..<5 {
    assert_true(instance_a.do_step(time_a, 0.1) is Ok)
    time_a += 0.1
  }
  assert_true(
    close_enough(instance_a.get_real_one(1U), 0.3486784401, 0.000000000001),
    msg="a diverged after solo steps: \{instance_a.get_real_one(1U)}",
  )
  assert_true(
    close_enough(instance_b.get_real_one(1U), 0.16807, 0.000000000001),
    msg="b changed while a was stepping: \{instance_b.get_real_one(1U)}",
  )
  instance_a.terminate()
  instance_b.terminate()
  instance_a.free()
  instance_b.free()
  assert_eq(library.open_instance_count(), 0)
  library.close()
  assert_true(library.is_closed())
}
