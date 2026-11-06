///|
/// Semantic validation (tasks B-11..B-16). Rule numbers follow
/// `docs/standards/model-description.md` §10. Both validators collect all
/// findings instead of stopping at the first one; parse-level failures
/// have already surfaced as `SchemaError` before this stage runs.

///|
/// Accumulator shared by the FMI 2 rule checks.
priv struct Fmi2Rules {
  model : Fmi2ModelDescription
  index : Fmi2Index
  diagnostics : Array[Diagnostic]
}

///|
fn Fmi2Rules::add(
  self : Fmi2Rules,
  code~ : String,
  message~ : String,
  path~ : String,
  severity~ : Severity = Error,
  line? : Int32,
  column? : Int32,
  hint? : String,
) -> Unit {
  self.diagnostics.push(
    Diagnostic::new(code~, severity~, message~, path~, line?, column?, hint?),
  )
}

///|
fn fmi2_var_path(position : Int32) -> String {
  "/fmiModelDescription/ModelVariables/ScalarVariable[\{position}]"
}

///|
fn fmi2_has_start(variable : Fmi2ScalarVariable) -> Bool {
  match variable.payload {
    Real(attrs) => attrs.start is Some(_)
    Integer(attrs) => attrs.start is Some(_)
    Boolean(attrs) => attrs.start is Some(_)
    Str(attrs) => attrs.start is Some(_)
    Enumeration(attrs) => attrs.start is Some(_)
  }
}

///|
fn Fmi2Rules::type_definition(
  self : Fmi2Rules,
  name : String,
) -> Fmi2TypeDefinition? {
  for definition in self.model.type_definitions {
    if definition.name == name {
      return Some(definition)
    }
  }
  None
}

///|
fn Fmi2Rules::unit_exists(self : Fmi2Rules, name : String) -> Bool {
  for unit in self.model.unit_definitions {
    if unit.name == name {
      return true
    }
  }
  false
}

///|
/// Validate the semantic rules for an FMI 2 model.
pub fn validate_fmi2(
  model : Fmi2ModelDescription,
  index : Fmi2Index,
) -> Array[Diagnostic] {
  let rules : Fmi2Rules = { model, index, diagnostics: [], }
  rules.check_root()
  rules.check_variables()
  rules.check_model_structure()
  rules.check_types()
  rules.diagnostics
}

///|
/// MD-003..MD-007, MD-062: root and interface rules.
fn Fmi2Rules::check_root(self : Fmi2Rules) -> Unit {
  let root = "/fmiModelDescription"
  if self.model.interface_count() == 0 {
    self.add(
      code="MD-003",
      message="at least one of <ModelExchange> or <CoSimulation> is required",
      path=root,
      hint="an FMU without any interface cannot be instantiated",
    )
  }
  if self.model.model_name == "" {
    self.add(code="MD-005", message="modelName must not be empty", path=root)
  }
  if self.model.guid == "" {
    self.add(
      code="MD-006",
      message="guid must not be empty",
      path=root,
      hint="the guid ties modelDescription.xml to the binary",
    )
  }
  for interface in self.model.interfaces() {
    let path = "\{root}/\{interface.kind.name()}"
    if interface.model_identifier == "" {
      self.add(
        code="MD-004",
        message="modelIdentifier must not be empty",
        path~,
      )
    } else if !is_safe_model_identifier(interface.model_identifier) {
      self.add(
        code="MD-062",
        message="modelIdentifier '\{interface.model_identifier}' is not safe",
        path~,
        hint="it must not contain path separators, '..', ':', or control characters",
      )
    }
    for source_file in interface.source_files {
      if !is_safe_internal_path(source_file) {
        self.add(
          code="MD-063",
          message="source file reference '\{source_file}' escapes the FMU root",
          path~,
        )
      }
    }
  }
}

