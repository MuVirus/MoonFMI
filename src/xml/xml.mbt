///|
/// Limits applied before and while reading an XML document.
pub struct XmlLimits {
  max_bytes : Int32
  max_depth : Int32
  max_attributes : Int32
  max_attribute_length : Int32
}

///|
pub fn XmlLimits::default() -> XmlLimits {
  {
    max_bytes: 32 * 1024 * 1024,
    max_depth: 256,
    max_attributes: 1024,
    max_attribute_length: 64 * 1024,
  }
}

///|
pub fn XmlLimits::new(
  max_bytes~ : Int32 = 32 * 1024 * 1024,
  max_depth~ : Int32 = 256,
  max_attributes~ : Int32 = 1024,
  max_attribute_length~ : Int32 = 64 * 1024,
) -> XmlLimits {
  { max_bytes, max_depth, max_attributes, max_attribute_length, }
}

///|
pub fn XmlLimits::allows_size(self : XmlLimits, size : Int32) -> Bool {
  size >= 0 && size <= self.max_bytes
}

///|
pub fn XmlLimits::max_bytes(self : XmlLimits) -> Int32 {
  self.max_bytes
}

///|
pub fn XmlLimits::max_depth(self : XmlLimits) -> Int32 {
  self.max_depth
}

///|
/// A source position in the original document.
pub struct XmlPosition {
  line : Int32
  column : Int32
}

///|
pub fn XmlPosition::line(self : XmlPosition) -> Int32 {
  self.line
}

///|
pub fn XmlPosition::column(self : XmlPosition) -> Int32 {
  self.column
}

///|
pub struct XmlSpan {
  start : XmlPosition
  end : XmlPosition
}

///|
pub fn XmlSpan::start(self : XmlSpan) -> XmlPosition {
  self.start
}

///|
pub fn XmlSpan::end(self : XmlSpan) -> XmlPosition {
  self.end
}

///|
pub struct XmlAttribute {
  name : String
  value : String
  span : XmlSpan
}

///|
pub fn XmlAttribute::name(self : XmlAttribute) -> String {
  self.name
}

///|
pub fn XmlAttribute::value(self : XmlAttribute) -> String {
  self.value
}

///|
pub fn XmlAttribute::span(self : XmlAttribute) -> XmlSpan {
  self.span
}

///|
pub struct XmlElement {
  name : String
  attributes : Array[XmlAttribute]
  span : XmlSpan
}

///|
pub fn XmlElement::name(self : XmlElement) -> String {
  self.name
}

///|
pub fn XmlElement::attributes(self : XmlElement) -> Array[XmlAttribute] {
  self.attributes
}

///|
pub fn XmlElement::attribute(self : XmlElement, name : String) -> String? {
  for attribute in self.attributes {
    if attribute.name == name {
      return Some(attribute.value)
    }
  }
  None
}

///|
pub fn XmlElement::span(self : XmlElement) -> XmlSpan {
  self.span
}

///|
/// The stable event shape exposed to the rest of MoonFMI.
pub(all) enum XmlEvent {
  Start(XmlElement)
  End(String)
  Empty(XmlElement)
  Text(String)
  CData(String)
  Comment(String)
  ProcessingInstruction(target~ : String, data~ : String)
  Declaration(version~ : String, encoding~ : String?, standalone~ : String?)
  DocType
  Eof
}

///|
pub(all) suberror XmlError {
  InvalidInput(message~ : String)
  LimitExceeded(message~ : String, line~ : Int32, column~ : Int32)
  DoctypeNotAllowed(line~ : Int32, column~ : Int32)
  ParseError(message~ : String, line~ : Int32, column~ : Int32)
}

///|
pub fn XmlError::message(self : XmlError) -> String {
  match self {
    InvalidInput(message~) => message
    LimitExceeded(message~, ..) => message
    DoctypeNotAllowed(..) =>
      "DOCTYPE is not allowed in an FMI model description"
    ParseError(message~, ..) => message
  }
}

///|
pub fn XmlError::line(self : XmlError) -> Int32 {
  match self {
    InvalidInput(..) => 0
    LimitExceeded(line~, ..) => line
    DoctypeNotAllowed(line~, ..) => line
    ParseError(line~, ..) => line
  }
}

///|
pub fn XmlError::column(self : XmlError) -> Int32 {
  match self {
    InvalidInput(..) => 0
    LimitExceeded(column~, ..) => column
    DoctypeNotAllowed(column~, ..) => column
    ParseError(column~, ..) => column
  }
}

///|
pub fn XmlError::to_string(self : XmlError) -> String {
  let line = self.line()
  let column = self.column()
  if line > 0 {
    self.message() +
    " (line " +
    line.to_string() +
    ", column " +
    column.to_string() +
    ")"
  } else {
    self.message()
  }
}

///|
/// A pull reader with size, depth, and attribute limits on top of the XML
/// library. Entity expansion inside DOCTYPE is never reached because DOCTYPE
/// is rejected before the underlying reader is created.
pub struct XmlReader {
  inner : @xml_lib.Reader
  limits : XmlLimits
  mut depth : Int32
}

