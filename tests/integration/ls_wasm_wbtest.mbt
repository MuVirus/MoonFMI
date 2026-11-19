///|
/// LS-WASM manifest validation tests (0.7.0): hand-built archives whose
/// WASM layer is validated through the same `validate_fmu_bytes` pipeline
/// `moonfmi validate` uses. The components are fixture bytes — the checks
/// cover manifest structure and cross-references, not WASM code.

///|
/// Minimal FMI 3 CS model description with a parameterized identifier.
fn ls_wasm_model_description(model_identifier : String) -> Bytes {
  @utf8.encode(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<fmiModelDescription fmiVersion=\"3.0\" modelName=\"WasmFixture\" instantiationToken=\"{00000000-0000-0000-0000-000000000002}\"><CoSimulation modelIdentifier=\"\{model_identifier}\"/><ModelVariables><Float64 name=\"time\" valueReference=\"0\" causality=\"independent\" variability=\"continuous\"/></ModelVariables><ModelStructure/></fmiModelDescription>",
  )
}

///|
/// Build an FMU archive with a WASM layer: model description, a fixture
/// component under `binaries/wasm32-wasip2/`, and an optional manifest.
fn ls_wasm_fmu(
  model_identifier : String,
  component_name : String,
  manifest : Bytes?,
) -> Bytes {
  let entries : Array[(String, Bytes)] = [
    ("modelDescription.xml", ls_wasm_model_description(model_identifier)),
    ("binaries/wasm32-wasip2/\{component_name}.wasm", b"fixture-component"),
  ]
  match manifest {
    Some(bytes) => entries.push((@fmi.LS_WASM_MANIFEST_ENTRY, bytes))
    None => ()
  }
  @zip.build_deterministic_zip(entries) catch {
    error => abort("building LS-WASM fixture failed: \{error.message()}")
  }
}

///|
/// The manifest the exporter writes for a component named `ident`.
fn ls_wasm_manifest(model_identifier : String) -> Bytes {
  @utf8.encode(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<fmiLSWASMManifest fmiVersion=\"3.0\"><Binary path=\"binaries/wasm32-wasip2/\{model_identifier}.wasm\" entrypoint=\"\{model_identifier}.wasm\" world=\"moonfmi:fmu/fmu\"/></fmiLSWASMManifest>",
  )
}

///|
/// Collect the LS-WASM diagnostic messages of an archive.
fn ls_wasm_errors(data : Bytes) -> Array[String] {
  let (_, report) = @fmi.validate_fmu_bytes(data)
  let messages : Array[String] = []
  for diagnostic in report.diagnostics() {
    if diagnostic.code() == @fmi.LS_WASM_DIAGNOSTIC_CODE &&
      diagnostic.severity is @schema.Severity::Error {
      messages.push(diagnostic.render())
    }
  }
  messages
}

///|
test "ls-wasm manifest with matching component validates cleanly" {
  let data = ls_wasm_fmu(
    "WasmAdder",
    "WasmAdder",
    Some(ls_wasm_manifest("WasmAdder")),
  )
  assert_eq(ls_wasm_errors(data).length(), 0)
  // `moonfmi info` reports the layer.
  let (manifest, components) = @fmi.ls_wasm_layer(data) catch {
    error => abort("ls_wasm_layer failed: \{error.message()}")
  }
  assert_true(manifest)
  assert_eq(components, 1)
}

///|
test "wasm component without a manifest is rejected" {
  let data = ls_wasm_fmu("WasmAdder", "WasmAdder", None)
  let errors = ls_wasm_errors(data)
  assert_eq(errors.length(), 1)
  assert_true(
    errors[0].contains("no extra/org.modelica.fmi-ls-wasm/manifest.xml"),
    msg="expected the missing-manifest diagnostic, got: " + errors[0],
  )
}

///|
/// Reference-FMUs ships incidental `.wasm` components alongside native
/// binaries (fmi3/BouncingBall.fmu does exactly this) — a mixed archive
/// without a manifest stays diagnostic-free; only wasm-only FMUs require
/// the manifest.
test "mixed native plus wasm archive without manifest is diagnostic-free" {
  let entries : Array[(String, Bytes)] = [
    ("modelDescription.xml", ls_wasm_model_description("WasmAdder")),
    ("binaries/wasm32-wasip2/WasmAdder.wasm", b"fixture-component"),
    ("binaries/x86_64-windows/WasmAdder.dll", b"fixture-native"),
  ]
  let data = @zip.build_deterministic_zip(entries) catch {
    error => abort("building mixed fixture failed: \{error.message()}")
  }
  assert_eq(ls_wasm_errors(data).length(), 0)
}

///|
test "ls-wasm manifest structural errors are reported" {
  // Wrong root element.
  let bad_root = @utf8.encode(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<fmiLayeredStandardManifest fmi-ls-name=\"x\"/>",
  )
  let root_errors = ls_wasm_errors(
    ls_wasm_fmu("WasmAdder", "WasmAdder", Some(bad_root)),
  )
  assert_true(
    root_errors.length() > 0 && root_errors[0].contains("fmiLSWASMManifest"),
    msg="expected a root-element diagnostic, got: " + root_errors.join(" | "),
  )
  // Component file name does not match the model identifier: the
  // manifest names OtherName.wasm, which IS present in the archive, but
  // the model description declares WasmAdder.
  let mismatch = ls_wasm_fmu(
    "WasmAdder",
    "OtherName",
    Some(ls_wasm_manifest("OtherName")),
  )
  let mismatch_errors = ls_wasm_errors(mismatch)
  assert_eq(mismatch_errors.length(), 1)
  assert_true(
    mismatch_errors[0].contains("does not match any model identifier"),
    msg="expected an identifier mismatch, got: " + mismatch_errors[0],
  )
  // Manifest references a binary that is not in the archive.
  let missing_binary = ls_wasm_fmu(
    "WasmAdder",
    "WasmAdder",
    Some(ls_wasm_manifest("Ghost")),
  )
  // The fixture component is WasmAdder.wasm but the manifest names Ghost.wasm.
  let ghost_errors = ls_wasm_errors(missing_binary)
  assert_eq(ghost_errors.length(), 1)
  assert_true(
    ghost_errors[0].contains("is not present in the archive"),
    msg="expected a missing-binary diagnostic, got: " + ghost_errors[0],
  )
}

///|
test "ls-wasm manifest on an fmi2 model description is rejected" {
  let fmi2_xml = @utf8.encode(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<fmiModelDescription fmiVersion=\"2.0\" modelName=\"WasmFixture\" guid=\"{11111111-1111-1111-1111-111111111111}\"><CoSimulation modelIdentifier=\"WasmAdder\"/><ModelVariables/><ModelStructure/></fmiModelDescription>",
  )
  let entries : Array[(String, Bytes)] = [
    ("modelDescription.xml", fmi2_xml),
    ("binaries/wasm32-wasip2/WasmAdder.wasm", b"fixture-component"),
    (@fmi.LS_WASM_MANIFEST_ENTRY, ls_wasm_manifest("WasmAdder")),
  ]
  let data = @zip.build_deterministic_zip(entries) catch {
    error => abort("building FMI 2 wasm fixture failed: \{error.message()}")
  }
  let errors = ls_wasm_errors(data)
  assert_eq(errors.length(), 1)
  assert_true(
    errors[0].contains("FMI 2"),
    msg="expected an FMI 2 rejection, got: " + errors[0],
  )
}