///|
/// MD-010..MD-020, MD-050, MD-051: variable rules.
fn Fmi2Rules::check_variables(self : Fmi2Rules) -> Unit {
  let seen_names : Map[String, Int32] = Map([])
  for position, variable in self.model.variables {
    let path = fmi2_var_path(position + 1)
    // MD-010: unique variable names.
    match seen_names.get(variable.name) {
      Some(first) =>
        self.add(
          code="MD-010",
          message="variable name '\{variable.name}' is already used by ScalarVariable[\{first}]",
          path~,
          line=variable.line,
          column=variable.column,
        )
      None => seen_names.set(variable.name, position + 1)
    }
    // MD-012: causality/variability/initial combination.
    let causality = variable.effective_causality()
    let variability = variable.effective_variability()
    if !causality_allows_variability(causality, variability) {
      let allowed = allowed_variabilities(causality)
      let names : Array[String] = []
      for candidate in allowed {
        names.push(candidate.name())
      }
      let allowed_text = names.join(", ")
      self.add(
        code="MD-012",
        message="causality '\{causality.name()}' does not allow variability '\{variability.name()}'",
        path~,
        line=variable.line,
        column=variable.column,
        hint="allowed variability values: " + allowed_text,
      )
    } else if variable.initial is Some(initial) {
      match allowed_initials(causality, variability) {
        Some(permitted) => {
          let mut ok = false
          for candidate in permitted {
            if candidate == initial {
              ok = true
            }
          }
          if !ok {
            self.add(
              code="MD-012",
              message="initial '\{initial.name()}' is not valid for causality '\{causality.name()}' with variability '\{variability.name()}'",
              path~,
              line=variable.line,
              column=variable.column,
            )
          }
        }
        None =>
          self.add(
            code="MD-012",
            message="causality '\{causality.name()}' must not declare an initial attribute",
            path~,
            line=variable.line,
            column=variable.column,
          )
      }
    }
    // MD-013: initial=exact/approx should come with a start value
    // (FMPy requires one for inputs as well, which derive initial=exact).
    if variable.effective_initial() is (Some(Exact) | Some(Approx)) &&
      !fmi2_has_start(variable) {
      self.add(
        code="MD-013",
        message="variable declares initial='exact' but has no start value",
        path~,
        severity=Warning,
        line=variable.line,
        column=variable.column,
      )
    }
    // MD-012 follow-ups mirrored from FMPy's validator: a calculated
    // initial must not carry a start value, and independent variables
    // must not carry one at all.
    if variable.initial is Some(Calculated) && fmi2_has_start(variable) {
      self.add(
        code="MD-012",
        message="variable declares initial='calculated' but provides a start value",
        path~,
        line=variable.line,
        column=variable.column,
      )
    }
    if causality == Independent && fmi2_has_start(variable) {
      self.add(
        code="MD-012",
        message="independent variable must not provide a start value",
        path~,
        line=variable.line,
        column=variable.column,
      )
    }
    // MD-014: min <= max, nominal > 0.
    match variable.payload {
      Real(attrs) => {
        match (attrs.min, attrs.max) {
          (Some(min), Some(max)) =>
            if min > max {
              self.add(
                code="MD-014",
                message="min (\{min}) must not exceed max (\{max})",
                path~,
                line=variable.line,
                column=variable.column,
              )
            }
          _ => ()
        }
        match attrs.nominal {
          Some(nominal) =>
            if !(nominal > 0.0) {
              self.add(
                code="MD-014",
                message="nominal (\{nominal}) must be greater than zero",
                path~,
                line=variable.line,
                column=variable.column,
              )
            }
          None => ()
        }
        // MD-050/MD-051: unit and display unit references.
        match attrs.unit {
          Some(unit) =>
            if !self.unit_exists(unit) {
              self.add(
                code="MD-050",
                message="unit '\{unit}' is not defined in <UnitDefinitions>",
                path~,
                severity=Warning,
                line=variable.line,
                column=variable.column,
              )
            }
          None => ()
        }
        match (attrs.unit, attrs.display_unit) {
          (Some(unit), Some(display_unit)) => {
            let mut defined = false
            match self.find_unit(unit) {
              Some(definition) =>
                for display in definition.display_units {
                  if display.name == display_unit {
                    defined = true
                  }
                }
              None => ()
            }
            if !defined {
              self.add(
                code="MD-051",
                message="displayUnit '\{display_unit}' is not defined for unit '\{unit}'",
                path~,
                severity=Warning,
                line=variable.line,
                column=variable.column,
              )
            }
          }
          (None, Some(_)) =>
            self.add(
              code="MD-051",
              message="displayUnit requires the unit attribute to be present",
              path~,
              severity=Warning,
              line=variable.line,
              column=variable.column,
            )
          _ => ()
        }
        // MD-017: derivative reference.
        match attrs.derivative {
          Some(target_index) =>
            self.check_derivative(target_index, variable, position + 1)
          None => ()
        }
        // MD-018: reinit only for continuous states.
        if attrs.reinit == Some(true) && !self.is_state(position + 1) {
          self.add(
            code="MD-018",
            message="reinit=true is only valid for continuous states listed in <Derivatives>",
            path~,
            line=variable.line,
            column=variable.column,
          )
        }
      }
      Integer(attrs) => {
        match (attrs.min, attrs.max) {
          (Some(min), Some(max)) =>
            if min > max {
              self.add(
                code="MD-014",
                message="min (\{min}) must not exceed max (\{max})",
                path~,
                line=variable.line,
                column=variable.column,
              )
            }
          _ => ()
        }
        self.check_declared_type(variable, position + 1)
      }
      Boolean(attrs) =>
        self.check_declared_type_of(variable, Boolean(attrs), position + 1)
      Str(attrs) =>
        self.check_declared_type_of(variable, Str(attrs), position + 1)
      Enumeration(attrs) => {
        match (attrs.min, attrs.max) {
          (Some(min), Some(max)) =>
            if min > max {
              self.add(
                code="MD-014",
                message="min (\{min}) must not exceed max (\{max})",
                path~,
                line=variable.line,
                column=variable.column,
              )
            }
          _ => ()
        }
        // MD-015: Enumeration needs a declared type that exists.
        match attrs.declared_type {
          Some(name) =>
            match self.type_definition(name) {
              Some(definition) =>
                match definition.payload {
                  Enumeration(_) => ()
                  _ =>
                    self.add(
                      code="MD-015",
                      message="declaredType '\{name}' is not an enumeration type",
                      path~,
                      line=variable.line,
                      column=variable.column,
                    )
                }
              None =>
                self.add(
                  code="MD-015",
                  message="declaredType '\{name}' does not exist in <TypeDefinitions>",
                  path~,
                  line=variable.line,
                  column=variable.column,
                )
            }
          None =>
            self.add(
              code="MD-015",
              message="Enumeration variables must declare declaredType",
              path~,
              line=variable.line,
              column=variable.column,
            )
        }
      }
    }
    // MD-019: canHandleMultipleSetPerTimeInstant only for ME inputs.
    match variable.can_handle_multiple_set_per_time_instant {
      Some(_) =>
        if causality != Input {
          self.add(
            code="MD-019",
            message="canHandleMultipleSetPerTimeInstant is only valid for input variables",
            path~,
            line=variable.line,
            column=variable.column,
          )
        } else if self.model.model_exchange is None {
          self.add(
            code="MD-019",
            message="canHandleMultipleSetPerTimeInstant has no effect without <ModelExchange>",
            path~,
            severity=Warning,
            line=variable.line,
            column=variable.column,
          )
        }
      None => ()
    }
  }
}

