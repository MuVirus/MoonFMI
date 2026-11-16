// Model IR for the exporter (roadmap P6 / task E-01).
//
// The IR is FMI-version neutral: one `ModelIr` can be exported as an FMI 2 or
// an FMI 3 source FMU. It supports the restricted explicit model form from
// docs/design/exporter.md §3 — continuous states, direct-feedthrough outputs,
// parameters and inputs — not a general Modelica compiler.
//
// Variable order in `variables` is the export order and the value-reference
// order (vr = declaration index); keep it stable for reproducible output.

///|
/// Value types carried by start values and equations.
#derive(Eq, Debug)
pub(all) enum IrDataType {
  Float64
  Float32
  Int32
  Int64
  UInt64
  Boolean
  Str
}

///|
pub extend IrDataType with Eq::{not_equal, equal}

///|
pub extend IrDataType with @debug.Debug::{to_repr}

///|
pub fn IrDataType::name(self : IrDataType) -> String {
  match self {
    IrDataType::Float64 => "Float64"
    IrDataType::Float32 => "Float32"
    IrDataType::Int32 => "Int32"
    IrDataType::Int64 => "Int64"
    IrDataType::UInt64 => "UInt64"
    IrDataType::Boolean => "Boolean"
    IrDataType::Str => "String"
  }
}

///|
/// C type of the generated struct member for this data type.
pub fn IrDataType::c_type(self : IrDataType) -> String {
  match self {
    IrDataType::Float64 => "double"
    IrDataType::Float32 => "float"
    IrDataType::Int32 => "int32_t"
    IrDataType::Int64 => "int64_t"
    IrDataType::UInt64 => "uint64_t"
    IrDataType::Boolean => "unsigned char"
    IrDataType::Str => "char*"
  }
}

///|
/// Start/constant value; array forms exist for FMI 3 dimensioned variables.
#derive(Eq, Debug)
pub(all) enum IrValue {
  Real(Double)
  Int(Int64)
  Bool(Bool)
  Str(String)
  RealArray(Array[Double])
  IntArray(Array[Int64])
}

///|
pub extend IrValue with Eq::{not_equal, equal}

///|
pub extend IrValue with @debug.Debug::{to_repr}

///|
/// A variable in the IR. `dimensions` is empty for scalars; otherwise it
/// holds the fixed literal sizes (FMI 3 only; FMI 2 rejects arrays).
pub struct IrVariable {
  name : String
  data_type : IrDataType
  causality : @schema.Causality
  mut variability : @schema.Variability
  mut initial : @schema.Initial?
  mut start : IrValue?
  mut unit : String?
  display_unit : String?
  quantity : String?
  mut description : String?
  min : Double?
  max : Double?
  mut nominal : Double?
  dimensions : Array[UInt32]
}

///|
pub fn IrVariable::new(
  name~ : String,
  data_type~ : IrDataType,
  causality~ : @schema.Causality,
  initial? : @schema.Initial,
  unit? : String,
  display_unit? : String,
  quantity? : String,
  min? : Double,
  max? : Double,
) -> IrVariable {
  let variability = match causality {
    @schema.Causality::Parameter => @schema.Variability::Fixed
    @schema.Causality::StructuralParameter => @schema.Variability::Fixed
    @schema.Causality::CalculatedParameter => @schema.Variability::Tunable
    @schema.Causality::Input => @schema.Variability::Discrete
    @schema.Causality::Output => @schema.Variability::Continuous
    @schema.Causality::Local => @schema.Variability::Continuous
    @schema.Causality::Independent => @schema.Variability::Continuous
  }
  {
    name,
    data_type,
    causality,
    variability,
    initial,
    start: None,
    unit,
    display_unit,
    quantity,
    description: None,
    min,
    max,
    nominal: None,
    dimensions: [],
  }
}

///|
/// `der(x) = expr` — state `x` must be a continuous local/output variable.
pub(all) enum IrEquation {
  Derivative(String, IrExpr)
  Output(String, IrExpr)
}

