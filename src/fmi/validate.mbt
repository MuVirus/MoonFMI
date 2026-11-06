///|
/// FMU container pipeline (validation stages V0..V4 from
/// `docs/design/xsd-and-validation.md`):
///
/// - V0: container layout — the archive opens and carries
///   `modelDescription.xml` (code `FMU-LAYOUT`);
/// - V1: XML well-formedness, encoding, entity and size limits (codes
///   `XML`, `MD-060`, `MD-061`);
/// - V2: typed parsing — element order, required attributes, enums;
/// - V3/V4: indexes and the semantic rules MD-001..MD-063.
///
/// The pipeline always returns a report; parse failures produce a report
/// with a single diagnostic instead of an error.
/// True when the bytes look like a ZIP archive (`PK\x03\x04`).
pub fn is_zip_archive(data : Bytes) -> Bool {
  data.length() >= 4 &&
  data[0] == 0x50 &&
  data[1] == 0x4B &&
  data[2] == 0x03 &&
  data[3] == 0x04
}

///|
fn layout_diagnostic(message~ : String) -> @schema.Diagnostic {
  @schema.Diagnostic::new(code="FMU-LAYOUT", severity=Error, message~, path="/")
}

///|
/// The name of the mandatory model description entry inside an FMU.
const MODEL_DESCRIPTION_ENTRY : String = "modelDescription.xml"

///|
/// Validate raw FMU bytes (a ZIP archive) or a bare
/// `modelDescription.xml`. Returns the parsed model when the container
/// and XML stages succeeded.
pub fn validate_fmu_bytes(
  data : Bytes,
) -> (@schema.ModelDescription?, @schema.ValidationReport) {
  if !is_zip_archive(data) {
    // Bare XML document (or garbage); straight into the XML stages.
    return @schema.parse_and_validate(data)
  }
  let archive = @zip.ZipArchive::open(data) catch {
    error => {
      let report = @schema.ValidationReport::new()
      report.push(
        layout_diagnostic(message="cannot read FMU archive: \{error.message()}"),
      )
      return (None, report)
    }
  }
  let entry = match archive.entry(MODEL_DESCRIPTION_ENTRY) {
    Some(entry) => entry
    None => {
      let report = @schema.ValidationReport::new()
      report.push(
        @schema.Diagnostic::new(
          code="FMU-LAYOUT",
          severity=@schema.Severity::Error,
          message="FMU archive does not contain \{MODEL_DESCRIPTION_ENTRY}",
          path="/",
          hint="the model description must sit at the archive root",
        ),
      )
      return (None, report)
    }
  }
  let _ = entry
  let xml_bytes = archive.read(MODEL_DESCRIPTION_ENTRY) catch {
    error => {
      let report = @schema.ValidationReport::new()
      report.push(
        layout_diagnostic(
          message="cannot read \{MODEL_DESCRIPTION_ENTRY}: \{error.message()}",
        ),
      )
      return (None, report)
    }
  }
  @schema.parse_and_validate(xml_bytes)
}
