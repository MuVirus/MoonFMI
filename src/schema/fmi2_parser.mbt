///|
/// FMI 2 typed-model parser. Consumes the XML event stream after the root
/// start element and enforces the XSD `xs:sequence` order of the root
/// children and of the model structure.
let fmi2_root_order : Array[String] = [
  "ModelExchange", "CoSimulation", "UnitDefinitions", "TypeDefinitions", "LogCategories",
  "DefaultExperiment", "VendorAnnotations", "ModelVariables", "ModelStructure",
]

///|
/// Consume `</name>`; any other event is an error.
fn expect_end(cursor : Cursor, name : String) -> Unit raise SchemaError {
  while true {
    match cursor.peek() {
      Eof =>
        raise cursor.fail(
          message="unexpected end of document, expected </\{name}>",
        )
      End(end_name) =>
        if end_name == name {
          let _ = cursor.next()
          return
        } else {
          raise cursor.fail(
            message="unexpected end element </\{end_name}>, expected </\{name}>",
          )
        }
      Start(child) | Empty(child) =>
        raise cursor.fail(
          message="unexpected element <\{child.name}> inside <\{name}>",
        )
      Text(_)
      | CData(_)
      | Declaration(..)
      | Comment(_)
      | ProcessingInstruction(..)
      | DocType => {
        // read_normalized never yields these; consume defensively.
        let _ = cursor.next()
      }
    }
  }
}

///|
/// After consuming the start element of `name`, consume its end element.
/// Self-closing (`Empty`) elements have nothing to consume.
fn finish_element(
  cursor : Cursor,
  name : String,
  had_start : Bool,
) -> Unit raise SchemaError {
  if had_start {
    expect_end(cursor, name)
  }
}

