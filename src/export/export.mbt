// Source FMU export (roadmap P6, tasks E-01…E-08).
//
// `export_source_fmu` turns a validated ModelIr into a source FMU directory:
// modelDescription.xml (E-02), generated C99 model + entry code (E-03),
// CMakeLists.txt (E-04), buildDescription.xml for FMI 3 (E-05), and — when
// `package` is on — a deterministic .fmu archive whose hash is stable for
// the same IR (E-08). Compiling the generated sources into a loadable
// binary FMU (E-06/E-07) is left to the caller's toolchain; tests use clang
// through tests/integration/support.c.

///|
pub(all) suberror ExportError {
  Failed(@schema.Diagnostic)
}

///|
pub fn ExportError::diagnostic(self : ExportError) -> @schema.Diagnostic {
  match self {
    ExportError::Failed(diagnostic) => diagnostic
  }
}

///|
pub fn ExportError::message(self : ExportError) -> String {
  let diagnostic = self.diagnostic()
  "\{diagnostic.code}: \{diagnostic.message}"
}

///|
pub struct ExportOptions {
  fmi_version : @schema.FmiVersion
  /// `None` derives `<model_name>_fmu` next to the current directory.
  output_dir : String?
  /// Also write the deterministic `.fmu` archive into the output directory.
  write_fmu : Bool
}

///|
pub fn ExportOptions::new(
  fmi_version~ : @schema.FmiVersion,
  output_dir~ : String? = None,
  write_fmu~ : Bool = true,
) -> ExportOptions {
  { fmi_version, output_dir, write_fmu, }
}

///|
pub struct ExportResult {
  /// Directory the exported tree was written to.
  output_dir : String
  /// `(archive-name, bytes)` pairs; archive names use `/` separators. This is
  /// the exact input of the deterministic ZIP writer, so callers can repackage
  /// elsewhere and get identical bytes.
  files : Array[(String, Bytes)]
  /// Path of the packaged `.fmu`, when `options.write_fmu` was on.
  fmu_path : String?
  /// SHA-256 of the packaged archive (hex), when packaging ran.
  sha256 : String?
  /// IR validation diagnostics that are not errors (warnings/info).
  diagnostics : Array[@schema.Diagnostic]
}

///|
fn ensure_directory(path : String) -> Unit {
  // create_dir does not create parents; walk the segments.
  let mut prefix = ""
  for segment in path.split("/") {
    let segment = segment.to_owned()
    if segment.is_empty() {
      continue
    }
    prefix = if prefix.is_empty() { segment } else { "\{prefix}/\{segment}" }
    @fs.create_dir(prefix) catch {
      _ =>
        // Already exists or race; keep going, the write below will surface
        // a real failure.
        ()
    }
  }
}

///|
fn text_file(name : String, content : String) -> (String, Bytes) {
  (name, @utf8.encode(content))
}