///|
/// Restricted expression AST (docs/design/exporter.md §3.2).
#derive(Eq, Debug)
pub(all) enum IrExpr {
  Const(Double)
  Time
  Var(String)
  Add(IrExpr, IrExpr)
  Sub(IrExpr, IrExpr)
  Mul(IrExpr, IrExpr)
  Div(IrExpr, IrExpr)
  Neg(IrExpr)
  Call(String, Array[IrExpr])
}

///|
pub extend IrExpr with Eq::{not_equal, equal}

///|
pub extend IrExpr with @debug.Debug::{to_repr}

///|
/// Functions the C codegen knows how to emit. `min`/`max`/`pow` take two
/// arguments, `abs` maps to `fabs`, the rest take one.
pub fn IrExpr::allowed_calls() -> Array[String] {
  [
    "sin", "cos", "tan", "exp", "log", "sqrt", "abs", "floor", "ceil", "pow", "min",
    "max",
  ]
}

///|
pub struct IrInterface {
  kind : @schema.InterfaceKind
  model_identifier : String
}

///|
pub struct IrDefaultExperiment {
  start_time : Double
  stop_time : Double
  step_size : Double?
  tolerance : Double?
}

///|
pub struct IrLogCategory {
  name : String
  description : String?
}

///|
pub fn IrDefaultExperiment::new(
  start_time~ : Double,
  stop_time~ : Double,
  step_size~ : Double? = None,
  tolerance~ : Double? = None,
) -> IrDefaultExperiment {
  { start_time, stop_time, step_size, tolerance, }
}

///|
pub struct ModelIr {
  model_name : String
  description : String?
  model_version : String?
  /// `None` derives a stable GUID/instantiationToken from the IR content.
  guid : String?
  interfaces : Array[IrInterface]
  variables : Array[IrVariable]
  equations : Array[IrEquation]
  units : Array[@schema.UnitDef]
  log_categories : Array[IrLogCategory]
  default_experiment : IrDefaultExperiment?
  generation_tool : String
}

///|
pub fn ModelIr::new(
  model_name~ : String,
  generation_tool~ : String,
  description? : String,
  model_version? : String,
  guid? : String,
  default_experiment? : IrDefaultExperiment,
) -> ModelIr {
  {
    model_name,
    description,
    model_version,
    guid,
    interfaces: [],
    variables: [],
    equations: [],
    units: [],
    log_categories: [],
    default_experiment,
    generation_tool,
  }
}

///|
/// Declaration index of a variable by name.
pub fn ModelIr::index_of(self : ModelIr, name : String) -> Int32? {
  let mut i = 0
  for v in self.variables {
    if v.name == name {
      return Some(i)
    }
    i += 1
  }
  None
}

///|
/// Value reference of a variable by name — its declaration index.
pub fn ModelIr::value_reference(self : ModelIr, name : String) -> UInt32? {
  match self.index_of(name) {
    Some(i) => Some(i.reinterpret_as_uint())
    None => None
  }
}

///|
/// Names targeted by derivative equations, in equation order. This is the
/// generated continuous-state order (struct and get/set index order).
pub fn ModelIr::state_names(self : ModelIr) -> Array[String] {
  let names = []
  for eq in self.equations {
    match eq {
      IrEquation::Derivative(name, _) => names.push(name)
      _ => ()
    }
  }
  names
}

///|
/// Variable declarations targeted by output equations, in equation order.
pub fn ModelIr::output_equation_names(self : ModelIr) -> Array[String] {
  let names = []
  for eq in self.equations {
    match eq {
      IrEquation::Output(name, _) => names.push(name)
      _ => ()
    }
  }
  names
}

///|
fn IrExpr::walk(self : IrExpr, visit : (String) -> Unit) -> Unit {
  match self {
    IrExpr::Const(_) => ()
    IrExpr::Time => ()
    IrExpr::Var(name) => visit(name)
    IrExpr::Add(a, b)
    | IrExpr::Sub(a, b)
    | IrExpr::Mul(a, b)
    | IrExpr::Div(a, b) => {
      a.walk(visit)
      b.walk(visit)
    }
    IrExpr::Neg(a) => a.walk(visit)
    IrExpr::Call(_, args) =>
      for arg in args {
        arg.walk(visit)
      }
  }
}

