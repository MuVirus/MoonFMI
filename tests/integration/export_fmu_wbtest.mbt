///|
/// P6 integration: the generated source FMU must compile with an external
/// C99 compiler, load through MoonFMI's own native backend, and reproduce the
/// analytic trajectory (roadmap P6 exit criteria 1–3, 5, 6). The export
/// requires a C compiler on PATH (clang / MSVC cl); the compile step runs
/// through the `system()` stub in support.c, so the test needs the native
/// target.
#borrow(command)
extern "C" fn moonfmi_run_command(command : Bytes) -> Int64 = "moonfmi_test_run_command"

///|
/// Run a shell command and return its exit status. The NUL terminator is
/// appended here because MoonBit `Bytes` is not NUL-terminated.
fn run_shell(command : String) -> Int64 {
  moonfmi_run_command(@utf8.encode(command + "\u{0000}"))
}

///|
fn have_c_compiler() -> Bool {
  run_shell("clang --version") == 0L
}

///|
fn compiler_probe_skip() -> String? {
  if have_c_compiler() {
    None
  } else {
    Some("clang not on PATH; source-FMU compile tests skipped")
  }
}

///|
fn host() -> @fmi.HostPlatform {
  match @fmi.parse_host_platform(@native_backend.host_platform_name()) {
    Some(host) => host
    None => abort("unknown host platform")
  }
}

///|
/// Create `path` and any missing parents (@fs.create_dir needs parents).
fn ensure_test_dir(path : String) -> Unit {
  let mut prefix = ""
  for segment in path.split("/") {
    let segment = segment.to_owned()
    if segment.is_empty() {
      continue
    }
    prefix = if prefix.is_empty() { segment } else { "\{prefix}/\{segment}" }
    @fs.create_dir(prefix) catch {
      _ => ()
    }
  }
}

///|
/// Export the example IR, compile the generated sources with clang, append
/// the binary to the exported file map, and package the deterministic FMU.
/// Returns the FMU bytes and the export result.
fn build_source_fmu(
  version : @schema.FmiVersion,
  tag : String,
) -> (Bytes, @export.ExportResult) {
  let ir = @export.dahlquist_example_ir()
  let options = @export.ExportOptions::new(
    fmi_version=version,
    output_dir=Some(".moonfmi-tmp/export-\{tag}-\{@env.now()}"),
  )
  let result = @export.export_source_fmu(ir, options) catch {
    error => abort("export failed: " + error.message())
  }
  // The generated modelDescription.xml must pass MoonFMI's own parser and
  // semantic validator before any binary is built.
  let xml_bytes = result.files[0].1
  let (_, report) = @schema.parse_and_validate(xml_bytes)
  if report.error_count() > 0 {
    abort(
      "generated modelDescription.xml failed validation: \{report.diagnostics[0].render()}",
    )
  }
  // Compile (E-06). The exported layout already contains sources/.
  let (platform, entry_file, ext) = match version {
    @schema.FmiVersion::V2 => ("win64", "fmi2Functions.c", "dll")
    @schema.FmiVersion::V3 => ("x86_64-windows", "fmi3Functions.c", "dll")
  }
  let binary_path = "\{result.output_dir}/binaries/\{platform}/MoonfmiDahlquist.\{ext}"
  ensure_test_dir("\{result.output_dir}/binaries/\{platform}")
  let command = "clang -O1 -shared -o \"\{binary_path}\" \"\{result.output_dir}/sources/moonfmi_model.c\" \"\{result.output_dir}/sources/\{entry_file}\""
  if run_shell(command) != 0L {
    abort("clang failed: \{command}")
  }
  let binary = @fs.read_file_to_bytes(binary_path) catch {
    error => abort("reading compiled binary failed: " + io_message(error))
  }
  // Package: exported files + the platform binary, deterministic ZIP (E-08).
  let entries : Array[(String, Bytes)] = []
  for entry in result.files {
    entries.push(entry)
  }
  entries.push(("binaries/\{platform}/MoonfmiDahlquist.\{ext}", binary))
  let archive = @zip.build_deterministic_zip(entries) catch {
    error => abort("packaging failed: " + error.message())
  }
  (archive, result)
}

