///|
/// The reference trajectory produced by `tests/abi/fmi2_host.c`:
/// BouncingBall from t=0 to t=3 with a fixed 10 ms step. Samples are taken
/// every 50 steps, so each row is `(time, h, v)`.
fn bouncing_ball_reference() -> Array[(Double, Double, Double)] {
  [
    (0.5, 0.13560068699999941, 2.64968099999999),
    (1.0, 0.23664368699999475, -2.2553190000000161),
    (1.5, 0.07350171929999888, -1.8420237000000108),
    (2.0, 0.054889077789000158, -0.35254491299999868),
    (2.5, 0.00080600419771164038, 0.17697604942791004),
    (3.0, 2.2250738585072014e-308, 0.0),
  ]
}

///|
fn ensure_dir(path : String) -> Unit {
  let exists = @fs.is_dir(path) catch { _ => false }
  if !exists {
    @fs.create_dir(path) catch {
      error => abort("could not create " + path + ": " + io_message(error))
    }
  }
}

///|
fn absolute_path(path : String) -> String {
  match @env.current_dir() {
    Some(directory) => directory + "/" + path
    None => path
  }
}

///|
fn extract_if_present(
  archive : @zip.ZipArchive,
  entry : String,
  target : String,
) -> Bool {
  if !archive.contains(entry) {
    return false
  }
  let bytes = archive.read(entry) catch {
    error => abort("could not read " + entry + ": " + error.message())
  }
  @fs.write_bytes_to_file(target, bytes) catch {
    error => abort("could not write " + target + ": " + io_message(error))
  }
  true
}

///|
/// Unpacks the BouncingBall binary and resources into a stable directory.
/// Returns the library and the absolute resource directory.
fn open_bouncing_ball() -> (@native_backend.Fmi2Library, String) {
  let root = "tests/abi/.cache/fmu/BouncingBall"
  ensure_dir("tests/abi/.cache/fmu")
  ensure_dir(root)
  ensure_dir(root + "/binaries")
  ensure_dir(root + "/binaries/win64")
  ensure_dir(root + "/binaries/linux64")
  ensure_dir(root + "/binaries/aarch64-linux")
  ensure_dir(root + "/resources")

  let archive = open_cached_fmu("fmi2/BouncingBall.fmu")
  let dll = root + "/binaries/win64/BouncingBall.dll"
  let so = root + "/binaries/linux64/BouncingBall.so"
  let so_arm = root + "/binaries/aarch64-linux/BouncingBall.so"
  let have_dll = extract_if_present(
    archive, "binaries/win64/BouncingBall.dll", dll,
  )
  let have_so = extract_if_present(
    archive, "binaries/linux64/BouncingBall.so", so,
  )
  let have_so_arm = extract_if_present(
    archive, "binaries/aarch64-linux/BouncingBall.so", so_arm,
  )
  if !have_dll && !have_so && !have_so_arm {
    abort("BouncingBall.fmu contains no binary for this platform")
  }
  let resource = absolute_path(root + "/resources")

  // The FMU carries one binary per platform; loading is the cheapest way to
  // find out which of them this host can actually use. An ARM runner cannot
  // load the linux64 (x86-64) binary, so the aarch64 candidate comes last
  // but is reachable.
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
  if have_so_arm {
    let loaded = Some(@native_backend.Fmi2Library::open(so_arm)) catch {
      _ => None
    }
    match loaded {
      Some(library) => return (library, resource)
      None => ()
    }
  }
  abort("BouncingBall binary could not be loaded on this platform")
}

///|
fn close_enough(actual : Double, expected : Double, tolerance : Double) -> Bool {
  let difference = if actual >= expected {
    actual - expected
  } else {
    expected - actual
  }
  difference <= tolerance
}

///|
test "BouncingBall co-simulation matches the C reference host" {
  let (library, resource) = open_bouncing_ball()
  assert_eq(library.version(), "2.0")
  let messages : Array[String] = []
  let instance = library.instantiate(
    instance_name="bouncingball",
    guid="{1AE5E10D-9521-4DE3-80B9-D0EAAA7D5AF1}",
    resource_path=resource,
    on_log=fn(message) {
      messages.push(message.category + ": " + message.message)
    },
  )
  instance.setup_experiment(start_time=0.0, stop_time=3.0)
  instance.enter_initialization_mode()
  instance.exit_initialization_mode()

  let reference = bouncing_ball_reference()
  let mut time = 0.0
  let mut index = 0
  for step in 0..<300 {
    let status = instance.do_step(time, 0.01)
    if !(status is Ok) {
      abort(
        "fmi2DoStep returned " + status.name() + " at t=" + time.to_string(),
      )
    }
    time += 0.01
    if (step + 1) % 50 == 0 {
      let values = instance.get_real([1U, 3U])
      let (expected_time, expected_h, expected_v) = reference[index]
      if !close_enough(time, expected_time, 1.0e-9) {
        abort(
          "time drift at sample " +
          index.to_string() +
          ": " +
          time.to_string() +
          " vs " +
          expected_time.to_string(),
        )
      }
      if !close_enough(values[0], expected_h, 1.0e-12) {
        abort(
          "h differs at sample " +
          index.to_string() +
          ": " +
          values[0].to_string() +
          " vs " +
          expected_h.to_string(),
        )
      }
      if !close_enough(values[1], expected_v, 1.0e-12) {
        abort(
          "v differs at sample " +
          index.to_string() +
          ": " +
          values[1].to_string() +
          " vs " +
          expected_v.to_string(),
        )
      }
      index = index + 1
    }
  }
  assert_eq(index, 6)
  instance.terminate()
  instance.free()
  assert_true(instance.is_freed())
  let _ = messages
  library.close()
  assert_true(library.is_closed())
}