///|
fn parse_fmi2_model(
  cursor : Cursor,
  root : XmlElement,
) -> Fmi2ModelDescription raise SchemaError {
  let root_path = "/fmiModelDescription"
  cursor.set_path(root_path)
  let model_name = required_attr(
    root,
    "modelName",
    path=root_path,
    code="MD-005",
    hint="every FMI 2 model description needs a non-empty modelName",
  )
  let guid = required_attr(
    root,
    "guid",
    path=root_path,
    code="MD-006",
    hint="every FMI 2 model description needs a non-empty guid",
  )
  let naming = optional_enum(
    root,
    "variableNamingConvention",
    NamingConvention::parse,
    path=root_path,
  )
  let description = optional_attr(root, "description", path=root_path)
  let author = optional_attr(root, "author", path=root_path)
  let version = optional_attr(root, "version", path=root_path)
  let copyright = optional_attr(root, "copyright", path=root_path)
  let license = optional_attr(root, "license", path=root_path)
  let generation_tool = optional_attr(root, "generationTool", path=root_path)
  let generation_date = optional_attr(
    root,
    "generationDateAndTime",
    path=root_path,
  )
  let event_indicators = optional_uint32(
    root,
    "numberOfEventIndicators",
    path=root_path,
  )
  let mut model_exchange : Fmi2Interface? = None
  let mut co_simulation : Fmi2Interface? = None
  let mut units : Array[UnitDef] = []
  let mut types : Array[Fmi2TypeDefinition] = []
  let mut log_categories : Array[LogCategory] = []
  let mut experiment : DefaultExperiment? = None
  let mut variables : Array[Fmi2ScalarVariable] = []
  let mut structure : Fmi2ModelStructure? = None
  let mut order_index = 0
  let mut seen_variables = false
  let mut seen_structure = false
  while true {
    let event = cursor.peek()
    match event {
      Eof =>
        raise cursor.fail(
          message="unexpected end of document inside <fmiModelDescription>",
        )
      End(name) =>
        if name == "fmiModelDescription" {
          let _ = cursor.next()
          break
        } else {
          raise cursor.fail(
            message="unexpected end element </\{name}> inside <fmiModelDescription>",
          )
        }
      Start(element) | Empty(element) => {
        let position = index_in_order(fmi2_root_order, element.name)
        if position < 0 {
          raise cursor.fail(
            message="unexpected element <\{element.name}> in <fmiModelDescription>",
            hint="allowed root children: " + fmi2_root_order.join(", "),
          )
        }
        if position < order_index {
          raise cursor.fail(
            message="element <\{element.name}> is out of order",
            hint="the XSD fixes the root order to " + fmi2_root_order.join(", "),
          )
        }
        order_index = position + 1
        let _ = cursor.next()
        match element.name {
          "ModelExchange" =>
            model_exchange = Some(
              parse_fmi2_interface(
                cursor,
                element,
                InterfaceKind::ModelExchange,
                had_start=event is Start(_),
              ),
            )
          "CoSimulation" =>
            co_simulation = Some(
              parse_fmi2_interface(
                cursor,
                element,
                InterfaceKind::CoSimulation,
                had_start=event is Start(_),
              ),
            )
          "UnitDefinitions" =>
            units = parse_fmi2_units(cursor, had_start=event is Start(_))
          "TypeDefinitions" =>
            types = parse_fmi2_type_definitions(
              cursor,
              had_start=event is Start(_),
            )
          "LogCategories" =>
            log_categories = parse_fmi2_log_categories(
              cursor,
              had_start=event is Start(_),
            )
          "DefaultExperiment" =>
            experiment = Some(parse_fmi2_experiment(element))
          "VendorAnnotations" =>
            if event is Start(_) {
              cursor.skip_subtree("VendorAnnotations")
            }
          "ModelVariables" => {
            variables = parse_fmi2_variables(
              cursor,
              had_start=event is Start(_),
            )
            seen_variables = true
          }
          "ModelStructure" => {
            structure = Some(
              parse_fmi2_model_structure(cursor, had_start=event is Start(_)),
            )
            seen_structure = true
          }
          _ => abort("unreachable")
        }
      }
      Text(_)
      | CData(_)
      | Declaration(..)
      | Comment(_)
      | ProcessingInstruction(..)
      | DocType => {
        // read_normalized never yields these; consume defensively.
        let _ = cursor.next()
      }
    }
  }
  if !seen_variables {
    raise cursor.fail(message="required element <ModelVariables> is missing")
  }
  if !seen_structure {
    raise cursor.fail(message="required element <ModelStructure> is missing")
  }
  {
    fmi_version: root.attribute("fmiVersion").unwrap_or(""),
    model_name,
    guid,
    description,
    author,
    version,
    copyright,
    license,
    generation_tool,
    generation_date_and_time: generation_date,
    variable_naming_convention: naming,
    number_of_event_indicators: event_indicators,
    model_exchange,
    co_simulation,
    unit_definitions: units,
    type_definitions: types,
    log_categories,
    default_experiment: experiment,
    variables,
    model_structure: match structure {
      Some(value) => value
      None => { outputs: [], derivatives: [], initial_unknowns: [], }
    },
  }
}

///|
fn index_in_order(order : Array[String], name : String) -> Int32 {
  for index, candidate in order {
    if candidate == name {
      return index
    }
  }
  -1
}

///|
let fmi2_interface_attrs : Array[String] = [
  "modelIdentifier", "needsExecutionTool", "completedIntegratorStepNotNeeded", "canHandleVariableCommunicationStepSize",
  "canInterpolateInputs", "maxOutputDerivativeOrder", "canRunAsynchronuously", "canBeInstantiatedOnlyOncePerProcess",
  "canNotUseMemoryManagementFunctions", "canGetAndSetFMUstate", "canSerializeFMUstate",
  "providesDirectionalDerivative",
]