///|
fn Fmi2Rules::find_unit(self : Fmi2Rules, name : String) -> UnitDef? {
  for unit in self.model.unit_definitions {
    if unit.name == name {
      return Some(unit)
    }
  }
  None
}

///|
fn Fmi2Rules::check_derivative(
  self : Fmi2Rules,
  target_index : UInt32,
  variable : Fmi2ScalarVariable,
  position : Int32,
) -> Unit {
  let path = fmi2_var_path(position)
  let index = target_index.reinterpret_as_int()
  if index < 1 || index > self.model.variables.length() {
    self.add(
      code="MD-017",
      message="derivative index \{index} is out of range (1..\{self.model.variables.length()})",
      path~,
      line=variable.line,
      column=variable.column,
    )
    return
  }
  let target = self.model.variables[index - 1]
  match target.payload {
    Real(_) => ()
    _ =>
      self.add(
        code="MD-017",
        message="derivative target '\{target.name}' must be a Real variable",
        path~,
        line=variable.line,
        column=variable.column,
      )
  }
  if index == position {
    self.add(
      code="MD-017",
      message="variable '\{variable.name}' cannot be its own derivative",
      path~,
      line=variable.line,
      column=variable.column,
    )
  }
}

///|

///|
/// True when some variable declares `index` as its derivative, i.e. the
/// variable is a continuous state. Note FMI 2 lists the *derivative*
/// variables in ModelStructure/Derivatives, not the states themselves.
fn Fmi2Rules::is_state(self : Fmi2Rules, index : Int32) -> Bool {
  for variable in self.model.variables {
    match variable.payload {
      Real(attrs) =>
        match attrs.derivative {
          Some(target) =>
            if target.reinterpret_as_int() == index {
              return true
            }
          None => ()
        }
      _ => ()
    }
  }
  false
}

///|
/// MD-016 for payload kinds without extra checks.
fn Fmi2Rules::check_declared_type(
  self : Fmi2Rules,
  variable : Fmi2ScalarVariable,
  position : Int32,
) -> Unit {
  self.check_declared_type_of(variable, variable.payload, position)
}

///|
/// MD-016: declaredType must exist and carry a matching payload kind.
fn Fmi2Rules::check_declared_type_of(
  self : Fmi2Rules,
  variable : Fmi2ScalarVariable,
  payload : Fmi2Payload,
  position : Int32,
) -> Unit {
  let name = match payload {
    Real(attrs) => attrs.declared_type
    Integer(attrs) => attrs.declared_type
    Boolean(attrs) => attrs.declared_type
    Str(attrs) => attrs.declared_type
    Enumeration(attrs) => attrs.declared_type
  }
  match name {
    Some(type_name) =>
      match self.type_definition(type_name) {
        Some(definition) => {
          let same_kind = payload_kind_of(definition.payload) ==
            payload_kind_of(payload)
          if !same_kind {
            self.add(
              code="MD-016",
              message="declaredType '\{type_name}' has a different type than variable '\{variable.name}'",
              path=fmi2_var_path(position),
              line=variable.line,
              column=variable.column,
            )
          }
        }
        None =>
          self.add(
            code="MD-016",
            message="declaredType '\{type_name}' does not exist in <TypeDefinitions>",
            path=fmi2_var_path(position),
            line=variable.line,
            column=variable.column,
          )
      }
    None => ()
  }
}

///|
fn payload_kind_of(payload : Fmi2Payload) -> String {
  match payload {
    Real(_) => "Real"
    Integer(_) => "Integer"
    Boolean(_) => "Boolean"
    Str(_) => "String"
    Enumeration(_) => "Enumeration"
  }
}

