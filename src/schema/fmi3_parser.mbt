///|
/// FMI 3 typed-model parser. Root children follow the fixed XSD sequence;
/// inside variables the child categories (Dimension, Start, Alias,
/// Annotations) are multiplicity-checked but order-tolerant, matching the
/// loose ordering real exporters produce.
let fmi3_root_order : Array[String] = [
  "ModelExchange", "CoSimulation", "ScheduledExecution", "UnitDefinitions", "TypeDefinitions",
  "LogCategories", "DefaultExperiment", "ModelVariables", "ModelStructure", "Annotations",
]

///|
let fmi3_structure_order : Array[String] = [
  "Output", "ContinuousStateDerivative", "ClockedState", "InitialUnknown", "EventIndicator",
]

///|
fn parse_fmi3_model(
  cursor : Cursor,
  root : XmlElement,
) -> Fmi3ModelDescription raise SchemaError {
  let root_path = "/fmiModelDescription"
  cursor.set_path(root_path)
  let model_name = required_attr(
    root,
    "modelName",
    path=root_path,
    code="MD-005",
    hint="every FMI 3 model description needs a non-empty modelName",
  )
  let instantiation_token = required_attr(
    root,
    "instantiationToken",
    path=root_path,
    code="MD-006",
    hint="every FMI 3 model description needs a non-empty instantiationToken",
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
  let interfaces : Array[Fmi3Interface] = []
  let mut units : Array[UnitDef] = []
  let mut types : Array[Fmi3TypeDefinition] = []
  let mut log_categories : Array[LogCategory] = []
  let mut experiment : DefaultExperiment? = None
  let mut variables : Array[Fmi3Variable] = []
  let mut structure : Fmi3ModelStructure? = None
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
        let position = index_in_order(fmi3_root_order, element.name)
        if position < 0 {
          raise cursor.fail(
            message="unexpected element <\{element.name}> in <fmiModelDescription>",
            hint="allowed root children: " + fmi3_root_order.join(", "),
          )
        }
        if position < order_index {
          raise cursor.fail(
            message="element <\{element.name}> is out of order",
            hint="the XSD fixes the root order to " + fmi3_root_order.join(", "),
          )
        }
        order_index = position + 1
        let _ = cursor.next()
        match element.name {
          "ModelExchange" =>
            interfaces.push(
              parse_fmi3_interface(
                cursor,
                element,
                InterfaceKind::ModelExchange,
                had_start=event is Start(_),
              ),
            )
          "CoSimulation" =>
            interfaces.push(
              parse_fmi3_interface(
                cursor,
                element,
                InterfaceKind::CoSimulation,
                had_start=event is Start(_),
              ),
            )
          "ScheduledExecution" =>
            interfaces.push(
              parse_fmi3_interface(
                cursor,
                element,
                InterfaceKind::ScheduledExecution,
                had_start=event is Start(_),
              ),
            )
          "UnitDefinitions" => units = parse_fmi3_units(cursor)
          "TypeDefinitions" => types = parse_fmi3_type_definitions(cursor)
          "LogCategories" => log_categories = parse_fmi2_log_categories(cursor)
          "DefaultExperiment" =>
            experiment = Some(parse_fmi2_experiment(element))
          "ModelVariables" => {
            variables = parse_fmi3_variables(cursor)
            seen_variables = true
          }
          "ModelStructure" => {
            structure = Some(parse_fmi3_model_structure(cursor))
            seen_structure = true
          }
          "Annotations" =>
            if event is Start(_) {
              cursor.skip_subtree("Annotations")
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
    instantiation_token,
    description,
    author,
    version,
    copyright,
    license,
    generation_tool,
    generation_date_and_time: generation_date,
    variable_naming_convention: naming,
    interfaces,
    unit_definitions: units,
    type_definitions: types,
    log_categories,
    default_experiment: experiment,
    variables,
    model_structure: match structure {
      Some(value) => value
      None =>
        {
          outputs: [],
          continuous_state_derivatives: [],
          clocked_states: [],
          initial_unknowns: [],
          event_indicators: [],
        }
    },
  }
}

///|
fn parse_fmi3_interface(
  cursor : Cursor,
  element : XmlElement,
  kind : InterfaceKind,
  had_start~ : Bool,
) -> Fmi3Interface raise SchemaError {
  let path = "\{cursor.path}/\{element.name}"
  cursor.set_path(path)
  // FMI 3 interface types carry xs:anyAttribute; unknown attributes are
  // tolerated and ignored.
  let interface : Fmi3Interface = {
    kind,
    model_identifier: required_attr(
      element,
      "modelIdentifier",
      path~,
      code="MD-004",
      hint="each interface needs a modelIdentifier that names the shared library",
    ),
    needs_execution_tool: optional_bool(element, "needsExecutionTool", path~),
    can_be_instantiated_only_once_per_process: optional_bool(
      element,
      "canBeInstantiatedOnlyOncePerProcess",
      path~,
    ),
    can_get_and_set_fmustate: optional_bool(
      element,
      "canGetAndSetFMUState",
      path~,
    ),
    can_serialize_fmustate: optional_bool(
      element,
      "canSerializeFMUState",
      path~,
    ),
    provides_directional_derivatives: optional_bool(
      element,
      "providesDirectionalDerivatives",
      path~,
    ),
    provides_adjoint_derivatives: optional_bool(
      element,
      "providesAdjointDerivatives",
      path~,
    ),
    provides_per_element_dependencies: optional_bool(
      element,
      "providesPerElementDependencies",
      path~,
    ),
    needs_completed_integrator_step: optional_bool(
      element,
      "needsCompletedIntegratorStep",
      path~,
    ),
    provides_evaluate_discrete_states: optional_bool(
      element,
      "providesEvaluateDiscreteStates",
      path~,
    ),
    can_handle_variable_communication_step_size: optional_bool(
      element,
      "canHandleVariableCommunicationStepSize",
      path~,
    ),
    fixed_internal_step_size: optional_double(
      element,
      "fixedInternalStepSize",
      path~,
    ),
    max_output_derivative_order: optional_uint32(
      element,
      "maxOutputDerivativeOrder",
      path~,
    ),
    recommended_intermediate_input_smoothness: optional_int32(
      element,
      "recommendedIntermediateInputSmoothness",
      path~,
    ),
    provides_intermediate_update: optional_bool(
      element,
      "providesIntermediateUpdate",
      path~,
    ),
    might_return_early_from_do_step: optional_bool(
      element,
      "mightReturnEarlyFromDoStep",
      path~,
    ),
    can_return_early_after_intermediate_update: optional_bool(
      element,
      "canReturnEarlyAfterIntermediateUpdate",
      path~,
    ),
    has_event_mode: optional_bool(element, "hasEventMode", path~),
    line: line_of(element),
    column: column_of(element),
  }
  if !had_start {
    // Self-closing interface element: attributes only, nothing to consume.
    cursor.set_path("/fmiModelDescription")
    return interface
  }
  // The only allowed child is an optional Annotations element.
  match cursor.peek() {
    Start(child) | Empty(child) => {
      if child.name != "Annotations" {
        raise cursor.fail(
          message="unexpected element <\{child.name}> inside <\{element.name}>",
        )
      }
      let _ = cursor.next()
      cursor.skip_subtree("Annotations")
    }
    End(_) | Eof => ()
    Text(_)
    | CData(_)
    | Declaration(..)
    | Comment(_)
    | ProcessingInstruction(..)
    | DocType => {
      let _ = cursor.next()
    }
  }
  expect_end(cursor, element.name)
  cursor.set_path("/fmiModelDescription")
  interface
}

///|
fn parse_fmi3_units(cursor : Cursor) -> Array[UnitDef] raise SchemaError {
  let units : Array[UnitDef] = []
  let parent = cursor.path
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
        units.push(parse_fmi3_unit(cursor, element, parent, had_start~))
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
fn parse_fmi3_unit(
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
            display_units.push(parse_fmi3_display_unit(child, path))
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
fn parse_fmi3_display_unit(
  element : XmlElement,
  path : String,
) -> DisplayUnit raise SchemaError {
  let name = required_attr(element, "name", path~)
  {
    name,
    factor: optional_double(element, "factor", path~).unwrap_or(1.0),
    offset: optional_double(element, "offset", path~).unwrap_or(0.0),
    inverse: optional_bool(element, "inverse", path~),
  }
}

///|
/// Map a `*Type` element name to its variable kind.
fn fmi3_type_kind_of(element_name : String) -> Fmi3TypeKind? {
  match element_name {
    "Float32Type" => Some(Float32)
    "Float64Type" => Some(Float64)
    "Int8Type" => Some(Int8)
    "UInt8Type" => Some(UInt8)
    "Int16Type" => Some(Int16)
    "UInt16Type" => Some(UInt16)
    "Int32Type" => Some(Int32)
    "UInt32Type" => Some(UInt32)
    "Int64Type" => Some(Int64)
    "UInt64Type" => Some(UInt64)
    "BooleanType" => Some(Boolean)
    "StringType" => Some(Str)
    "BinaryType" => Some(Binary)
    "EnumerationType" => Some(Enumeration)
    "ClockType" => Some(Clock)
    _ => None
  }
}

///|
fn parse_fmi3_type_definitions(
  cursor : Cursor,
) -> Array[Fmi3TypeDefinition] raise SchemaError {
  let definitions : Array[Fmi3TypeDefinition] = []
  let parent = cursor.path
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
        let kind = match fmi3_type_kind_of(element.name) {
          Some(kind) => kind
          None =>
            raise cursor.fail(
              message="unexpected element <\{element.name}> inside <TypeDefinitions>",
              hint="expected one of the FMI 3 type definition elements (Float64Type, ...)",
            )
        }
        let had_start = cursor.peek() is Start(_)
        let _ = cursor.next()
        definitions.push(
          parse_fmi3_type_definition(cursor, element, kind, parent, had_start~),
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
fn parse_fmi3_type_definition(
  cursor : Cursor,
  element : XmlElement,
  kind : Fmi3TypeKind,
  parent_path : String,
  had_start~ : Bool,
) -> Fmi3TypeDefinition raise SchemaError {
  let path = "\{parent_path}/\{element.name}"
  cursor.set_path(path)
  let name = required_attr(element, "name", path~)
  let description = optional_attr(element, "description", path~)
  let payload = parse_fmi3_payload_attrs(element, kind, path)
  if had_start && kind is Enumeration {
    // EnumerationType carries its items as <Item> child elements.
    match payload {
      Enum(attrs) => {
        let parsed_items = parse_fmi3_enum_items(cursor, path, element.name)
        for item in parsed_items {
          attrs.items.push(item)
        }
      }
      _ => abort("unreachable")
    }
  }
  finish_element(cursor, element.name, had_start)
  cursor.set_path(parent_path)
  {
    type_kind: kind,
    name,
    description,
    payload,
    line: line_of(element),
    column: column_of(element),
  }
}

///|
/// Read the payload attributes of an FMI 3 variable or type-definition
/// element according to its type kind.
fn parse_fmi3_payload_attrs(
  element : XmlElement,
  kind : Fmi3TypeKind,
  path : String,
) -> Fmi3Payload raise SchemaError {
  let payload : Fmi3Payload = match kind {
    Float32 | Float64 =>
      Float({
        declared_type: optional_attr(element, "declaredType", path~),
        quantity: optional_attr(element, "quantity", path~),
        unit: optional_attr(element, "unit", path~),
        display_unit: optional_attr(element, "displayUnit", path~),
        relative_quantity: optional_bool(element, "relativeQuantity", path~),
        unbounded: optional_bool(element, "unbounded", path~),
        min: optional_double(element, "min", path~),
        max: optional_double(element, "max", path~),
        nominal: optional_double(element, "nominal", path~),
        starts: parse_start_list_attr(element, path),
        derivative: optional_uint32(element, "derivative", path~),
        reinit: optional_bool(element, "reinit", path~),
      })
    Int8 | Int16 | Int32 | Int64 =>
      Int({
        declared_type: optional_attr(element, "declaredType", path~),
        quantity: optional_attr(element, "quantity", path~),
        min: optional_int64(element, "min", path~),
        max: optional_int64(element, "max", path~),
        starts: parse_int64_start_list(element, path),
      })
    UInt8 | UInt16 | UInt32 | UInt64 =>
      UInt({
        declared_type: optional_attr(element, "declaredType", path~),
        quantity: optional_attr(element, "quantity", path~),
        min: optional_uint64(element, "min", path~),
        max: optional_uint64(element, "max", path~),
        starts: parse_uint64_start_list(element, path),
      })
    Boolean =>
      Bool({
        declared_type: optional_attr(element, "declaredType", path~),
        starts: parse_bool_start_list(element, path),
      })
    Str =>
      Text({
        declared_type: optional_attr(element, "declaredType", path~),
        starts: [],
      })
    Binary =>
      Bin({
        declared_type: optional_attr(element, "declaredType", path~),
        mime_type: optional_attr(element, "mimeType", path~),
        max_size: optional_uint64(element, "maxSize", path~),
        starts: [],
      })
    Enumeration =>
      Enum({
        declared_type: optional_attr(element, "declaredType", path~),
        quantity: optional_attr(element, "quantity", path~),
        min: optional_int64(element, "min", path~),
        max: optional_int64(element, "max", path~),
        starts: parse_int64_start_list(element, path),
        items: [],
      })
    Clock =>
      Clock({
        declared_type: optional_attr(element, "declaredType", path~),
        can_be_deactivated: optional_bool(element, "canBeDeactivated", path~),
        priority: optional_uint32(element, "priority", path~),
        interval_variability: optional_enum(
          element,
          "intervalVariability",
          ClockIntervalVariability::parse,
          path~,
        ),
        interval_decimal: optional_double(element, "intervalDecimal", path~),
        shift_decimal: optional_double(element, "shiftDecimal", path~),
        supports_fraction: optional_bool(element, "supportsFraction", path~),
        resolution: optional_uint64(element, "resolution", path~),
        interval_counter: optional_uint64(element, "intervalCounter", path~),
        shift_counter: optional_uint64(element, "shiftCounter", path~),
      })
  }
  payload
}

///|
fn parse_start_list_attr(
  element : XmlElement,
  path : String,
) -> Array[Double] raise SchemaError {
  let starts : Array[Double] = []
  match optional_attr(element, "start", path~) {
    Some(text) =>
      for item in split_ws_list(text) {
        starts.push(
          parse_double_value(
            item,
            path~,
            line=line_of(element),
            column=column_of(element),
          ),
        )
      }
    None => ()
  }
  starts
}

///|
fn parse_int64_start_list(
  element : XmlElement,
  path : String,
) -> Array[Int64] raise SchemaError {
  let starts : Array[Int64] = []
  match optional_attr(element, "start", path~) {
    Some(text) =>
      for item in split_ws_list(text) {
        starts.push(
          parse_int64_value(
            item,
            path~,
            line=line_of(element),
            column=column_of(element),
          ),
        )
      }
    None => ()
  }
  starts
}

///|
fn parse_uint64_start_list(
  element : XmlElement,
  path : String,
) -> Array[UInt64] raise SchemaError {
  let starts : Array[UInt64] = []
  match optional_attr(element, "start", path~) {
    Some(text) =>
      for item in split_ws_list(text) {
        starts.push(
          parse_uint64_value(
            item,
            path~,
            line=line_of(element),
            column=column_of(element),
          ),
        )
      }
    None => ()
  }
  starts
}

///|
fn parse_bool_start_list(
  element : XmlElement,
  path : String,
) -> Array[Bool] raise SchemaError {
  let starts : Array[Bool] = []
  match optional_attr(element, "start", path~) {
    Some(text) =>
      for item in split_ws_list(text) {
        starts.push(
          parse_bool_value(
            item,
            path~,
            line=line_of(element),
            column=column_of(element),
          ),
        )
      }
    None => ()
  }
  starts
}

///|
fn parse_fmi3_variables(
  cursor : Cursor,
) -> Array[Fmi3Variable] raise SchemaError {
  let variables : Array[Fmi3Variable] = []
  let parent = cursor.path
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
        let kind = match Fmi3TypeKind::parse(element.name) {
          Some(kind) => kind
          None =>
            raise cursor.fail(
              message="unexpected element <\{element.name}> inside <ModelVariables>",
              hint="FMI 3 variables are declared with their type element, e.g. <Float64>",
            )
        }
        let position = variables.length() + 1
        let path = "\{parent}/\{element.name}[\{position}]"
        cursor.set_path(path)
        let had_start = cursor.peek() is Start(_)
        let _ = cursor.next()
        variables.push(
          parse_fmi3_variable(cursor, element, kind, path, had_start~),
        )
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
fn parse_fmi3_variable(
  cursor : Cursor,
  element : XmlElement,
  kind : Fmi3TypeKind,
  path : String,
  had_start~ : Bool,
) -> Fmi3Variable raise SchemaError {
  let name = required_attr(element, "name", path~)
  let value_reference_text = required_attr(element, "valueReference", path~)
  let value_reference = parse_uint32_value(
    value_reference_text,
    path~,
    line=line_of(element),
    column=column_of(element),
  )
  let variable : Fmi3Variable = {
    type_kind: kind,
    name,
    value_reference,
    description: optional_attr(element, "description", path~),
    causality: optional_enum(element, "causality", Causality::parse, path~),
    variability: optional_enum(
      element,
      "variability",
      Variability::parse,
      path~,
    ),
    initial: optional_enum(element, "initial", Initial::parse, path~),
    can_handle_multiple_set_per_time_instant: optional_bool(
      element,
      "canHandleMultipleSetPerTimeInstant",
      path~,
    ),
    clocks: optional_attr(element, "clocks", path~),
    intermediate_update: optional_bool(element, "intermediateUpdate", path~),
    previous: optional_uint32(element, "previous", path~),
    dimensions: [],
    payload: parse_fmi3_payload_attrs(element, kind, path),
    aliases: [],
    line: line_of(element),
    column: column_of(element),
  }
  if had_start {
    parse_fmi3_variable_children(cursor, kind, path, variable)
  }
  variable
}

///|
/// Parse the child elements of a non-empty FMI 3 variable: `Dimension*`,
/// `Start*` (String/Binary only), `Alias*`, `Annotations?`. Category
/// multiplicities are enforced; order inside the variable is tolerated.
fn parse_fmi3_variable_children(
  cursor : Cursor,
  kind : Fmi3TypeKind,
  parent_path : String,
  variable : Fmi3Variable,
) -> Unit raise SchemaError {
  let mut seen_annotations = false
  while true {
    match cursor.peek() {
      Eof =>
        raise cursor.fail(
          message="unexpected end of document inside <\{variable.type_kind.name()}>",
        )
      End(name) =>
        if name == variable.type_kind.name() {
          let _ = cursor.next()
          return
        } else {
          raise cursor.fail(
            message="unexpected end element </\{name}>, expected </\{variable.type_kind.name()}>",
          )
        }
      Start(child) | Empty(child) => {
        let child_had_start = cursor.peek() is Start(_)
        match child.name {
          "Dimension" => {
            let _ = cursor.next()
            let path = "\{parent_path}/Dimension[\{variable.dimensions.length() + 1}]"
            variable.dimensions.push(parse_fmi3_dimension(child, path))
            finish_element(cursor, "Dimension", child_had_start)
          }
          "Start" => {
            if !(kind is (Str | Binary)) {
              raise cursor.fail(
                message="<Start> elements are only valid for String and Binary variables",
                hint="use the start attribute for \{kind.name()} variables",
              )
            }
            let _ = cursor.next()
            let path = "\{parent_path}/Start[\{start_count_of(variable.payload) + 1}]"
            let value = required_attr(child, "value", path~)
            match variable.payload {
              Text(attrs) => attrs.starts.push(value)
              Bin(attrs) => attrs.starts.push(value)
              _ => abort("unreachable")
            }
            finish_element(cursor, "Start", child_had_start)
          }
          "Alias" => {
            let _ = cursor.next()
            let path = "\{parent_path}/Alias[\{variable.aliases.length() + 1}]"
            let alias_name = required_attr(child, "name", path~)
            variable.aliases.push({
              name: alias_name,
              description: optional_attr(child, "description", path~),
              line: line_of(child),
              column: column_of(child),
            })
            finish_element(cursor, "Alias", child_had_start)
          }
          "Annotations" => {
            if seen_annotations {
              raise cursor.fail(
                message="duplicate <Annotations> element inside <\{variable.type_kind.name()}>",
              )
            }
            seen_annotations = true
            let _ = cursor.next()
            cursor.skip_subtree("Annotations")
          }
          other =>
            raise cursor.fail(
              message="unexpected element <\{other}> inside <\{variable.type_kind.name()}>",
              hint="allowed children: Dimension*, Start* (String/Binary), Alias*, Annotations?",
            )
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
}

///|
fn start_count_of(payload : Fmi3Payload) -> Int32 {
  match payload {
    Float(attrs) => attrs.starts.length()
    Int(attrs) => attrs.starts.length()
    UInt(attrs) => attrs.starts.length()
    Bool(attrs) => attrs.starts.length()
    Text(attrs) => attrs.starts.length()
    Bin(attrs) => attrs.starts.length()
    Enum(attrs) => attrs.starts.length()
    Clock(_) => 0
  }
}

///|
fn parse_fmi3_dimension(
  element : XmlElement,
  path : String,
) -> Fmi3Dimension raise SchemaError {
  {
    start: optional_uint64(element, "start", path~),
    value_reference: optional_uint32(element, "valueReference", path~),
    line: line_of(element),
    column: column_of(element),
  }
}

///|
fn parse_fmi3_model_structure(
  cursor : Cursor,
) -> Fmi3ModelStructure raise SchemaError {
  let parent = cursor.path
  let outputs : Array[Fmi3Unknown] = []
  let derivatives : Array[Fmi3Unknown] = []
  let clocked_states : Array[Fmi3Unknown] = []
  let initial_unknowns : Array[Fmi3Unknown] = []
  let event_indicators : Array[Fmi3Unknown] = []
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
        // The FMI 3 ModelStructure is flat: Output, ContinuousStateDerivative,
        // ClockedState, InitialUnknown, and EventIndicator elements appear
        // directly under <ModelStructure> in that fixed order.
        let position = index_in_order(fmi3_structure_order, element.name)
        if position < 0 {
          raise cursor.fail(
            message="unexpected element <\{element.name}> inside <ModelStructure>",
            hint="allowed children: Output*, ContinuousStateDerivative*, ClockedState*, InitialUnknown*, EventIndicator*",
          )
        }
        // Repeats of the current section kind are fine (Output*,
        // InitialUnknown*, ...); anything before it is out of order.
        if position < order_index - 1 {
          raise cursor.fail(
            message="element <\{element.name}> is out of order inside <ModelStructure>",
          )
        }
        order_index = position + 1
        let unknowns = match element.name {
          "Output" => outputs
          "ContinuousStateDerivative" => derivatives
          "ClockedState" => clocked_states
          "InitialUnknown" => initial_unknowns
          "EventIndicator" => event_indicators
          _ => abort("unreachable")
        }
        let path = "\{parent}/\{element.name}[\{unknowns.length() + 1}]"
        cursor.set_path(path)
        let had_start = cursor.peek() is Start(_)
        let _ = cursor.next()
        let vr_text = required_attr(element, "valueReference", path~)
        let value_reference = parse_uint32_value(
          vr_text,
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
        finish_element(cursor, element.name, had_start)
        unknowns.push({
          value_reference,
          dependencies,
          dependencies_kind: kinds,
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
  {
    outputs,
    continuous_state_derivatives: derivatives,
    clocked_states,
    initial_unknowns,
    event_indicators,
  }
}

///|
/// Parse the <Item> children of an <EnumerationType> (or report a precise
/// error for unexpected children). Consumes the closing tag of
/// `owner_name` and returns the items.
fn parse_fmi3_enum_items(
  cursor : Cursor,
  parent_path : String,
  owner_name : String,
) -> Array[EnumItem] raise SchemaError {
  let items : Array[EnumItem] = []
  while true {
    match cursor.peek() {
      Eof =>
        raise cursor.fail(
          message="unexpected end of document inside <\{owner_name}>",
        )
      End(name) => {
        let _ = name
        return items
      }
      Start(element) | Empty(element) => {
        if element.name != "Item" {
          raise cursor.fail(
            message="unexpected element <\{element.name}>; only <Item> is allowed inside <\{owner_name}>",
          )
        }
        let path = "\{parent_path}/Item"
        let had_start = cursor.peek() is Start(_)
        let _ = cursor.next()
        let name = required_attr(element, "name", path~)
        let value_text = required_attr(element, "value", path~)
        let value = parse_int64_value(
          value_text,
          path~,
          line=line_of(element),
          column=column_of(element),
        )
        finish_element(cursor, "Item", had_start)
        items.push({
          name,
          value,
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
