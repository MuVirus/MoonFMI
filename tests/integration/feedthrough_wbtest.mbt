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
  let mut rejected_string = false
  instance.set_string([29U], ["a", "b"]) catch {
    _ => rejected_string = true
  }
  assert_true(rejected_string)
  loaded.dispose()
}

///|
test "fmi2 string channel roundtrips through feedthrough" {
  let loaded = open_feedthrough()
  let instance = loaded.instance()
  // String_input vr 29 -> String_output vr 30; non-ASCII content exercises
  // the UTF-8 copy in the shim and the UTF-8 decode on the MoonBit side.
  let text = "你好，world 🎯"
  instance.set_string_one(29U, text)
  instance.setup_experiment(start_time=0.0, stop_time=1.0)
  instance.enter_initialization_mode()
  instance.exit_initialization_mode()
  let status = instance.do_step(0.0, 0.1)
  assert_true(status is Ok)
  assert_eq(instance.get_string_one(30U), text)
  // A second value while the run continues; the channel stays live.
  instance.set_string_one(29U, "二次写入")
  let status2 = instance.do_step(0.1, 0.1)
  assert_true(status2 is Ok)
  assert_eq(instance.get_string_one(30U), "二次写入")
  // Array form: input and output read in one call.
  assert_eq(instance.get_string([29U, 30U]), ["二次写入", "二次写入"])
  loaded.dispose()
}

///|
test "fmi3 string channel roundtrips through feedthrough" {
  let loaded = load_fmi3("fmi3/Feedthrough.fmu", "fmi3-ft-string")
  let instance = loaded.instance()
  instance.setup_experiment(start_time=0.0, stop_time=1.0)
  init_fmi3_cs(instance)
  let text = "字符串 🎯 roundtrip"
  instance.set_string([29U], [text])
  instance.step(0.0, 0.1)
  assert_eq(instance.get_string([30U]), [text])
  instance.terminate()
  loaded.dispose()
}

///|
test "fmi3 binary channel roundtrips through feedthrough" {
  let loaded = load_fmi3("fmi3/Feedthrough.fmu", "fmi3-ft-binary")
  let instance = loaded.instance()
  instance.setup_experiment(start_time=0.0, stop_time=1.0)
  init_fmi3_cs(instance)
  // Raw bytes with an embedded NUL: copied by length, never interpreted as
  // UTF-8 or C text, and not truncated at the NUL byte.
  let payload = b"bin\x00ary 中"
  instance.set_binary([31U], [payload])
  instance.step(0.0, 0.1)
  assert_eq(instance.get_binary([32U]), [payload])
  instance.terminate()
  loaded.dispose()
}