///|
fn parse_fmi2_interface(
  cursor : Cursor,
  element : XmlElement,
  kind : InterfaceKind,
  had_start~ : Bool,
) -> Fmi2Interface raise SchemaError {
  let path = "\{cursor.path}/\{element.name}"
  cursor.set_path(path)
  check_no_unknown_attrs(element, fmi2_interface_attrs, path~)
  let model_identifier = required_attr(
    element,
    "modelIdentifier",
    path~,
    code="MD-004",
    hint="each interface needs a modelIdentifier that names the shared library",
  )
  let interface : Fmi2Interface = {
    kind,
    model_identifier,
    needs_execution_tool: optional_bool(element, "needsExecutionTool", path~),
    completed_integrator_step_not_needed: optional_bool(
      element,
      "completedIntegratorStepNotNeeded",
      path~,
    ),
    can_handle_variable_communication_step_size: optional_bool(
      element,
      "canHandleVariableCommunicationStepSize",
      path~,
    ),
    can_interpolate_inputs: optional_bool(
      element,
      "canInterpolateInputs",
      path~,
    ),
    max_output_derivative_order: optional_uint32(
      element,
      "maxOutputDerivativeOrder",
      path~,
    ),
    can_run_asynchronuously: optional_bool(
      element,
      "canRunAsynchronuously",
      path~,
    ),
    can_be_instantiated_only_once_per_process: optional_bool(
      element,
      "canBeInstantiatedOnlyOncePerProcess",
      path~,
    ),
    can_not_use_memory_management_functions: optional_bool(
      element,
      "canNotUseMemoryManagementFunctions",
      path~,
    ),
    can_get_and_set_fmustate: optional_bool(
      element,
      "canGetAndSetFMUstate",
      path~,
    ),
    can_serialize_fmustate: optional_bool(
      element,
      "canSerializeFMUstate",
      path~,
    ),
    provides_directional_derivative: optional_bool(
      element,
      "providesDirectionalDerivative",
      path~,
    ),
    source_files: [],
    line: line_of(element),
    column: column_of(element),
  }
  if !had_start {
    // Self-closing interface element: attributes only, nothing to consume.
    cursor.set_path("/fmiModelDescription")
    return interface
  }
  let mut seen_source_files = false
  while true {
    match cursor.peek() {
      Eof =>
        raise cursor.fail(
          message="unexpected end of document inside <\{element.name}>",
        )
      End(name) =>
        if name == element.name {
          let _ = cursor.next()
          break
        } else {
          raise cursor.fail(
            message="unexpected end element </\{name}>, expected </\{element.name}>",
          )
        }
      Start(child) | Empty(child) => {
        if child.name != "SourceFiles" || seen_source_files {
          raise cursor.fail(
            message="unexpected element <\{child.name}> inside <\{element.name}>",
            hint="only one optional <SourceFiles> may appear inside an interface element",
          )
        }
        seen_source_files = true
        let _ = cursor.next()
        // parse_fmi2_source_files consumes the closing </SourceFiles>
        // itself, so there is nothing left for finish_element here.
        let parsed_files = parse_fmi2_source_files(cursor)
        for file in parsed_files {
          interface.source_files.push(file)
        }
      }
      Text(_)
      | CData(_)
      | Declaration(..)
      | Comment(_)
      | ProcessingInstruction(..)
      | DocType => {
        let _ = cursor.next()
      }
    }
  }
  cursor.set_path("/fmiModelDescription")
  interface
}

///|
fn parse_fmi2_source_files(cursor : Cursor) -> Array[String] raise SchemaError {
  let files : Array[String] = []
  while true {
    match cursor.peek() {
      Eof =>
        raise cursor.fail(
          message="unexpected end of document inside <SourceFiles>",
        )
      End(name) =>
        if name == "SourceFiles" {
          let _ = cursor.next()
          return files
        } else {
          raise cursor.fail(
            message="unexpected end element </\{name}>, expected </SourceFiles>",
          )
        }
      Start(element) | Empty(element) => {
        if element.name != "File" {
          raise cursor.fail(
            message="unexpected element <\{element.name}> inside <SourceFiles>",
            hint="only <File> elements are allowed here",
          )
        }
        let path = "\{cursor.path}/File"
        let had_start = cursor.peek() is Start(_)
        let _ = cursor.next()
        let name = required_attr(element, "name", path~)
        finish_element(cursor, "File", had_start)
        files.push(name)
      }
      Text(_)
      | CData(_)
      | Declaration(..)
      | Comment(_)
      | ProcessingInstruction(..)
      | DocType => {
        let _ = cursor.next()
      }
    }
  }
  files
}

