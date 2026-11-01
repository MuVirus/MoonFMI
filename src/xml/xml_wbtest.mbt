///|
const FMI2_MINIMAL : String = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
  "<fmiModelDescription fmiVersion=\"2.0\" modelName=\"BouncingBall\" guid=\"{8c4e810f-3df3-4a00-8276-176fa3c9f008}\">\n" +
  "  <ModelExchange modelIdentifier=\"BouncingBall\"/>\n" +
  "  <CoSimulation modelIdentifier=\"BouncingBall\" canHandleVariableCommunicationStepSize=\"true\"/>\n" +
  "  <DefaultExperiment startTime=\"0\" stopTime=\"3\"/>\n" +
  "  <ModelVariables>\n" +
  "    <ScalarVariable name=\"h\" valueReference=\"0\" causality=\"output\" variability=\"continuous\">\n" +
  "      <Real start=\"1\"/>\n" +
  "    </ScalarVariable>\n" +
  "  </ModelVariables>\n" +
  "</fmiModelDescription>\n"

///|
test "parses a model description into stable events" {
  let events = XmlReader::new(FMI2_MINIMAL).read_events()
  assert_true(
    events[0]
    is Declaration(version="1.0", encoding=Some("UTF-8"), standalone=None),
  )
  let root = match events[1] {
    Start(element) => element
    _ => abort("expected the root element")
  }
  assert_eq(root.name(), "fmiModelDescription")
  assert_eq(root.attribute("fmiVersion"), Some("2.0"))
  assert_eq(root.attribute("modelName"), Some("BouncingBall"))
  assert_eq(root.attribute("missing"), None)
  assert_eq(root.attributes().length(), 3)
  assert_eq(root.span().start().line(), 2)
  let first = root.attributes()[0]
  assert_eq(first.name(), "fmiVersion")
  assert_eq(first.value(), "2.0")
  assert_eq(first.span().start().line(), 2)
  assert_true(events[2] is Text(_))
  let exchange = match events[3] {
    Empty(element) => element
    _ => abort("expected a self-closing element")
  }
  assert_eq(exchange.name(), "ModelExchange")
  assert_true(events[events.length() - 2] is End("fmiModelDescription"))
  assert_true(events[events.length() - 1] is Eof)
}

///|
test "depth reflects open elements" {
  let reader = XmlReader::new("<a><b><c/></b></a>")
  assert_eq(reader.depth(), 0)
  assert_true(reader.read_event() is Start(_))
  assert_eq(reader.depth(), 1)
  assert_true(reader.read_event() is Start(_))
  assert_eq(reader.depth(), 2)
  assert_true(reader.read_event() is Empty(_))
  assert_eq(reader.depth(), 2)
  assert_true(reader.read_event() is End("b"))
  assert_eq(reader.depth(), 1)
  assert_true(reader.read_event() is End("a"))
  assert_eq(reader.depth(), 0)
  assert_true(reader.read_event() is Eof)
}

///|
test "unicode text and attributes survive decoding" {
  let events = XmlReader::new(
    "<模型 名称=\"弹球\"><变量>高度</变量><![CDATA[速率]]></模型>",
  ).read_events()
  let root = match events[0] {
    Start(element) => element
    _ => abort("expected the root element")
  }
  assert_eq(root.name(), "模型")
  assert_eq(root.attribute("名称"), Some("弹球"))
  assert_true(events[1] is Start(_))
  assert_true(events[2] is Text("高度"))
  assert_true(events[3] is End("变量"))
  assert_true(events[4] is CData("速率"))
  assert_true(events[5] is End("模型"))
}

///|
test "comments and processing instructions are exposed" {
  let events = XmlReader::new(
    "<?xml version=\"1.0\"?><!-- note --><?fmi data?><a/>",
  ).read_events()
  assert_true(events[1] is Comment(" note "))
  assert_true(events[2] is ProcessingInstruction(target="fmi", data="data"))
  assert_true(events[3] is Empty(_))
}

