///|
/// Top-level entry points: raw bytes in, typed model and validation
/// report out. This file owns version dispatch (rules MD-001 / MD-002).
/// Parse the raw bytes of a `modelDescription.xml` document.
///
/// Security limits (size, depth, entities, DOCTYPE) are enforced by the
/// `xml` package below this parser; violations surface as MD-060/MD-061
/// diagnostics wrapped in `SchemaError`.
pub fn parse_model_description(
  data : Bytes,
) -> ModelDescription raise SchemaError {
  let reader = XmlReader::from_bytes(data) catch {
    error =>
      raise Failed(
        Diagnostic::new(
          code=xml_error_code(error),
          severity=Error,
          message=error.message(),
          path="/",
          line=error.line(),
          column=error.column(),
        ),
      )
  }
  let cursor = Cursor::new(reader, root_path="/fmiModelDescription")
  // The cursor is normalized: only Start/Empty/End/Eof ever surface.
  let root = match cursor.next() {
    Start(element) | Empty(element) => Some(element)
    End(_) | Eof => None
    Text(_)
    | CData(_)
    | Declaration(..)
    | Comment(_)
    | ProcessingInstruction(..)
    | DocType => None
  }
  let element = match root {
    Some(element) => element
    None =>
      raise Failed(
        Diagnostic::new(
          code="MD-001",
          severity=Error,
          message="document is empty; expected a <fmiModelDescription> root element",
          path="/",
          line=1,
          column=1,
        ),
      )
  }
  if element.name != "fmiModelDescription" {
    raise Failed(
      Diagnostic::new(
        code="MD-001",
        severity=Error,
        message="root element must be <fmiModelDescription>, found <\{element.name}>",
        path="/\{element.name}",
        line=element.span.start.line,
        column=element.span.start.column,
        hint="check that the file really is a modelDescription.xml",
      ),
    )
  }
  let version_text = required_attr(
    element,
    "fmiVersion",
    path="/fmiModelDescription",
    code="MD-002",
    hint="the root element must carry fmiVersion=\"2.0\" or fmiVersion=\"3.0\"",
  )
  let version = parse_fmi_version(
    version_text,
    path="/fmiModelDescription",
    line=element.span.start.line,
    column=element.span.start.column,
  )
  match version {
    V2 => V2(parse_fmi2_model(cursor, element))
    V3 => V3(parse_fmi3_model(cursor, element))
  }
}

///|
/// Validate a typed model against the semantic rules MD-001..MD-063 and
/// return the normalized report (sorted, deduplicated).
pub fn validate_model(model : ModelDescription) -> ValidationReport {
  let report = ValidationReport::new()
  match model {
    V2(m) => {
      let index = build_fmi2_index(m)
      for diagnostic in validate_fmi2(m, index) {
        report.push(diagnostic)
      }
    }
    V3(m) => {
      let index = build_fmi3_index(m)
      for diagnostic in validate_fmi3(m, index) {
        report.push(diagnostic)
      }
    }
  }
  report.normalize()
  report
}

///|
/// Convenience: parse and validate in one call. When parsing fails, the
/// returned report contains the single parse diagnostic and the model is
/// `None`; semantic results are otherwise collected in full.
pub fn parse_and_validate(
  data : Bytes,
) -> (ModelDescription?, ValidationReport) {
  let model = parse_model_description(data) catch {
    error => {
      let report = ValidationReport::new()
      report.push(error.diagnostic())
      return (None, report)
    }
  }
  let report = validate_model(model)
  (Some(model), report)
}
