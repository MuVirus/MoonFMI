///|
/// Payload attributes of an FMI 2 `Real` variable or type definition.
/// Fields mirror the XSD attribute group "fmi2RealAttributes"; `derivative`
/// is the 1-based `ScalarVariable` index of the state this variable is the
/// derivative of (FMI 2 uses indices, not value references).
pub struct Fmi2RealAttrs {
  declared_type : String?
  quantity : String?
  unit : String?
  display_unit : String?
  relative_quantity : Bool?
  min : Double?
  max : Double?
  nominal : Double?
  unbounded : Bool?
  start : Double?
  derivative : UInt32?
  reinit : Bool?
}

///|
/// Payload attributes of an FMI 2 `Integer` variable or type definition.
/// Fields mirror the XSD attribute group "fmi2IntegerAttributes".
pub struct Fmi2IntAttrs {
  declared_type : String?
  quantity : String?
  min : Int32?
  max : Int32?
  start : Int32?
  items : Array[EnumItem]
}

///|
/// Payload attributes of an FMI 2 `Boolean` variable or type definition.
pub struct Fmi2BoolAttrs {
  declared_type : String?
  start : Bool?
}

///|
/// Payload attributes of an FMI 2 `String` variable or type definition.
pub struct Fmi2StringAttrs {
  declared_type : String?
  start : String?
}

///|
/// Payload attributes of an FMI 2 `Enumeration` variable or type
/// definition. `declared_type` is required by the XSD; it is kept optional
/// so rule MD-015 can report its absence.
pub struct Fmi2EnumAttrs {
  declared_type : String?
  quantity : String?
  min : Int32?
  max : Int32?
  start : Int32?
  items : Array[EnumItem]
}

///|
/// The type-specific payload of an FMI 2 `ScalarVariable` or `SimpleType`.
/// Type definitions never carry `start`/`derivative`/`reinit`, so those
/// fields stay `None` there.
pub(all) enum Fmi2Payload {
  Real(Fmi2RealAttrs)
  Integer(Fmi2IntAttrs)
  Boolean(Fmi2BoolAttrs)
  Str(Fmi2StringAttrs)
  Enumeration(Fmi2EnumAttrs)
}

///|
/// One `<ScalarVariable>` of `<ModelVariables>`, in document order.
/// Causality/variability/initial stay as written; defaults are derived on
/// demand (see `defaults.mbt`).
pub struct Fmi2ScalarVariable {
  name : String
  value_reference : UInt32
  description : String?
  causality : Causality?
  variability : Variability?
  initial : Initial?
  can_handle_multiple_set_per_time_instant : Bool?
  payload : Fmi2Payload
  line : Int32
  column : Int32
}

///|
/// A `<SimpleType>` of `<TypeDefinitions>`.
pub struct Fmi2TypeDefinition {
  name : String
  payload : Fmi2Payload
  line : Int32
  column : Int32
}

///|
/// `ModelExchange` / `CoSimulation` capabilities. Only the ME-only and
/// CS-only attributes are set for the matching kind. Attribute values keep
/// their XSD defaults of `false` when absent; `None` means "not written".
pub struct Fmi2Interface {
  kind : InterfaceKind
  model_identifier : String
  needs_execution_tool : Bool?
  completed_integrator_step_not_needed : Bool?
  can_handle_variable_communication_step_size : Bool?
  can_interpolate_inputs : Bool?
  max_output_derivative_order : UInt32?
  can_run_asynchronuously : Bool?
  can_be_instantiated_only_once_per_process : Bool?
  can_not_use_memory_management_functions : Bool?
  can_get_and_set_fmustate : Bool?
  can_serialize_fmustate : Bool?
  provides_directional_derivative : Bool?
  source_files : Array[String]
  line : Int32
  column : Int32
}

///|
/// One `<Unknown>` of the FMI 2 `<ModelStructure>`. `index` is the 1-based
/// `ScalarVariable` index. Missing `dependencies` means "depends on all
/// known quantities"; an empty list means "depends on nothing".
pub struct Fmi2Unknown {
  index : UInt32
  dependencies : Array[UInt32]?
  dependencies_kind : Array[DependencyKind]?
  line : Int32
  column : Int32
}

///|
/// The FMI 2 `<ModelStructure>`.
pub struct Fmi2ModelStructure {
  outputs : Array[Fmi2Unknown]
  derivatives : Array[Fmi2Unknown]
  initial_unknowns : Array[Fmi2Unknown]
}

///|
/// The typed FMI 2.0 model description.
pub struct Fmi2ModelDescription {
  fmi_version : String
  model_name : String
  guid : String
  description : String?
  author : String?
  version : String?
  copyright : String?
  license : String?
  generation_tool : String?
  generation_date_and_time : String?
  variable_naming_convention : NamingConvention?
  number_of_event_indicators : UInt32?
  model_exchange : Fmi2Interface?
  co_simulation : Fmi2Interface?
  unit_definitions : Array[UnitDef]
  type_definitions : Array[Fmi2TypeDefinition]
  log_categories : Array[LogCategory]
  default_experiment : DefaultExperiment?
  variables : Array[Fmi2ScalarVariable]
  model_structure : Fmi2ModelStructure
  /// `<VendorAnnotations><Tool name="...">` entries, in document order.
  /// Only the required `name` is carried; the tool-specific payload is
  /// skipped (fmi2Annotation.xsd allows any lax content).
  tools : Array[Fmi2Tool]
}

///|
/// A vendor `<Tool>` element of the FMI 2 `VendorAnnotations` section.
pub struct Fmi2Tool {
  name : String
  line : Int32
  column : Int32
}

///|
pub fn Fmi2ModelDescription::interface_count(
  self : Fmi2ModelDescription,
) -> Int32 {
  let mut count = 0
  if self.model_exchange is Some(_) {
    count += 1
  }
  if self.co_simulation is Some(_) {
    count += 1
  }
  count
}

///|
/// All interfaces in document order.
pub fn Fmi2ModelDescription::interfaces(
  self : Fmi2ModelDescription,
) -> Array[Fmi2Interface] {
  let result : Array[Fmi2Interface] = []
  if self.model_exchange is Some(interface) {
    result.push(interface)
  }
  if self.co_simulation is Some(interface) {
    result.push(interface)
  }
  result
}