///|
fn IrExpr::render(self : IrExpr) -> String {
  match self {
    IrExpr::Const(value) =>
      // %.17g equivalent shortest round-trip via Double::to_string keeps the
      // generated C readable and exact.
      value.to_string()
    IrExpr::Time => "t"
    IrExpr::Var(name) => "m->\{c_member(name)}"
    IrExpr::Add(a, b) => "(\{a.render()} + \{b.render()})"
    IrExpr::Sub(a, b) => "(\{a.render()} - \{b.render()})"
    IrExpr::Mul(a, b) => "(\{a.render()} * \{b.render()})"
    IrExpr::Div(a, b) => "(\{a.render()} / \{b.render()})"
    IrExpr::Neg(a) => "(-\{a.render()})"
    IrExpr::Call(name, args) => {
      let mapped = match (name, args.length()) {
        ("abs", 1) => "fabs"
        (_, _) => name
      }
      let rendered = []
      for arg in args {
        rendered.push(arg.render())
      }
      "\{mapped}(\{rendered.join(", ")})"
    }
  }
}

///|
/// Identifiers used in the IR are emitted as C struct members with a fixed
/// prefix and sanitised identifier body so FMI names never collide with C
/// keywords or runtime names.
pub fn c_member(name : String) -> String {
  "v_" + c_identifier(name)
}

///|
/// C preprocessor constant name for a variable's value reference.
pub fn c_vr_macro(name : String) -> String {
  "MOONFMI_VR_\{name}"
}

///|
/// C identifier sanitisation for generated function/file names. Variables
/// keep their FMI names in the XML; only C names go through here.
pub fn c_identifier(name : String) -> String {
  let buf = StringBuilder()
  let mut position = 0
  for index, ch in name {
    let code : Int32 = ch.to_int()
    let ok = (code >= 97 && code <= 122) ||
      (code >= 65 && code <= 90) ||
      (code >= 48 && code <= 57 && position > 0)
    if ok {
      buf.write_char(ch)
    } else {
      buf.write_char('_')
    }
    position += 1
    let _ = index
  }
  let out = buf.to_string()
  if out.is_empty() {
    return "_"
  }
  let first_code : Int32 = out[0].to_int()
  let is_letter = (first_code >= 97 && first_code <= 122) ||
    (first_code >= 65 && first_code <= 90)
  if is_letter {
    out
  } else {
    "_" + out
  }
}

