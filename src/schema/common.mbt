///|
/// Variable causality, shared by FMI 2 and FMI 3. `StructuralParameter`
/// only exists in FMI 3.
#derive(Eq, Debug)
pub(all) enum Causality {
  Parameter
  CalculatedParameter
  Input
  Output
  Local
  Independent
  StructuralParameter
}

///|
pub fn Causality::parse(text : String) -> Causality? {
  match text {
    "parameter" => Some(Parameter)
    "calculatedParameter" => Some(CalculatedParameter)
    "input" => Some(Input)
    "output" => Some(Output)
    "local" => Some(Local)
    "independent" => Some(Independent)
    "structuralParameter" => Some(StructuralParameter)
    _ => None
  }
}

///|
pub fn Causality::name(self : Causality) -> String {
  match self {
    Parameter => "parameter"
    CalculatedParameter => "calculatedParameter"
    Input => "input"
    Output => "output"
    Local => "local"
    Independent => "independent"
    StructuralParameter => "structuralParameter"
  }
}

///|
/// Variable variability, shared by FMI 2 and FMI 3. FMI 2 defaults to
/// `Continuous`, FMI 3 has no default.
#derive(Eq, Debug)
pub(all) enum Variability {
  Constant
  Fixed
  Tunable
  Discrete
  Continuous
}

///|
pub fn Variability::parse(text : String) -> Variability? {
  match text {
    "constant" => Some(Constant)
    "fixed" => Some(Fixed)
    "tunable" => Some(Tunable)
    "discrete" => Some(Discrete)
    "continuous" => Some(Continuous)
    _ => None
  }
}

///|
pub fn Variability::name(self : Variability) -> String {
  match self {
    Constant => "constant"
    Fixed => "fixed"
    Tunable => "tunable"
    Discrete => "discrete"
    Continuous => "continuous"
  }
}

///|
/// Variable initial-declaration kind, shared by FMI 2 and FMI 3.
#derive(Eq, Debug)
pub(all) enum Initial {
  Exact
  Approx
  Calculated
}

///|
pub fn Initial::parse(text : String) -> Initial? {
  match text {
    "exact" => Some(Exact)
    "approx" => Some(Approx)
    "calculated" => Some(Calculated)
    _ => None
  }
}

///|
pub fn Initial::name(self : Initial) -> String {
  match self {
    Exact => "exact"
    Approx => "approx"
    Calculated => "calculated"
  }
}

///|
/// Variable naming convention on the root element. Absent means `Flat`.
#derive(Eq, Debug)
pub(all) enum NamingConvention {
  Flat
  Structured
}

///|
pub fn NamingConvention::parse(text : String) -> NamingConvention? {
  match text {
    "flat" => Some(Flat)
    "structured" => Some(Structured)
    _ => None
  }
}

///|
/// Dependency kind of a model-structure entry. Shared by FMI 2 and FMI 3.
#derive(Eq, Debug)
pub(all) enum DependencyKind {
  Dependent
  Constant
  Fixed
  Tunable
  Discrete
}

///|
pub fn DependencyKind::parse(text : String) -> DependencyKind? {
  match text {
    "dependent" => Some(Dependent)
    "constant" => Some(Constant)
    "fixed" => Some(Fixed)
    "tunable" => Some(Tunable)
    "discrete" => Some(Discrete)
    _ => None
  }
}

///|
/// Interface element kind. `ScheduledExecution` only exists in FMI 3.
#derive(Eq, Debug)
pub(all) enum InterfaceKind {
  ModelExchange
  CoSimulation
  ScheduledExecution
}

///|
pub fn InterfaceKind::name(self : InterfaceKind) -> String {
  match self {
    ModelExchange => "ModelExchange"
    CoSimulation => "CoSimulation"
    ScheduledExecution => "ScheduledExecution"
  }
}

///|
/// A `<Category>` inside `<LogCategories>`.
pub struct LogCategory {
  name : String
  description : String?
}

///|
/// `<DefaultExperiment>` attributes; every value is optional advice.
pub struct DefaultExperiment {
  start_time : Double?
  stop_time : Double?
  tolerance : Double?
  step_size : Double?
}

///|
/// `<BaseUnit>` of a unit definition. Exponents default to 0, `factor` to 1
/// and `offset` to 0.
pub struct BaseUnit {
  kg : Int32
  m : Int32
  s : Int32
  a : Int32
  kelvin : Int32
  mol : Int32
  cd : Int32
  rad : Int32
  factor : Double
  offset : Double
}

///|
pub fn BaseUnit::default() -> BaseUnit {
  {
    kg: 0,
    m: 0,
    s: 0,
    a: 0,
    kelvin: 0,
    mol: 0,
    cd: 0,
    rad: 0,
    factor: 1.0,
    offset: 0.0,
  }
}

///|
/// `<DisplayUnit>`; `inverse` only exists in FMI 3.
pub struct DisplayUnit {
  name : String
  factor : Double
  offset : Double
  inverse : Bool?
}

///|
/// One `<Unit>` entry of `<UnitDefinitions>`, shared by FMI 2 and FMI 3.
pub struct UnitDef {
  name : String
  base_unit : BaseUnit?
  display_units : Array[DisplayUnit]
}

///|
/// An `<Item>` of an enumeration type definition, shared by both versions.
pub struct EnumItem {
  name : String
  value : Int64
  description : String?
}

///|
pub extend Causality with Eq::{not_equal, equal}

///|
pub extend Causality with @debug.Debug::{to_repr}

///|
pub extend Variability with Eq::{not_equal, equal}

///|
pub extend Variability with @debug.Debug::{to_repr}

///|
pub extend Initial with Eq::{not_equal, equal}

///|
pub extend Initial with @debug.Debug::{to_repr}

///|
pub extend NamingConvention with Eq::{not_equal, equal}

///|
pub extend NamingConvention with @debug.Debug::{to_repr}

///|
pub extend DependencyKind with Eq::{not_equal, equal}

///|
pub extend DependencyKind with @debug.Debug::{to_repr}

///|
pub extend InterfaceKind with Eq::{not_equal, equal}

///|
pub extend InterfaceKind with @debug.Debug::{to_repr}