///|
fn parse_fmi2_units(
  cursor : Cursor,
  had_start~ : Bool,
) -> Array[UnitDef] raise SchemaError {
  let units : Array[UnitDef] = []
  let parent = cursor.path
  if !had_start {
    cursor.set_path(parent)
    return units
  }
  while true {
    match cursor.peek() {
      Eof =>
        raise cursor.fail(
          message="unexpected end of document inside <UnitDefinitions>",
        )
      End(name) =>
        if name == "UnitDefinitions" {
          let _ = cursor.next()
          return units
        } else {
          raise cursor.fail(
            message="unexpected end element </\{name}>, expected </UnitDefinitions>",
          )
        }
      Start(element) | Empty(element) => {
        if element.name != "Unit" {
          raise cursor.fail(
            message="unexpected element <\{element.name}> inside <UnitDefinitions>",
            hint="only <Unit> elements are allowed here",
          )
        }
        let had_start = cursor.peek() is Start(_)
        let _ = cursor.next()
        units.push(parse_fmi2_unit(cursor, element, parent, had_start~))
      }
      Text(_)
      | CData(_)
      | Declaration(..)
      | Comment(_)
      | ProcessingInstruction(..)
      | DocType => {
        let _ = cursor.next()
      }
    }
  }
  units
}

///|
fn parse_fmi2_unit(
  cursor : Cursor,
  element : XmlElement,
  parent_path : String,
  had_start~ : Bool,
) -> UnitDef raise SchemaError {
  let path = "\{parent_path}/Unit"
  cursor.set_path(path)
  let name = required_attr(element, "name", path~)
  let mut base_unit : BaseUnit? = None
  let display_units : Array[DisplayUnit] = []
  let mut order_index = 0
  if !had_start {
    cursor.set_path(parent_path)
    return { name, base_unit: None, display_units, }
  }
  while true {
    match cursor.peek() {
      Eof =>
        raise cursor.fail(message="unexpected end of document inside <Unit>")
      End(name) =>
        if name == "Unit" {
          let _ = cursor.next()
          break
        } else {
          raise cursor.fail(
            message="unexpected end element </\{name}>, expected </Unit>",
          )
        }
      Start(child) | Empty(child) => {
        let position = match child.name {
          "BaseUnit" => 0
          "DisplayUnit" => 1
          _ => -1
        }
        if position < 0 {
          raise cursor.fail(
            message="unexpected element <\{child.name}> inside <Unit>",
            hint="allowed children: BaseUnit?, DisplayUnit*",
          )
        }
        if position < order_index {
          raise cursor.fail(
            message="element <\{child.name}> is out of order inside <Unit>",
          )
        }
        order_index = position + 1
        let had_start = cursor.peek() is Start(_)
        let _ = cursor.next()
        match child.name {
          "BaseUnit" => base_unit = Some(parse_fmi2_base_unit(child, path))
          "DisplayUnit" =>
            display_units.push(parse_fmi2_display_unit(child, path))
          _ => abort("unreachable")
        }
        finish_element(cursor, child.name, had_start)
      }
      Text(_)
      | CData(_)
      | Declaration(..)
      | Comment(_)
      | ProcessingInstruction(..)
      | DocType => {
        let _ = cursor.next()
      }
    }
  }
  cursor.set_path(parent_path)
  { name, base_unit, display_units, }
}

///|
fn parse_fmi2_base_unit(
  element : XmlElement,
  path : String,
) -> BaseUnit raise SchemaError {
  {
    kg: optional_int32(element, "kg", path~).unwrap_or(0),
    m: optional_int32(element, "m", path~).unwrap_or(0),
    s: optional_int32(element, "s", path~).unwrap_or(0),
    a: optional_int32(element, "A", path~).unwrap_or(0),
    kelvin: optional_int32(element, "K", path~).unwrap_or(0),
    mol: optional_int32(element, "mol", path~).unwrap_or(0),
    cd: optional_int32(element, "cd", path~).unwrap_or(0),
    rad: optional_int32(element, "rad", path~).unwrap_or(0),
    factor: optional_double(element, "factor", path~).unwrap_or(1.0),
    offset: optional_double(element, "offset", path~).unwrap_or(0.0),
  }
}

