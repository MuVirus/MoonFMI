///|
/// Short aliases so the parser files read like the XSD.
type XmlReader = @xml.XmlReader

///|
type XmlEvent = @xml.XmlEvent

///|
type XmlElement = @xml.XmlElement

///|
type XmlError = @xml.XmlError

///|
/// Lookahead cursor over the XML event stream. Comments, processing
/// instructions, the XML declaration, and whitespace-only text are skipped;
/// stray text content is a structure error. All `XmlError`s from the
/// underlying reader are converted to `SchemaError` diagnostics so the
/// parser only ever raises `SchemaError`.
priv struct Cursor {
  reader : XmlReader
  mut buffer : XmlEvent?
  mut path : String
}

///|
fn Cursor::new(reader : XmlReader, root_path~ : String) -> Cursor {
  { reader, buffer: None, path: root_path, }
}

///|
fn Cursor::set_path(self : Cursor, path : String) -> Unit {
  self.path = path
}

///|
fn Cursor::fail(
  self : Cursor,
  code~ : String = "STRUCTURE",
  message~ : String,
  hint? : String,
) -> SchemaError {
  Failed(
    Diagnostic::new(
      code~,
      severity=Error,
      message~,
      path=self.path,
      line=self.reader.line(),
      column=self.reader.column(),
      hint?,
    ),
  )
}

///|
fn is_ws_text(text : String) -> Bool {
  for ch in text {
    if !(ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
      return false
    }
  }
  true
}

///|
/// Return the next significant event without consuming it.
fn Cursor::peek(self : Cursor) -> XmlEvent raise SchemaError {
  if self.buffer is Some(event) {
    return event
  }
  let event = self.read_normalized()
  self.buffer = Some(event)
  event
}

///|
/// Consume and return the next significant event.
fn Cursor::next(self : Cursor) -> XmlEvent raise SchemaError {
  match self.buffer {
    Some(event) => {
      self.buffer = None
      event
    }
    None => self.read_normalized()
  }
}

///|
fn Cursor::read_normalized(self : Cursor) -> XmlEvent raise SchemaError {
  while true {
    let event = self.reader.read_event() catch {
      error =>
        raise Failed(
          Diagnostic::new(
            code=xml_error_code(error),
            severity=Error,
            message=error.message(),
            path=self.path,
            line=error.line(),
            column=error.column(),
          ),
        )
    }
    match event {
      Comment(_) => continue
      ProcessingInstruction(..) => continue
      Declaration(..) => continue
      Text(text) =>
        if is_ws_text(text) {
          continue
        } else {
          raise self.fail(
            message="unexpected text content in '\{last_path_segment(self.path)}'",
            hint="FMI model descriptions carry all data in attributes; element text is not allowed",
          )
        }
      CData(_) =>
        raise self.fail(
          message="CDATA sections are not allowed in an FMI model description",
        )
      other => return other
    }
  }
  abort("unreachable")
}

///|
/// Map an XML-layer error to a diagnostic code. DOCTYPE is rule MD-060 and
/// limit violations are rule MD-061; everything else is lexical.
fn xml_error_code(error : XmlError) -> String {
  match error {
    DoctypeNotAllowed(..) => "MD-060"
    LimitExceeded(..) => "MD-061"
    _ => "XML"
  }
}

///|
fn last_path_segment(path : String) -> String {
  let mut start = 0
  for index, ch in path {
    if ch == '/' {
      start = index + 1
    }
  }
  let builder = StringBuilder()
  for index = start; index < path.length(); index = index + 1 {
    builder.write_char(UInt16::unsafe_to_char(path[index]))
  }
  builder.to_string()
}

///|
/// Consume an already-peeked empty element, or a full subtree rooted at the
/// current start element. Used for skipped content such as annotations.
fn Cursor::skip_subtree(
  self : Cursor,
  element_name : String,
) -> Unit raise SchemaError {
  let mut depth = 0
  while true {
    let event = self.peek()
    match event {
      Eof =>
        raise self.fail(
          message="unexpected end of document inside <\{element_name}>",
        )
      End(_) =>
        if depth == 0 {
          let _ = self.next()
          return
        } else {
          depth -= 1
          let _ = self.next()
        }
      Start(el) => {
        depth += 1
        let _ = self.next()
        let _ = el
      }
      Empty(_) => {
        let _ = self.next()
        if depth == 0 {
          return
        }
      }
      Text(_)
      | CData(_)
      | Declaration(..)
      | Comment(_)
      | ProcessingInstruction(..)
      | DocType => {
        // read_normalized never yields these; consume defensively.
        let _ = self.next()
      }
    }
  }
}

///|
/// The number of times `name` occurs among the element's attributes.
fn attribute_count(element : XmlElement, name : String) -> Int32 {
  let mut count = 0
  for attribute in element.attributes {
    if attribute.name == name {
      count += 1
    }
  }
  count
}

///|
/// Read an optional attribute, rejecting duplicates.
fn optional_attr(
  element : XmlElement,
  name : String,
  path~ : String,
) -> String? raise SchemaError {
  if attribute_count(element, name) > 1 {
    raise structure_error(
      message="duplicate attribute '\{name}'",
      path~,
      line=element.span.start.line,
      column=element.span.start.column,
    )
  }
  element.attribute(name)
}