///|
fn load_source_fmu(data : Bytes, tag : String) -> @native_backend.LoadedFmu2 {
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let directory = absolute_path(".moonfmi-tmp/load-\{tag}-\{@env.now()}")
  let platform = host()
  @native_backend.load_fmi2_fmu(data, host=platform, temp_directory=directory) catch {
    error => abort("loading exported FMU failed: " + error.message())
  }
}

///|
test "exported fmi2 cs source fmu matches the analytic discrete solution" {
  match compiler_probe_skip() {
    Some(reason) => {
      println("SKIP: \{reason}")
      return
    }
    None => ()
  }
  let (archive, _) = build_source_fmu(@schema.FmiVersion::V2, "fmi2-cs")
  let loaded = load_source_fmu(archive, "fmi2-cs")
  // Value references follow IR declaration order: k = 0, x = 1, y = 2.
  let config = @sim.CsConfig::new(
    start_time=0.0,
    stop_time=1.0,
    step_size=0.1,
    record=[1U, 2U],
  )
  let result = @sim.run_cs_simulation(loaded.instance(), config~) catch {
    error => {
      let detail = error.message()
      loaded.dispose()
      abort("simulation failed: " + detail)
    }
  }
  assert_eq(result.steps(), 10)
  // The generated CS FMU applies one explicit Euler step per communication
  // interval, so x_n = (1 - k*h)^n exactly, like Reference-FMUs' Dahlquist.
  let mut x = 1.0
  for n in 0..<=10 {
    let actual = result.series()[0][n]
    assert_true(
      (actual - x).abs() <= 0.000000000001,
      msg="x[\{n}] = \{actual}, expected \{x}",
    )
    let y = result.series()[1][n]
    assert_true((y - x).abs() <= 0.000000000001, msg="y[\{n}] must track x")
    x = x * 0.9
  }
  loaded.dispose()
}

///|
test "exported fmi2 me source fmu matches rk4 against the exponential" {
  match compiler_probe_skip() {
    Some(reason) => {
      println("SKIP: \{reason}")
      return
    }
    None => ()
  }
  let (archive, _) = build_source_fmu(@schema.FmiVersion::V2, "fmi2-me")
  let data = archive
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let directory = absolute_path(".moonfmi-tmp/load-me-\{@env.now()}")
  let loaded = @native_backend.load_fmi2_me_fmu(
    data,
    host=host(),
    temp_directory=directory,
  ) catch {
    error => abort("loading exported ME FMU failed: " + error.message())
  }
  let config = @sim.MeConfig::new(
    start_time=0.0,
    stop_time=1.0,
    step_size=0.1,
    record=[1U],
    solver=@sim.MeSolver::Rk4,
    state_count=1,
    event_indicator_count=0,
  )
  let result = @sim.run_me_simulation(loaded.instance(), config~) catch {
    error => {
      let detail = error.message()
      loaded.dispose()
      abort("ME simulation failed: " + detail)
    }
  }
  assert_eq(result.steps(), 10)
  // RK4 for x' = -x at h = 0.1 sits within ~1e-7 of e^{-t}.
  let expected = 0.36787944117144233
  let actual = result.series()[0][10]
  assert_true(
    (actual - expected).abs() <= 0.00001,
    msg="x(1) = \{actual}, expected e^-1 = \{expected}",
  )
  loaded.dispose()
}

///|
test "exported fmi3 cs source fmu matches the analytic discrete solution" {
  match compiler_probe_skip() {
    Some(reason) => {
      println("SKIP: \{reason}")
      return
    }
    None => ()
  }
  let (archive, _) = build_source_fmu(@schema.FmiVersion::V3, "fmi3-cs")
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let directory = absolute_path(".moonfmi-tmp/load-fmi3-\{@env.now()}")
  let loaded = @native_backend.load_fmi3_fmu(
    archive,
    host=host(),
    temp_directory=directory,
  ) catch {
    error => abort("loading exported FMI 3 FMU failed: " + error.message())
  }
  let config = @sim.CsConfig::new(
    start_time=0.0,
    stop_time=1.0,
    step_size=0.1,
    record=[1U],
  )
  let result = @sim.run_cs_simulation(loaded.instance(), config~) catch {
    error => {
      let detail = error.message()
      loaded.dispose()
      abort("FMI 3 simulation failed: " + detail)
    }
  }
  assert_eq(result.steps(), 10)
  let mut x = 1.0
  for n in 0..<=10 {
    let actual = result.series()[0][n]
    assert_true(
      (actual - x).abs() <= 0.000000000001,
      msg="fmi3 x[\{n}] = \{actual}, expected \{x}",
    )
    x = x * 0.9
  }
  loaded.dispose()
}

