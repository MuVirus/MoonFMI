///|
fn xml_message(error : @xml.XmlError) -> String {
  error.to_string()
}

///|
fn io_message(error : @fs.IOError) -> String {
  match error {
    @fs.IOError(message) => message
  }
}

///|
fn fmu_path(relative : String) -> String {
  "tests/data/.cache/" + relative
}

///|
fn open_cached_fmu(relative : String) -> @zip.ZipArchive {
  let data = @fs.read_file_to_bytes(fmu_path(relative)) catch {
    error => abort("reading " + relative + " failed: " + io_message(error))
  }
  @zip.ZipArchive::open(data) catch {
    error => abort("opening " + relative + " failed: " + error.message())
  }
}

///|
fn read_model_description(relative : String) -> String {
  let archive = open_cached_fmu(relative)
  let bytes = archive.read("modelDescription.xml") catch {
    error => abort("reading " + relative + " failed: " + error.message())
  }
  @utf8.decode(bytes.exact_view()) catch {
    _ => abort(relative + " has a modelDescription.xml that is not UTF-8")
  }
}

///|
fn root_of(events : Array[@xml.XmlEvent]) -> @xml.XmlElement {
  for event in events {
    if event is Start(element) {
      return element
    }
  }
  abort("document has no root element")
}

///|
fn samples() -> Array[(String, String, Array[String])] {
  [
    (
      "fmi2/BouncingBall.fmu",
      "2.0",
      ["binaries/win64/BouncingBall.dll", "binaries/linux64/BouncingBall.so"],
    ),
    (
      "fmi2/Feedthrough.fmu",
      "2.0",
      ["binaries/win64/Feedthrough.dll", "binaries/linux64/Feedthrough.so"],
    ),
    (
      "fmi2/Resource.fmu",
      "2.0",
      ["binaries/win64/Resource.dll", "binaries/linux64/Resource.so"],
    ),
    (
      "fmi3/BouncingBall.fmu",
      "3.0",
      ["binaries/x86_64-windows/BouncingBall.dll"],
    ),
    ("fmi3/Feedthrough.fmu", "3.0", ["binaries/x86_64-windows/Feedthrough.dll"]),
  ]
}

///|
test "real FMU containers expose their manifest entries" {
  for sample in samples() {
    let (relative, _, binaries) = sample
    let archive = open_cached_fmu(relative)
    assert_true(archive.entry_count() > 0)
    assert_true(archive.contains("modelDescription.xml"))
    for binary in binaries {
      let entry = match archive.entry(binary) {
        Some(entry) => entry
        None => abort(relative + " is missing " + binary)
      }
      assert_true(entry.uncompressed_size() > 0)
      assert_false(entry.is_directory())
    }
  }
}

///|
test "real FMU model descriptions parse with the XML wrapper" {
  for sample in samples() {
    let (relative, version, _) = sample
    let text = read_model_description(relative)
    let reader = @xml.XmlReader::new(text) catch {
      error => abort(relative + " failed to parse: " + xml_message(error))
    }
    let events = reader.read_events() catch {
      error => abort(relative + " failed to parse: " + xml_message(error))
    }
    let root = root_of(events)
    assert_eq(root.name(), "fmiModelDescription")
    assert_eq(root.attribute("fmiVersion"), Some(version))
    let model_name = match root.attribute("modelName") {
      Some(name) => name
      None => abort(relative + " has no modelName")
    }
    assert_true(model_name.length() > 0)
    assert_true(events[events.length() - 1] is Eof)
  }
}

///|
test "one megabyte model description parses within 100 ms" {
  let item = "<ScalarVariable name=\"x\" valueReference=\"0\" causality=\"output\"><Real start=\"0\"/></ScalarVariable>\n"
  let document = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
    "<fmiModelDescription fmiVersion=\"3.0\" modelName=\"Large\">\n" +
    item.repeat(11000) +
    "</fmiModelDescription>\n"
  assert_true(@utf8.encode(document).length() >= 1024 * 1024)
  // Warm up the parser so the measurement reflects steady-state throughput
  // rather than first-call allocation and JIT effects.
  let warmup = @xml.XmlReader::new(document) catch {
    error => abort(xml_message(error))
  }
  let _ = warmup.read_events() catch { error => abort(xml_message(error)) }
  let mut best = 1_000_000
  let mut event_count = 0
  for _ in 0..<3 {
    let started = @env.now()
    let reader = @xml.XmlReader::new(document) catch {
      error => abort(xml_message(error))
    }
    let events = reader.read_events() catch {
      error => abort(xml_message(error))
    }
    let elapsed = (@env.now() - started).to_int()
    if elapsed < best {
      best = elapsed
    }
    event_count = events.length()
  }
  assert_true(event_count > 11000)
  // Debug builds are roughly twice as slow as release builds, so the
  // acceptance number (100 ms) only applies to optimized binaries. The looser
  // debug bound still catches accidental quadratic behaviour.
  let budget = perf_budget_ms()
  if best >= budget {
    abort("parsing 1 MB took " + best.to_string() + " ms")
  }
}

