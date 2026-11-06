///|
/// The 15 FMI 3 variable types, taken from the element name.
#derive(Eq, Debug)
pub(all) enum Fmi3TypeKind {
  Float32
  Float64
  Int8
  UInt8
  Int16
  UInt16
  Int32
  UInt32
  Int64
  UInt64
  Boolean
  Str
  Binary
  Enumeration
  Clock
}

///|
pub fn Fmi3TypeKind::parse(name : String) -> Fmi3TypeKind? {
  match name {
    "Float32" => Some(Float32)
    "Float64" => Some(Float64)
    "Int8" => Some(Int8)
    "UInt8" => Some(UInt8)
    "Int16" => Some(Int16)
    "UInt16" => Some(UInt16)
    "Int32" => Some(Int32)
    "UInt32" => Some(UInt32)
    "Int64" => Some(Int64)
    "UInt64" => Some(UInt64)
    "Boolean" => Some(Boolean)
    "String" => Some(Str)
    "Binary" => Some(Binary)
    "Enumeration" => Some(Enumeration)
    "Clock" => Some(Clock)
    _ => None
  }
}

///|
pub fn Fmi3TypeKind::name(self : Fmi3TypeKind) -> String {
  match self {
    Float32 => "Float32"
    Float64 => "Float64"
    Int8 => "Int8"
    UInt8 => "UInt8"
    Int16 => "Int16"
    UInt16 => "UInt16"
    Int32 => "Int32"
    UInt32 => "UInt32"
    Int64 => "Int64"
    UInt64 => "UInt64"
    Boolean => "Boolean"
    Str => "String"
    Binary => "Binary"
    Enumeration => "Enumeration"
    Clock => "Clock"
  }
}

///|
/// `true` for the floating point kinds (`Float32` / `Float64`).
pub fn Fmi3TypeKind::is_float(self : Fmi3TypeKind) -> Bool {
  self is (Float32 | Float64)
}

///|
/// `true` for the signed integer kinds (`Int8`..`Int64`).
pub fn Fmi3TypeKind::is_signed(self : Fmi3TypeKind) -> Bool {
  self is (Int8 | Int16 | Int32 | Int64)
}

///|
/// `true` for the unsigned integer kinds (`UInt8`..`UInt64`).
pub fn Fmi3TypeKind::is_unsigned(self : Fmi3TypeKind) -> Bool {
  self is (UInt8 | UInt16 | UInt32 | UInt64)
}

///|
/// `true` for the integer kinds including `Enumeration`.
pub fn Fmi3TypeKind::is_integer_like(self : Fmi3TypeKind) -> Bool {
  self.is_signed() || self.is_unsigned() || self is Enumeration
}

///|
/// Interval variability of a `Clock` variable (required attribute).
#derive(Eq, Debug)
pub(all) enum ClockIntervalVariability {
  Constant
  Calculated
  Triggered
}

///|
pub fn ClockIntervalVariability::parse(
  text : String,
) -> ClockIntervalVariability? {
  match text {
    "constant" => Some(Constant)
    "calculated" => Some(Calculated)
    "triggered" => Some(Triggered)
    _ => None
  }
}

///|
pub fn ClockIntervalVariability::name(
  self : ClockIntervalVariability,
) -> String {
  match self {
    Constant => "constant"
    Calculated => "calculated"
    Triggered => "triggered"
  }
}

///|
/// Attributes of a `Float32` / `Float64` variable. `derivative` is the
/// `valueReference` of the state this variable is the derivative of
/// (FMI 3 uses value references, unlike FMI 2 which uses indices).
pub struct Fmi3FloatAttrs {
  declared_type : String?
  quantity : String?
  unit : String?
  display_unit : String?
  relative_quantity : Bool?
  unbounded : Bool?
  min : Double?
  max : Double?
  nominal : Double?
  starts : Array[Double]
  derivative : UInt32?
  reinit : Bool?
}

///|
/// Attributes of a signed integer variable (`Int8`..`Int64`).
pub struct Fmi3IntAttrs {
  declared_type : String?
  quantity : String?
  min : Int64?
  max : Int64?
  starts : Array[Int64]
}

///|
/// Attributes of an unsigned integer variable (`UInt8`..`UInt64`).
pub struct Fmi3UIntAttrs {
  declared_type : String?
  quantity : String?
  min : UInt64?
  max : UInt64?
  starts : Array[UInt64]
}

///|
/// Attributes of a `Boolean` variable.
pub struct Fmi3BoolAttrs {
  declared_type : String?
  starts : Array[Bool]
}

///|
/// Attributes of a `String` variable; starts come from `<Start value>`.
pub struct Fmi3StringAttrs {
  declared_type : String?
  starts : Array[String]
}

///|
/// Attributes of a `Binary` variable.
pub struct Fmi3BinaryAttrs {
  declared_type : String?
  mime_type : String?
  max_size : UInt64?
  starts : Array[String]
}

///|
/// Attributes of an `Enumeration` variable.
pub struct Fmi3EnumAttrs {
  declared_type : String?
  quantity : String?
  min : Int64?
  max : Int64?
  starts : Array[Int64]
  items : Array[EnumItem]
}

///|
/// Attributes of a `Clock` variable. `interval_variability` is required by
/// the XSD; it is kept optional so rule MD-033 can report its absence.
pub struct Fmi3ClockAttrs {
  declared_type : String?
  can_be_deactivated : Bool?
  priority : UInt32?
  interval_variability : ClockIntervalVariability?
  interval_decimal : Double?
  shift_decimal : Double?
  supports_fraction : Bool?
  resolution : UInt64?
  interval_counter : UInt64?
  shift_counter : UInt64?
}