///|
fn parse_fmi2_display_unit(
  element : XmlElement,
  path : String,
) -> DisplayUnit raise SchemaError {
  let name = required_attr(element, "name", path~)
  {
    name,
    factor: optional_double(element, "factor", path~).unwrap_or(1.0),
    offset: optional_double(element, "offset", path~).unwrap_or(0.0),
    inverse: None,
  }
}

///|
fn parse_fmi2_type_definitions(
  cursor : Cursor,
  had_start~ : Bool,
) -> Array[Fmi2TypeDefinition] raise SchemaError {
  let definitions : Array[Fmi2TypeDefinition] = []
  let parent = cursor.path
  if !had_start {
    cursor.set_path(parent)
    return definitions
  }
  while true {
    match cursor.peek() {
      Eof =>
        raise cursor.fail(
          message="unexpected end of document inside <TypeDefinitions>",
        )
      End(name) =>
        if name == "TypeDefinitions" {
          let _ = cursor.next()
          return definitions
        } else {
          raise cursor.fail(
            message="unexpected end element </\{name}>, expected </TypeDefinitions>",
          )
        }
      Start(element) | Empty(element) => {
        if element.name != "SimpleType" {
          raise cursor.fail(
            message="unexpected element <\{element.name}> inside <TypeDefinitions>",
            hint="only <SimpleType> elements are allowed here",
          )
        }
        let had_start = cursor.peek() is Start(_)
        let _ = cursor.next()
        definitions.push(
          parse_fmi2_simple_type(cursor, element, parent, had_start~),
        )
      }
      Text(_)
      | CData(_)
      | Declaration(..)
      | Comment(_)
      | ProcessingInstruction(..)
      | DocType => {
        let _ = cursor.next()
      }
    }
  }
  definitions
}

///|
fn parse_fmi2_simple_type(
  cursor : Cursor,
  element : XmlElement,
  parent_path : String,
  had_start~ : Bool,
) -> Fmi2TypeDefinition raise SchemaError {
  let path = "\{parent_path}/SimpleType"
  cursor.set_path(path)
  let name = required_attr(element, "name", path~)
  let payload = parse_fmi2_payload(cursor, element, path)
  finish_element(cursor, "SimpleType", had_start)
  cursor.set_path(parent_path)
  { name, payload, line: line_of(element), column: column_of(element), }
}

///|
/// Parse the single payload element of a `SimpleType` or `ScalarVariable`.
fn parse_fmi2_payload(
  cursor : Cursor,
  owner : XmlElement,
  owner_path : String,
) -> Fmi2Payload raise SchemaError {
  let event = cursor.peek()
  let element = match event {
    Start(element) | Empty(element) => element
    Eof | End(_) => {
      let found = match event {
        End(name) => "</\{name}>"
        _ => "end of document"
      }
      raise cursor.fail(
        message="<\{owner.name}> must contain exactly one of Real/Integer/Boolean/String/Enumeration, found \{found}",
      )
    }
    Text(_)
    | CData(_)
    | Declaration(..)
    | Comment(_)
    | ProcessingInstruction(..)
    | DocType => {
      let _ = cursor.next()
      raise cursor.fail(
        message="<\{owner.name}> must contain exactly one of Real/Integer/Boolean/String/Enumeration",
      )
    }
  }
  let path = "\{owner_path}/\{element.name}"
  cursor.set_path(path)
  let had_start = event is Start(_)
  let _ = cursor.next()
  let payload : Fmi2Payload = match element.name {
    "Real" =>
      Real({
        declared_type: optional_attr(element, "declaredType", path~),
        quantity: optional_attr(element, "quantity", path~),
        unit: optional_attr(element, "unit", path~),
        display_unit: optional_attr(element, "displayUnit", path~),
        relative_quantity: optional_bool(element, "relativeQuantity", path~),
        min: optional_double(element, "min", path~),
        max: optional_double(element, "max", path~),
        nominal: optional_double(element, "nominal", path~),
        unbounded: optional_bool(element, "unbounded", path~),
        start: optional_double(element, "start", path~),
        derivative: optional_uint32(element, "derivative", path~),
        reinit: optional_bool(element, "reinit", path~),
      })
    "Integer" =>
      Integer({
        declared_type: optional_attr(element, "declaredType", path~),
        quantity: optional_attr(element, "quantity", path~),
        min: optional_int32(element, "min", path~),
        max: optional_int32(element, "max", path~),
        start: optional_int32(element, "start", path~),
        items: [],
      })
    "Boolean" =>
      Boolean({
        declared_type: optional_attr(element, "declaredType", path~),
        start: optional_bool(element, "start", path~),
      })
    "String" =>
      Str({
        declared_type: optional_attr(element, "declaredType", path~),
        start: optional_attr(element, "start", path~),
      })
    "Enumeration" =>
      Enumeration({
        declared_type: optional_attr(element, "declaredType", path~),
        quantity: optional_attr(element, "quantity", path~),
        min: optional_int32(element, "min", path~),
        max: optional_int32(element, "max", path~),
        start: optional_int32(element, "start", path~),
        items: [],
      })
    _ =>
      raise cursor.fail(
        message="unexpected element <\{element.name}>; expected Real, Integer, Boolean, String, or Enumeration",
        hint="a ScalarVariable must contain exactly one type element",
      )
  }
  if had_start {
    // Only Enumeration may carry Item children; anything else is an error.
    if element.name != "Enumeration" {
      raise cursor.fail(
        message="unexpected child element inside <\{element.name}>; type elements have no children",
      )
    }
    match payload {
      Enumeration(attrs) => {
        let parsed_items = parse_fmi2_enum_items(cursor, path)
        for item in parsed_items {
          attrs.items.push(item)
        }
      }
      _ => abort("unreachable")
    }
  }
  cursor.set_path(owner_path)
  payload
}