///|
/// MD-040..MD-044: model structure rules.
fn Fmi2Rules::check_model_structure(self : Fmi2Rules) -> Unit {
  let variable_count = self.model.variables.length()
  // MD-040: Outputs covers exactly the causality="output" variables.
  let output_indexes : Map[Int32, Unit] = Map([])
  for position, variable in self.model.variables {
    if variable.effective_causality() == Output {
      output_indexes.set(position + 1, ())
    }
  }
  let listed_outputs : Map[Int32, Unit] = Map([])
  for unknown in self.model.model_structure.outputs {
    let index = unknown.index.reinterpret_as_int()
    let path = "/fmiModelDescription/ModelStructure/Outputs"
    if index < 1 || index > variable_count {
      self.add(
        code="MD-040",
        message="Outputs index \{index} is out of range (1..\{variable_count})",
        path~,
        line=unknown.line,
        column=unknown.column,
      )
    } else {
      if listed_outputs.contains(index) {
        self.add(
          code="MD-040",
          message="Outputs lists index \{index} twice",
          path~,
          line=unknown.line,
          column=unknown.column,
        )
      }
      listed_outputs.set(index, ())
      if !output_indexes.contains(index) {
        self.add(
          code="MD-040",
          message="Outputs lists index \{index}, which is not an output variable",
          path~,
          line=unknown.line,
          column=unknown.column,
        )
      }
    }
  }
  for index, _ in output_indexes {
    if !listed_outputs.contains(index) {
      self.add(
        code="MD-040",
        message="output variable ScalarVariable[\{index}] is missing from <Outputs>",
        path="/fmiModelDescription/ModelStructure/Outputs",
      )
    }
  }
  // MD-041: Derivatives entries are valid Real indices without duplicates.
  let listed_derivatives : Map[Int32, Unit] = Map([])
  for unknown in self.model.model_structure.derivatives {
    let index = unknown.index.reinterpret_as_int()
    let path = "/fmiModelDescription/ModelStructure/Derivatives"
    if index < 1 || index > variable_count {
      self.add(
        code="MD-041",
        message="Derivatives index \{index} is out of range (1..\{variable_count})",
        path~,
        line=unknown.line,
        column=unknown.column,
      )
    } else {
      if listed_derivatives.contains(index) {
        self.add(
          code="MD-041",
          message="Derivatives lists index \{index} twice",
          path~,
          line=unknown.line,
          column=unknown.column,
        )
      }
      listed_derivatives.set(index, ())
      match self.model.variables[index - 1].payload {
        Real(attrs) =>
          // Derivatives lists the *derivative* variables: each entry must
          // declare which state it is the derivative of.
          if attrs.derivative is None {
            self.add(
              code="MD-041",
              message="Derivatives index \{index} must reference a derivative variable (one that declares a derivative attribute)",
              path~,
              line=unknown.line,
              column=unknown.column,
            )
          }
        _ =>
          self.add(
            code="MD-041",
            message="Derivatives index \{index} must reference a Real variable",
            path~,
            line=unknown.line,
            column=unknown.column,
          )
      }
    }
  }
  // MD-042: InitialUnknowns ascending without duplicates.
  let mut previous = 0
  for unknown in self.model.model_structure.initial_unknowns {
    let index = unknown.index.reinterpret_as_int()
    let path = "/fmiModelDescription/ModelStructure/InitialUnknowns"
    if index <= previous {
      self.add(
        code="MD-042",
        message="InitialUnknowns must be sorted ascending by index without duplicates (found \{index} after \{previous})",
        path~,
        line=unknown.line,
        column=unknown.column,
      )
    }
    previous = index
  }
  // MD-043/MD-044/MD-049: dependency lists.
  self.check_dependencies(self.model.model_structure.outputs, "Outputs")
  self.check_dependencies(self.model.model_structure.derivatives, "Derivatives")
  self.check_dependencies(
    self.model.model_structure.initial_unknowns,
    "InitialUnknowns",
  )
}

///|
fn Fmi2Rules::check_dependencies(
  self : Fmi2Rules,
  unknowns : Array[Fmi2Unknown],
  container : String,
) -> Unit {
  let variable_count = self.model.variables.length()
  for unknown in unknowns {
    let path = "/fmiModelDescription/ModelStructure/\{container}"
    match (unknown.dependencies, unknown.dependencies_kind) {
      (None, Some(_)) =>
        self.add(
          code="MD-044",
          message="dependenciesKind requires dependencies to be present",
          path~,
          line=unknown.line,
          column=unknown.column,
        )
      (Some(dependencies), kinds) => {
        let mut previous = 0
        for dependency in dependencies {
          let index = dependency.reinterpret_as_int()
          if index < 1 || index > variable_count {
            self.add(
              code="MD-043",
              message="dependencies index \{index} is out of range (1..\{variable_count})",
              path~,
              line=unknown.line,
              column=unknown.column,
            )
          } else if index <= previous {
            self.add(
              code="MD-043",
              message="dependencies must be sorted ascending without duplicates (found \{index} after \{previous})",
              path~,
              line=unknown.line,
              column=unknown.column,
            )
          }
          previous = index
        }
        match kinds {
          Some(kinds) =>
            if kinds.length() != dependencies.length() {
              self.add(
                code="MD-044",
                message="dependenciesKind has \{kinds.length()} entries but dependencies has \{dependencies.length()}",
                path~,
                line=unknown.line,
                column=unknown.column,
              )
            }
          None => ()
        }
      }
      (None, None) => ()
    }
  }
}

///|
/// MD-053/MD-054: type definition names and enumeration items.
fn Fmi2Rules::check_types(self : Fmi2Rules) -> Unit {
  let seen : Map[String, Unit] = Map([])
  for definition in self.model.type_definitions {
    let path = "/fmiModelDescription/TypeDefinitions/SimpleType"
    if seen.contains(definition.name) {
      self.add(
        code="MD-053",
        message="type name '\{definition.name}' is defined twice",
        path~,
        line=definition.line,
        column=definition.column,
      )
    }
    seen.set(definition.name, ())
    if self.index.by_name.contains(definition.name) {
      self.add(
        code="MD-053",
        message="type name '\{definition.name}' collides with a variable name",
        path~,
        line=definition.line,
        column=definition.column,
      )
    }
    match definition.payload {
      Enumeration(attrs) => {
        let values : Map[Int64, Unit] = Map([])
        for item in attrs.items {
          if values.contains(item.value) {
            self.add(
              code="MD-054",
              message="enumeration '\{definition.name}' defines value \{item.value} twice",
              path~,
              line=definition.line,
              column=definition.column,
            )
          }
          values.set(item.value, ())
        }
      }
      _ => ()
    }
  }
}

///|
/// Accumulator shared by the FMI 3 rule checks.
priv struct Fmi3Rules {
  model : Fmi3ModelDescription
  index : Fmi3Index
  diagnostics : Array[Diagnostic]
}

///|
fn Fmi3Rules::add(
  self : Fmi3Rules,
  code~ : String,
  message~ : String,
  path~ : String,
  severity~ : Severity = Error,
  line? : Int32,
  column? : Int32,
  hint? : String,
) -> Unit {
  self.diagnostics.push(
    Diagnostic::new(code~, severity~, message~, path~, line?, column?, hint?),
  )
}

///|
fn fmi3_var_path(position : Int32) -> String {
  "/fmiModelDescription/ModelVariables[\{position}]"
}