///|
/// IR self-check. Returns diagnostics in the shared schema format so the CLI
/// can render them like any other finding. Checks are version independent;
/// version-specific rules (e.g. FMI 2 rejects arrays) run in the export path.
pub fn ModelIr::check(self : ModelIr) -> Array[@schema.Diagnostic] {
  let diagnostics = []
  let fail = (code : String, message : String, hint : String?) => {
    diagnostics.push(
      @schema.Diagnostic::new(
        code~,
        severity=@schema.Severity::Error,
        message~,
        path="/export/ir/\{self.model_name}",
        hint?,
      ),
    )
  }
  if self.model_name.is_empty() {
    fail("EX-001", "model name must not be empty", None)
  }
  if self.interfaces.is_empty() {
    fail(
      "EX-002",
      "at least one interface (CoSimulation or ModelExchange) is required",
      Some("add ModelIr::add_interface(kind~, model_identifier~)"),
    )
  }
  let seen : Map[String, Bool] = Map([])
  for v in self.variables {
    if v.name.is_empty() {
      fail(
        "EX-003",
        "variable name must not be empty",
        Some("every exported variable needs a non-empty FMI name"),
      )
    }
    if seen.contains(v.name) {
      fail(
        "EX-004",
        "duplicate variable name '\{v.name}'",
        Some("FMI names must be unique within the model"),
      )
    }
    seen[v.name] = true
    if v.data_type is IrDataType::Str && v.unit is Some(_) {
      fail(
        "EX-005",
        "string variable '\{v.name}' must not declare a unit",
        None,
      )
    }
    match v.start {
      Some(IrValue::Real(_)) | Some(IrValue::RealArray(_)) =>
        if !(v.data_type is IrDataType::Float64 ||
          v.data_type is IrDataType::Float32) {
          fail(
            "EX-006",
            "variable '\{v.name}' is \{v.data_type.name()} but has a real start value",
            None,
          )
        }
      Some(IrValue::Int(_)) | Some(IrValue::IntArray(_)) =>
        if !(v.data_type is IrDataType::Int32 ||
          v.data_type is IrDataType::Int64 ||
          v.data_type is IrDataType::UInt64) {
          fail(
            "EX-006",
            "variable '\{v.name}' is \{v.data_type.name()} but has an integer start value",
            None,
          )
        }
      Some(IrValue::Bool(_)) =>
        if !(v.data_type is IrDataType::Boolean) {
          fail(
            "EX-006",
            "variable '\{v.name}' is \{v.data_type.name()} but has a boolean start value",
            None,
          )
        }
      Some(IrValue::Str(_)) =>
        if !(v.data_type is IrDataType::Str) {
          fail(
            "EX-006",
            "variable '\{v.name}' is \{v.data_type.name()} but has a string start value",
            None,
          )
        }
      None => ()
    }
    let allowed = @schema.allowed_variabilities(v.causality)
    if !allowed.contains(v.variability) {
      fail(
        "EX-007",
        "causality '\{v.causality.name()}' does not allow variability '\{v.variability.name()}' on '\{v.name}'",
        None,
      )
    }
    match v.unit {
      Some(unit) => {
        let known = self.units.iter().any(fn(u) { u.name == unit })
        if !known {
          fail(
            "EX-008",
            "variable '\{v.name}' references undefined unit '\{unit}'",
            Some("declare the unit in ModelIr::add_unit first"),
          )
        }
      }
      None => ()
    }
    if v.dimensions.length() > 0 {
      for d in v.dimensions {
        if d == 0U {
          fail(
            "EX-009",
            "variable '\{v.name}' has a zero dimension; the codegen only emits fixed sizes",
            None,
          )
        }
      }
    }
  }
  for eq in self.equations {
    let (target, expr) = match eq {
      IrEquation::Derivative(name, expr) => (name, expr)
      IrEquation::Output(name, expr) => (name, expr)
    }
    match self.index_of(target) {
      None =>
        fail("EX-010", "equation targets unknown variable '\{target}'", None)
      Some(index) => {
        let v = self.variables[index]
        if v.data_type is IrDataType::Str {
          fail(
            "EX-011",
            "equation target '\{target}' is a string; only numeric variables can be computed",
            None,
          )
        }
        if v.dimensions.length() > 0 {
          fail(
            "EX-012",
            "equation target '\{target}' is an array; the first codegen only computes scalar equations",
            None,
          )
        }
        match eq {
          IrEquation::Derivative(_, _) =>
            if !(v.variability is @schema.Variability::Continuous) {
              fail(
                "EX-013",
                "derivative target '\{target}' must be continuous",
                None,
              )
            }
          IrEquation::Output(_, _) =>
            if !(v.causality is @schema.Causality::Output) {
              fail(
                "EX-014",
                "output equation target '\{target}' must have causality output",
                None,
              )
            }
        }
      }
    }
    expr.walk(fn(name) {
      match self.index_of(name) {
        None =>
          fail("EX-010", "equation references unknown variable '\{name}'", None)
        Some(_) => ()
      }
    })
  }
  match self.expr_call_diagnostics() {
    Some(diagnostic) => diagnostics.push(diagnostic)
    None => ()
  }
  // Duplicate model identifiers / interface kinds.
  let kinds : Map[Int32, Bool] = Map([])
  for itf in self.interfaces {
    if itf.model_identifier.is_empty() {
      fail("EX-015", "interface model identifier must not be empty", None)
    }
    let key : Int32 = match itf.kind {
      @schema.InterfaceKind::CoSimulation => 1
      _ => 0
    }
    if kinds.contains(key) {
      fail("EX-016", "duplicate interface kind '\{itf.kind.name()}'", None)
    }
    kinds[key] = true
  }
  diagnostics
}