///|
test "truncated document fails with a line and column" {
  let error = try {
    let _ = XmlReader::new("<root>\n  <child>\n</root>").read_events()
    None
  } catch {
    error => Some(error)
  }
  assert_true(error is Some(_))
  let error = error.unwrap()
  assert_true(error is ParseError(..))
  assert_true(error.line() > 0)
  assert_true(error.column() > 0)
  assert_true(error.to_string().contains("line"))
}

///|
test "nesting deeper than the limit fails with a position" {
  let mut document = ""
  for _ in 0..<20 {
    document = document + "<a>"
  }
  for _ in 0..<20 {
    document = document + "</a>"
  }
  let observed = try {
    let _ = XmlReader::new(document, limits=XmlLimits::new(max_depth=4)).read_events()
    None
  } catch {
    LimitExceeded(message~, line~, column~) => Some((message, line, column))
    _ => None
  }
  assert_true(observed is Some(_))
  let (message, line, _) = observed.unwrap()
  assert_true(message.contains("depth"))
  assert_eq(line, 1)
}

///|
test "overlong attribute values are rejected before they are exposed" {
  let document = "<a value=\"" + "x".repeat(100) + "\"/>"
  let observed = try {
    let _ = XmlReader::new(
      document,
      limits=XmlLimits::new(max_attribute_length=16),
    ).read_events()
    false
  } catch {
    LimitExceeded(message~, ..) => message.contains("attribute")
    _ => false
  }
  assert_true(observed)
}

///|
test "oversized documents are rejected before parsing" {
  let observed = try {
    let _ = XmlReader::new("x".repeat(100), limits=XmlLimits::new(max_bytes=32))
    false
  } catch {
    LimitExceeded(message~, line~, column~) =>
      message.contains("size") && line == 1 && column == 1
    _ => false
  }
  assert_true(observed)
}

///|
test "DOCTYPE and billion laughs are rejected before entity expansion" {
  let document = "<?xml version=\"1.0\"?>\n" +
    "<!DOCTYPE lolz [\n" +
    "  <!ENTITY lol \"lol\">\n" +
    "  <!ENTITY lol2 \"&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;\">\n" +
    "  <!ENTITY lol3 \"&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;\">\n" +
    "]>\n" +
    "<lolz>&lol3;</lolz>"
  let observed = try {
    let _ = XmlReader::new(document).read_events()
    None
  } catch {
    DoctypeNotAllowed(line~, column~) => Some((line, column))
    _ => None
  }
  assert_eq(observed, Some((2, 1)))
}

///|
test "external entities are rejected through the DOCTYPE rule" {
  let document = "<?xml version=\"1.0\"?>\n" +
    "<!DOCTYPE foo [<!ENTITY xxe SYSTEM \"file:///etc/passwd\">]>\n" +
    "<foo>&xxe;</foo>"
  let observed = try {
    let _ = XmlReader::new(document).read_events()
    false
  } catch {
    DoctypeNotAllowed(..) => true
    _ => false
  }
  assert_true(observed)
}

///|
test "invalid UTF-8 bytes are rejected" {
  let data = Bytes::from_array([
    b'<', b'a', b'>', b'\xff', b'<', b'/', b'a', b'>',
  ])
  let observed = try {
    let _ = XmlReader::from_bytes(data)
    false
  } catch {
    InvalidInput(message~) => message.contains("UTF-8")
    _ => false
  }
  assert_true(observed)
}

///|
test "valid UTF-8 bytes decode" {
  let bytes = @utf8.encode("<a>弹球</a>")
  let events = XmlReader::from_bytes(bytes).read_events()
  assert_true(events[1] is Text("弹球"))
}

///|
test "error messages include line and column when known" {
  let error = try {
    let _ = XmlReader::new("<!DOCTYPE foo><foo/>")
    abort("expected DOCTYPE rejection")
  } catch {
    error => error
  }
  assert_eq(error.line(), 1)
  assert_eq(error.column(), 1)
  assert_true(error.to_string().contains("(line 1, column 1)"))
}
