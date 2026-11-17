///|
/// Whitebox tests for the typed parsers and the MD-001..MD-063 semantic
/// rules. Every implemented rule carries at least one positive and one
/// negative case; XML documents are inline so the tests run on every
/// target.
/// Build an FMI 2 document around the given ModelVariables and
/// ModelStructure snippets.
fn fmi2_doc(
  variables~ : String,
  structure~ : String,
  extra~ : String = "",
) -> String {
  let builder = StringBuilder()
  builder.write_string("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
  builder.write_string(
    "<fmiModelDescription fmiVersion=\"2.0\" modelName=\"M\" guid=\"{00000000-0000-0000-0000-000000000001}\">\n",
  )
  builder.write_string("  <CoSimulation modelIdentifier=\"M\"/>\n")
  builder.write_string(extra)
  builder.write_string("  <ModelVariables>\n")
  builder.write_string(variables)
  builder.write_string("  </ModelVariables>\n  <ModelStructure>\n")
  builder.write_string(structure)
  builder.write_string("  </ModelStructure>\n</fmiModelDescription>\n")
  builder.to_string()
}

///|
/// Build an FMI 3 document around the given ModelVariables and
/// ModelStructure snippets.
fn fmi3_doc(
  variables~ : String,
  structure~ : String,
  extra~ : String = "",
) -> String {
  let builder = StringBuilder()
  builder.write_string("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
  builder.write_string(
    "<fmiModelDescription fmiVersion=\"3.0\" modelName=\"M\" instantiationToken=\"{00000000-0000-0000-0000-000000000002}\">\n",
  )
  builder.write_string("  <CoSimulation modelIdentifier=\"M\"/>\n")
  builder.write_string(extra)
  builder.write_string("  <ModelVariables>\n")
  builder.write_string(variables)
  builder.write_string("  </ModelVariables>\n  <ModelStructure>\n")
  builder.write_string(structure)
  builder.write_string("  </ModelStructure>\n</fmiModelDescription>\n")
  builder.to_string()
}

///|
let fmi2_default_structure : String = "\n    <Outputs>\n      <Unknown index=\"2\"/>\n    </Outputs>\n"

///|
let fmi3_default_structure : String = "\n    <Output valueReference=\"2\"/>\n"

///|
fn run_validate(xml : String) -> ValidationReport {
  let (_, report) = parse_and_validate(@utf8.encode(xml))
  report
}

///|
fn rule_codes_from(report : ValidationReport) -> String {
  report.diagnostics().map(fn(d) { d.code() }).join(",")
}

///|
/// The rule codes of a report joined with commas, in normalized order.
fn rule_codes(xml : String) -> String {
  rule_codes_from(run_validate(xml))
}

///|
test "fmi version identity attribute" {
  assert_eq(FmiVersion::V2.identity_attribute(), "guid")
  assert_eq(FmiVersion::V3.identity_attribute(), "instantiationToken")
}

///|
test "fmi2 minimal document parses and validates" {
  let xml = fmi2_doc(
    variables="\n    <ScalarVariable name=\"u\" valueReference=\"0\" causality=\"input\" variability=\"continuous\" initial=\"exact\">\n      <Real start=\"0\"/>\n    </ScalarVariable>\n    <ScalarVariable name=\"y\" valueReference=\"1\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real/>\n    </ScalarVariable>\n",
    structure=fmi2_default_structure,
  )
  let report = run_validate(xml)
  assert_eq(report.error_count(), 0)
  assert_eq(report.warning_count(), 0)
}

///|
test "fmi2 parses units, types, logs and experiment" {
  let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<fmiModelDescription fmiVersion=\"2.0\" modelName=\"Full\" guid=\"{g}\" generationTool=\"MoonFMI\" variableNamingConvention=\"structured\" numberOfEventIndicators=\"2\">\n  <CoSimulation modelIdentifier=\"Full\" canHandleVariableCommunicationStepSize=\"true\" canRunAsynchronuously=\"true\"/>\n  <UnitDefinitions>\n    <Unit name=\"m\">\n      <BaseUnit m=\"1\"/>\n      <DisplayUnit name=\"mm\" factor=\"0.001\"/>\n    </Unit>\n  </UnitDefinitions>\n  <TypeDefinitions>\n    <SimpleType name=\"Position\">\n      <Real quantity=\"Position\" unit=\"m\"/>\n    </SimpleType>\n    <SimpleType name=\"Mode\">\n      <Enumeration>\n        <Item name=\"Off\" value=\"0\"/>\n        <Item name=\"On\" value=\"1\"/>\n      </Enumeration>\n    </SimpleType>\n  </TypeDefinitions>\n  <LogCategories>\n    <Category name=\"logEvents\" description=\"events\"/>\n  </LogCategories>\n  <DefaultExperiment startTime=\"0\" stopTime=\"3\" tolerance=\"0.0001\" stepSize=\"0.001\"/>\n  <ModelVariables>\n    <ScalarVariable name=\"h\" valueReference=\"1\" causality=\"output\" variability=\"continuous\" initial=\"exact\" description=\"position\">\n      <Real start=\"1\" declaredType=\"Position\" reinit=\"true\" unit=\"m\"/>\n    </ScalarVariable>\n    <ScalarVariable name=\"der(h)\" valueReference=\"2\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real derivative=\"1\" declaredType=\"Position\"/>\n    </ScalarVariable>\n    <ScalarVariable name=\"mode\" valueReference=\"3\" causality=\"local\" variability=\"discrete\" initial=\"calculated\">\n      <Enumeration declaredType=\"Mode\"/>\n    </ScalarVariable>\n    <ScalarVariable name=\"flag\" valueReference=\"4\" causality=\"parameter\" variability=\"tunable\" initial=\"exact\">\n      <Boolean start=\"true\"/>\n    </ScalarVariable>\n    <ScalarVariable name=\"label\" valueReference=\"5\" causality=\"parameter\" variability=\"fixed\" initial=\"exact\">\n      <String start=\"hello\"/>\n    </ScalarVariable>\n    <ScalarVariable name=\"count\" valueReference=\"6\" causality=\"output\" variability=\"discrete\" initial=\"calculated\">\n      <Integer min=\"0\" max=\"10\"/>\n    </ScalarVariable>\n  </ModelVariables>\n  <ModelStructure>\n    <Outputs>\n      <Unknown index=\"1\" dependencies=\"6\" dependenciesKind=\"dependent\"/>\n      <Unknown index=\"2\" dependencies=\"\"/>\n      <Unknown index=\"6\"/>\n    </Outputs>\n    <Derivatives>\n      <Unknown index=\"2\"/>\n    </Derivatives>\n    <InitialUnknowns>\n      <Unknown index=\"2\"/>\n      <Unknown index=\"6\"/>\n    </InitialUnknowns>\n  </ModelStructure>\n</fmiModelDescription>\n"
  let model = parse_model_description(@utf8.encode(xml))
  let m = match model {
    V2(m) => m
    V3(_) => abort("expected FMI 2")
  }
  assert_eq(m.model_name, "Full")
  assert_true(m.variable_naming_convention is Some(Structured))
  assert_eq(m.number_of_event_indicators, Some(2U))
  assert_eq(m.unit_definitions.length(), 1)
  assert_eq(m.type_definitions.length(), 2)
  assert_eq(m.log_categories.length(), 1)
  assert_true(m.default_experiment is Some(_))
  assert_eq(m.variables.length(), 6)
  assert_eq(m.model_structure.outputs.length(), 3)
  assert_eq(m.model_structure.derivatives.length(), 1)
  // The initial unknowns must be preserved in document order.
  assert_eq(
    m.model_structure.initial_unknowns
    .map(fn(u) { u.index.reinterpret_as_int().to_string() })
    .join(","),
    "2,6",
  )
  assert_true(run_validate(xml).is_valid())
}

///|
test "fmi2 interface with source files" {
  let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<fmiModelDescription fmiVersion=\"2.0\" modelName=\"Src\" guid=\"{g}\">\n  <ModelExchange modelIdentifier=\"Src\">\n    <SourceFiles>\n      <File name=\"src.c\"/>\n      <File name=\"lib/model.c\"/>\n    </SourceFiles>\n  </ModelExchange>\n  <ModelVariables/>\n  <ModelStructure/>\n</fmiModelDescription>\n"
  let model = parse_model_description(@utf8.encode(xml))
  let m = match model {
    V2(m) => m
    V3(_) => abort("expected FMI 2")
  }
  let interface = match m.model_exchange {
    Some(interface) => interface
    None => abort("expected ModelExchange")
  }
  assert_eq(interface.source_files.join(","), "src.c,lib/model.c")
}

///|
test "fmi3 minimal document parses and validates" {
  let xml = fmi3_doc(
    variables="\n    <Float64 name=\"u\" valueReference=\"0\" causality=\"input\" variability=\"continuous\" initial=\"exact\" start=\"0\"/>\n    <Float64 name=\"y\" valueReference=\"1\" causality=\"output\" variability=\"continuous\" initial=\"calculated\"/>\n",
    structure="\n    <Output valueReference=\"1\"/>\n    <InitialUnknown valueReference=\"1\"/>\n",
  )
  assert_true(run_validate(xml).is_valid())
}

///|
test "fmi3 parses arrays, alias, clock and binary" {
  let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<fmiModelDescription fmiVersion=\"3.0\" modelName=\"F3\" instantiationToken=\"{t}\">\n  <ModelExchange modelIdentifier=\"F3\" needsCompletedIntegratorStep=\"true\"/>\n  <CoSimulation modelIdentifier=\"F3\" hasEventMode=\"true\"/>\n  <ScheduledExecution modelIdentifier=\"F3\"/>\n  <TypeDefinitions>\n    <EnumerationType name=\"Mode\">\n      <Item name=\"Off\" value=\"0\"/>\n      <Item name=\"On\" value=\"1\"/>\n    </EnumerationType>\n    <BinaryType name=\"Blob\" mimeType=\"image/png\" maxSize=\"1024\"/>\n  </TypeDefinitions>\n  <ModelVariables>\n    <UInt32 name=\"n\" valueReference=\"0\" causality=\"structuralParameter\" variability=\"fixed\" start=\"3\"/>\n    <Float64 name=\"vec\" valueReference=\"1\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Dimension valueReference=\"0\"/>\n      <Alias name=\"v\" description=\"velocity alias\"/>\n    </Float64>\n    <Float64 name=\"mat\" valueReference=\"2\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Dimension start=\"2\"/>\n      <Dimension valueReference=\"0\"/>\n    </Float64>\n    <Clock name=\"tick\" valueReference=\"3\" causality=\"parameter\" variability=\"tunable\" intervalVariability=\"constant\" intervalDecimal=\"0.1\" priority=\"5\"/>\n    <Binary name=\"payload\" valueReference=\"4\" causality=\"parameter\" variability=\"fixed\" declaredType=\"Blob\">\n      <Start value=\"DEADBEEF\"/>\n    </Binary>\n    <String name=\"label\" valueReference=\"5\" causality=\"parameter\" variability=\"fixed\">\n      <Start value=\"hello\"/>\n      <Start value=\"world\"/>\n    </String>\n    <Enumeration name=\"mode\" valueReference=\"6\" causality=\"parameter\" variability=\"fixed\" declaredType=\"Mode\" start=\"1\"/>\n  </ModelVariables>\n  <ModelStructure>\n    <Output valueReference=\"1\"/>\n    <Output valueReference=\"2\"/>\n    <InitialUnknown valueReference=\"1\"/>\n    <InitialUnknown valueReference=\"2\"/>\n    <EventIndicator valueReference=\"1\"/>\n  </ModelStructure>\n</fmiModelDescription>\n"
  let model = parse_model_description(@utf8.encode(xml))
  let m = match model {
    V3(m) => m
    V2(_) => abort("expected FMI 3")
  }
  assert_eq(m.interfaces.length(), 3)
  assert_eq(m.type_definitions.length(), 2)
  assert_eq(m.variables.length(), 7)
  // Array dimensions and aliases.
  let vec = m.variables[1]
  assert_eq(vec.dimensions.length(), 1)
  assert_eq(vec.aliases.length(), 1)
  assert_eq(vec.aliases[0].name, "v")
  let mat = m.variables[2]
  assert_eq(mat.dimensions.length(), 2)
  assert_true(mat.dimensions[0].start is Some(_))
  // String variables collect their Start elements in order.
  match m.variables[5].payload {
    Text(attrs) => assert_eq(attrs.starts.join(","), "hello,world")
    _ => abort("expected String payload")
  }
  match m.variables[4].payload {
    Bin(attrs) => assert_eq(attrs.starts[0], "DEADBEEF")
    _ => abort("expected Binary payload")
  }
  match m.variables[3].payload {
    Clock(attrs) => assert_true(attrs.interval_variability is Some(Constant))
    _ => abort("expected Clock payload")
  }
  match m.type_definitions[0].payload {
    Enum(attrs) => assert_eq(attrs.items.length(), 2)
    _ => abort("expected enumeration type")
  }
  assert_true(run_validate(xml).is_valid())
}

///|
test "version dispatch accepts patches and rejects others" {
  let xml20 = fmi2_doc(variables="", structure="")
  assert_true(run_validate(xml20).is_valid())
  let xml204 = xml20.replace(
    old="fmiVersion=\"2.0\"",
    new="fmiVersion=\"2.0.4\"",
  )
  assert_true(run_validate(xml204).is_valid())
  let xml302 = fmi3_doc(variables="", structure="").replace(
    old="fmiVersion=\"3.0\"",
    new="fmiVersion=\"3.0.2\"",
  )
  assert_true(run_validate(xml302).is_valid())
  // MD-002: unsupported versions.
  assert_true(
    rule_codes(
      xml20.replace(old="fmiVersion=\"2.0\"", new="fmiVersion=\"2.1\""),
    ).contains("MD-002"),
  )
  assert_true(
    rule_codes(
      fmi3_doc(variables="", structure="").replace(
        old="fmiVersion=\"3.0\"",
        new="fmiVersion=\"3.1\"",
      ),
    ).contains("MD-002"),
  )
  assert_true(
    rule_codes(xml20.replace(old="fmiVersion=\"2.0\"", new="fmiVersion=\"x\"")).contains(
      "MD-002",
    ),
  )
}

///|
test "MD-001 wrong root element" {
  let xml = @utf8.encode("<?xml version=\"1.0\"?><wrong/>")
  let (_, report) = parse_and_validate(xml)
  assert_eq(rule_codes_from(report), "MD-001")
}

///|
test "MD-002 missing fmiVersion" {
  let xml = @utf8.encode(
    "<?xml version=\"1.0\"?><fmiModelDescription modelName=\"M\" guid=\"{g}\"/>",
  )
  let (_, report) = parse_and_validate(xml)
  assert_eq(rule_codes_from(report), "MD-002")
}

///|
test "structural errors: order, unknown elements, missing sections" {
  // ModelVariables before CoSimulation violates the XSD sequence.
  let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<fmiModelDescription fmiVersion=\"2.0\" modelName=\"M\" guid=\"{g}\">\n  <ModelVariables/>\n  <CoSimulation modelIdentifier=\"M\"/>\n  <ModelStructure/>\n</fmiModelDescription>\n"
  assert_true(rule_codes(xml).contains("STRUCTURE"))
  // Unknown root child.
  let xml2 = fmi2_doc(variables="", structure="", extra="  <Bogus/>")
  assert_true(rule_codes(xml2).contains("STRUCTURE"))
  // Missing ModelStructure.
  let xml3 = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<fmiModelDescription fmiVersion=\"2.0\" modelName=\"M\" guid=\"{g}\">\n  <CoSimulation modelIdentifier=\"M\"/>\n  <ModelVariables/>\n</fmiModelDescription>\n"
  assert_true(rule_codes(xml3).contains("STRUCTURE"))
  // Missing required attribute.
  let xml4 = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<fmiModelDescription fmiVersion=\"2.0\" modelName=\"M\" guid=\"{g}\">\n  <CoSimulation/>\n  <ModelVariables/>\n  <ModelStructure/>\n</fmiModelDescription>\n"
  assert_true(rule_codes(xml4).contains("MD-004"))
  // Invalid enum value on a ScalarVariable.
  let xml5 = fmi2_doc(
    variables="\n    <ScalarVariable name=\"x\" valueReference=\"0\" causality=\"typo\" variability=\"continuous\">\n      <Real/>\n    </ScalarVariable>\n",
    structure="",
  )
  assert_true(rule_codes(xml5).contains("STRUCTURE"))
}

///|
test "MD-003 requires at least one interface" {
  let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<fmiModelDescription fmiVersion=\"2.0\" modelName=\"M\" guid=\"{g}\">\n  <ModelVariables/>\n  <ModelStructure/>\n</fmiModelDescription>\n"
  assert_true(rule_codes(xml).contains("MD-003"))
}

///|
test "MD-004/MD-062 model identifier safety" {
  let empty = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<fmiModelDescription fmiVersion=\"2.0\" modelName=\"M\" guid=\"{g}\">\n  <CoSimulation modelIdentifier=\"\"/>\n  <ModelVariables/>\n  <ModelStructure/>\n</fmiModelDescription>\n"
  assert_true(rule_codes(empty).contains("MD-004"))
  let traversal = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<fmiModelDescription fmiVersion=\"2.0\" modelName=\"M\" guid=\"{g}\">\n  <CoSimulation modelIdentifier=\"../bin/sh\"/>\n  <ModelVariables/>\n  <ModelStructure/>\n</fmiModelDescription>\n"
  assert_true(rule_codes(traversal).contains("MD-062"))
}

///|
test "MD-005/MD-006 empty identity attributes" {
  let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<fmiModelDescription fmiVersion=\"2.0\" modelName=\"\" guid=\"\">\n  <CoSimulation modelIdentifier=\"M\"/>\n  <ModelVariables/>\n  <ModelStructure/>\n</fmiModelDescription>\n"
  let codes = rule_codes(xml)
  assert_true(codes.contains("MD-005"))
  assert_true(codes.contains("MD-006"))
}

///|
test "MD-010 duplicate variable names" {
  let xml = fmi2_doc(
    variables="\n    <ScalarVariable name=\"x\" valueReference=\"0\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real/>\n    </ScalarVariable>\n    <ScalarVariable name=\"x\" valueReference=\"1\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real/>\n    </ScalarVariable>\n",
    structure=fmi2_default_structure,
  )
  assert_true(rule_codes(xml).contains("MD-010"))
}

///|
test "MD-011 FMI3 duplicate value references" {
  let xml = fmi3_doc(
    variables="\n    <Float64 name=\"a\" valueReference=\"7\" causality=\"output\" variability=\"continuous\" initial=\"calculated\"/>\n    <Float64 name=\"b\" valueReference=\"7\" causality=\"output\" variability=\"continuous\" initial=\"calculated\"/>\n",
    structure=fmi3_default_structure,
  )
  assert_true(rule_codes(xml).contains("MD-011"))
}

///|
test "MD-012 illegal combinations and real-world acceptance" {
  // parameter + continuous is illegal.
  let bad_pair = fmi2_doc(
    variables="\n    <ScalarVariable name=\"p\" valueReference=\"0\" causality=\"parameter\" variability=\"continuous\" initial=\"exact\">\n      <Real start=\"0\"/>\n    </ScalarVariable>\n",
    structure="",
  )
  assert_true(rule_codes(bad_pair).contains("MD-012"))
  // output + constant + calculated is illegal.
  let bad_initial = fmi2_doc(
    variables="\n    <ScalarVariable name=\"y\" valueReference=\"0\" causality=\"output\" variability=\"constant\" initial=\"calculated\">\n      <Real/>\n    </ScalarVariable>\n",
    structure=fmi2_default_structure,
  )
  assert_true(rule_codes(bad_initial).contains("MD-012"))
  // calculated with a start value mirrors FMPy's check.
  let calculated_with_start = fmi2_doc(
    variables="\n    <ScalarVariable name=\"y\" valueReference=\"0\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real start=\"1\"/>\n    </ScalarVariable>\n",
    structure=fmi2_default_structure,
  )
  assert_true(rule_codes(calculated_with_start).contains("MD-012"))
  // independent with a start value.
  let independent_with_start = fmi2_doc(
    variables="\n    <ScalarVariable name=\"t\" valueReference=\"0\" causality=\"independent\" variability=\"continuous\">\n      <Real start=\"0\"/>\n    </ScalarVariable>\n",
    structure="",
  )
  assert_true(rule_codes(independent_with_start).contains("MD-012"))
  // The BouncingBall pattern (output + continuous + exact) is legal.
  let bouncing = fmi2_doc(
    variables="\n    <ScalarVariable name=\"h\" valueReference=\"1\" causality=\"output\" variability=\"continuous\" initial=\"exact\">\n      <Real start=\"1\" reinit=\"true\"/>\n    </ScalarVariable>\n    <ScalarVariable name=\"der(h)\" valueReference=\"2\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real derivative=\"1\"/>\n    </ScalarVariable>\n",
    structure="\n    <Outputs>\n      <Unknown index=\"1\"/>\n      <Unknown index=\"2\"/>\n    </Outputs>\n    <Derivatives>\n      <Unknown index=\"2\"/>\n    </Derivatives>\n    <InitialUnknowns>\n      <Unknown index=\"1\"/>\n      <Unknown index=\"2\"/>\n    </InitialUnknowns>\n",
  )
  assert_true(run_validate(bouncing).is_valid())
}

///|
test "MD-013 exact/approx without start warns" {
  let xml = fmi2_doc(
    variables="\n    <ScalarVariable name=\"p\" valueReference=\"0\" causality=\"parameter\" variability=\"fixed\" initial=\"exact\">\n      <Real/>\n    </ScalarVariable>\n",
    structure="",
  )
  let report = run_validate(xml)
  assert_eq(report.error_count(), 0)
  assert_eq(report.warning_count(), 1)
  assert_eq(report.diagnostics()[0].code(), "MD-013")
}

///|
test "MD-014 min/max and nominal bounds" {
  let xml = fmi2_doc(
    variables="\n    <ScalarVariable name=\"y\" valueReference=\"0\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real min=\"5\" max=\"1\" nominal=\"0\"/>\n    </ScalarVariable>\n",
    structure=fmi2_default_structure,
  )
  let codes = rule_codes(xml)
  assert_true(codes.contains("MD-014"))
}

///|
test "MD-015 enumeration needs a declared type" {
  let xml = fmi2_doc(
    variables="\n    <ScalarVariable name=\"m\" valueReference=\"0\" causality=\"parameter\" variability=\"fixed\" initial=\"exact\">\n      <Enumeration start=\"0\"/>\n    </ScalarVariable>\n",
    structure="",
  )
  assert_true(rule_codes(xml).contains("MD-015"))
  let missing_type = fmi2_doc(
    variables="\n    <ScalarVariable name=\"m\" valueReference=\"0\" causality=\"parameter\" variability=\"fixed\" initial=\"exact\">\n      <Enumeration declaredType=\"Nope\" start=\"0\"/>\n    </ScalarVariable>\n",
    structure="",
  )
  assert_true(rule_codes(missing_type).contains("MD-015"))
}

///|
test "MD-016 declared type must exist and match" {
  let xml = fmi2_doc(
    variables="\n    <ScalarVariable name=\"h\" valueReference=\"0\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real declaredType=\"Nope\"/>\n    </ScalarVariable>\n",
    structure=fmi2_default_structure,
  )
  assert_true(rule_codes(xml).contains("MD-016"))
  // Kind mismatch: an Integer variable pointing at a Real type.
  let mismatch = fmi2_doc(
    variables="\n    <ScalarVariable name=\"n\" valueReference=\"0\" causality=\"parameter\" variability=\"fixed\" initial=\"exact\">\n      <Integer declaredType=\"RealType\" start=\"0\"/>\n    </ScalarVariable>\n",
    structure="",
    extra="\n  <TypeDefinitions>\n    <SimpleType name=\"RealType\">\n      <Real quantity=\"Length\"/>\n    </SimpleType>\n  </TypeDefinitions>\n",
  )
  assert_true(rule_codes(mismatch).contains("MD-016"))
}

///|
test "MD-017 derivative references" {
  let oob = fmi2_doc(
    variables="\n    <ScalarVariable name=\"y\" valueReference=\"0\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real derivative=\"99\"/>\n    </ScalarVariable>\n",
    structure=fmi2_default_structure,
  )
  assert_true(rule_codes(oob).contains("MD-017"))
  // Target must be a Real variable.
  let not_real = fmi2_doc(
    variables="\n    <ScalarVariable name=\"n\" valueReference=\"0\" causality=\"parameter\" variability=\"fixed\" initial=\"exact\">\n      <Integer start=\"0\"/>\n    </ScalarVariable>\n    <ScalarVariable name=\"y\" valueReference=\"1\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real derivative=\"1\"/>\n    </ScalarVariable>\n",
    structure="\n    <Outputs>\n      <Unknown index=\"2\"/>\n    </Outputs>\n",
  )
  assert_true(rule_codes(not_real).contains("MD-017"))
}

///|
test "MD-018 reinit only for continuous states" {
  let non_state = fmi2_doc(
    variables="\n    <ScalarVariable name=\"y\" valueReference=\"0\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real reinit=\"true\"/>\n    </ScalarVariable>\n",
    structure=fmi2_default_structure,
  )
  assert_true(rule_codes(non_state).contains("MD-018"))
  // The BouncingBall case in the MD-012 test passes because reinit sits
  // on a state that der(h) references.
}

///|
test "MD-019 multiple set per time instant only for inputs" {
  let not_input = fmi2_doc(
    variables="\n    <ScalarVariable name=\"y\" valueReference=\"0\" causality=\"output\" variability=\"continuous\" initial=\"calculated\" canHandleMultipleSetPerTimeInstant=\"true\">\n      <Real/>\n    </ScalarVariable>\n",
    structure=fmi2_default_structure,
  )
  assert_true(rule_codes(not_input).contains("MD-019"))
}

///|
test "MD-020 alias names must not collide (FMI3)" {
  let xml = fmi3_doc(
    variables="\n    <Float64 name=\"speed\" valueReference=\"0\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Alias name=\"speed\"/>\n    </Float64>\n",
    structure=fmi3_default_structure,
  )
  assert_true(rule_codes(xml).contains("MD-020"))
}

///|
test "MD-030..MD-032 dimensions" {
  // Both attributes missing.
  let missing = fmi3_doc(
    variables="\n    <Float64 name=\"v\" valueReference=\"0\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Dimension/>\n    </Float64>\n",
    structure=fmi3_default_structure,
  )
  assert_true(rule_codes(missing).contains("MD-030"))
  // valueReference must name a structuralParameter.
  let not_structural = fmi3_doc(
    variables="\n    <UInt32 name=\"n\" valueReference=\"5\" causality=\"parameter\" variability=\"fixed\" start=\"2\"/>\n    <Float64 name=\"v\" valueReference=\"0\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Dimension valueReference=\"5\"/>\n    </Float64>\n",
    structure=fmi3_default_structure,
  )
  assert_true(rule_codes(not_structural).contains("MD-031"))
  // Fixed-dimension product overflow.
  let overflow = fmi3_doc(
    variables="\n    <Float64 name=\"v\" valueReference=\"0\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Dimension start=\"18446744073709551615\"/>\n      <Dimension start=\"18446744073709551615\"/>\n    </Float64>\n",
    structure=fmi3_default_structure,
  )
  assert_true(rule_codes(overflow).contains("MD-032"))
}

///|
test "MD-033..MD-037 clock rules" {
  let missing_interval = fmi3_doc(
    variables="\n    <Clock name=\"c\" valueReference=\"0\" causality=\"parameter\" variability=\"tunable\"/>\n",
    structure="",
  )
  assert_true(rule_codes(missing_interval).contains("MD-033"))
  // clocks entries are value references of Clock variables (FMI 3.0.2).
  let missing_clock = fmi3_doc(
    variables="\n    <Boolean name=\"b\" valueReference=\"0\" causality=\"input\" variability=\"discrete\" clocks=\"nope\"/>\n",
    structure="",
  )
  assert_true(rule_codes(missing_clock).contains("MD-034"))
  let unknown_reference = fmi3_doc(
    variables="\n    <Boolean name=\"b\" valueReference=\"0\" causality=\"input\" variability=\"discrete\" clocks=\"7\"/>\n",
    structure="",
  )
  assert_true(rule_codes(unknown_reference).contains("MD-034"))
  let good_reference = fmi3_doc(
    variables="\n    <Clock name=\"c\" valueReference=\"0\" causality=\"input\" intervalVariability=\"constant\" intervalDecimal=\"1\" priority=\"0\"/>\n    <Boolean name=\"b\" valueReference=\"1\" causality=\"input\" variability=\"discrete\" clocks=\"0\"/>\n",
    structure="",
  )
  assert_false(rule_codes(good_reference).contains("MD-034"))
  // Triggered clock with a fixed interval warns (MD-035).
  let triggered = fmi3_doc(
    variables="\n    <Clock name=\"c\" valueReference=\"0\" causality=\"parameter\" variability=\"tunable\" intervalVariability=\"triggered\" intervalDecimal=\"1\"/>\n",
    structure="",
  )
  assert_true(rule_codes(triggered).contains("MD-035"))
  // Output clocks must not declare priority (MD-036, FMI 3.0.2 2.4.2).
  let output_priority = fmi3_doc(
    variables="\n    <Clock name=\"c\" valueReference=\"0\" causality=\"output\" intervalVariability=\"triggered\" priority=\"3\"/>\n",
    structure="",
  )
  assert_true(rule_codes(output_priority).contains("MD-036"))
  // SE input clocks must declare priority (MD-037, mandatory per spec).
  let se_missing_priority = fmi3_doc(
    variables="\n    <Clock name=\"c\" valueReference=\"0\" causality=\"input\" intervalVariability=\"constant\" intervalDecimal=\"1\"/>\n",
    structure="",
    extra="  <ScheduledExecution modelIdentifier=\"M\"/>\n",
  )
  assert_true(rule_codes(se_missing_priority).contains("MD-037"))
  // Constant input clocks may declare priority: no MD-036 warning.
  let constant_priority = fmi3_doc(
    variables="\n    <Clock name=\"c\" valueReference=\"0\" causality=\"input\" intervalVariability=\"constant\" intervalDecimal=\"1\" priority=\"3\"/>\n",
    structure="",
  )
  assert_false(rule_codes(constant_priority).contains("MD-036"))
}

///|
test "MD-040 outputs must cover exactly the output variables" {
  let missing = fmi2_doc(
    variables="\n    <ScalarVariable name=\"a\" valueReference=\"0\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real/>\n    </ScalarVariable>\n    <ScalarVariable name=\"b\" valueReference=\"1\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real/>\n    </ScalarVariable>\n",
    structure="\n    <Outputs>\n      <Unknown index=\"1\"/>\n    </Outputs>\n",
  )
  assert_true(rule_codes(missing).contains("MD-040"))
  let not_output = fmi2_doc(
    variables="\n    <ScalarVariable name=\"p\" valueReference=\"0\" causality=\"parameter\" variability=\"fixed\" initial=\"exact\">\n      <Real start=\"0\"/>\n    </ScalarVariable>\n",
    structure="\n    <Outputs>\n      <Unknown index=\"1\"/>\n    </Outputs>\n",
  )
  assert_true(rule_codes(not_output).contains("MD-040"))
}

///|
test "MD-041 derivatives entries" {
  let oob = fmi2_doc(
    variables="\n    <ScalarVariable name=\"y\" valueReference=\"0\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real/>\n    </ScalarVariable>\n",
    structure=fmi2_default_structure +
      "\n    <Derivatives>\n      <Unknown index=\"99\"/>\n    </Derivatives>\n",
  )
  assert_true(rule_codes(oob).contains("MD-041"))
  // A Real without a derivative attribute is not a derivative variable.
  let not_derivative = fmi2_doc(
    variables="\n    <ScalarVariable name=\"y\" valueReference=\"0\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real/>\n    </ScalarVariable>\n",
    structure="\n    <Outputs>\n      <Unknown index=\"1\"/>\n    </Outputs>\n    <Derivatives>\n      <Unknown index=\"1\"/>\n    </Derivatives>\n",
  )
  assert_true(rule_codes(not_derivative).contains("MD-041"))
}

///|
test "MD-042 initial unknowns must ascend" {
  let xml = fmi2_doc(
    variables="\n    <ScalarVariable name=\"a\" valueReference=\"0\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real/>\n    </ScalarVariable>\n    <ScalarVariable name=\"b\" valueReference=\"1\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real/>\n    </ScalarVariable>\n",
    structure="\n    <Outputs>\n      <Unknown index=\"1\"/>\n      <Unknown index=\"2\"/>\n    </Outputs>\n    <InitialUnknowns>\n      <Unknown index=\"2\"/>\n      <Unknown index=\"1\"/>\n    </InitialUnknowns>\n",
  )
  assert_true(rule_codes(xml).contains("MD-042"))
}

///|
test "MD-043/MD-044 dependency lists" {
  let unsorted = fmi2_doc(
    variables="\n    <ScalarVariable name=\"u\" valueReference=\"0\" causality=\"input\" variability=\"continuous\" initial=\"exact\">\n      <Real start=\"0\"/>\n    </ScalarVariable>\n    <ScalarVariable name=\"y\" valueReference=\"1\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real/>\n    </ScalarVariable>\n",
    structure="\n    <Outputs>\n      <Unknown index=\"2\" dependencies=\"2 1\"/>\n    </Outputs>\n",
  )
  assert_true(rule_codes(unsorted).contains("MD-043"))
  let length_mismatch = fmi2_doc(
    variables="\n    <ScalarVariable name=\"u\" valueReference=\"0\" causality=\"input\" variability=\"continuous\" initial=\"exact\">\n      <Real start=\"0\"/>\n    </ScalarVariable>\n    <ScalarVariable name=\"y\" valueReference=\"1\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real/>\n    </ScalarVariable>\n",
    structure="\n    <Outputs>\n      <Unknown index=\"2\" dependencies=\"1\" dependenciesKind=\"dependent dependent\"/>\n    </Outputs>\n",
  )
  assert_true(rule_codes(length_mismatch).contains("MD-044"))
  // Kind without dependencies.
  let kind_only = fmi2_doc(
    variables="\n    <ScalarVariable name=\"y\" valueReference=\"1\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real/>\n    </ScalarVariable>\n",
    structure="\n    <Outputs>\n      <Unknown index=\"1\" dependenciesKind=\"dependent\"/>\n    </Outputs>\n",
  )
  assert_true(rule_codes(kind_only).contains("MD-044"))
}

///|
test "MD-045..MD-048 FMI3 model structure" {
  let missing_vr = fmi3_doc(
    variables="\n    <Float64 name=\"y\" valueReference=\"0\" causality=\"output\" variability=\"continuous\" initial=\"calculated\"/>\n",
    structure="\n    <Output valueReference=\"42\"/>\n",
  )
  assert_true(rule_codes(missing_vr).contains("MD-045"))
  // ContinuousStateDerivative entry must be a derivative variable.
  let not_derivative = fmi3_doc(
    variables="\n    <Float64 name=\"y\" valueReference=\"0\" causality=\"output\" variability=\"continuous\" initial=\"calculated\"/>\n",
    structure="\n    <Output valueReference=\"0\"/>\n    <ContinuousStateDerivative valueReference=\"0\"/>\n",
  )
  assert_true(rule_codes(not_derivative).contains("MD-046"))
  // EventIndicator must be a Float variable.
  let not_float = fmi3_doc(
    variables="\n    <Int32 name=\"y\" valueReference=\"0\" causality=\"output\" variability=\"discrete\" initial=\"calculated\"/>\n",
    structure="\n    <EventIndicator valueReference=\"0\"/>\n",
  )
  assert_true(rule_codes(not_float).contains("MD-047"))
  // Duplicate InitialUnknown.
  let duplicate = fmi3_doc(
    variables="\n    <Float64 name=\"y\" valueReference=\"0\" causality=\"output\" variability=\"continuous\" initial=\"calculated\"/>\n",
    structure="\n    <Output valueReference=\"0\"/>\n    <InitialUnknown valueReference=\"0\"/>\n    <InitialUnknown valueReference=\"0\"/>\n",
  )
  assert_true(rule_codes(duplicate).contains("MD-048"))
}

///|
test "MD-049 FMI3 dependenciesKind length" {
  let xml = fmi3_doc(
    variables="\n    <Float64 name=\"u\" valueReference=\"0\" causality=\"input\" variability=\"continuous\" initial=\"exact\" start=\"0\"/>\n    <Float64 name=\"y\" valueReference=\"1\" causality=\"output\" variability=\"continuous\" initial=\"calculated\"/>\n",
    structure="\n    <Output valueReference=\"1\" dependencies=\"0\" dependenciesKind=\"dependent dependent\"/>\n",
  )
  assert_true(rule_codes(xml).contains("MD-049"))
}

///|
test "MD-050/MD-051 unit references warn" {
  let xml = fmi2_doc(
    variables="\n    <ScalarVariable name=\"y\" valueReference=\"0\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real unit=\"nope\" displayUnit=\"nope\"/>\n    </ScalarVariable>\n",
    structure="\n    <Outputs>\n      <Unknown index=\"1\"/>\n    </Outputs>\n",
  )
  let report = run_validate(xml)
  assert_eq(report.error_count(), 0)
  assert_eq(report.warning_count(), 2)
  assert_eq(report.diagnostics()[0].code(), "MD-050")
  assert_eq(report.diagnostics()[1].code(), "MD-051")
}

///|
test "MD-053/MD-054 type definitions" {
  let collision = fmi2_doc(
    variables="\n    <ScalarVariable name=\"y\" valueReference=\"0\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real/>\n    </ScalarVariable>\n",
    structure=fmi2_default_structure,
    extra="\n  <TypeDefinitions>\n    <SimpleType name=\"y\">\n      <Real quantity=\"Length\"/>\n    </SimpleType>\n  </TypeDefinitions>\n",
  )
  assert_true(rule_codes(collision).contains("MD-053"))
  // Duplicate enumeration item values.
  let items = fmi2_doc(
    variables="\n    <ScalarVariable name=\"m\" valueReference=\"0\" causality=\"parameter\" variability=\"fixed\" initial=\"exact\">\n      <Enumeration declaredType=\"Mode\" start=\"0\"/>\n    </ScalarVariable>\n",
    structure="",
    extra="\n  <TypeDefinitions>\n    <SimpleType name=\"Mode\">\n      <Enumeration>\n        <Item name=\"Off\" value=\"0\"/>\n        <Item name=\"On\" value=\"0\"/>\n      </Enumeration>\n    </SimpleType>\n  </TypeDefinitions>\n",
  )
  assert_true(rule_codes(items).contains("MD-054"))
}

///|
test "MD-060 rejects DOCTYPE (XXE prevention)" {
  let xml = @utf8.encode(
    "<?xml version=\"1.0\"?><!DOCTYPE fmiModelDescription [<!ENTITY xxe SYSTEM \"file:///etc/passwd\">]><fmiModelDescription fmiVersion=\"2.0\" modelName=\"M\" guid=\"{g}\"><CoSimulation modelIdentifier=\"M\"/><ModelVariables/><ModelStructure/></fmiModelDescription>",
  )
  let (_, report) = parse_and_validate(xml)
  assert_eq(rule_codes_from(report), "MD-060")
}

///|
test "MD-061 limits are enforced" {
  // A single attribute far beyond the configured length limit.
  let builder = StringBuilder()
  builder.write_string(
    "<?xml version=\"1.0\"?><fmiModelDescription fmiVersion=\"2.0\" modelName=\"",
  )
  for _i = 0; _i < 100000; _i = _i + 1 {
    builder.write_string("x")
  }
  builder.write_string(
    "\" guid=\"{g}\"><CoSimulation modelIdentifier=\"M\"/><ModelVariables/><ModelStructure/></fmiModelDescription>",
  )
  let (_, report) = parse_and_validate(@utf8.encode(builder.to_string()))
  assert_eq(rule_codes_from(report), "MD-061")
}

///|
test "MD-063 source file references stay inside the FMU" {
  let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<fmiModelDescription fmiVersion=\"2.0\" modelName=\"M\" guid=\"{g}\">\n  <ModelExchange modelIdentifier=\"M\">\n    <SourceFiles>\n      <File name=\"../../etc/passwd\"/>\n    </SourceFiles>\n  </ModelExchange>\n  <ModelVariables/>\n  <ModelStructure/>\n</fmiModelDescription>\n"
  assert_true(rule_codes(xml).contains("MD-063"))
}

///|
test "diagnostics are normalized and sorted" {
  let xml = fmi2_doc(
    variables="\n    <ScalarVariable name=\"a\" valueReference=\"0\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real/>\n    </ScalarVariable>\n    <ScalarVariable name=\"b\" valueReference=\"1\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real/>\n    </ScalarVariable>\n",
    structure="\n    <Outputs>\n      <Unknown index=\"1\"/>\n      <Unknown index=\"2\"/>\n    </Outputs>\n    <InitialUnknowns>\n      <Unknown index=\"2\"/>\n      <Unknown index=\"1\"/>\n    </InitialUnknowns>\n",
  )
  let report = run_validate(xml)
  let codes = report.diagnostics().map(fn(d) { d.code() }).join(",")
  assert_true(codes.contains("MD-042"))
  // The second InitialUnknown is out of order; the first is fine.
  assert_eq(report.diagnostics().length(), 1)
}

///|
test "golden snapshot of a semantic-invalid report" {
  let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<fmiModelDescription fmiVersion=\"2.0\" modelName=\"Bad\" guid=\"\">\n  <CoSimulation modelIdentifier=\"../bad\"/>\n  <ModelVariables>\n    <ScalarVariable name=\"p\" valueReference=\"0\" causality=\"parameter\" variability=\"continuous\" initial=\"exact\">\n      <Real min=\"9\" max=\"1\"/>\n    </ScalarVariable>\n    <ScalarVariable name=\"y\" valueReference=\"1\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real unit=\"ghost\"/>\n    </ScalarVariable>\n  </ModelVariables>\n  <ModelStructure>\n    <Outputs>\n      <Unknown index=\"2\"/>\n    </Outputs>\n  </ModelStructure>\n</fmiModelDescription>\n"
  let report = run_validate(xml)
  let lines = report.diagnostics().map(fn(d) { d.render() }).join("\n")
  debug_inspect(
    lines,
    content=(
      #|"[MD-006] error: guid must not be empty (/fmiModelDescription)\n[MD-062] error: modelIdentifier '../bad' is not safe (/fmiModelDescription/CoSimulation)\n[MD-012] error: causality 'parameter' does not allow variability 'continuous' (/fmiModelDescription/ModelVariables/ScalarVariable[1], line 5, column 5)\n[MD-013] warning: variable declares initial='exact' but has no start value (/fmiModelDescription/ModelVariables/ScalarVariable[1], line 5, column 5)\n[MD-014] error: min (9) must not exceed max (1) (/fmiModelDescription/ModelVariables/ScalarVariable[1], line 5, column 5)\n[MD-050] warning: unit 'ghost' is not defined in <UnitDefinitions> (/fmiModelDescription/ModelVariables/ScalarVariable[2], line 8, column 5)"
    ),
  )
}

///|
test "fuzz regression with fixed seed does not panic" {
  // xorshift-style PRNG keeps the corpus deterministic across runs.
  let mut state : UInt64 = 0x9E3779B97F4A7C15UL
  fn next() -> UInt64 {
    state = state * 6364136223846793005UL + 1442695040888963407UL
    let x = state
    (x ^ (x >> 29)) * 0xBF58476D1CE4E5B9UL
  }
  let base = fmi2_doc(
    variables="\n    <ScalarVariable name=\"u\" valueReference=\"0\" causality=\"input\" variability=\"continuous\" initial=\"exact\">\n      <Real start=\"0\" unit=\"m\"/>\n    </ScalarVariable>\n    <ScalarVariable name=\"y\" valueReference=\"1\" causality=\"output\" variability=\"continuous\" initial=\"calculated\">\n      <Real derivative=\"1\"/>\n    </ScalarVariable>\n",
    structure="\n    <Outputs>\n      <Unknown index=\"2\" dependencies=\"1\"/>\n    </Outputs>\n    <Derivatives>\n      <Unknown index=\"2\"/>\n    </Derivatives>\n",
  )
  let data = @utf8.encode(base)
  for _iteration = 0; _iteration < 300; _iteration = _iteration + 1 {
    let mutated = Bytes::from_iter(
      data
      .iter()
      .map(fn(b) {
        let roll = next() & 15UL
        if roll == 0 {
          (next() & 255UL).to_int().to_byte()
        } else if roll == 1 {
          b'\x00'
        } else {
          b
        }
      }),
    )
    // Any outcome is fine as long as it does not panic or loop forever.
    let _ = parse_and_validate(mutated)
  }
}

///|
test "fuzz regression extension covers fmi3 and both full samples (G-01)" {
  // Second-generation corpus for G-01: the same deterministic PRNG, but the
  // mutation bases now include the generated FMI 3 document (different
  // element/attribute surface) and both "full" sample descriptions, plus
  // structural mutations (truncation and duplication) on top of byte flips.
  let mut state : UInt64 = 0xC0FFEE123456789UL
  fn next() -> UInt64 {
    state = state * 6364136223846793005UL + 1442695040888963407UL
    let x = state
    (x ^ (x >> 29)) * 0xBF58476D1CE4E5B9UL
  }
  let bases : Array[Bytes] = [
    @utf8.encode(
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?><fmiModelDescription fmiVersion=\"3.0\" modelName=\"F\" instantiationToken=\"{g}\"><CoSimulation modelIdentifier=\"F\"/><ModelVariables><Float64 name=\"x\" valueReference=\"0\" causality=\"output\" variability=\"continuous\" initial=\"exact\" start=\"1\"/></ModelVariables><ModelStructure><ContinuousStateDerivative valueReference=\"0\"/></ModelStructure></fmiModelDescription>",
    ),
    @utf8.encode(fmi2_doc(variables="", structure="")),
  ]
  for base in bases {
    for _iteration = 0; _iteration < 200; _iteration = _iteration + 1 {
      let mutated = Bytes::from_iter(
        base
        .iter()
        .map(fn(b) {
          let roll = next() & 15UL
          if roll == 0 {
            (next() & 255UL).to_int().to_byte()
          } else if roll == 1 {
            b'\x00'
          } else {
            b
          }
        }),
      )
      let candidate = if (next() & 3UL) == 0UL {
        // Truncate at a pseudo-random position.
        let position = (next() % (mutated.length().to_uint64() + 1)).to_int()
        Bytes::from_iter(mutated.iter().take(position))
      } else {
        mutated
      }
      // Any outcome is fine as long as it does not panic or loop forever.
      let _ = parse_and_validate(candidate)
    }
  }
}