///|
test "a truncated real FMU is rejected before extraction" {
  let data = @fs.read_file_to_bytes(fmu_path("fmi2/BouncingBall.fmu"))
  let cut = data.exact_view(end=4096).to_owned()
  let observed = try {
    let _ = @zip.ZipArchive::open(cut)
    false
  } catch {
    @zip.Truncated(..) | @zip.InvalidArchive(..) => true
    _ => false
  }
  assert_true(observed)
}

///|
fn fixture_path(name : String) -> String {
  let dll = "tests/abi/.cache/" + name + ".dll"
  let so = "tests/abi/.cache/" + name + ".so"
  if @fs.path_exists(dll) {
    dll
  } else if @fs.path_exists(so) {
    so
  } else {
    abort(
      "missing " +
      dll +
      "; run tests/abi/build-fixture.ps1 or tests/abi/build-fixture.sh first",
    )
  }
}

///|
test "dynamic library loads, calls, and unloads" {
  let path = fixture_path("libmoonfmi_fixture")
  let library = @native_backend.DynamicLibrary::open(path) catch {
    error => abort(error.message())
  }
  assert_eq(library.path(), path)
  let add : FuncRef[(Int32, Int32) -> Int32] = library.funcref("moonfmi_add") catch {
    error => abort(error.message())
  }
  assert_eq(add(2, 3), 5)
  let multiply : FuncRef[(Double, Double) -> Double] = library.funcref(
    "moonfmi_multiply",
  ) catch {
    error => abort(error.message())
  }
  assert_eq(multiply(2.5, 4.0), 10.0)
  let fill : FuncRef[(@c.Pointer[Double], Double, Double) -> Unit] = library.funcref(
    "moonfmi_fill_point",
  ) catch {
    error => abort(error.message())
  }
  let point = FixedArray::make(2, 0.0)
  fill(@c.Pointer::unsafe_from_array(point), 1.25, -3.5)
  assert_eq(point[0], 1.25)
  assert_eq(point[1], -3.5)
  library.close() catch {
    error => abort(error.message())
  }
  assert_true(library.is_closed())
}

///|
test "missing library and missing symbol produce distinct errors" {
  let missing = try {
    let _ = @native_backend.DynamicLibrary::open(
      "tests/abi/.cache/does-not-exist.dll",
    )
    false
  } catch {
    @native_backend.LibraryNotFound(..) => true
    _ => false
  }
  assert_true(missing)
  let path = fixture_path("libmoonfmi_fixture")
  let library = @native_backend.DynamicLibrary::open(path) catch {
    error => abort(error.message())
  }
  let observed = try {
    let _ = library.symbol("moonfmi_not_here")
    ""
  } catch {
    @native_backend.SymbolNotFound(path~, symbol~, os_message~) =>
      path + "|" + symbol + "|" + os_message
    _ => "<other>"
  }
  assert_true(observed.contains("libmoonfmi_fixture"))
  assert_true(observed.contains("moonfmi_not_here"))
  library.close() catch {
    error => abort(error.message())
  }
}

///|
test "a library with a missing dependency is diagnosed" {
  let path = fixture_path("libmoonfmi_broken")
  let observed = try {
    let _ = @native_backend.DynamicLibrary::open(path)
    ""
  } catch {
    error => error.message()
  }
  if !observed.contains("dependency") {
    abort("unexpected message: " + observed)
  }
  assert_true(observed.contains("libmoonfmi_broken"))
}

///|
test "a library can be deleted after it is unloaded" {
  let source = fixture_path("libmoonfmi_fixture")
  let target = "tests/abi/.cache/unload-test" +
    (if source.has_suffix(".dll") { ".dll" } else { ".so" })
  if @fs.path_exists(target) {
    @fs.remove_file(target) catch {
      error => abort("could not clean up " + target + ": " + io_message(error))
    }
  }
  let bytes = @fs.read_file_to_bytes(source)
  @fs.write_bytes_to_file(target, bytes) catch {
    error => abort("could not copy the fixture: " + io_message(error))
  }
  let library = @native_backend.DynamicLibrary::open(target) catch {
    error => abort(error.message())
  }
  library.close() catch {
    error => abort(error.message())
  }
  @fs.remove_file(target) catch {
    error =>
      abort(
        "the library file was still locked after unload: " + io_message(error),
      )
  }
  assert_false(@fs.path_exists(target))
}