///|
test "source export is byte-for-byte deterministic" {
  // E-08: the same IR exported twice must produce identical archives. The
  // GUID derives from the IR hash and the ZIP writer fixes timestamps and
  // order, so no clock or platform detail can leak in.
  let first = @export.export_source_fmu(
    @export.dahlquist_example_ir(),
    @export.ExportOptions::new(
      fmi_version=@schema.FmiVersion::V3,
      output_dir=Some(".moonfmi-tmp/export-det-a-\{@env.now()}"),
    ),
  ) catch {
    error => abort("export failed: " + error.message())
  }
  let second = @export.export_source_fmu(
    @export.dahlquist_example_ir(),
    @export.ExportOptions::new(
      fmi_version=@schema.FmiVersion::V3,
      output_dir=Some(".moonfmi-tmp/export-det-b-\{@env.now()}"),
    ),
  ) catch {
    error => abort("export failed: " + error.message())
  }
  let sha_a = first.sha256.unwrap_or("missing")
  let sha_b = second.sha256.unwrap_or("missing")
  assert_eq(sha_a, sha_b)
  assert_true(sha_a.length() == 64)
  // The packaged FMU survives a full read-back through MoonFMI's own reader
  // (D-06 behaviour, applied to exported output).
  let fmu_bytes = @fs.read_file_to_bytes(first.fmu_path.unwrap_or("")) catch {
    error => abort("reading exported FMU failed: " + io_message(error))
  }
  let archive = @zip.ZipArchive::open(fmu_bytes) catch {
    error => abort("exported FMU is not a valid zip: " + error.message())
  }
  assert_true(archive.contains("modelDescription.xml"))
  assert_true(archive.contains("buildDescription.xml"))
  assert_true(archive.contains("sources/fmi3Functions.c"))
}

///|
test "exported fmi3 array passthrough roundtrips u[3]" {
  match compiler_probe_skip() {
    Some(reason) => {
      println("SKIP: \{reason}")
      return
    }
    None => ()
  }
  let ir = @export.array_passthrough_example_ir()
  let options = @export.ExportOptions::new(
    fmi_version=@schema.FmiVersion::V3,
    output_dir=Some(".moonfmi-tmp/export-array-\{@env.now()}"),
  )
  let result = @export.export_source_fmu(ir, options) catch {
    error => abort("export failed: " + error.message())
  }
  let binary_path = "\{result.output_dir}/binaries/x86_64-windows/MoonfmiArrayPassthrough.dll"
  ensure_test_dir("\{result.output_dir}/binaries/x86_64-windows")
  let command = "clang -O1 -shared -o \"\{binary_path}\" \"\{result.output_dir}/sources/moonfmi_model.c\" \"\{result.output_dir}/sources/fmi3Functions.c\""
  if run_shell(command) != 0L {
    abort("clang failed: \{command}")
  }
  let binary = @fs.read_file_to_bytes(binary_path) catch {
    error => abort("reading compiled binary failed: " + io_message(error))
  }
  let entries : Array[(String, Bytes)] = []
  for entry in result.files {
    entries.push(entry)
  }
  entries.push(("binaries/x86_64-windows/MoonfmiArrayPassthrough.dll", binary))
  let archive = @zip.build_deterministic_zip(entries) catch {
    error => abort("packaging failed: " + error.message())
  }
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let directory = absolute_path(".moonfmi-tmp/load-array-\{@env.now()}")
  let platform = host()
  let loaded = @native_backend.load_fmi3_fmu(
    archive,
    host=platform,
    temp_directory=directory,
  ) catch {
    error => abort("loading array FMU failed: " + error.message())
  }
  let instance = loaded.instance()
  // Initialize through the CS trait so the event-mode settlement runs.
  instance.initialize() catch {
    error => abort("initialize failed: " + error.message())
  }
  // Array write/read roundtrip through the real FMI 3 ABI: sizes and
  // offsets must match the Dimension elements in the model description.
  instance.set_float64([0U], [4.0, 5.0, 6.0]) catch {
    error => abort("set u failed: " + error.message())
  }
  let u = instance.get_float64_values([0U], 3) catch {
    error => abort("get u failed: " + error.message())
  }
  assert_true(
    u[0] == 4.0 && u[1] == 5.0 && u[2] == 6.0,
    msg="u roundtrip: \{u}",
  )
  let y = instance.get_float64_values([1U], 3) catch {
    error => abort("get y failed: " + error.message())
  }
  assert_eq(y.length(), 3)
  loaded.dispose()
}