///|
/// Export the IR as a source FMU (tasks E-01…E-05, E-08).
pub fn export_source_fmu(
  ir : ModelIr,
  options : ExportOptions,
) -> ExportResult raise ExportError {
  // E-01: the IR must pass its own validation before anything is generated.
  let diagnostics = ir.check()
  for diagnostic in diagnostics {
    if diagnostic.severity is @schema.Severity::Error {
      raise ExportError::Failed(diagnostic)
    }
  }
  if ir.interfaces.is_empty() {
    raise export_error(
      message="the IR declares no interface; nothing to export",
      hint="call ModelIr::add_interface for CoSimulation and/or ModelExchange",
    )
  }
  // The XML generation layer enforces version-specific rules (FMI 2 rejects
  // arrays and the narrower type set).
  let xml = model_description_xml(ir, options.fmi_version)
  let files : Array[(String, Bytes)] = []
  files.push(text_file("modelDescription.xml", xml))
  // E-03: model + entry code.
  files.push(text_file("sources/moonfmi_model.h", generate_model_header(ir)))
  files.push(text_file("sources/moonfmi_model.c", generate_model_c(ir)))
  match options.fmi_version {
    @schema.FmiVersion::V2 => {
      files.push(text_file("sources/moonfmi_fmi2.h", generate_fmi2_header(ir)))
      files.push(text_file("sources/fmi2Functions.c", generate_fmi2_entry(ir)))
    }
    @schema.FmiVersion::V3 => {
      files.push(text_file("sources/moonfmi_fmi3.h", generate_fmi3_header(ir)))
      files.push(text_file("sources/fmi3Functions.c", generate_fmi3_entry(ir)))
      // E-05: FMI 3 build description.
      files.push(text_file("buildDescription.xml", build_description_xml(ir)))
    }
  }
  // E-04: build scripts.
  files.push(
    text_file("sources/CMakeLists.txt", generate_cmake(ir, options.fmi_version)),
  )
  files.push(
    text_file("documentation/README.txt", generate_documentation(ir, options)),
  )
  // Reproducibility: identical IR → identical bytes, so the GUID derives
  // from the IR hash and the entry files embed it.
  let output_dir = match options.output_dir {
    Some(directory) => directory
    None => "\{c_identifier(ir.model_name)}_fmu"
  }
  ensure_directory(output_dir)
  for (name, bytes) in files {
    let path = "\{output_dir}/\{name}"
    ensure_directory(parent_directory(path))
    @fs.write_bytes_to_file(path, bytes) catch {
      error =>
        raise export_error(
          message="writing \{path} failed: \{io_message_of(error)}",
          hint="check that the output directory is writable",
        )
    }
  }
  let mut fmu_path : String? = None
  let mut sha256 : String? = None
  if options.write_fmu {
    // E-08: deterministic packaging — sorted entries, fixed timestamps.
    let archive = @zip.build_deterministic_zip(files) catch {
      error =>
        raise export_error(
          message="building \{ir.model_name}.fmu failed: \{error.message()}",
        )
    }
    let path = "\{output_dir}/\{c_identifier(ir.model_name)}.fmu"
    @fs.write_bytes_to_file(path, archive) catch {
      error =>
        raise export_error(
          message="writing \{path} failed: \{io_message_of(error)}",
        )
    }
    fmu_path = Some(path)
    sha256 = Some(@crypto.bytes_to_hex_string(@crypto.sha256(archive)))
  }
  let warnings = []
  for diagnostic in diagnostics {
    if !(diagnostic.severity is @schema.Severity::Error) {
      warnings.push(diagnostic)
    }
  }
  { output_dir, files, fmu_path, sha256, diagnostics: warnings, }
}

///|
fn parent_directory(path : String) -> String {
  // Split on "/" and drop the last segment; archive names always use `/`.
  let segments = path.split("/").collect()
  let count = segments.length()
  if count <= 1 {
    return "."
  }
  let parent = StringBuilder()
  for i in 0..<(count - 1) {
    if i > 0 {
      parent.write_char('/')
    }
    parent.write_string(segments[i].to_owned())
  }
  parent.to_string()
}

///|
fn io_message_of(error : @fs.IOError) -> String {
  @debug.Debug::to_repr(error).to_string()
}

///|
/// Short generated documentation describing how to build the FMU.
fn generate_documentation(ir : ModelIr, options : ExportOptions) -> String {
  let writer = XmlWriter::new()
  let build = match options.fmi_version {
    @schema.FmiVersion::V2 => "FMI 2.0 (source FMU)"
    @schema.FmiVersion::V3 => "FMI 3.0 (source FMU)"
  }
  writer.line("\{ir.model_name}")
  writer.line("==========")
  writer.line("")
  match ir.description {
    Some(description) => {
      writer.line(description)
      writer.line("")
    }
    None => ()
  }
  writer.line("Generated by \{ir.generation_tool} as a \{build}.")
  writer.line("Identity: \{ir.guid_value()}")
  writer.line("")
  writer.line("Build (CMake):")
  writer.line("")
  writer.line("    cmake -S sources -B build")
  writer.line("    cmake --build build --config Release")
  writer.line("")
  writer.line(
    "The shared library lands in binaries/<platform>/ as required by the",
  )
  writer.line("FMI layout. Any C99 compiler works as well, e.g.:")
  writer.line("")
  writer.line("    clang -O2 -shared -fPIC -I sources sources/*.c -o <output>")
  writer.line("")
  writer.to_string()
}
