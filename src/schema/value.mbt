///|
/// Attribute-value parsing helpers shared by the FMI 2 and FMI 3 parsers.
/// All helpers raise `SchemaError` with a `STRUCTURE` diagnostic so the
/// CLI can point at the offending attribute.
/// Largest finite Double, used as the sentinel for `xs:double` `INF`.
const DOUBLE_MAX : Double = 1.7976931348623157e308

///|
fn fail_value(
  message~ : String,
  path~ : String,
  line~ : Int32,
  column~ : Int32,
  code~ : String = "STRUCTURE",
) -> SchemaError {
  structure_error(message~, path~, line~, column~, code~)
}

///|
/// Parse an `xs:double` attribute, accepting `INF` / `-INF` / `NaN`.
pub fn parse_double_value(
  text : String,
  path~ : String,
  line~ : Int32,
  column~ : Int32,
) -> Double raise SchemaError {
  if text == "INF" || text == "inf" || text == "+INF" || text == "+inf" {
    return DOUBLE_MAX
  }
  if text == "-INF" || text == "-inf" {
    return -DOUBLE_MAX
  }
  if text == "NaN" || text == "nan" {
    // NaN bounds are meaningless; surface as a structure error instead of
    // propagating a NaN that would silently pass every comparison.
    raise fail_value(
      message="value must be a number (NaN is not allowed here)",
      path~,
      line~,
      column~,
    )
  }
  @string.parse_double(text) catch {
    _ =>
      raise fail_value(
        message="'\{text}' is not a valid number",
        path~,
        line~,
        column~,
      )
  }
}

///|
/// Parse an `xs:unsignedInt` attribute (value references, indices, ...).
pub fn parse_uint32_value(
  text : String,
  path~ : String,
  line~ : Int32,
  column~ : Int32,
) -> UInt32 raise SchemaError {
  @string.parse_uint(text) catch {
    _ =>
      raise fail_value(
        message="'\{text}' is not a valid unsigned integer",
        path~,
        line~,
        column~,
      )
  }
}

///|
/// Parse an `xs:int` attribute (FMI 2 integer bounds and starts). `code~`
/// names the owning rule for non-integer text (MD-052 for unit exponents).
pub fn parse_int32_value(
  text : String,
  path~ : String,
  line~ : Int32,
  column~ : Int32,
  code~ : String = "STRUCTURE",
) -> Int32 raise SchemaError {
  @string.parse_int(text) catch {
    _ =>
      raise fail_value(
        message="'\{text}' is not a valid integer",
        path~,
        line~,
        column~,
        code~,
      )
  }
}

///|
/// Parse an `xs:long` attribute (FMI 3 signed integer bounds and starts).
pub fn parse_int64_value(
  text : String,
  path~ : String,
  line~ : Int32,
  column~ : Int32,
) -> Int64 raise SchemaError {
  @string.parse_int64(text) catch {
    _ =>
      raise fail_value(
        message="'\{text}' is not a valid integer",
        path~,
        line~,
        column~,
      )
  }
}

///|
/// Parse an `xs:unsignedLong` attribute (FMI 3 unsigned bounds, sizes,
/// dimensions).
pub fn parse_uint64_value(
  text : String,
  path~ : String,
  line~ : Int32,
  column~ : Int32,
) -> UInt64 raise SchemaError {
  @string.parse_uint64(text) catch {
    _ =>
      raise fail_value(
        message="'\{text}' is not a valid unsigned integer",
        path~,
        line~,
        column~,
      )
  }
}

///|
/// Parse an `xs:boolean` attribute; the XSD also allows `0` and `1`.
pub fn parse_bool_value(
  text : String,
  path~ : String,
  line~ : Int32,
  column~ : Int32,
) -> Bool raise SchemaError {
  match text {
    "true" | "1" => true
    "false" | "0" => false
    _ =>
      raise fail_value(
        message="'\{text}' is not a valid boolean (expected true/false)",
        path~,
        line~,
        column~,
      )
  }
}

///|
/// Split a whitespace-separated XSD list into its items.
pub fn split_ws_list(text : String) -> Array[String] {
  let items : Array[String] = []
  let builder = StringBuilder()
  for ch in text {
    if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' {
      if !builder.is_empty() {
        items.push(builder.to_string())
        builder.reset()
      }
    } else {
      builder.write_char(ch)
    }
  }
  if !builder.is_empty() {
    items.push(builder.to_string())
  }
  items
}

///|
/// Parse the `fmiVersion` attribute. Accepts `2.0` (optionally `2.0.x`),
/// and `3.0` / `3.0.x`. Anything else is rule MD-002.
pub fn parse_fmi_version(
  text : String,
  path~ : String,
  line~ : Int32,
  column~ : Int32,
) -> FmiVersion raise SchemaError {
  let parts = split_dot(text)
  match parts {
    [major, minor] =>
      match (major, minor) {
        ("2", "0") => V2
        ("3", "0") => V3
        _ =>
          raise Failed(
            Diagnostic::new(
              code="MD-002",
              severity=Error,
              message="unsupported fmiVersion '\{text}' (supported: 2.0, 3.0)",
              path~,
              line~,
              column~,
            ),
          )
      }
    [major, minor, _patch] =>
      match (major, minor) {
        // 2.0.x and 3.0.x patch releases keep the same schema family.
        ("2", "0") => V2
        ("3", "0") => V3
        _ =>
          raise Failed(
            Diagnostic::new(
              code="MD-002",
              severity=Error,
              message="unsupported fmiVersion '\{text}' (supported: 2.0, 3.0)",
              path~,
              line~,
              column~,
            ),
          )
      }
    _ =>
      raise Failed(
        Diagnostic::new(
          code="MD-002",
          severity=Error,
          message="malformed fmiVersion '\{text}' (expected 2.0 or 3.0)",
          path~,
          line~,
          column~,
        ),
      )
  }
}

///|
fn split_dot(text : String) -> Array[String] {
  let parts : Array[String] = []
  let builder = StringBuilder()
  for ch in text {
    if ch == '.' {
      parts.push(builder.to_string())
      builder.reset()
    } else {
      builder.write_char(ch)
    }
  }
  parts.push(builder.to_string())
  parts
}

///|
/// Rule MD-004 / MD-062: a model identifier must be non-empty and must not
/// contain path separators, `..`, `:`, or control characters. Dots inside a
/// name are allowed (e.g. `My.Model`), but a `..` segment is not.
pub fn is_safe_model_identifier(text : String) -> Bool {
  if text == "" {
    return false
  }
  if text.contains("..") {
    return false
  }
  for ch in text {
    if ch == '/' || ch == '\\' || ch == ':' {
      return false
    }
    if ch < ' ' {
      return false
    }
  }
  true
}

///|
/// Rule MD-063: a file reference inside an FMU must stay inside the FMU
/// root: no absolute paths, no drive letters, no `..` segments, no colons,
/// no control characters, and no empty names.
pub fn is_safe_internal_path(text : String) -> Bool {
  if text == "" {
    return false
  }
  if text.contains("..") || text.contains(":") {
    return false
  }
  if text.has_prefix("/") || text.has_prefix("\\") {
    return false
  }
  for ch in text {
    if ch < ' ' {
      return false
    }
  }
  true
}