///|
fn parse_fmi2_enum_items(
  cursor : Cursor,
  parent_path : String,
) -> Array[EnumItem] raise SchemaError {
  let items : Array[EnumItem] = []
  while true {
    match cursor.peek() {
      Eof =>
        raise cursor.fail(
          message="unexpected end of document inside enumeration type",
        )
      End(name) =>
        if name == "Enumeration" {
          let _ = cursor.next()
          return items
        } else {
          raise cursor.fail(
            message="unexpected end element </\{name}>, expected </Enumeration>",
          )
        }
      Start(element) | Empty(element) => {
        if element.name != "Item" {
          raise cursor.fail(
            message="unexpected element <\{element.name}>; only <Item> is allowed inside an enumeration type",
          )
        }
        let path = "\{parent_path}/Item"
        let had_start = cursor.peek() is Start(_)
        let _ = cursor.next()
        let name = required_attr(element, "name", path~)
        let value_text = required_attr(element, "value", path~)
        let value = parse_int32_value(
          value_text,
          path~,
          line=line_of(element),
          column=column_of(element),
        )
        finish_element(cursor, "Item", had_start)
        items.push({
          name,
          value: value.to_int64(),
          description: optional_attr(element, "description", path~),
        })
      }
      Text(_)
      | CData(_)
      | Declaration(..)
      | Comment(_)
      | ProcessingInstruction(..)
      | DocType => {
        let _ = cursor.next()
      }
    }
  }
  items
}

///|
fn parse_fmi2_log_categories(
  cursor : Cursor,
  had_start~ : Bool,
) -> Array[LogCategory] raise SchemaError {
  let categories : Array[LogCategory] = []
  let parent = cursor.path
  if !had_start {
    cursor.set_path(parent)
    return categories
  }
  while true {
    match cursor.peek() {
      Eof =>
        raise cursor.fail(
          message="unexpected end of document inside <LogCategories>",
        )
      End(name) =>
        if name == "LogCategories" {
          let _ = cursor.next()
          return categories
        } else {
          raise cursor.fail(
            message="unexpected end element </\{name}>, expected </LogCategories>",
          )
        }
      Start(element) | Empty(element) => {
        if element.name != "Category" {
          raise cursor.fail(
            message="unexpected element <\{element.name}> inside <LogCategories>",
          )
        }
        let path = "\{parent}/Category"
        let had_start = cursor.peek() is Start(_)
        let _ = cursor.next()
        let name = required_attr(element, "name", path~)
        finish_element(cursor, "Category", had_start)
        categories.push({
          name,
          description: optional_attr(element, "description", path~),
        })
      }
      Text(_)
      | CData(_)
      | Declaration(..)
      | Comment(_)
      | ProcessingInstruction(..)
      | DocType => {
        let _ = cursor.next()
      }
    }
  }
  categories
}