///|
test "wasm fmu packaging layout validates (F-07)" {
  // Produced by `node tests/fmu-wasm/run.mjs package`; skip when the node
  // toolchain has not run.
  let data = @fs.read_file_to_bytes("tests/fmu-wasm/.cache/MoonfmiAdder.fmu") catch {
    _ => {
      println(
        "SKIP: tests/fmu-wasm/.cache/MoonfmiAdder.fmu not built; run node tests/fmu-wasm/run.mjs package",
      )
      return
    }
  }
  let archive = @zip.ZipArchive::open(data) catch {
    error => abort("wasm fmu is not a valid zip: " + error.message())
  }
  assert_true(archive.contains("modelDescription.xml"))
  assert_true(archive.contains("binaries/wasm32-wasip2/MoonfmiAdder.wasm"))
  assert_true(archive.contains("extra/org.modelica.fmi-ls-wasm/manifest.xml"))
  // The generated model description must pass MoonFMI's own parser and
  // semantic rules, exactly like a native FMU.
  let xml = archive.read("modelDescription.xml")
  let (_, report) = @schema.parse_and_validate(xml)
  assert_eq(report.error_count(), 0)
  if report.error_count() > 0 {
    abort(
      "wasm fmu model description failed: \{report.diagnostics[0].render()}",
    )
  }
}

///|
/// C-09: FMI 2 FMU state save/restore against the real Dahlquist FMU
/// (canGetAndSetFMUstate="true", canSerializeFMUstate="true"), plus the
/// explicit capability-missing error on the exported FMU (which declares
/// canGetAndSetFMUstate="false").
test "fmi2 fmu state roundtrip and capability missing" {
  let data = @fs.read_file_to_bytes(fmu_path("fmi2/Dahlquist.fmu")) catch {
    error => abort("reading Dahlquist failed: " + io_message(error))
  }
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let directory = absolute_path(".moonfmi-tmp/fmu-state-\{@env.now()}")
  let platform = host()
  let loaded = @native_backend.load_fmi2_fmu(
    data,
    host=platform,
    temp_directory=directory,
  ) catch {
    error => abort("loading Dahlquist failed: " + error.message())
  }
  let instance = loaded.instance()
  assert_true(instance.supports_fmu_state(), msg="Dahlquist supports fmu state")
  assert_true(
    instance.supports_serialized_fmu_state(),
    msg="Dahlquist supports serialized fmu state",
  )
  instance.setup_experiment(start_time=0.0) catch {
    error => abort("setup failed: " + error.message())
  }
  instance.initialize() catch {
    error => abort("init failed: " + error.message())
  }
  // Three steps of 0.1: x = 0.9^3.
  for t in 0..<3 {
    instance.step(t.to_double() * 0.1, 0.1) catch {
      error => abort("step failed: " + error.message())
    }
  }
  let captured = instance.get_fmu_state() catch {
    error => abort("get state failed: " + error.message())
  }
  let before_restore = instance.read_real(1U) catch {
    error => abort("read failed: " + error.message())
  }
  let expected = 0.9 * 0.9 * 0.9
  assert_true(
    (before_restore - expected).abs() <= 0.000000000001,
    msg="x after 3 steps = \{before_restore}",
  )
  // Advance further, then rewind to the captured state.
  instance.step(0.3, 0.1) catch {
    error => abort("step failed: " + error.message())
  }
  instance.step(0.4, 0.1) catch {
    error => abort("step failed: " + error.message())
  }
  instance.set_fmu_state(captured) catch {
    error => abort("set state failed: " + error.message())
  }
  let after_restore = instance.read_real(1U) catch {
    error => abort("read failed: " + error.message())
  }
  assert_true(
    (after_restore - expected).abs() <= 0.000000000001,
    msg="rewound x = \{after_restore}, expected \{expected}",
  )
  // Byte-level serialization roundtrip; the binding sizes the buffer via
  // the FMU's size query when present, growing it otherwise.
  let buffer = instance.serialize_fmu_state(captured) catch {
    error => abort("serialize failed: " + error.message())
  }
  assert_true(buffer.length() > 0, msg="serialized \{buffer.length()} bytes")
  let restored = instance.deserialize_fmu_state(buffer) catch {
    error => abort("deserialize failed: " + error.message())
  }
  instance.set_fmu_state(restored) catch {
    error => abort("set restored state failed: " + error.message())
  }
  let after_deserialize = instance.read_real(1U) catch {
    error => abort("read failed: " + error.message())
  }
  assert_true(
    (after_deserialize - expected).abs() <= 0.000000000001,
    msg="deserialized x = \{after_deserialize}",
  )
  instance.free_fmu_state(captured) catch {
    error => abort("free failed: " + error.message())
  }
  instance.free_fmu_state(restored) catch {
    error => abort("free failed: " + error.message())
  }
  loaded.dispose()
}