///|
fn fmi3_has_start(variable : Fmi3Variable) -> Bool {
  match variable.payload {
    Float(attrs) => !attrs.starts.is_empty()
    Int(attrs) => !attrs.starts.is_empty()
    UInt(attrs) => !attrs.starts.is_empty()
    Bool(attrs) => !attrs.starts.is_empty()
    Text(attrs) => !attrs.starts.is_empty()
    Bin(attrs) => !attrs.starts.is_empty()
    Enum(attrs) => !attrs.starts.is_empty()
    Clock(_) => true
  }
}

///|
fn Fmi3Rules::type_definition(
  self : Fmi3Rules,
  name : String,
) -> Fmi3TypeDefinition? {
  for definition in self.model.type_definitions {
    if definition.name == name {
      return Some(definition)
    }
  }
  None
}

///|
fn Fmi3Rules::unit_exists(self : Fmi3Rules, name : String) -> Bool {
  for unit in self.model.unit_definitions {
    if unit.name == name {
      return true
    }
  }
  false
}

///|
/// Variable position (1-based) by value reference, excluding a position.
fn Fmi3Rules::position_of_vr(
  self : Fmi3Rules,
  value_reference : UInt32,
  exclude~ : Int32,
) -> Int32? {
  match self.index.positions_of_value_reference(value_reference) {
    Some(positions) =>
      for position in positions {
        if position != exclude {
          return Some(position)
        }
      }
    None => ()
  }
  None
}

///|
/// Validate the semantic rules for an FMI 3 model.
pub fn validate_fmi3(
  model : Fmi3ModelDescription,
  index : Fmi3Index,
) -> Array[Diagnostic] {
  let rules : Fmi3Rules = { model, index, diagnostics: [], }
  rules.check_root()
  rules.check_variables()
  rules.check_model_structure()
  rules.check_types()
  rules.diagnostics
}

///|
fn Fmi3Rules::check_root(self : Fmi3Rules) -> Unit {
  let root = "/fmiModelDescription"
  if self.model.interfaces.is_empty() {
    self.add(
      code="MD-003",
      message="at least one of <ModelExchange>, <CoSimulation>, or <ScheduledExecution> is required",
      path=root,
    )
  }
  if self.model.model_name == "" {
    self.add(code="MD-005", message="modelName must not be empty", path=root)
  }
  if self.model.instantiation_token == "" {
    self.add(
      code="MD-006",
      message="instantiationToken must not be empty",
      path=root,
    )
  }
  for interface in self.model.interfaces {
    let path = "\{root}/\{interface.kind.name()}"
    if interface.model_identifier == "" {
      self.add(
        code="MD-004",
        message="modelIdentifier must not be empty",
        path~,
      )
    } else if !is_safe_model_identifier(interface.model_identifier) {
      self.add(
        code="MD-062",
        message="modelIdentifier '\{interface.model_identifier}' is not safe",
        path~,
        hint="it must not contain path separators, '..', ':', or control characters",
      )
    }
  }
}