///|
pub fn XmlReader::new(
  input : String,
  limits~ : XmlLimits = XmlLimits::default(),
) -> XmlReader raise XmlError {
  if !limits.allows_size(input.length()) {
    raise LimitExceeded(
      message="XML document exceeds the configured size limit",
      line=1,
      column=1,
    )
  }
  reject_doctype(input)
  { inner: @xml_lib.Reader::from_string(input), limits, depth: 0, }
}

///|
pub fn XmlReader::from_bytes(
  data : Bytes,
  limits~ : XmlLimits = XmlLimits::default(),
) -> XmlReader raise XmlError {
  if !limits.allows_size(data.length()) {
    raise LimitExceeded(
      message="XML document exceeds the configured size limit",
      line=1,
      column=1,
    )
  }
  let decoder = @encoding.decoder(@encoding.UTF8)
  let input = decoder.decode(data.exact_view()) catch {
    _ => raise InvalidInput(message="XML document is not valid UTF-8")
  }
  XmlReader::new(input, limits~)
}

///|
pub fn XmlReader::depth(self : XmlReader) -> Int32 {
  self.depth
}

///|
pub fn XmlReader::line(self : XmlReader) -> Int32 {
  self.inner.line()
}

///|
pub fn XmlReader::column(self : XmlReader) -> Int32 {
  self.inner.column()
}

///|
pub fn XmlReader::read_event(self : XmlReader) -> XmlEvent raise XmlError {
  let event = self.inner.read_event() catch {
    error =>
      raise ParseError(
        message=error.to_string(),
        line=self.line(),
        column=self.column(),
      )
  }
  match event.kind {
    @xml_lib.Start(element) => {
      self.depth += 1
      if self.depth > self.limits.max_depth {
        raise LimitExceeded(
          message="XML nesting depth exceeds the configured limit",
          line=event.span.start.line,
          column=event.span.start.column,
        )
      }
      Start(convert_element(element, event.span, self.limits))
    }
    @xml_lib.End(name) => {
      if self.depth > 0 {
        self.depth -= 1
      }
      End(name)
    }
    @xml_lib.Empty(element) =>
      Empty(convert_element(element, event.span, self.limits))
    @xml_lib.Text(text) => Text(text)
    @xml_lib.CData(text) => CData(text)
    @xml_lib.Comment(text) => Comment(text)
    @xml_lib.PI(target~, data~) => ProcessingInstruction(target~, data~)
    @xml_lib.Decl(version~, encoding~, standalone~) =>
      Declaration(version~, encoding~, standalone~)
    @xml_lib.DocType(_) =>
      raise DoctypeNotAllowed(
        line=event.span.start.line,
        column=event.span.start.column,
      )
    @xml_lib.Eof => Eof
  }
}

///|
pub fn XmlReader::read_events(
  self : XmlReader,
) -> Array[XmlEvent] raise XmlError {
  let events : Array[XmlEvent] = []
  while true {
    let event = self.read_event()
    events.push(event)
    if event is Eof {
      break
    }
  }
  events
}

///|
fn convert_element(
  element : @xml_lib.XmlElement,
  span : @xml_lib.SourceSpan,
  limits : XmlLimits,
) -> XmlElement raise XmlError {
  if element.attributes.length() > limits.max_attributes {
    raise LimitExceeded(
      message="XML element has too many attributes",
      line=span.start.line,
      column=span.start.column,
    )
  }
  let attributes : Array[XmlAttribute] = []
  for attribute in element.attributes {
    if attribute.value.length() > limits.max_attribute_length {
      raise LimitExceeded(
        message="XML attribute value exceeds the configured limit",
        line=attribute.value_span.start.line,
        column=attribute.value_span.start.column,
      )
    }
    attributes.push({
      name: attribute.name,
      value: attribute.value,
      span: convert_span(attribute.span),
    })
  }
  { name: element.name, attributes, span: convert_span(span), }
}

///|
fn convert_span(span : @xml_lib.SourceSpan) -> XmlSpan {
  {
    start: { line: span.start.line, column: span.start.column, },
    end: { line: span.end.line, column: span.end.column, },
  }
}

///|
fn reject_doctype(input : String) -> Unit raise XmlError {
  let needle = "<!DOCTYPE"
  let mut index = 0
  while index + needle.length() <= input.length() {
    if is_doctype_at(input, index) {
      let position = position_at(input, index)
      raise DoctypeNotAllowed(line=position.0, column=position.1)
    }
    index += 1
  }
}

///|
fn is_doctype_at(input : String, index : Int32) -> Bool {
  let needle = "<!DOCTYPE"
  for offset = 0; offset < needle.length(); offset = offset + 1 {
    if ascii_upper(UInt16::unsafe_to_char(input[index + offset])) !=
      UInt16::unsafe_to_char(needle[offset]) {
      return false
    }
  }
  true
}

///|
fn ascii_upper(char : Char) -> Char {
  if char >= 'a' && char <= 'z' {
    Int32::unsafe_to_char(char.to_int() - 32)
  } else {
    char
  }
}

///|
fn position_at(input : String, index : Int32) -> (Int32, Int32) {
  let mut line = 1
  let mut column = 1
  for i = 0; i < index; i = i + 1 {
    if input[i] == '\n' {
      line += 1
      column = 1
    } else {
      column += 1
    }
  }
  (line, column)
}