///|
/// The type-specific payload of an FMI 3 variable or type definition.
pub(all) enum Fmi3Payload {
  Float(Fmi3FloatAttrs)
  Int(Fmi3IntAttrs)
  UInt(Fmi3UIntAttrs)
  Bool(Fmi3BoolAttrs)
  Text(Fmi3StringAttrs)
  Bin(Fmi3BinaryAttrs)
  Enum(Fmi3EnumAttrs)
  Clock(Fmi3ClockAttrs)
}

///|
/// One `<Dimension>` of an FMI 3 array variable. Exactly one of `start`
/// (fixed dimension) or `value_reference` (structural parameter) is
/// normally present; both missing is rule MD-030.
pub struct Fmi3Dimension {
  start : UInt64?
  value_reference : UInt32?
  line : Int32
  column : Int32
}

///|
/// An `<Alias>` of an FMI 3 variable. Aliases share the owner's
/// `valueReference` but have their own `name`.
pub struct Fmi3Alias {
  name : String
  description : String?
  line : Int32
  column : Int32
}

///|
/// One FMI 3 variable of `<ModelVariables>`, in document order.
pub struct Fmi3Variable {
  type_kind : Fmi3TypeKind
  name : String
  value_reference : UInt32
  description : String?
  causality : Causality?
  variability : Variability?
  initial : Initial?
  can_handle_multiple_set_per_time_instant : Bool?
  clocks : String?
  intermediate_update : Bool?
  previous : UInt32?
  dimensions : Array[Fmi3Dimension]
  payload : Fmi3Payload
  aliases : Array[Fmi3Alias]
  line : Int32
  column : Int32
}

///|
/// An FMI 3 type definition (`Float64Type`, `EnumerationType`, ...). The
/// payload mirrors the variable payloads; starts stay empty.
pub struct Fmi3TypeDefinition {
  type_kind : Fmi3TypeKind
  name : String
  description : String?
  payload : Fmi3Payload
  line : Int32
  column : Int32
}

///|
/// One FMI 3 interface element (`ModelExchange`, `CoSimulation`, or
/// `ScheduledExecution`). ME-only and CS-only attributes stay `None` for
/// the other kinds.
pub struct Fmi3Interface {
  kind : InterfaceKind
  model_identifier : String
  needs_execution_tool : Bool?
  can_be_instantiated_only_once_per_process : Bool?
  can_get_and_set_fmustate : Bool?
  can_serialize_fmustate : Bool?
  provides_directional_derivatives : Bool?
  provides_adjoint_derivatives : Bool?
  provides_per_element_dependencies : Bool?
  needs_completed_integrator_step : Bool?
  provides_evaluate_discrete_states : Bool?
  can_handle_variable_communication_step_size : Bool?
  fixed_internal_step_size : Double?
  max_output_derivative_order : UInt32?
  recommended_intermediate_input_smoothness : Int32?
  provides_intermediate_update : Bool?
  might_return_early_from_do_step : Bool?
  can_return_early_after_intermediate_update : Bool?
  has_event_mode : Bool?
  line : Int32
  column : Int32
}

///|
/// One `fmi3Unknown` of the `<ModelStructure>`; references use
/// `valueReference` (unlike FMI 2 which uses indices).
pub struct Fmi3Unknown {
  value_reference : UInt32
  dependencies : Array[UInt32]?
  dependencies_kind : Array[DependencyKind]?
  line : Int32
  column : Int32
}

///|
/// The FMI 3 `<ModelStructure>`. Child order is fixed: outputs, continuous
/// state derivatives, clocked states, initial unknowns, event indicators.
pub struct Fmi3ModelStructure {
  outputs : Array[Fmi3Unknown]
  continuous_state_derivatives : Array[Fmi3Unknown]
  clocked_states : Array[Fmi3Unknown]
  initial_unknowns : Array[Fmi3Unknown]
  event_indicators : Array[Fmi3Unknown]
}

///|
/// The typed FMI 3.0 model description.
pub struct Fmi3ModelDescription {
  fmi_version : String
  model_name : String
  instantiation_token : String
  description : String?
  author : String?
  version : String?
  copyright : String?
  license : String?
  generation_tool : String?
  generation_date_and_time : String?
  variable_naming_convention : NamingConvention?
  interfaces : Array[Fmi3Interface]
  unit_definitions : Array[UnitDef]
  type_definitions : Array[Fmi3TypeDefinition]
  log_categories : Array[LogCategory]
  default_experiment : DefaultExperiment?
  variables : Array[Fmi3Variable]
  model_structure : Fmi3ModelStructure
}

///|
pub fn Fmi3ModelDescription::interface_of(
  self : Fmi3ModelDescription,
  kind : InterfaceKind,
) -> Fmi3Interface? {
  for interface in self.interfaces {
    if interface.kind == kind {
      return Some(interface)
    }
  }
  None
}

///|
pub extend Fmi3TypeKind with Eq::{not_equal, equal}

///|
pub extend Fmi3TypeKind with @debug.Debug::{to_repr}

///|
pub extend ClockIntervalVariability with Eq::{not_equal, equal}

///|
pub extend ClockIntervalVariability with @debug.Debug::{to_repr}