///|
fn parse_fmi2_experiment(
  element : XmlElement,
) -> DefaultExperiment raise SchemaError {
  let path = "/fmiModelDescription/DefaultExperiment"
  {
    start_time: optional_double(element, "startTime", path~),
    stop_time: optional_double(element, "stopTime", path~),
    tolerance: optional_double(element, "tolerance", path~),
    step_size: optional_double(element, "stepSize", path~),
  }
}

///|
let fmi2_scalar_variable_attrs : Array[String] = [
  "name", "valueReference", "description", "causality", "variability", "initial",
  "canHandleMultipleSetPerTimeInstant",
]

///|
fn parse_fmi2_variables(
  cursor : Cursor,
  had_start~ : Bool,
) -> Array[Fmi2ScalarVariable] raise SchemaError {
  let variables : Array[Fmi2ScalarVariable] = []
  let parent = cursor.path
  if !had_start {
    cursor.set_path(parent)
    return variables
  }
  while true {
    match cursor.peek() {
      Eof =>
        raise cursor.fail(
          message="unexpected end of document inside <ModelVariables>",
        )
      End(name) =>
        if name == "ModelVariables" {
          let _ = cursor.next()
          return variables
        } else {
          raise cursor.fail(
            message="unexpected end element </\{name}>, expected </ModelVariables>",
          )
        }
      Start(element) | Empty(element) => {
        if element.name != "ScalarVariable" {
          raise cursor.fail(
            message="unexpected element <\{element.name}> inside <ModelVariables>",
            hint="FMI 2 variables are declared as <ScalarVariable> elements",
          )
        }
        let position = variables.length() + 1
        let path = "\{parent}/ScalarVariable[\{position}]"
        cursor.set_path(path)
        check_no_unknown_attrs(element, fmi2_scalar_variable_attrs, path~)
        let had_start = cursor.peek() is Start(_)
        let _ = cursor.next()
        let name = required_attr(element, "name", path~)
        let value_reference_text = required_attr(
          element,
          "valueReference",
          path~,
        )
        let value_reference = parse_uint32_value(
          value_reference_text,
          path~,
          line=line_of(element),
          column=column_of(element),
        )
        let causality = optional_enum(
          element,
          "causality",
          Causality::parse,
          path~,
        )
        let variability = optional_enum(
          element,
          "variability",
          Variability::parse,
          path~,
        )
        let initial = optional_enum(element, "initial", Initial::parse, path~)
        let payload = parse_fmi2_payload(cursor, element, path)
        // Only the optional <Annotations> may follow the payload element.
        match cursor.peek() {
          End(_) => ()
          Start(child) | Empty(child) => {
            if child.name != "Annotations" {
              raise cursor.fail(
                message="unexpected element <\{child.name}> inside <ScalarVariable>",
                hint="only one type element and optional <Annotations> may appear",
              )
            }
            let _ = cursor.next()
            cursor.skip_subtree("Annotations")
          }
          Eof =>
            raise cursor.fail(
              message="unexpected end of document inside <ScalarVariable>",
            )
          Text(_)
          | CData(_)
          | Declaration(..)
          | Comment(_)
          | ProcessingInstruction(..)
          | DocType => {
            let _ = cursor.next()
          }
        }
        finish_element(cursor, "ScalarVariable", had_start)
        variables.push({
          name,
          value_reference,
          description: optional_attr(element, "description", path~),
          causality,
          variability,
          initial,
          can_handle_multiple_set_per_time_instant: optional_bool(
            element,
            "canHandleMultipleSetPerTimeInstant",
            path~,
          ),
          payload,
          line: line_of(element),
          column: column_of(element),
        })
        cursor.set_path(parent)
      }
      Text(_)
      | CData(_)
      | Declaration(..)
      | Comment(_)
      | ProcessingInstruction(..)
      | DocType => {
        let _ = cursor.next()
      }
    }
  }
  variables
}