///|
fn ModelIr::expr_call_diagnostics(self : ModelIr) -> @schema.Diagnostic? {
  let allowed = IrExpr::allowed_calls()
  for eq in self.equations {
    let expr = match eq {
      IrEquation::Derivative(_, expr) => expr
      IrEquation::Output(_, expr) => expr
    }
    let bad : StringBuilder = StringBuilder()
    check_expr_calls(expr, allowed, bad)
    if !bad.to_string().is_empty() {
      return Some(
        @schema.Diagnostic::new(
          code="EX-017",
          severity=@schema.Severity::Error,
          message="unsupported call(s) \{bad.to_string()} in equation for '\{equation_target(eq)}'",
          path="/export/ir/\{self.model_name}",
          hint="allowed calls: \{allowed.join(", ")}",
        ),
      )
    }
  }
  None
}

///|
fn equation_target(eq : IrEquation) -> String {
  match eq {
    IrEquation::Derivative(name, _) => name
    IrEquation::Output(name, _) => name
  }
}

///|
fn check_expr_calls(
  expr : IrExpr,
  allowed : Array[String],
  bad : StringBuilder,
) -> Unit {
  match expr {
    IrExpr::Call(name, args) => {
      if !allowed.contains(name) {
        bad.write_string("\{name} ")
      } else if (name == "pow" || name == "min" || name == "max") &&
        args.length() != 2 {
        bad.write_string("\{name}/argc ")
      } else if !(name == "pow" || name == "min" || name == "max") &&
        args.length() != 1 {
        bad.write_string("\{name}/argc ")
      }
      for arg in args {
        check_expr_calls(arg, allowed, bad)
      }
    }
    IrExpr::Add(a, b)
    | IrExpr::Sub(a, b)
    | IrExpr::Mul(a, b)
    | IrExpr::Div(a, b) => {
      check_expr_calls(a, allowed, bad)
      check_expr_calls(b, allowed, bad)
    }
    IrExpr::Neg(a) => check_expr_calls(a, allowed, bad)
    _ => ()
  }
}

///|
/// Builder helpers -----------------------------------------------------------
/// The struct has mutable array fields, so builders just push.

///|
pub fn ModelIr::add_interface(
  self : ModelIr,
  kind~ : @schema.InterfaceKind,
  model_identifier~ : String,
) -> Unit {
  self.interfaces.push({ kind, model_identifier, })
}

///|
pub fn ModelIr::add_variable(self : ModelIr, variable : IrVariable) -> Unit {
  self.variables.push(variable)
}

///|
pub fn ModelIr::add_real_parameter(
  self : ModelIr,
  name~ : String,
  start~ : Double,
  unit? : String,
  description? : String,
) -> IrVariable {
  let v = IrVariable::new(
    name~,
    data_type=IrDataType::Float64,
    causality=@schema.Causality::Parameter,
  )
  v.variability = @schema.Variability::Fixed
  v.start = Some(IrValue::Real(start))
  v.unit = unit
  v.description = description
  self.add_variable(v)
  v
}

///|
pub fn ModelIr::add_real_input(
  self : ModelIr,
  name~ : String,
  start~ : Double,
  unit? : String,
  description? : String,
) -> IrVariable {
  let v = IrVariable::new(
    name~,
    data_type=IrDataType::Float64,
    causality=@schema.Causality::Input,
  )
  v.start = Some(IrValue::Real(start))
  v.unit = unit
  v.description = description
  self.add_variable(v)
  v
}

