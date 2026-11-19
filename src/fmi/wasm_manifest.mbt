///|
/// LS-WASM layered-standard manifest checks (0.7.0; design:
/// `docs/design/wasm-strategy.md` §4.1/§5.1, exporter obligation in
/// `docs/design/exporter.md` §6). The manifest is validated structurally
/// with the project XML reader — the bundled
/// `fmi3LayeredStandardManifest.xsd` is the *generic* layered-standard
/// schema and does not cover the LS-WASM profile root
/// `fmiLSWASMManifest`, so an XSD engine is not used here (the same
/// hand-written-rules stance as the model-description semantic checks).

///|
/// Archive path of the LS-WASM manifest.
pub const LS_WASM_MANIFEST_ENTRY : String = "extra/org.modelica.fmi-ls-wasm/manifest.xml"

///|
/// Platform directory that holds WebAssembly components.
pub const LS_WASM_PLATFORM_DIR : String = "wasm32-wasip2"

///|
/// Diagnostic code for the LS-WASM manifest stage.
pub const LS_WASM_DIAGNOSTIC_CODE : String = "LS-WASM"

///|
/// True when the entry name is a WebAssembly component under the LS-WASM
/// platform directory (`binaries/wasm32-wasip2/*.wasm`).
fn is_wasm_component_entry(entry : String) -> Bool {
  let prefix = "binaries/\{LS_WASM_PLATFORM_DIR}/"
  if !entry.has_prefix(prefix) {
    return false
  }
  let rest = entry[prefix.length():]
  // The component sits directly in the platform directory (no nested
  // directories) and carries the `.wasm` extension.
  !rest.is_empty() && !rest.contains("/") && rest.has_suffix(".wasm")
}

///|
/// Summary of an archive's WASM layer for `moonfmi info`: whether the
/// LS-WASM manifest is present and how many `.wasm` components sit under
/// `binaries/wasm32-wasip2/`.
pub fn ls_wasm_layer(data : Bytes) -> (Bool, Int32) raise @zip.ZipError {
  let archive = @zip.ZipArchive::open(data)
  let has_manifest = archive.contains(LS_WASM_MANIFEST_ENTRY)
  let mut components = 0
  for entry in archive.entries() {
    if is_wasm_component_entry(entry.name()) {
      components += 1
    }
  }
  (has_manifest, components)
}

///|
/// Validate the LS-WASM layer of an opened FMU archive against its parsed
/// model description. Diagnostics (code `LS-WASM`) are appended to the
/// report; the model itself is not modified. Rules:
///
/// - a **wasm-only** FMU — `.wasm` components but no native `binaries/`
///   platform directory — without a manifest is an error: it can never be
///   loaded natively and the layered standard requires the manifest
///   (exporter.md §6). Reference-FMUs ships incidental `.wasm` components
///   alongside native binaries; those stay diagnostic-free;
/// - the manifest must have root `fmiLSWASMManifest` with
///   `fmiVersion="3.0"`, and the layered standard only exists for FMI 3;
/// - its `Binary` element must carry `path`, `entrypoint` and `world`,
///   the path must point into `binaries/wasm32-wasip2/` and name the
///   model identifier (`<modelIdentifier>.wasm`), and the referenced
///   component must exist in the archive.
pub fn validate_ls_wasm(
  archive : @zip.ZipArchive,
  model : @schema.ModelDescription?,
  report : @schema.ValidationReport,
) -> Unit {
  let has_manifest = archive.contains(LS_WASM_MANIFEST_ENTRY)
  let mut wasm_components = 0
  let mut native_binaries = 0
  for entry in archive.entries() {
    if is_wasm_component_entry(entry.name()) {
      wasm_components += 1
    } else if is_native_binary_entry(entry.name()) {
      native_binaries += 1
    }
  }
  if wasm_components == 0 && !has_manifest {
    // No WASM layer: nothing to check.
    return
  }
  if wasm_components > 0 && !has_manifest {
    if native_binaries == 0 {
      // Wasm-only FMU without the manifest required by the layered
      // standard: it cannot be loaded by any backend.
      report.push(
        @schema.Diagnostic::new(
          code=LS_WASM_DIAGNOSTIC_CODE,
          severity=@schema.Severity::Error,
          message="FMU only carries WebAssembly component(s) under binaries/\{LS_WASM_PLATFORM_DIR}/ but no \{LS_WASM_MANIFEST_ENTRY}",
          path="/",
          hint="LS-WASM FMUs must declare the layered-standard manifest next to their components",
        ),
      )
    }
    return
  }
  // The manifest exists; it is only meaningful for FMI 3 models.
  match model {
    Some(@schema.V2(_)) => {
      report.push(
        @schema.Diagnostic::new(
          code=LS_WASM_DIAGNOSTIC_CODE,
          severity=@schema.Severity::Error,
          message="FMU declares an LS-WASM manifest but the model description is FMI 2",
          path="/",
          hint="the layered standard targets FMI 3; drop the manifest or export an FMI 3 FMU",
        ),
      )
      return
    }
    _ => ()
  }
  let manifest_bytes = archive.read(LS_WASM_MANIFEST_ENTRY) catch {
    error => {
      report.push(
        @schema.Diagnostic::new(
          code=LS_WASM_DIAGNOSTIC_CODE,
          severity=@schema.Severity::Error,
          message="cannot read \{LS_WASM_MANIFEST_ENTRY}: \{error.message()}",
          path="/\{LS_WASM_MANIFEST_ENTRY}",
        ),
      )
      return
    }
  }
  validate_ls_wasm_manifest(manifest_bytes, model, report, archive)
}

