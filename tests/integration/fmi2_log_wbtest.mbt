///|
/// Test-only memory query implemented by `tests/integration/support.c`.
extern "C" fn resident_bytes() -> Int64 = "moonfmi_test_resident_bytes"

///|
/// Returns freed heap blocks to the operating system so a resident-size
/// comparison measures live data instead of allocator churn.
extern "C" fn trim_memory() -> Unit = "moonfmi_test_trim_memory"

///|
fn open_logging_fmu() -> @native_backend.Fmi2Library {
  let path = fixture_path("libmoonfmi_logging_fmu")
  @native_backend.Fmi2Library::open(path) catch {
    error => abort(error.message())
  }
}

///|
fn logging_instance(
  library : @native_backend.Fmi2Library,
  on_log : (@native_backend.Fmi2LogMessage) -> Unit,
) -> @native_backend.Fmi2Instance raise @native_backend.Fmi2Error {
  let instance = library.instantiate(
    instance_name="fake",
    guid="{00000000-0000-0000-0000-000000000000}",
    resource_path="tests/abi/.cache",
    on_log~,
  )
  instance.setup_experiment(start_time=0.0, stop_time=1.0)
  instance.enter_initialization_mode()
  instance.exit_initialization_mode()
  instance
}

///|
/// Reads the messages emitted by one step with the given kind and count.
fn messages_for_kind(
  kind : Double,
  count : Double,
) -> Array[@native_backend.Fmi2LogMessage] {
  let library = open_logging_fmu()
  let messages : Array[@native_backend.Fmi2LogMessage] = []
  let instance = logging_instance(library, fn(message) {
    messages.push(message)
  }) catch {
    error => abort(error.message())
  }
  messages.clear()
  instance.set_real([0U, 1U], [count, kind]) catch {
    error => abort(error.message())
  }
  let status = instance.do_step(0.0, 0.1)
  if !(status is Ok) {
    abort("fmi2DoStep returned " + status.name())
  }
  instance.free()
  library.close() catch {
    error => abort(error.message())
  }
  messages
}

///|
test "log messages arrive during initialization, steps and release" {
  let library = open_logging_fmu()
  let messages : Array[@native_backend.Fmi2LogMessage] = []
  let instance = library.instantiate(
    instance_name="fake",
    guid="{00000000-0000-0000-0000-000000000000}",
    resource_path="tests/abi/.cache",
    on_log=fn(message) { messages.push(message) },
  )
  assert_eq(messages.length(), 1)
  assert_eq(messages[0].message, "instantiated")
  assert_eq(messages[0].instance_name, "fake")
  assert_eq(messages[0].category, "init")
  assert_true(messages[0].status is Ok)
  instance.setup_experiment(start_time=0.0, stop_time=1.0)
  instance.enter_initialization_mode()
  instance.exit_initialization_mode()
  assert_eq(messages.length(), 2)
  assert_eq(messages[1].message, "initialized")
  let status = instance.do_step(0.0, 0.1)
  assert_true(status is Ok)
  assert_eq(messages.length(), 3)
  assert_eq(messages[2].message, "step 1")
  assert_eq(messages[2].category, "step")
  // The fake FMU logs from `fmi2FreeInstance`; that message must be dropped.
  instance.free()
  assert_eq(messages.length(), 3)
  assert_true(instance.is_freed())
  library.close()
}

///|
test "Chinese and emoji survive the log round trip byte for byte" {
  let messages = messages_for_kind(2.0, 1.0)
  assert_eq(messages.length(), 1)
  let expected = "中文🙂 你好，世界 — Ünïcode"
  assert_eq(messages[0].message, expected)
  assert_eq(
    @utf8.encode(messages[0].message).length(),
    @utf8.encode(expected).length(),
  )
}

///|
test "an 8 KB message is truncated to 4 KB" {
  let messages = messages_for_kind(1.0, 1.0)
  assert_eq(messages.length(), 1)
  let text = messages[0].message
  assert_eq(@utf8.encode(text).length(), 4096)
  assert_eq(text.length(), 4096)
  let expected = "a".repeat(4096)
  assert_eq(text, expected)
}

///|
test "truncation backs off to a UTF-8 character boundary" {
  // 4094 bytes then a 3-byte character: cutting at 4096 would split it.
  let three = messages_for_kind(3.0, 1.0)
  assert_eq(@utf8.encode(three[0].message).length(), 4094)
  assert_eq(three[0].message, "a".repeat(4094))
  // 4093 bytes then a 4-byte emoji: the cut lands inside the emoji.
  let four = messages_for_kind(4.0, 1.0)
  assert_eq(@utf8.encode(four[0].message).length(), 4093)
  assert_eq(four[0].message, "a".repeat(4093))
  // Exactly 4096 bytes is not truncated at all.
  let exact = messages_for_kind(5.0, 1.0)
  assert_eq(@utf8.encode(exact[0].message).length(), 4096)
  assert_eq(exact[0].message, "b".repeat(4096))
  for message in [three[0], four[0], exact[0]] {
    assert_false(message.message.contains("\u{FFFD}"))
  }
}

///|
test "logging from the FMU's own thread does not crash" {
  let messages = messages_for_kind(6.0, 1.0)
  assert_eq(messages.length(), 1)
  assert_eq(messages[0].category, "thread")
  assert_eq(messages[0].message, "from the FMU thread")
}

///|
test "ten thousand log messages do not accumulate memory" {
  let library = open_logging_fmu()
  let mut received = 0
  let mut last_length = 0
  let instance = logging_instance(library, fn(message) {
    received = received + 1
    last_length = @utf8.encode(message.message).length()
  }) catch {
    error => abort(error.message())
  }
  // One round to warm up allocator arenas and the runtime, then compare the
  // resident set size across a steady-state burst of 4 KB messages. The size
  // matters: a leak of a whole message buffer is 200 MB across 50,000
  // messages, far above the noise a refcounting run can add.
  instance.set_real([0U, 1U], [100.0, 0.0]) catch {
    error => abort(error.message())
  }
  for step in 0..<100 {
    let status = instance.do_step(step.to_double() * 0.1, 0.1)
    if !(status is Ok) {
      abort("warm-up step returned " + status.name())
    }
  }
  assert_eq(received, 10002)
  trim_memory()
  let before = resident_bytes()
  instance.set_real([1U], [5.0]) catch {
    error => abort(error.message())
  }
  for step in 0..<500 {
    let status = instance.do_step(100.0 + step.to_double() * 0.1, 0.1)
    if !(status is Ok) {
      abort("stress step returned " + status.name())
    }
  }
  trim_memory()
  let after = resident_bytes()
  assert_eq(received, 60002)
  assert_eq(last_length, 4096)
  let growth = after - before
  if growth > 48 * 1024 * 1024 {
    abort(
      "resident memory grew by " +
      growth.to_string() +
      " bytes across 50,000 four-kilobyte log messages",
    )
  }
  instance.free()
  library.close()
}