///|
pub fn ModelIr::add_real_output(
  self : ModelIr,
  name~ : String,
  unit? : String,
  description? : String,
) -> IrVariable {
  let v = IrVariable::new(
    name~,
    data_type=IrDataType::Float64,
    causality=@schema.Causality::Output,
  )
  v.unit = unit
  v.description = description
  self.add_variable(v)
  v
}

///|
pub fn ModelIr::add_real_state(
  self : ModelIr,
  name~ : String,
  start~ : Double,
  unit? : String,
  description? : String,
  nominal? : Double,
) -> IrVariable {
  let v = IrVariable::new(
    name~,
    data_type=IrDataType::Float64,
    causality=@schema.Causality::Output,
  )
  v.initial = Some(@schema.Initial::Exact)
  v.start = Some(IrValue::Real(start))
  v.unit = unit
  v.description = description
  v.nominal = nominal
  self.add_variable(v)
  v
}

///|
pub fn ModelIr::add_real_local(
  self : ModelIr,
  name~ : String,
  start~ : Double,
  description? : String,
) -> IrVariable {
  let v = IrVariable::new(
    name~,
    data_type=IrDataType::Float64,
    causality=@schema.Causality::Local,
  )
  v.start = Some(IrValue::Real(start))
  v.description = description
  self.add_variable(v)
  v
}

///|
pub fn ModelIr::add_int_parameter(
  self : ModelIr,
  name~ : String,
  start~ : Int64,
  description? : String,
) -> IrVariable {
  let v = IrVariable::new(
    name~,
    data_type=IrDataType::Int32,
    causality=@schema.Causality::Parameter,
  )
  v.variability = @schema.Variability::Fixed
  v.start = Some(IrValue::Int(start))
  v.description = description
  self.add_variable(v)
  v
}

///|
pub fn ModelIr::add_boolean_input(
  self : ModelIr,
  name~ : String,
  start~ : Bool,
  description? : String,
) -> IrVariable {
  let v = IrVariable::new(
    name~,
    data_type=IrDataType::Boolean,
    causality=@schema.Causality::Input,
  )
  v.variability = @schema.Variability::Discrete
  v.start = Some(IrValue::Bool(start))
  v.description = description
  self.add_variable(v)
  v
}

///|
pub fn ModelIr::add_string_output(
  self : ModelIr,
  name~ : String,
  start~ : String,
  description? : String,
) -> IrVariable {
  let v = IrVariable::new(
    name~,
    data_type=IrDataType::Str,
    causality=@schema.Causality::Output,
  )
  v.variability = @schema.Variability::Discrete
  v.start = Some(IrValue::Str(start))
  v.description = description
  self.add_variable(v)
  v
}

///|
pub fn ModelIr::add_int_input(
  self : ModelIr,
  name~ : String,
  start~ : Int64,
  description? : String,
) -> IrVariable {
  let v = IrVariable::new(
    name~,
    data_type=IrDataType::Int32,
    causality=@schema.Causality::Input,
  )
  v.start = Some(IrValue::Int(start))
  v.description = description
  self.add_variable(v)
  v
}

///|
pub fn ModelIr::add_real_input_array(
  self : ModelIr,
  name~ : String,
  size~ : UInt32,
  start~ : Array[Double],
  description? : String,
) -> IrVariable {
  let v = IrVariable::new(
    name~,
    data_type=IrDataType::Float64,
    causality=@schema.Causality::Input,
  )
  v.start = Some(IrValue::RealArray(start))
  v.description = description
  v.dimensions.push(size)
  self.add_variable(v)
  v
}

///|
pub fn ModelIr::add_real_output_array(
  self : ModelIr,
  name~ : String,
  size~ : UInt32,
  description? : String,
) -> IrVariable {
  let v = IrVariable::new(
    name~,
    data_type=IrDataType::Float64,
    causality=@schema.Causality::Output,
  )
  v.description = description
  v.dimensions.push(size)
  self.add_variable(v)
  v
}

///|
pub fn ModelIr::add_derivative(
  self : ModelIr,
  state~ : String,
  expr~ : IrExpr,
) -> Unit {
  self.equations.push(IrEquation::Derivative(state, expr))
}