///|
/// True when the entry name is a native shared-library binary under a
/// platform directory other than the WASM one (`binaries/<dir>/<lib>`).
fn is_native_binary_entry(entry : String) -> Bool {
  let prefix = "binaries/"
  if !entry.has_prefix(prefix) {
    return false
  }
  let rest = entry[prefix.length():].to_owned()
  let mut slash = -1
  for index, ch in rest {
    if ch == '/' {
      slash = index
      break
    }
  }
  if slash < 0 {
    return false
  }
  let platform = rest[:slash].to_owned()
  let file = rest[slash + 1:].to_owned()
  platform != LS_WASM_PLATFORM_DIR &&
  !file.is_empty() &&
  !file.contains("/") &&
  (
    file.has_suffix(".dll") ||
    file.has_suffix(".so") ||
    file.has_suffix(".dylib")
  )
}

///|
/// Structural validation of the manifest XML: root element, version and
/// the Binary element's attributes and cross-references.
fn validate_ls_wasm_manifest(
  manifest_bytes : Bytes,
  model : @schema.ModelDescription?,
  report : @schema.ValidationReport,
  archive : @zip.ZipArchive,
) -> Unit {
  let fail = (message : String, hint : String?) => {
    report.push(
      @schema.Diagnostic::new(
        code=LS_WASM_DIAGNOSTIC_CODE,
        severity=@schema.Severity::Error,
        message~,
        path="/\{LS_WASM_MANIFEST_ENTRY}",
        hint?,
      ),
    )
  }
  let reader = @xml.XmlReader::from_bytes(manifest_bytes) catch {
    error => {
      fail("manifest is not well-formed XML: \{error.message()}", None)
      return
    }
  }
  // Expected shape (exporter and LS-WASM draft):
  // <fmiLSWASMManifest fmiVersion="3.0"><Binary path entrypoint world/></fmiLSWASMManifest>
  let mut root_seen = false
  let mut binary_count = 0
  let mut done = false
  while !done {
    let event = reader.read_event() catch {
      error => {
        fail("manifest XML error: \{error.message()}", None)
        return
      }
    }
    match event {
      Start(element) =>
        if !root_seen {
          root_seen = true
          if element.name() != "fmiLSWASMManifest" {
            fail(
              "manifest root must be <fmiLSWASMManifest>, got <\{element.name()}>",
              None,
            )
            return
          }
          match element.attribute("fmiVersion") {
            Some("3.0") => ()
            Some(other) =>
              fail(
                "manifest fmiVersion must be \"3.0\", got \"\{other}\"",
                None,
              )
            None => fail("manifest is missing the fmiVersion attribute", None)
          }
        } else if element.name() == "Binary" {
          binary_count += 1
          validate_ls_wasm_binary(element, model, archive, fail)
        } else {
          fail(
            "unexpected element <\{element.name()}> inside the manifest",
            None,
          )
        }
      End(_) => ()
      Empty(element) =>
        if !root_seen {
          root_seen = true
          fail(
            "manifest root must be <fmiLSWASMManifest>, got <\{element.name()}>",
            None,
          )
          return
        } else if element.name() == "Binary" {
          binary_count += 1
          validate_ls_wasm_binary(element, model, archive, fail)
        }
      Eof => done = true
      _ => ()
    }
  }
  if binary_count == 0 {
    fail("manifest declares no <Binary> component", None)
  }
}

///|
/// Validate one `<Binary path entrypoint world/>` element: required
/// attributes, platform-directory placement, model-identifier match and
/// archive presence.
fn validate_ls_wasm_binary(
  element : @xml.XmlElement,
  model : @schema.ModelDescription?,
  archive : @zip.ZipArchive,
  fail : (String, String?) -> Unit,
) -> Unit {
  let path = element.attribute("path")
  let entrypoint = element.attribute("entrypoint")
  let world = element.attribute("world")
  let path = match path {
    Some(path) => path
    None => {
      fail("<Binary> is missing the path attribute", None)
      return
    }
  }
  if entrypoint is None || entrypoint is Some("") {
    fail("<Binary path=\"\{path}\"> is missing a non-empty entrypoint", None)
  }
  if world is None || world is Some("") {
    fail("<Binary path=\"\{path}\"> is missing a non-empty world", None)
  }
  let prefix = "binaries/\{LS_WASM_PLATFORM_DIR}/"
  if !path.has_prefix(prefix) || !path.has_suffix(".wasm") {
    fail(
      "<Binary path=\"\{path}\"> must point to binaries/\{LS_WASM_PLATFORM_DIR}/<modelIdentifier>.wasm",
      None,
    )
    return
  }
  if !archive.contains(path) {
    fail("<Binary path=\"\{path}\"> is not present in the archive", None)
    return
  }
  // The component file name must match the model identifier of the model
  // description (wasm-strategy.md §4.1).
  let rest = path[prefix.length():path.char_length() - 5].to_owned()
  match model {
    Some(@schema.V3(m)) => {
      let identifiers = m.interfaces.map(fn(i) { i.model_identifier })
      if !identifiers.contains(rest) {
        fail(
          "component file name '\{rest}' does not match any model identifier (\{identifiers.join(", ")})",
          Some(
            "rename binaries/\{LS_WASM_PLATFORM_DIR}/<modelIdentifier>.wasm or update the manifest",
          ),
        )
      }
    }
    _ => ()
  }
}