///|
test "exported fmi2 fmu reports missing fmu state capability" {
  match compiler_probe_skip() {
    Some(reason) => {
      println("SKIP: \{reason}")
      return
    }
    None => ()
  }
  let (archive, _) = build_source_fmu(@schema.FmiVersion::V2, "fmu-state-cap")
  let loaded = load_source_fmu(archive, "fmu-state-cap")
  let instance = loaded.instance()
  assert_false(
    instance.supports_fmu_state(),
    msg="exported FMU has no state group",
  )
  let outcome : Result[Unit, @native_backend.Fmi2Error] = try {
    let state = instance.get_fmu_state()
    instance.free_fmu_state(state)
    Ok(())
  } catch {
    error => Err(error)
  }
  match outcome {
    Ok(_) => abort("capability-missing call must fail")
    Err(error) =>
      assert_true(
        error.message().contains("canGetAndSetFMUstate"),
        msg="error names the capability: \{error.message()}",
      )
  }
  loaded.dispose()
}

///|
/// F-08: the WASM exporter's tree must build with the external component
/// toolchain and package a loadable-by-inspection FMU. Skips when node or
/// wit-bindgen is absent (the main gate never depends on them).
test "wasm export builds a component fmu end to end" {
  if run_shell("node --version") != 0L {
    println("SKIP: node not on PATH")
    return
  }
  if run_shell("wit-bindgen --version") != 0L &&
    run_shell("\"%USERPROFILE%/.moonfmi/bin/wit-bindgen.exe\" --version") != 0L {
    println("SKIP: wit-bindgen not available")
    return
  }
  let ir = @export.dahlquist_example_ir()
  let result = @export.export_wasm_fmu(
    ir,
    @export.ExportOptions::new(
      fmi_version=@schema.FmiVersion::V3,
      output_dir=Some(".moonfmi-tmp/wasm-e2e-\{@env.now()}"),
      write_fmu=false,
    ),
  ) catch {
    error => abort("wasm export failed: " + error.message())
  }
  let command = "node tests/fmu-wasm/run.mjs build-export \"\{result.output_dir}\""
  if run_shell(command) != 0L {
    abort("wasm build failed: " + command)
  }
  let fmu_path = "\{result.output_dir}/MoonfmiDahlquist.fmu"
  let data = @fs.read_file_to_bytes(fmu_path) catch {
    error => abort("reading built wasm fmu failed: " + io_message(error))
  }
  let archive = @zip.ZipArchive::open(data) catch {
    error => abort("wasm fmu is not a valid zip: " + error.message())
  }
  assert_true(archive.contains("modelDescription.xml"))
  assert_true(archive.contains("binaries/wasm32-wasip2/MoonfmiDahlquist.wasm"))
  assert_true(archive.contains("extra/org.modelica.fmi-ls-wasm/manifest.xml"))
  let xml = archive.read("modelDescription.xml")
  let (_, report) = @schema.parse_and_validate(xml)
  assert_eq(report.error_count(), 0)
  if report.error_count() > 0 {
    abort("wasm model description failed: \{report.diagnostics[0].render()}")
  }
}
