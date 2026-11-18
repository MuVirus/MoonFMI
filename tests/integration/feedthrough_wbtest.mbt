///|
/// C-08 leftovers: FMI 2 Integer/Boolean get/set bindings (task C-08's
/// "typed channels" criterion). The Reference-FMUs `Feedthrough` model
/// passes every input type straight through to the output, so a
/// set → step → get roundtrip pins both directions of each channel.

///|
/// Loads the Feedthrough FMU as a Co-Simulation instance.
fn open_feedthrough() -> @native_backend.LoadedFmu2 {
  let data = @fs.read_file_to_bytes(fmu_path("fmi2/Feedthrough.fmu")) catch {
    error => abort("reading Feedthrough failed: " + io_message(error))
  }
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let directory = absolute_path(".moonfmi-tmp/feedthrough-\{@env.now()}")
  let host = match
    @fmi.parse_host_platform(@native_backend.host_platform_name()) {
    Some(host) => host
    None => abort("unknown host platform")
  }
  @native_backend.load_fmi2_fmu(data, host~, temp_directory=directory) catch {
    error => abort("loading Feedthrough failed: " + error.message())
  }
}

///|
test "fmi2 integer channel roundtrips through feedthrough" {
  let loaded = open_feedthrough()
  let instance = loaded.instance()
  // Int32_input / Int32_output per the model description; vr 7 is the
  // Float64_continuous_input used as a companion Real write.
  instance.set_integer_one(19U, 7)
  instance.set_real_one(7U, 2.5)
  instance.setup_experiment(start_time=0.0, stop_time=1.0)
  instance.enter_initialization_mode()
  instance.exit_initialization_mode()
  let status = instance.do_step(0.0, 0.1)
  assert_true(status is Ok)
  assert_eq(instance.get_integer_one(20U), 7)
  // A second value while the run continues, so the channel is live.
  instance.set_integer_one(19U, -3)
  let status2 = instance.do_step(0.1, 0.1)
  assert_true(status2 is Ok)
  assert_eq(instance.get_integer_one(20U), -3)
  // Array form works too.
  assert_eq(instance.get_integer([19U, 20U]), [-3, -3])
  loaded.dispose()
}

///|
test "zz boolean channel" {
  let loaded = open_feedthrough()
  let instance = loaded.instance()
  // Boolean_input / Boolean_output per the model description.
  instance.set_boolean_one(27U, true)
  instance.setup_experiment(start_time=0.0, stop_time=1.0)
  instance.enter_initialization_mode()
  instance.exit_initialization_mode()
  let status = instance.do_step(0.0, 0.1)
  assert_true(status is Ok)
  assert_true(instance.get_boolean_one(28U))
  instance.set_boolean_one(27U, false)
  let status2 = instance.do_step(0.1, 0.1)
  assert_true(status2 is Ok)
  assert_false(instance.get_boolean_one(28U))
  assert_eq(instance.get_boolean([27U, 28U]), [false, false])
  loaded.dispose()
}

///|
test "zz mismatch" {
  let loaded = open_feedthrough()
  let instance = loaded.instance()
  let mut rejected = false
  instance.set_integer([19U], [1, 2]) catch {
    _ => rejected = true
  }
  assert_true(rejected)
  let mut rejected_boolean = false
  instance.set_boolean([27U, 28U], [true]) catch {
    _ => rejected_boolean = true
  }
  assert_true(rejected_boolean)
  loaded.dispose()
}
