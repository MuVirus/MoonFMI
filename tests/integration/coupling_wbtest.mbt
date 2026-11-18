///|
/// Coupling MVP end-to-end: two exported source FMUs (Dahlquist generator
/// and a pure feedthrough gain) coupled through `run_coupled_simulation`.
/// The generator integrates x' = -k*x per communication step (one Euler
/// step of size h, so x_n = (1 - h)^n), and the gain computes y = 2*u from
/// its input. Because the coupled master steps participants in
/// topological order, the recorded gain output at t_n must be exactly
/// 2 * (1 - h)^n — a one-step lag would show up as 2 * (1 - h)^(n-1).
/// Requires a C compiler on PATH (see export_fmu_wbtest.mbt).

///|
/// The gain IR: parameter k = 2, input u, direct-feedthrough output
/// y = k * u. Value references follow declaration order: k = 0, u = 1,
/// y = 2.
fn gain_example_ir() -> @export.ModelIr {
  let ir = @export.ModelIr::new(
    model_name="MoonfmiGain",
    generation_tool="MoonFMI source exporter",
    description="y = k * u feedthrough gain",
  )
  ir.add_interface(
    kind=@schema.InterfaceKind::CoSimulation,
    model_identifier="MoonfmiGain",
  )
  ignore(ir.add_real_parameter(name="k", start=2.0, description="gain factor"))
  ignore(ir.add_real_input(name="u", start=0.0, description="input"))
  ignore(ir.add_real_output(name="y", description="gain output"))
  ir.add_output_equation(
    output="y",
    expr=@export.IrExpr::mul(@export.IrExpr::v("k"), @export.IrExpr::v("u")),
  )
  ir
}

///|
/// Exports the gain IR, compiles it with clang, and packages a
/// deterministic FMU (same pipeline as build_source_fmu).
fn build_gain_fmu(tag : String) -> Bytes {
  let ir = gain_example_ir()
  let options = @export.ExportOptions::new(
    fmi_version=@schema.FmiVersion::V2,
    output_dir=Some(".moonfmi-tmp/export-\{tag}-\{@env.now()}"),
  )
  let result = @export.export_source_fmu(ir, options) catch {
    error => abort("gain export failed: " + error.message())
  }
  let xml_bytes = result.files[0].1
  let (_, report) = @schema.parse_and_validate(xml_bytes)
  if report.error_count() > 0 {
    abort(
      "gain modelDescription.xml failed validation: \{report.diagnostics[0].render()}",
    )
  }
  let host_platform = host()
  let extension = match host_platform.os {
    @fmi.Windows => "dll"
    @fmi.Darwin => "dylib"
    @fmi.Linux => "so"
  }
  let platform = @fmi.fmi2_platform_dir(host_platform)
  let binary_path = "\{result.output_dir}/binaries/\{platform}/MoonfmiGain.\{extension}"
  ensure_test_dir("\{result.output_dir}/binaries/\{platform}")
  let flags = match host_platform.os {
    @fmi.Windows => "-O1 -shared"
    @fmi.Darwin => "-O1 -dynamiclib"
    @fmi.Linux => "-O1 -shared -fPIC"
  }
  let command = "clang \{flags} -o \"\{binary_path}\" \"\{result.output_dir}/sources/moonfmi_model.c\" \"\{result.output_dir}/sources/fmi2Functions.c\""
  if run_shell(command) != 0L {
    abort("clang failed for the gain model: \{command}")
  }
  let binary = @fs.read_file_to_bytes(binary_path) catch {
    error => abort("reading gain binary failed: " + io_message(error))
  }
  let entries : Array[(String, Bytes)] = []
  for entry in result.files {
    entries.push(entry)
  }
  entries.push(("binaries/\{platform}/MoonfmiGain.\{extension}", binary))
  @zip.build_deterministic_zip(entries) catch {
    error => abort("gain packaging failed: " + error.message())
  }
}

///|
test "exported generator and gain couple without a one-step lag" {
  match compiler_probe_skip() {
    Some(reason) => {
      println("SKIP: \{reason}")
      return
    }
    None => ()
  }
  let (generator_bytes, _) = build_source_fmu(
    @schema.FmiVersion::V2,
    "couple-gen",
  )
  let loaded_generator = load_source_fmu(generator_bytes, "couple-gen")
  let gain_bytes = build_gain_fmu("couple-gain")
  let loaded_gain = load_source_fmu(gain_bytes, "couple-gain")
  // Generator VRs: k = 0, x = 1, y = 2. Gain VRs: k = 0, u = 1, y = 2.
  let config = @sim.CoupledConfig::new(
    start_time=0.0,
    stop_time=1.0,
    step_size=0.1,
    participants=[
      @sim.CoupledParticipant::new(
        name="generator",
        instance=loaded_generator.instance(),
        record=[2U],
      ),
      @sim.CoupledParticipant::new(
        name="gain",
        instance=loaded_gain.instance(),
        record=[2U],
      ),
    ],
    connections=[
      @sim.Coupling::new(from="generator", out_vr=2U, to="gain", in_vr=1U),
    ],
  )
  let result = @sim.run_coupled_simulation(config~) catch {
    error => {
      loaded_generator.dispose()
      loaded_gain.dispose()
      abort("coupled simulation failed: " + error.message())
    }
  }
  assert_eq(result.steps(), 10)
  assert_eq(result.times().length(), 11)
  // x_n = (1 - h)^n; the gain output must be exactly twice the generator
  // state at the same communication point (no one-step lag).
  let mut x = 1.0
  for n in 0..<=10 {
    let generator_x = result.series()[0][n]
    let tolerance = 0.000000000001 * (if n == 0 { 1.0 } else { x })
    assert_true(
      (generator_x - x).abs() <= tolerance,
      msg="generator x[\{n}]=\{generator_x}, expected \{x}",
    )
    let gain_y = result.series()[1][n]
    assert_true(
      (gain_y - 2.0 * x).abs() <= tolerance,
      msg="gain y[\{n}]=\{gain_y}, expected \{2.0 * x}",
    )
    x = x * 0.9
  }
  loaded_generator.dispose()
  loaded_gain.dispose()
}