///|
fn Fmi3Rules::check_variables(self : Fmi3Rules) -> Unit {
  let seen_names : Map[String, Int32] = Map([])
  let seen_alias_names : Map[String, Int32] = Map([])
  for position, variable in self.model.variables {
    let path = fmi3_var_path(position + 1)
    // MD-010: unique variable names.
    match seen_names.get(variable.name) {
      Some(first) =>
        self.add(
          code="MD-010",
          message="variable name '\{variable.name}' is already used by ModelVariables[\{first}]",
          path~,
          line=variable.line,
          column=variable.column,
        )
      None => seen_names.set(variable.name, position + 1)
    }
    // MD-011: valueReference unique among variables.
    match self.index.positions_of_value_reference(variable.value_reference) {
      Some(positions) =>
        if positions.length() > 1 {
          self.add(
            code="MD-011",
            message="valueReference \{variable.value_reference} is used by \{positions.length()} variables (FMI 3 requires unique references)",
            path~,
            line=variable.line,
            column=variable.column,
          )
        }
      None => ()
    }
    // MD-020: alias names unique and collision-free.
    for alias_item in variable.aliases {
      if seen_alias_names.contains(alias_item.name) ||
        seen_names.contains(alias_item.name) {
        self.add(
          code="MD-020",
          message="alias name '\{alias_item.name}' collides with an existing variable or alias",
          path~,
          line=alias_item.line,
          column=alias_item.column,
        )
      }
      seen_alias_names.set(alias_item.name, position + 1)
    }
    // MD-012: combination matrix (shared with FMI 2). FMI 3 has no
    // variability default, so the effective value is inferred from the
    // type kind. Clock variables are exempt: FMI 3 defines their
    // activation semantics separately from the initial matrix.
    let causality = variable.effective_causality()
    if variable.type_kind is Clock {
      ()
    } else {
      let variability = variable.effective_variability()
      if !causality_allows_variability(causality, variability) {
        let allowed = allowed_variabilities(causality)
        let names : Array[String] = []
        for candidate in allowed {
          names.push(candidate.name())
        }
        let allowed_text = names.join(", ")
        self.add(
          code="MD-012",
          message="causality '\{causality.name()}' does not allow variability '\{variability.name()}'",
          path~,
          line=variable.line,
          column=variable.column,
          hint="allowed variability values: " + allowed_text,
        )
      } else if variable.initial is Some(initial) {
        match allowed_initials(causality, variability) {
          Some(permitted) => {
            let mut ok = false
            for candidate in permitted {
              if candidate == initial {
                ok = true
              }
            }
            if !ok {
              self.add(
                code="MD-012",
                message="initial '\{initial.name()}' is not valid for causality '\{causality.name()}' with variability '\{variability.name()}'",
                path~,
                line=variable.line,
                column=variable.column,
              )
            }
          }
          None =>
            self.add(
              code="MD-012",
              message="causality '\{causality.name()}' must not declare an initial attribute",
              path~,
              line=variable.line,
              column=variable.column,
            )
        }
      }
    }
    // MD-013: initial=exact/approx should come with a start value.
    if variable.effective_initial() is (Some(Exact) | Some(Approx)) &&
      !fmi3_has_start(variable) {
      self.add(
        code="MD-013",
        message="variable declares initial='exact' but has no start value",
        path~,
        severity=Warning,
        line=variable.line,
        column=variable.column,
      )
    }
    // MD-012 follow-ups mirrored from FMPy's validator.
    if variable.initial is Some(Calculated) && fmi3_has_start(variable) {
      self.add(
        code="MD-012",
        message="variable declares initial='calculated' but provides a start value",
        path~,
        line=variable.line,
        column=variable.column,
      )
    }
    if causality == Independent && fmi3_has_start(variable) {
      self.add(
        code="MD-012",
        message="independent variable must not provide a start value",
        path~,
        line=variable.line,
        column=variable.column,
      )
    }
    // MD-030..MD-032: dimensions.
    let mut product : UInt64 = 1UL
    for dimension in variable.dimensions {
      let dim_path = "\{path}/Dimension"
      match (dimension.start, dimension.value_reference) {
        (None, None) =>
          self.add(
            code="MD-030",
            message="Dimension needs a start or a valueReference",
            path=dim_path,
            line=dimension.line,
            column=dimension.column,
          )
        (Some(start), _) =>
          // MD-032: fixed-dimension product must not overflow.
          if start > 0UL && product > 0xFFFFFFFFFFFFFFFFUL / start {
            self.add(
              code="MD-032",
              message="array dimensions of '\{variable.name}' overflow 64 bits",
              path=dim_path,
              line=dimension.line,
              column=dimension.column,
            )
            product = 0UL
          } else if product > 0UL {
            product *= start
          }
        (None, Some(vr)) =>
          // MD-031: dimension reference must be a structural parameter.
          match self.position_of_vr(vr, exclude=-1) {
            Some(target_position) => {
              let target = self.model.variables[target_position - 1]
              if target.effective_causality() != StructuralParameter {
                self.add(
                  code="MD-031",
                  message="Dimension valueReference \{vr} points at '\{target.name}', which is not a structuralParameter",
                  path=dim_path,
                  line=dimension.line,
                  column=dimension.column,
                )
              }
            }
            None =>
              self.add(
                code="MD-031",
                message="Dimension valueReference \{vr} does not match any variable",
                path=dim_path,
                line=dimension.line,
                column=dimension.column,
              )
          }
      }
    }
    match variable.payload {
      Float(attrs) => {
        match (attrs.min, attrs.max) {
          (Some(min), Some(max)) =>
            if min > max {
              self.add(
                code="MD-014",
                message="min (\{min}) must not exceed max (\{max})",
                path~,
                line=variable.line,
                column=variable.column,
              )
            }
          _ => ()
        }
        match attrs.nominal {
          Some(nominal) =>
            if !(nominal > 0.0) {
              self.add(
                code="MD-014",
                message="nominal (\{nominal}) must be greater than zero",
                path~,
                line=variable.line,
                column=variable.column,
              )
            }
          None => ()
        }
        match attrs.unit {
          Some(unit) =>
            if !self.unit_exists(unit) {
              self.add(
                code="MD-050",
                message="unit '\{unit}' is not defined in <UnitDefinitions>",
                path~,
                severity=Warning,
                line=variable.line,
                column=variable.column,
              )
            }
          None => ()
        }
        match (attrs.unit, attrs.display_unit) {
          (Some(unit), Some(display_unit)) => {
            let mut defined = false
            match self.find_unit(unit) {
              Some(definition) =>
                for display in definition.display_units {
                  if display.name == display_unit {
                    defined = true
                  }
                }
              None => ()
            }
            if !defined {
              self.add(
                code="MD-051",
                message="displayUnit '\{display_unit}' is not defined for unit '\{unit}'",
                path~,
                severity=Warning,
                line=variable.line,
                column=variable.column,
              )
            }
          }
          (None, Some(_)) =>
            self.add(
              code="MD-051",
              message="displayUnit requires the unit attribute to be present",
              path~,
              severity=Warning,
              line=variable.line,
              column=variable.column,
            )
          _ => ()
        }
        // MD-017: derivative reference (FMI 3 uses value references).
        match attrs.derivative {
          Some(vr) =>
            match self.position_of_vr(vr, exclude=position + 1) {
              Some(target_position) => {
                let target = self.model.variables[target_position - 1]
                if !target.type_kind.is_float() {
                  self.add(
                    code="MD-017",
                    message="derivative target '\{target.name}' must be a Float variable",
                    path~,
                    line=variable.line,
                    column=variable.column,
                  )
                }
              }
              None =>
                self.add(
                  code="MD-017",
                  message="derivative valueReference \{vr} does not match any variable",
                  path~,
                  line=variable.line,
                  column=variable.column,
                )
            }
          None => ()
        }
        // MD-018: reinit=true marks a continuous state, i.e. some other
        // variable must name this one as its derivative.
        if attrs.reinit == Some(true) {
          let mut referenced = false
          for other in self.model.variables {
            match other.payload {
              Float(other_attrs) =>
                match other_attrs.derivative {
                  Some(vr) =>
                    if vr == variable.value_reference {
                      referenced = true
                    }
                  None => ()
                }
              _ => ()
            }
          }
          if !referenced {
            self.add(
              code="MD-018",
              message="reinit=true is only valid for continuous states (no variable declares '\{variable.name}' as its derivative)",
              path~,
              line=variable.line,
              column=variable.column,
            )
          }
        }
      }
      Int(attrs) => self.check_int_bounds(attrs.min, attrs.max, variable, path~)
      UInt(attrs) =>
        self.check_uint_bounds(attrs.min, attrs.max, variable, path~)
      Enum(attrs) => {
        match (attrs.min, attrs.max) {
          (Some(min), Some(max)) =>
            if min > max {
              self.add(
                code="MD-014",
                message="min (\{min}) must not exceed max (\{max})",
                path~,
                line=variable.line,
                column=variable.column,
              )
            }
          _ => ()
        }
        match attrs.declared_type {
          Some(name) =>
            match self.type_definition(name) {
              Some(definition) =>
                if !(definition.type_kind is Enumeration) {
                  self.add(
                    code="MD-015",
                    message="declaredType '\{name}' is not an enumeration type",
                    path~,
                    line=variable.line,
                    column=variable.column,
                  )
                }
              None =>
                self.add(
                  code="MD-015",
                  message="declaredType '\{name}' does not exist in <TypeDefinitions>",
                  path~,
                  line=variable.line,
                  column=variable.column,
                )
            }
          None =>
            self.add(
              code="MD-015",
              message="Enumeration variables must declare declaredType",
              path~,
              line=variable.line,
              column=variable.column,
            )
        }
      }
      Clock(attrs) => {
        // MD-033: intervalVariability required.
        match attrs.interval_variability {
          Some(variability) => {
            // MD-035: triggered clocks should not fix an interval.
            if variability is Triggered {
              if attrs.interval_decimal is Some(_) ||
                attrs.interval_counter is Some(_) {
                self.add(
                  code="MD-035",
                  message="triggered clock '\{variable.name}' should not declare a fixed interval",
                  path~,
                  severity=Warning,
                  line=variable.line,
                  column=variable.column,
                )
              }
            }
            // MD-036: priority only matters for triggered clocks.
            if attrs.priority is Some(_) && !(variability is Triggered) {
              self.add(
                code="MD-036",
                message="priority has no effect on '\{variability.name()}' clock '\{variable.name}'",
                path~,
                severity=Warning,
                line=variable.line,
                column=variable.column,
              )
            }
          }
          None =>
            self.add(
              code="MD-033",
              message="Clock '\{variable.name}' must declare intervalVariability",
              path~,
              line=variable.line,
              column=variable.column,
            )
        }
        // MD-034: clocks references exist and name Clock variables.
        match variable.clocks {
          Some(list) =>
            for clock_name in split_ws_list(list) {
              match self.index.position_of_name(clock_name) {
                Some(owner_position) => {
                  let owner = self.model.variables[owner_position - 1]
                  if !(owner.type_kind is Clock) {
                    self.add(
                      code="MD-034",
                      message="clocks reference '\{clock_name}' is not a Clock variable",
                      path~,
                      line=variable.line,
                      column=variable.column,
                    )
                  }
                }
                None =>
                  self.add(
                    code="MD-034",
                    message="clocks reference '\{clock_name}' does not match any variable",
                    path~,
                    line=variable.line,
                    column=variable.column,
                  )
              }
            }
          None => ()
        }
      }
      _ => ()
    }
    // MD-019: canHandleMultipleSetPerTimeInstant only for inputs.
    match variable.can_handle_multiple_set_per_time_instant {
      Some(_) =>
        if causality != Input {
          self.add(
            code="MD-019",
            message="canHandleMultipleSetPerTimeInstant is only valid for input variables",
            path~,
            line=variable.line,
            column=variable.column,
          )
        }
      None => ()
    }
    // MD-016: declaredType exists with the exact same kind.
    match variable.payload {
      Float(attrs) =>
        self.check_declared_type(variable, attrs.declared_type, position + 1)
      Int(attrs) =>
        self.check_declared_type(variable, attrs.declared_type, position + 1)
      UInt(attrs) =>
        self.check_declared_type(variable, attrs.declared_type, position + 1)
      Bool(attrs) =>
        self.check_declared_type(variable, attrs.declared_type, position + 1)
      Text(attrs) =>
        self.check_declared_type(variable, attrs.declared_type, position + 1)
      Bin(attrs) =>
        self.check_declared_type(variable, attrs.declared_type, position + 1)
      Enum(attrs) =>
        self.check_declared_type(variable, attrs.declared_type, position + 1)
      Clock(attrs) =>
        self.check_declared_type(variable, attrs.declared_type, position + 1)
    }
  }
}