///|
fn parse_fmi2_model_structure(
  cursor : Cursor,
  had_start~ : Bool,
) -> Fmi2ModelStructure raise SchemaError {
  let parent = cursor.path
  let mut outputs : Array[Fmi2Unknown] = []
  let mut derivatives : Array[Fmi2Unknown] = []
  let mut initial_unknowns : Array[Fmi2Unknown] = []
  if !had_start {
    cursor.set_path(parent)
    return { outputs: [], derivatives: [], initial_unknowns: [], }
  }
  let mut order_index = 0
  while true {
    match cursor.peek() {
      Eof =>
        raise cursor.fail(
          message="unexpected end of document inside <ModelStructure>",
        )
      End(name) =>
        if name == "ModelStructure" {
          let _ = cursor.next()
          break
        } else {
          raise cursor.fail(
            message="unexpected end element </\{name}>, expected </ModelStructure>",
          )
        }
      Start(element) | Empty(element) => {
        let position = match element.name {
          "Outputs" => 0
          "Derivatives" => 1
          "InitialUnknowns" => 2
          _ => -1
        }
        if position < 0 {
          raise cursor.fail(
            message="unexpected element <\{element.name}> inside <ModelStructure>",
            hint="allowed children: Outputs?, Derivatives?, InitialUnknowns?",
          )
        }
        if position < order_index {
          raise cursor.fail(
            message="element <\{element.name}> is out of order inside <ModelStructure>",
          )
        }
        order_index = position + 1
        let path = "\{parent}/\{element.name}"
        cursor.set_path(path)
        let _ = cursor.next()
        let unknowns = parse_fmi2_unknowns(cursor, element.name, path)
        match element.name {
          "Outputs" => outputs = unknowns
          "Derivatives" => derivatives = unknowns
          "InitialUnknowns" => initial_unknowns = unknowns
          _ => abort("unreachable")
        }
        cursor.set_path(parent)
      }
      Text(_)
      | CData(_)
      | Declaration(..)
      | Comment(_)
      | ProcessingInstruction(..)
      | DocType => {
        let _ = cursor.next()
      }
    }
  }
  { outputs, derivatives, initial_unknowns, }
}

///|
fn parse_fmi2_unknowns(
  cursor : Cursor,
  container : String,
  parent_path : String,
) -> Array[Fmi2Unknown] raise SchemaError {
  let unknowns : Array[Fmi2Unknown] = []
  while true {
    match cursor.peek() {
      Eof =>
        raise cursor.fail(
          message="unexpected end of document inside <\{container}>",
        )
      End(name) =>
        if name == container {
          let _ = cursor.next()
          return unknowns
        } else {
          raise cursor.fail(
            message="unexpected end element </\{name}>, expected </\{container}>",
          )
        }
      Start(element) | Empty(element) => {
        if element.name != "Unknown" {
          raise cursor.fail(
            message="unexpected element <\{element.name}> inside <\{container}>",
            hint="only <Unknown> elements are allowed here",
          )
        }
        let position = unknowns.length() + 1
        let path = "\{parent_path}/Unknown[\{position}]"
        cursor.set_path(path)
        let had_start = cursor.peek() is Start(_)
        let _ = cursor.next()
        let index_text = required_attr(element, "index", path~)
        let index = parse_uint32_value(
          index_text,
          path~,
          line=line_of(element),
          column=column_of(element),
        )
        let dependencies = optional_uint32_list(element, "dependencies", path~)
        let kinds = optional_dependency_kind_list(
          element,
          "dependenciesKind",
          path~,
        )
        finish_element(cursor, "Unknown", had_start)
        unknowns.push({
          index,
          dependencies,
          dependencies_kind: kinds,
          line: line_of(element),
          column: column_of(element),
        })
        cursor.set_path(parent_path)
      }
      Text(_)
      | CData(_)
      | Declaration(..)
      | Comment(_)
      | ProcessingInstruction(..)
      | DocType => {
        let _ = cursor.next()
      }
    }
  }
  unknowns
}