///|
/// Read a required attribute; a missing attribute is a structure error.
fn required_attr(
  element : XmlElement,
  name : String,
  path~ : String,
  code~ : String = "STRUCTURE",
  hint? : String,
) -> String raise SchemaError {
  let value = optional_attr(element, name, path~)
  match value {
    Some(value) => value
    None =>
      raise Failed(
        Diagnostic::new(
          code~,
          severity=Error,
          message="required attribute '\{name}' is missing",
          path~,
          line=element.span.start.line,
          column=element.span.start.column,
          hint?,
        ),
      )
  }
}

///|
/// Reject attributes outside the XSD-allowed set (FMI 2 is strict).
fn check_no_unknown_attrs(
  element : XmlElement,
  allowed : Array[String],
  path~ : String,
) -> Unit raise SchemaError {
  for attribute in element.attributes {
    let mut found = false
    for name in allowed {
      if attribute.name == name {
        found = true
        break
      }
    }
    if !found {
      raise structure_error(
        message="unknown attribute '\{attribute.name}' on <\{element.name}>",
        path~,
        line=attribute.span.start.line,
        column=attribute.span.start.column,
      )
    }
  }
}

///|
/// Read an optional boolean attribute (`true`/`false`/`1`/`0`).
fn optional_bool(
  element : XmlElement,
  name : String,
  path~ : String,
) -> Bool? raise SchemaError {
  match optional_attr(element, name, path~) {
    Some(text) =>
      Some(
        parse_bool_value(
          text,
          path~,
          line=line_of(element),
          column=column_of(element),
        ),
      )
    None => None
  }
}

///|
fn optional_double(
  element : XmlElement,
  name : String,
  path~ : String,
) -> Double? raise SchemaError {
  match optional_attr(element, name, path~) {
    Some(text) =>
      Some(
        parse_double_value(
          text,
          path~,
          line=line_of(element),
          column=column_of(element),
        ),
      )
    None => None
  }
}

///|
fn optional_uint32(
  element : XmlElement,
  name : String,
  path~ : String,
) -> UInt32? raise SchemaError {
  match optional_attr(element, name, path~) {
    Some(text) =>
      Some(
        parse_uint32_value(
          text,
          path~,
          line=line_of(element),
          column=column_of(element),
        ),
      )
    None => None
  }
}

///|
fn optional_int32(
  element : XmlElement,
  name : String,
  path~ : String,
) -> Int32? raise SchemaError {
  match optional_attr(element, name, path~) {
    Some(text) =>
      Some(
        parse_int32_value(
          text,
          path~,
          line=line_of(element),
          column=column_of(element),
        ),
      )
    None => None
  }
}

///|
fn optional_int64(
  element : XmlElement,
  name : String,
  path~ : String,
) -> Int64? raise SchemaError {
  match optional_attr(element, name, path~) {
    Some(text) =>
      Some(
        parse_int64_value(
          text,
          path~,
          line=line_of(element),
          column=column_of(element),
        ),
      )
    None => None
  }
}

///|
fn optional_uint64(
  element : XmlElement,
  name : String,
  path~ : String,
) -> UInt64? raise SchemaError {
  match optional_attr(element, name, path~) {
    Some(text) =>
      Some(
        parse_uint64_value(
          text,
          path~,
          line=line_of(element),
          column=column_of(element),
        ),
      )
    None => None
  }
}

///|
fn line_of(element : XmlElement) -> Int32 {
  element.span.start.line
}

///|
fn column_of(element : XmlElement) -> Int32 {
  element.span.start.column
}

///|
/// Read an optional enumeration attribute; an unknown value is a structure
/// error with the offending text in the message.
fn[T] optional_enum(
  element : XmlElement,
  name : String,
  parse : (String) -> T?,
  path~ : String,
) -> T? raise SchemaError {
  match optional_attr(element, name, path~) {
    Some(text) =>
      match parse(text) {
        Some(value) => Some(value)
        None =>
          raise structure_error(
            message="'\{text}' is not a valid value for attribute '\{name}'",
            path~,
            line=line_of(element),
            column=column_of(element),
          )
      }
    None => None
  }
}

///|
/// Parse a whitespace-separated list of unsigned integers
/// (`dependencies="1 2 3"`).
fn optional_uint32_list(
  element : XmlElement,
  name : String,
  path~ : String,
) -> Array[UInt32]? raise SchemaError {
  match optional_attr(element, name, path~) {
    Some(text) => {
      let result : Array[UInt32] = []
      for item in split_ws_list(text) {
        result.push(
          parse_uint32_value(
            item,
            path~,
            line=line_of(element),
            column=column_of(element),
          ),
        )
      }
      Some(result)
    }
    None => None
  }
}

///|
/// Parse a whitespace-separated list of dependency kinds.
fn optional_dependency_kind_list(
  element : XmlElement,
  name : String,
  path~ : String,
) -> Array[DependencyKind]? raise SchemaError {
  match optional_attr(element, name, path~) {
    Some(text) => {
      let result : Array[DependencyKind] = []
      for item in split_ws_list(text) {
        match DependencyKind::parse(item) {
          Some(kind) => result.push(kind)
          None =>
            raise structure_error(
              message="'\{item}' is not a valid dependenciesKind value",
              path~,
              line=line_of(element),
              column=column_of(element),
            )
        }
      }
      Some(result)
    }
    None => None
  }
}