///|
fn Fmi3Rules::find_unit(self : Fmi3Rules, name : String) -> UnitDef? {
  for unit in self.model.unit_definitions {
    if unit.name == name {
      return Some(unit)
    }
  }
  None
}

///|
fn Fmi3Rules::check_int_bounds(
  self : Fmi3Rules,
  min : Int64?,
  max : Int64?,
  variable : Fmi3Variable,
  path~ : String,
) -> Unit {
  match (min, max) {
    (Some(min), Some(max)) =>
      if min > max {
        self.add(
          code="MD-014",
          message="min (\{min}) must not exceed max (\{max})",
          path~,
          line=variable.line,
          column=variable.column,
        )
      }
    _ => ()
  }
}

///|
fn Fmi3Rules::check_uint_bounds(
  self : Fmi3Rules,
  min : UInt64?,
  max : UInt64?,
  variable : Fmi3Variable,
  path~ : String,
) -> Unit {
  match (min, max) {
    (Some(min), Some(max)) =>
      if min > max {
        self.add(
          code="MD-014",
          message="min (\{min}) must not exceed max (\{max})",
          path~,
          line=variable.line,
          column=variable.column,
        )
      }
    _ => ()
  }
}

///|
fn Fmi3Rules::check_declared_type(
  self : Fmi3Rules,
  variable : Fmi3Variable,
  declared_type : String?,
  position : Int32,
) -> Unit {
  match declared_type {
    Some(name) =>
      match self.type_definition(name) {
        Some(definition) =>
          if definition.type_kind != variable.type_kind {
            self.add(
              code="MD-016",
              message="declaredType '\{name}' has type \{definition.type_kind.name()} but variable '\{variable.name}' is \{variable.type_kind.name()}",
              path=fmi3_var_path(position),
              line=variable.line,
              column=variable.column,
            )
          }
        None =>
          self.add(
            code="MD-016",
            message="declaredType '\{name}' does not exist in <TypeDefinitions>",
            path=fmi3_var_path(position),
            line=variable.line,
            column=variable.column,
          )
      }
    None => ()
  }
}

