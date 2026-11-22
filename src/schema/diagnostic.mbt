///|
/// Severity of a validation diagnostic.
#derive(Eq, Debug)
pub(all) enum Severity {
  Error
  Warning
  Info
}

///|
/// One validation finding. `code` is a stable rule identifier such as
/// `MD-012`; structural and lexical problems use `STRUCTURE` / `XML`, and
/// container-level problems use `FMU-LAYOUT`. `path` is an XPath-style
/// location with 1-based element indices.
pub struct Diagnostic {
  code : String
  severity : Severity
  message : String
  path : String
  line : Int32?
  column : Int32?
  hint : String?
}

///|
pub fn Diagnostic::new(
  code~ : String,
  severity~ : Severity,
  message~ : String,
  path~ : String,
  line? : Int32,
  column? : Int32,
  hint? : String,
) -> Diagnostic {
  { code, severity, message, path, line, column, hint, }
}

///|
pub fn Diagnostic::code(self : Diagnostic) -> String {
  self.code
}

///|
pub fn Diagnostic::severity(self : Diagnostic) -> Severity {
  self.severity
}

///|
pub fn Diagnostic::message(self : Diagnostic) -> String {
  self.message
}

///|
pub fn Diagnostic::path(self : Diagnostic) -> String {
  self.path
}

///|
pub fn Diagnostic::line(self : Diagnostic) -> Int32? {
  self.line
}

///|
pub fn Diagnostic::column(self : Diagnostic) -> Int32? {
  self.column
}

///|
pub fn Diagnostic::hint(self : Diagnostic) -> String? {
  self.hint
}

///|
/// Render a diagnostic as the stable one-line text form used by the CLI:
/// `[MD-012] error: message (path, line L, column C)`.
pub fn Diagnostic::render(self : Diagnostic) -> String {
  let severity = match self.severity {
    Error => "error"
    Warning => "warning"
    Info => "info"
  }
  let builder = StringBuilder()
  builder.write_string("[")
  builder.write_string(self.code)
  builder.write_string("] ")
  builder.write_string(severity)
  builder.write_string(": ")
  builder.write_string(self.message)
  builder.write_string(" (")
  builder.write_string(self.path)
  if self.line is Some(line) {
    builder.write_string(", line ")
    builder.write_string(line.to_string())
  }
  if self.column is Some(column) {
    builder.write_string(", column ")
    builder.write_string(column.to_string())
  }
  builder.write_string(")")
  builder.to_string()
}

///|
/// Collect diagnostics for one validation run.
pub struct ValidationReport {
  mut diagnostics : Array[Diagnostic]
}

///|
pub fn ValidationReport::new(
  diagnostics~ : Array[Diagnostic] = [],
) -> ValidationReport {
  { diagnostics, }
}

///|
pub fn ValidationReport::diagnostics(
  self : ValidationReport,
) -> Array[Diagnostic] {
  self.diagnostics
}

///|
pub fn ValidationReport::push(
  self : ValidationReport,
  diagnostic : Diagnostic,
) -> Unit {
  self.diagnostics.push(diagnostic)
}

///|
pub fn ValidationReport::error_count(self : ValidationReport) -> Int32 {
  count_severity(self.diagnostics, Error)
}

///|
pub fn ValidationReport::warning_count(self : ValidationReport) -> Int32 {
  count_severity(self.diagnostics, Warning)
}

///|
pub fn ValidationReport::info_count(self : ValidationReport) -> Int32 {
  count_severity(self.diagnostics, Info)
}

///|
/// A model is accepted when it has no errors (warnings do not fail the run).
pub fn ValidationReport::is_valid(self : ValidationReport) -> Bool {
  self.error_count() == 0
}

///|
/// Merge `other` into `self`, keeping `self` first.
pub fn ValidationReport::merge_from(
  self : ValidationReport,
  other : ValidationReport,
) -> Unit {
  for diagnostic in other.diagnostics {
    self.diagnostics.push(diagnostic)
  }
}

///|
fn count_severity(
  diagnostics : Array[Diagnostic],
  severity : Severity,
) -> Int32 {
  let mut count = 0
  for diagnostic in diagnostics {
    if diagnostic.severity == severity {
      count += 1
    }
  }
  count
}

///|
/// Sort diagnostics by document position, then code, then message, and drop
/// duplicates (same position, code, and message). Sorting is stable so
/// diagnostics on the same position keep insertion order for equal keys.
pub fn ValidationReport::normalize(self : ValidationReport) -> Unit {
  let keyed : Array[(Int32, Int32, String, String, Int32, Diagnostic)] = []
  for index, diagnostic in self.diagnostics {
    let line = match diagnostic.line {
      Some(line) => line
      None => 0
    }
    let column = match diagnostic.column {
      Some(column) => column
      None => 0
    }
    keyed.push(
      (line, column, diagnostic.code, diagnostic.message, index, diagnostic),
    )
  }
  keyed.sort_by((a, b) => compare_key(a, b))
  let sorted : Array[Diagnostic] = []
  let mut previous : (Int32, Int32, String, String)? = None
  for entry in keyed {
    let key = (entry.0, entry.1, entry.2, entry.3)
    let duplicate = previous is Some(p) &&
      p.0 == key.0 &&
      p.1 == key.1 &&
      p.2 == key.2 &&
      p.3 == key.3
    if !duplicate {
      sorted.push(entry.5)
      previous = Some(key)
    }
  }
  self.diagnostics = sorted
}

///|
fn compare_key(
  a : (Int32, Int32, String, String, Int32, Diagnostic),
  b : (Int32, Int32, String, String, Int32, Diagnostic),
) -> Int32 {
  let mut order = a.0.compare(b.0)
  if order != 0 {
    return order
  }
  order = a.1.compare(b.1)
  if order != 0 {
    return order
  }
  order = a.2.compare(b.2)
  if order != 0 {
    return order
  }
  a.3.compare(b.3)
}

///|
/// Parse- or container-level failures are raised as a single diagnostic.
/// Semantic problems are collected into a report instead.
pub(all) suberror SchemaError {
  Failed(Diagnostic)
}

///|
pub fn SchemaError::diagnostic(self : SchemaError) -> Diagnostic {
  match self {
    Failed(diagnostic) => diagnostic
  }
}

///|
/// Build the standard structural diagnostic for a position. Parse-level
/// rule violations pass their MD code (e.g. MD-007, MD-052) so the report
/// names the rule instead of the generic `STRUCTURE` fallback.
pub fn structure_error(
  message~ : String,
  path~ : String,
  line~ : Int32,
  column~ : Int32,
  hint? : String,
  code~ : String = "STRUCTURE",
) -> SchemaError {
  Failed(
    Diagnostic::new(
      code~,
      severity=Error,
      message~,
      path~,
      line~,
      column~,
      hint?,
    ),
  )
}

///|
pub extend Severity with Eq::{not_equal, equal}

///|
pub extend Severity with @debug.Debug::{to_repr}