///|
pub fn ModelIr::add_output_equation(
  self : ModelIr,
  output~ : String,
  expr~ : IrExpr,
) -> Unit {
  self.equations.push(IrEquation::Output(output, expr))
}

///|
pub fn ModelIr::add_unit(self : ModelIr, unit : @schema.UnitDef) -> Unit {
  self.units.push(unit)
}

///|
pub fn ModelIr::add_log_category(
  self : ModelIr,
  name~ : String,
  description~ : String,
) -> Unit {
  self.log_categories.push({ name, description: Some(description), })
}

///|
/// Literal expression constructors, for readable model definitions.
pub fn IrExpr::c(value : Double) -> IrExpr {
  IrExpr::Const(value)
}

///|
pub fn IrExpr::v(name : String) -> IrExpr {
  IrExpr::Var(name)
}

///|
pub fn IrExpr::add(a : IrExpr, b : IrExpr) -> IrExpr {
  IrExpr::Add(a, b)
}

///|
pub fn IrExpr::sub(a : IrExpr, b : IrExpr) -> IrExpr {
  IrExpr::Sub(a, b)
}

///|
pub fn IrExpr::mul(a : IrExpr, b : IrExpr) -> IrExpr {
  IrExpr::Mul(a, b)
}

///|
pub fn IrExpr::div(a : IrExpr, b : IrExpr) -> IrExpr {
  IrExpr::Div(a, b)
}

///|
pub fn IrExpr::neg(a : IrExpr) -> IrExpr {
  IrExpr::Neg(a)
}

///|
pub fn IrExpr::call(name : String, args : Array[IrExpr]) -> IrExpr {
  IrExpr::Call(name, args)
}

///|
/// Example model: `x' = -k*x, y = x` (Dahlquist). Used by the exporter tests
/// and the docs; one parameter, one continuous state, one output. Value
/// references follow declaration order: k = 0, x = 1, y = 2.
pub fn dahlquist_example_ir() -> ModelIr {
  let ir = ModelIr::new(
    model_name="MoonfmiDahlquist",
    generation_tool="MoonFMI source exporter",
    description="x' = -k*x with one continuous state",
  )
  ir.add_interface(
    kind=@schema.InterfaceKind::CoSimulation,
    model_identifier="MoonfmiDahlquist",
  )
  ir.add_interface(
    kind=@schema.InterfaceKind::ModelExchange,
    model_identifier="MoonfmiDahlquist",
  )
  ignore(
    ir.add_real_parameter(name="k", start=1.0, description="decay constant"),
  )
  ignore(ir.add_real_state(name="x", start=1.0, description="state"))
  ignore(ir.add_real_output(name="y", description="output"))
  ir.add_derivative(
    state="x",
    expr=IrExpr::mul(IrExpr::neg(IrExpr::v("k")), IrExpr::v("x")),
  )
  ir.add_output_equation(output="y", expr=IrExpr::v("x"))
  ir
}

///|
/// Example model: FMI 3 array passthrough. `u[3]` input with start
/// `[1, 2, 3]` and a `y[3]` output the host reads back; there are no state
/// equations, so the model exercises array value-reference handling (sizes,
/// offsets, Dimension elements) without integration. FMI 3 only — FMI 2 has
/// no dimension support.
pub fn array_passthrough_example_ir() -> ModelIr {
  let ir = ModelIr::new(
    model_name="MoonfmiArrayPassthrough",
    generation_tool="MoonFMI source exporter",
    description="u[3] -> y[3] array passthrough",
  )
  ir.add_interface(
    kind=@schema.InterfaceKind::CoSimulation,
    model_identifier="MoonfmiArrayPassthrough",
  )
  ignore(
    ir.add_real_input_array(
      name="u",
      size=3U,
      start=[1.0, 2.0, 3.0],
      description="input vector",
    ),
  )
  ignore(
    ir.add_real_output_array(name="y", size=3U, description="output vector"),
  )
  ir
}