///|
fn Fmi3Rules::check_model_structure(self : Fmi3Rules) -> Unit {
  let structure = self.model.model_structure
  let sections = [
    ("Output", structure.outputs),
    ("ContinuousStateDerivative", structure.continuous_state_derivatives),
    ("ClockedState", structure.clocked_states),
    ("InitialUnknown", structure.initial_unknowns),
    ("EventIndicator", structure.event_indicators),
  ]
  // MD-045: every referenced valueReference must exist.
  for section in sections {
    let (name, unknowns) = section
    let path = "/fmiModelDescription/ModelStructure/\{name}"
    let seen : Map[UInt32, Unit] = Map([])
    for _position, unknown in unknowns {
      match self.index.positions_of_value_reference(unknown.value_reference) {
        Some(_) => ()
        None =>
          self.add(
            code="MD-045",
            message="\{name} valueReference \{unknown.value_reference} does not match any variable",
            path~,
            line=unknown.line,
            column=unknown.column,
          )
      }
      // MD-046: ContinuousStateDerivative entries must be derivative variables.
      if name == "ContinuousStateDerivative" {
        self.check_is_derivative(unknown, path~)
      }
      // MD-047: EventIndicator entries must be Float variables.
      if name == "EventIndicator" {
        match self.position_of_vr(unknown.value_reference, exclude=-1) {
          Some(target_position) => {
            let target = self.model.variables[target_position - 1]
            if !target.type_kind.is_float() {
              self.add(
                code="MD-047",
                message="EventIndicator '\{target.name}' must be a Float variable",
                path~,
                line=unknown.line,
                column=unknown.column,
              )
            }
          }
          None => ()
        }
      }
      // MD-048: InitialUnknown entries must not repeat.
      if name == "InitialUnknown" {
        if seen.contains(unknown.value_reference) {
          self.add(
            code="MD-048",
            message="InitialUnknown lists valueReference \{unknown.value_reference} twice",
            path~,
            line=unknown.line,
            column=unknown.column,
          )
        }
        seen.set(unknown.value_reference, ())
      }
      // MD-049: dependenciesKind needs dependencies of equal length.
      match (unknown.dependencies, unknown.dependencies_kind) {
        (None, Some(_)) =>
          self.add(
            code="MD-049",
            message="dependenciesKind requires dependencies to be present",
            path~,
            line=unknown.line,
            column=unknown.column,
          )
        (Some(dependencies), Some(kinds)) =>
          if kinds.length() != dependencies.length() {
            self.add(
              code="MD-049",
              message="dependenciesKind has \{kinds.length()} entries but dependencies has \{dependencies.length()}",
              path~,
              line=unknown.line,
              column=unknown.column,
            )
          }
        _ => ()
      }
    }
  }
}

///|
fn Fmi3Rules::check_is_derivative(
  self : Fmi3Rules,
  unknown : Fmi3Unknown,
  path~ : String,
) -> Unit {
  match self.position_of_vr(unknown.value_reference, exclude=-1) {
    Some(position) => {
      let variable = self.model.variables[position - 1]
      let mut has_derivative = false
      match variable.payload {
        Float(attrs) => has_derivative = attrs.derivative is Some(_)
        _ => ()
      }
      if !has_derivative {
        self.add(
          code="MD-046",
          message="ContinuousStateDerivative '\{variable.name}' does not declare a derivative attribute",
          path~,
          line=unknown.line,
          column=unknown.column,
        )
      }
    }
    None => ()
  }
}

///|
fn Fmi3Rules::check_types(self : Fmi3Rules) -> Unit {
  let seen : Map[String, Unit] = Map([])
  for definition in self.model.type_definitions {
    let path = "/fmiModelDescription/TypeDefinitions"
    if seen.contains(definition.name) {
      self.add(
        code="MD-053",
        message="type name '\{definition.name}' is defined twice",
        path~,
        line=definition.line,
        column=definition.column,
      )
    }
    seen.set(definition.name, ())
    if self.index.by_name.contains(definition.name) {
      self.add(
        code="MD-053",
        message="type name '\{definition.name}' collides with a variable name",
        path~,
        line=definition.line,
        column=definition.column,
      )
    }
    match definition.payload {
      Enum(attrs) => {
        let values : Map[Int64, Unit] = Map([])
        for item in attrs.items {
          if values.contains(item.value) {
            self.add(
              code="MD-054",
              message="enumeration '\{definition.name}' defines value \{item.value} twice",
              path~,
              line=definition.line,
              column=definition.column,
            )
          }
          values.set(item.value, ())
        }
      }
      _ => ()
    }
  }
}
