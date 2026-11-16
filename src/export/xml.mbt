// modelDescription.xml generation (roadmap P6 / task E-02) and
// buildDescription.xml generation (task E-05).
//
// Rules follow docs/design/exporter.md §7:
// - element order matches the FMI 2.0.4 / FMI 3.0.2 XSD `xs:sequence`;
// - attribute values are escaped (`& < > " '`), booleans render `true`/`false`;
// - doubles use the round-trip `Double::to_string` form;
// - `guid` / `instantiationToken` derive from the IR content hash, never a
//   random source, so the same IR produces byte-identical output;
// - capabilities declare only what the generated code implements.

///|
/// Indentation-aware XML writer. Always `\n` line endings for reproducible
/// output on Windows and Linux.
pub struct XmlWriter {
  mut indent : Int32
  buf : StringBuilder
}

///|
pub fn XmlWriter::new() -> XmlWriter {
  { indent: 0, buf: StringBuilder(), }
}

///|
pub fn XmlWriter::escape(text : String) -> String {
  let buf = StringBuilder()
  for ch in text {
    match ch {
      '&' => buf.write_string("&amp;")
      '<' => buf.write_string("&lt;")
      '>' => buf.write_string("&gt;")
      '"' => buf.write_string("&quot;")
      '\'' => buf.write_string("&apos;")
      c => buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
pub fn XmlWriter::line(self : XmlWriter, text : String) -> Unit {
  for _ in 0..<self.indent {
    self.buf.write_string("  ")
  }
  self.buf.write_string(text)
  self.buf.write_char('\n')
}

///|
pub fn XmlWriter::open(self : XmlWriter, tag : String) -> Unit {
  self.line("<\{tag}>")
  self.indent += 1
}

///|
pub fn XmlWriter::close(self : XmlWriter, tag : String) -> Unit {
  self.indent -= 1
  self.line("</\{tag}>")
}

///|
pub fn XmlWriter::element(self : XmlWriter, tag : String) -> Unit {
  self.line("<\{tag}/>")
}

///|
pub fn XmlWriter::to_string(self : XmlWriter) -> String {
  self.buf.to_string()
}

///|
fn xml_attr(name : String, value : String) -> String {
  " \{name}=\"\{XmlWriter::escape(value)}\""
}

///|
fn xml_bool(value : Bool) -> String {
  if value {
    "true"
  } else {
    "false"
  }
}

///|
fn xml_bool_attr(name : String, value : Bool) -> String {
  xml_attr(name, xml_bool(value))
}

///|
fn xml_double(value : Double) -> String {
  value.to_string()
}

///|
fn xml_opt_double_attr(name : String, value : Double?) -> String {
  match value {
    Some(v) => xml_attr(name, xml_double(v))
    None => ""
  }
}

///|
fn xml_opt_string_attr(name : String, value : String?) -> String {
  match value {
    Some(v) => xml_attr(name, v)
    None => ""
  }
}

///|
/// Render a start value for the FMI 2 `start` attribute / FMI 3 `start`
/// attribute. Array values are space-separated in declaration order.
fn ir_start_text(value : IrValue) -> String {
  match value {
    IrValue::Real(v) => xml_double(v)
    IrValue::Int(v) => v.to_string()
    IrValue::Bool(v) => xml_bool(v)
    IrValue::Str(v) => v
    IrValue::RealArray(values) => {
      let parts = []
      for v in values {
        parts.push(xml_double(v))
      }
      parts.join(" ")
    }
    IrValue::IntArray(values) => {
      let parts = []
      for v in values {
        parts.push(v.to_string())
      }
      parts.join(" ")
    }
  }
}

///|
/// Canonical IR signature: a deterministic textual projection of everything
/// that ends up in the FMU. Hashed for guid / instantiationToken (E-08).
pub fn ModelIr::signature(self : ModelIr) -> String {
  let buf = StringBuilder()
  buf.write_string("name=\{self.model_name};")
  let description_text : String = self.description.unwrap_or("")
  buf.write_string("desc=\{description_text};")
  let version_text : String = self.model_version.unwrap_or("")
  buf.write_string("version=\{version_text};")
  for itf in self.interfaces {
    buf.write_string("itf=\{itf.kind.name()}:\{itf.model_identifier};")
  }
  let mut index = 0
  for v in self.variables {
    buf.write_string(
      "v[\{index}]=\{v.name},\{v.data_type.name()},\{v.causality.name()},\{v.variability.name()};",
    )
    match v.start {
      Some(start) => buf.write_string("s[\{index}]=\{ir_start_text(start)};")
      None => ()
    }
    match v.unit {
      Some(unit) => buf.write_string("u[\{index}]=\{unit};")
      None => ()
    }
    index += 1
  }
  for eq in self.equations {
    match eq {
      IrEquation::Derivative(name, expr) =>
        buf.write_string("d[\{name}]=\{expr.render_ir()};")
      IrEquation::Output(name, expr) =>
        buf.write_string("o[\{name}]=\{expr.render_ir()};")
    }
  }
  for unit in self.units {
    buf.write_string("unit=\{unit.name};")
  }
  match self.default_experiment {
    Some(de) =>
      buf.write_string(
        "de=\{xml_double(de.start_time)},\{xml_double(de.stop_time)};",
      )
    None => ()
  }
  buf.to_string()
}

///|
/// IR-side expression rendering (variable names, not C members) so the
/// signature stays independent of codegen naming.
fn IrExpr::render_ir(self : IrExpr) -> String {
  match self {
    IrExpr::Const(value) => xml_double(value)
    IrExpr::Time => "time"
    IrExpr::Var(name) => name
    IrExpr::Add(a, b) => "(\{a.render_ir()}+\{b.render_ir()})"
    IrExpr::Sub(a, b) => "(\{a.render_ir()}-\{b.render_ir()})"
    IrExpr::Mul(a, b) => "(\{a.render_ir()}*\{b.render_ir()})"
    IrExpr::Div(a, b) => "(\{a.render_ir()}/\{b.render_ir()})"
    IrExpr::Neg(a) => "(-\{a.render_ir()})"
    IrExpr::Call(name, args) => {
      let rendered = []
      for arg in args {
        rendered.push(arg.render_ir())
      }
      "\{name}(\{rendered.join(",")})"
    }
  }
}

///|
/// Stable GUID derived from the IR content hash, formatted like the FMI
/// convention `{8-4-4-4-12}`.
pub fn ModelIr::derived_guid(self : ModelIr) -> String {
  let hex = ir_sha256_hex(self.signature())
  guid_from_hex(hex)
}

///|
pub fn ModelIr::guid_value(self : ModelIr) -> String {
  match self.guid {
    Some(guid) => guid
    None => self.derived_guid()
  }
}

///|
fn guid_from_hex(hex : String) -> String {
  let take = (offset : Int32, length : Int32) => {
    let slice = StringBuilder()
    for i in offset..<(offset + length) {
      slice.write_char(UInt16::unsafe_to_char(hex[i]))
    }
    slice.to_string()
  }
  "\{take(0, 8)}-\{take(8, 4)}-\{take(12, 4)}-\{take(16, 4)}-\{take(20, 12)}"
}

///|
pub fn ir_sha256_hex(data : String) -> String {
  @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(data)))
}

///|
fn ir_vr(index : Int32) -> UInt32 {
  index.reinterpret_as_uint()
}

///|
/// Interface lookup: exactly one CS / one ME in the IR (validated).
fn ir_find_interface(
  ir : ModelIr,
  kind : @schema.InterfaceKind,
) -> IrInterface? {
  for itf in ir.interfaces {
    if itf.kind == kind {
      return Some(itf)
    }
  }
  None
}

///|
/// Generate `modelDescription.xml` for the requested FMI version.
/// Raises when the IR violates version-specific rules (e.g. arrays in FMI 2).
pub fn model_description_xml(
  ir : ModelIr,
  version : @schema.FmiVersion,
) -> String raise ExportError {
  match version {
    @schema.FmiVersion::V2 => fmi2_model_description_xml(ir)
    @schema.FmiVersion::V3 => fmi3_model_description_xml(ir)
  }
}

///|
fn export_error(message~ : String, hint? : String) -> ExportError {
  ExportError::Failed(
    @schema.Diagnostic::new(
      code="EX-020",
      severity=@schema.Severity::Error,
      message~,
      path="/export/xml",
      hint?,
    ),
  )
}

///|
/// FMI 2 source export: no arrays, no Float32/Int64/UInt64.
fn fmi2_check_type(v : IrVariable) -> Unit raise ExportError {
  match v.data_type {
    IrDataType::Float64
    | IrDataType::Int32
    | IrDataType::Boolean
    | IrDataType::Str => ()
    other =>
      raise export_error(
        message="FMI 2 cannot represent variable '\{v.name}' with type \{other.name()}",
        hint="FMI 2 supports Float64/Int32/Boolean/String; use FMI 3 for the rest",
      )
  }
  if v.dimensions.length() > 0 {
    raise export_error(
      message="FMI 2 has no dimension support; variable '\{v.name}' is an array",
      hint="use FMI 3 export for array variables",
    )
  }
}

///|
fn fmi2_model_description_xml(ir : ModelIr) -> String raise ExportError {
  for v in ir.variables {
    fmi2_check_type(v)
  }
  let writer = XmlWriter::new()
  let cs = ir_find_interface(ir, @schema.InterfaceKind::CoSimulation)
  let me = ir_find_interface(ir, @schema.InterfaceKind::ModelExchange)
  writer.line("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
  let root = StringBuilder()
  root.write_string("<fmiModelDescription")
  root.write_string(xml_attr("fmiVersion", "2.0"))
  root.write_string(xml_attr("modelName", ir.model_name))
  root.write_string(xml_attr("guid", "{\{ir.guid_value()}}"))
  root.write_string(xml_opt_string_attr("description", ir.description))
  root.write_string(xml_opt_string_attr("version", ir.model_version))
  root.write_string(xml_attr("generationTool", ir.generation_tool))
  if me is Some(_) {
    // Generated models expose no event indicators.
    root.write_string(xml_attr("numberOfEventIndicators", "0"))
  }
  writer.line(root.to_string() + ">")
  writer.indent += 1
  match me {
    Some(itf) => {
      let attrs = StringBuilder()
      attrs.write_string("<ModelExchange")
      attrs.write_string(xml_attr("modelIdentifier", itf.model_identifier))
      attrs.write_string(xml_bool_attr("needsExecutionTool", false))
      attrs.write_string(
        xml_bool_attr("completedIntegratorStepNotNeeded", false),
      )
      attrs.write_string(
        xml_bool_attr("canHandleVariableCommunicationStepSize", true),
      )
      attrs.write_string(xml_bool_attr("canInterpolateInputs", false))
      attrs.write_string(xml_bool_attr("canGetAndSetFMUstate", false))
      attrs.write_string(xml_bool_attr("canSerializeFMUstate", false))
      attrs.write_string(xml_bool_attr("providesDirectionalDerivative", false))
      writer.line(attrs.to_string() + "/>")
    }
    None => ()
  }
  match cs {
    Some(itf) => {
      let attrs = StringBuilder()
      attrs.write_string("<CoSimulation")
      attrs.write_string(xml_attr("modelIdentifier", itf.model_identifier))
      attrs.write_string(xml_bool_attr("needsExecutionTool", false))
      attrs.write_string(
        xml_bool_attr("canHandleVariableCommunicationStepSize", true),
      )
      attrs.write_string(xml_bool_attr("canInterpolateInputs", false))
      attrs.write_string(xml_bool_attr("canGetAndSetFMUstate", false))
      attrs.write_string(xml_bool_attr("canSerializeFMUstate", false))
      attrs.write_string(xml_bool_attr("providesDirectionalDerivative", false))
      writer.line(attrs.to_string() + "/>")
    }
    None => ()
  }
  if ir.units.length() > 0 {
    writer.open("UnitDefinitions")
    for unit in ir.units {
      write_unit(writer, unit)
    }
    writer.close("UnitDefinitions")
  }
  if ir.log_categories.length() > 0 {
    writer.open("LogCategories")
    for category in ir.log_categories {
      let attrs = StringBuilder()
      attrs.write_string("<Category")
      attrs.write_string(xml_attr("name", category.name))
      attrs.write_string(
        xml_opt_string_attr("description", category.description),
      )
      writer.line(attrs.to_string() + "/>")
    }
    writer.close("LogCategories")
  }
  match ir.default_experiment {
    Some(de) => {
      let attrs = StringBuilder()
      attrs.write_string("<DefaultExperiment")
      attrs.write_string(xml_attr("startTime", xml_double(de.start_time)))
      attrs.write_string(xml_attr("stopTime", xml_double(de.stop_time)))
      match de.step_size {
        Some(step) => attrs.write_string(xml_attr("stepSize", xml_double(step)))
        None => ()
      }
      match de.tolerance {
        Some(tol) => attrs.write_string(xml_attr("tolerance", xml_double(tol)))
        None => ()
      }
      writer.line(attrs.to_string() + "/>")
    }
    None => ()
  }
  writer.open("ModelVariables")
  let mut index = 0
  for v in ir.variables {
    fmi2_write_variable(writer, ir, v, ir_vr(index))
    index += 1
  }
  // FMI 2 exposes derivatives as dedicated local variables `der(x)` with a
  // `derivative` attribute pointing at the state (the convention used by
  // Reference-FMUs and required by MD-041). They are appended after the
  // declared variables and get the next value references.
  let declared_count = ir.variables.length()
  let states = ir.state_names()
  let derivative_indexes : Array[Int32] = []
  let mut synthetic_index = declared_count + 1
  for name in states {
    match ir.value_reference(name) {
      Some(state_vr) => {
        writer.line(
          "<ScalarVariable name=\"der(\{XmlWriter::escape(name)})\" valueReference=\"\{ir_vr(synthetic_index - 1).to_string()}\" causality=\"local\" variability=\"continuous\" initial=\"calculated\">",
        )
        writer.indent += 1
        writer.line("<Real derivative=\"\{state_vr.to_string()}\"/>")
        writer.indent -= 1
        writer.line("</ScalarVariable>")
        derivative_indexes.push(synthetic_index)
        synthetic_index += 1
      }
      None => ()
    }
  }
  writer.close("ModelVariables")
  writer.open("ModelStructure")
  // Outputs: exactly the causality=output variables (MD-040). Derivatives:
  // the synthetic der(x) variables (MD-041). InitialUnknowns: outputs and
  // derivatives, ascending (MD-042). Dependencies are omitted, which per the
  // standard means "depends on all inputs/states" — conservative and valid.
  let output_indexes : Array[Int32] = []
  let mut index = 1
  for v in ir.variables {
    if v.causality is @schema.Causality::Output {
      output_indexes.push(index)
    }
    index += 1
  }
  if !output_indexes.is_empty() {
    writer.line("<Outputs>")
    writer.indent += 1
    for entry in output_indexes {
      writer.line("<Unknown index=\"\{entry.to_string()}\"/>")
    }
    writer.indent -= 1
    writer.line("</Outputs>")
  }
  if !derivative_indexes.is_empty() {
    writer.line("<Derivatives>")
    writer.indent += 1
    for entry in derivative_indexes {
      writer.line("<Unknown index=\"\{entry.to_string()}\"/>")
    }
    writer.indent -= 1
    writer.line("</Derivatives>")
  }
  // InitialUnknowns: outputs + derivative variables, merged ascending.
  let initial_indexes : Array[Int32] = []
  for entry in output_indexes {
    initial_indexes.push(entry)
  }
  for entry in derivative_indexes {
    initial_indexes.push(entry)
  }
  initial_indexes.sort()
  if !initial_indexes.is_empty() {
    writer.line("<InitialUnknowns>")
    writer.indent += 1
    for entry in initial_indexes {
      writer.line("<Unknown index=\"\{entry.to_string()}\"/>")
    }
    writer.indent -= 1
    writer.line("</InitialUnknowns>")
  }
  writer.close("ModelStructure")
  writer.indent -= 1
  writer.line("</fmiModelDescription>")
  writer.to_string()
}

///|
fn write_unit(writer : XmlWriter, unit : @schema.UnitDef) -> Unit {
  match unit.base_unit {
    Some(base) => {
      writer.line("<Unit name=\"\{XmlWriter::escape(unit.name)}\">")
      writer.indent += 1
      let attrs = StringBuilder()
      attrs.write_string("<BaseUnit")
      if base.kg != 0 {
        attrs.write_string(xml_attr("kg", base.kg.to_string()))
      }
      if base.m != 0 {
        attrs.write_string(xml_attr("m", base.m.to_string()))
      }
      if base.s != 0 {
        attrs.write_string(xml_attr("s", base.s.to_string()))
      }
      if base.a != 0 {
        attrs.write_string(xml_attr("A", base.a.to_string()))
      }
      if base.kelvin != 0 {
        attrs.write_string(xml_attr("K", base.kelvin.to_string()))
      }
      if base.mol != 0 {
        attrs.write_string(xml_attr("mol", base.mol.to_string()))
      }
      if base.cd != 0 {
        attrs.write_string(xml_attr("cd", base.cd.to_string()))
      }
      if base.rad != 0 {
        attrs.write_string(xml_attr("rad", base.rad.to_string()))
      }
      if base.factor != 1.0 {
        attrs.write_string(xml_attr("factor", xml_double(base.factor)))
      }
      if base.offset != 0.0 {
        attrs.write_string(xml_attr("offset", xml_double(base.offset)))
      }
      writer.line(attrs.to_string() + "/>")
      for display in unit.display_units {
        let dattrs = StringBuilder()
        dattrs.write_string("<DisplayUnit")
        dattrs.write_string(xml_attr("name", display.name))
        dattrs.write_string(xml_attr("factor", xml_double(display.factor)))
        dattrs.write_string(xml_attr("offset", xml_double(display.offset)))
        writer.line(dattrs.to_string() + "/>")
      }
      writer.indent -= 1
      writer.line("</Unit>")
    }
    None => writer.line("<Unit name=\"\{XmlWriter::escape(unit.name)}\"/>")
  }
}

///|
/// True when the variable is the target of a derivative equation.
pub fn ModelIr::has_derivative_equation(self : ModelIr, name : String) -> Bool {
  for eq in self.equations {
    match eq {
      IrEquation::Derivative(target, _) => if target == name { return true }
      _ => ()
    }
  }
  false
}

///|
/// True when the variable is the target of an output equation.
pub fn ModelIr::has_output_equation(self : ModelIr, name : String) -> Bool {
  for eq in self.equations {
    match eq {
      IrEquation::Output(target, _) => if target == name { return true }
      _ => ()
    }
  }
  false
}

///|
fn fmi2_write_variable(
  writer : XmlWriter,
  ir : ModelIr,
  v : IrVariable,
  vr : UInt32,
) -> Unit raise ExportError {
  let attrs = StringBuilder()
  attrs.write_string("<ScalarVariable")
  attrs.write_string(xml_attr("name", v.name))
  attrs.write_string(xml_attr("valueReference", vr.to_string()))
  attrs.write_string(xml_opt_string_attr("description", v.description))
  attrs.write_string(xml_attr("causality", v.causality.name()))
  attrs.write_string(xml_attr("variability", v.variability.name()))
  // Emit the effective initial so validators see the exact value the
  // generated code implements (matches schema::derive_initial defaults).
  let initial : @schema.Initial? = match v.initial {
    Some(value) => Some(value)
    None => @schema.derive_initial(v.causality, v.variability)
  }
  match initial {
    Some(value) => attrs.write_string(xml_attr("initial", value.name()))
    None => ()
  }
  let payload = match v.data_type {
    IrDataType::Float64 => {
      let a = StringBuilder()
      a.write_string("<Real")
      a.write_string(xml_opt_string_attr("quantity", v.quantity))
      a.write_string(xml_opt_string_attr("unit", v.unit))
      a.write_string(xml_opt_string_attr("displayUnit", v.display_unit))
      a.write_string(xml_opt_double_attr("min", v.min))
      a.write_string(xml_opt_double_attr("max", v.max))
      a.write_string(xml_opt_double_attr("nominal", v.nominal))
      match v.start {
        Some(start) => {
          let text = ir_start_text(start)
          a.write_string(xml_attr("start", text))
        }
        None => ()
      }
      a.write_string("/>")
      a.to_string()
    }
    IrDataType::Int32 => {
      let a = StringBuilder()
      a.write_string("<Integer")
      a.write_string(xml_opt_string_attr("quantity", v.quantity))
      a.write_string(xml_opt_double_attr("min", v.min))
      a.write_string(xml_opt_double_attr("max", v.max))
      match v.start {
        Some(start) => a.write_string(xml_attr("start", ir_start_text(start)))
        None => ()
      }
      a.write_string("/>")
      a.to_string()
    }
    IrDataType::Boolean => {
      let a = StringBuilder()
      a.write_string("<Boolean")
      match v.start {
        Some(start) => a.write_string(xml_attr("start", ir_start_text(start)))
        None => ()
      }
      a.write_string("/>")
      a.to_string()
    }
    IrDataType::Str => {
      let a = StringBuilder()
      a.write_string("<String")
      match v.start {
        Some(start) => a.write_string(xml_attr("start", ir_start_text(start)))
        None => ()
      }
      a.write_string("/>")
      a.to_string()
    }
    other =>
      // FMI 2 type filter already rejected this in fmi2_check_type.
      raise export_error(
        message="variable '\{v.name}' has unsupported FMI 2 type \{other.name()}",
      )
  }
  writer.line(attrs.to_string() + ">")
  writer.indent += 1
  writer.line(payload)
  writer.indent -= 1
  writer.line("</ScalarVariable>")
  let _ = ir
}

///|
fn fmi3_model_description_xml(ir : ModelIr) -> String {
  let writer = XmlWriter::new()
  let cs = ir_find_interface(ir, @schema.InterfaceKind::CoSimulation)
  let me = ir_find_interface(ir, @schema.InterfaceKind::ModelExchange)
  writer.line("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
  let root = StringBuilder()
  root.write_string("<fmiModelDescription")
  root.write_string(xml_attr("fmiVersion", "3.0"))
  root.write_string(xml_attr("modelName", ir.model_name))
  root.write_string(xml_attr("instantiationToken", "{\{ir.guid_value()}}"))
  root.write_string(xml_opt_string_attr("description", ir.description))
  root.write_string(xml_opt_string_attr("version", ir.model_version))
  root.write_string(xml_attr("generationTool", ir.generation_tool))
  writer.line(root.to_string() + ">")
  writer.indent += 1
  match me {
    Some(itf) => {
      let attrs = StringBuilder()
      attrs.write_string("<ModelExchange")
      attrs.write_string(xml_attr("modelIdentifier", itf.model_identifier))
      attrs.write_string(xml_bool_attr("needsExecutionTool", false))
      attrs.write_string(
        xml_bool_attr("completedIntegratorStepNotNeeded", false),
      )
      attrs.write_string(xml_bool_attr("canGetAndSetFMUstate", false))
      attrs.write_string(xml_bool_attr("canSerializeFMUstate", false))
      attrs.write_string(xml_bool_attr("providesDirectionalDerivative", false))
      writer.line(attrs.to_string() + "/>")
    }
    None => ()
  }
  match cs {
    Some(itf) => {
      let attrs = StringBuilder()
      attrs.write_string("<CoSimulation")
      attrs.write_string(xml_attr("modelIdentifier", itf.model_identifier))
      attrs.write_string(xml_bool_attr("needsExecutionTool", false))
      attrs.write_string(
        xml_bool_attr("canHandleVariableCommunicationStepSize", true),
      )
      attrs.write_string(xml_bool_attr("canInterpolateInputs", false))
      attrs.write_string(xml_bool_attr("canGetAndSetFMUstate", false))
      attrs.write_string(xml_bool_attr("canSerializeFMUstate", false))
      attrs.write_string(xml_bool_attr("providesDirectionalDerivative", false))
      attrs.write_string(xml_bool_attr("providesIntermediateUpdate", false))
      attrs.write_string(xml_bool_attr("hasEventMode", false))
      writer.line(attrs.to_string() + "/>")
    }
    None => ()
  }
  if ir.units.length() > 0 {
    writer.open("UnitDefinitions")
    for unit in ir.units {
      write_unit(writer, unit)
    }
    writer.close("UnitDefinitions")
  }
  if ir.log_categories.length() > 0 {
    writer.open("LogCategories")
    for category in ir.log_categories {
      let attrs = StringBuilder()
      attrs.write_string("<Category")
      attrs.write_string(xml_attr("name", category.name))
      attrs.write_string(
        xml_opt_string_attr("description", category.description),
      )
      writer.line(attrs.to_string() + "/>")
    }
    writer.close("LogCategories")
  }
  match ir.default_experiment {
    Some(de) => {
      let attrs = StringBuilder()
      attrs.write_string("<DefaultExperiment")
      attrs.write_string(xml_attr("startTime", xml_double(de.start_time)))
      attrs.write_string(xml_attr("stopTime", xml_double(de.stop_time)))
      match de.step_size {
        Some(step) => attrs.write_string(xml_attr("stepSize", xml_double(step)))
        None => ()
      }
      match de.tolerance {
        Some(tol) => attrs.write_string(xml_attr("tolerance", xml_double(tol)))
        None => ()
      }
      writer.line(attrs.to_string() + "/>")
    }
    None => ()
  }
  writer.open("ModelVariables")
  let mut index = 0
  for v in ir.variables {
    fmi3_write_variable(writer, ir, v, ir_vr(index))
    index += 1
  }
  // FMI 3 uses the same `der(x)` convention as FMI 2: a local continuous
  // variable with derivative=<state vr>; ContinuousStateDerivative points at
  // the der(x) value reference (MD-046).
  let declared_count = ir.variables.length()
  let states = ir.state_names()
  let derivative_vrs : Array[UInt32] = []
  let mut synthetic = declared_count
  for name in states {
    match ir.value_reference(name) {
      Some(state_vr) => {
        let der_vr = ir_vr(synthetic)
        writer.line(
          "<Float64 name=\"der(\{XmlWriter::escape(name)})\" valueReference=\"\{der_vr.to_string()}\" causality=\"local\" variability=\"continuous\" initial=\"calculated\" derivative=\"\{state_vr.to_string()}\"/>",
        )
        derivative_vrs.push(der_vr)
        synthetic += 1
      }
      None => ()
    }
  }
  writer.close("ModelVariables")
  writer.open("ModelStructure")
  for v in ir.variables {
    if v.causality is @schema.Causality::Output {
      let vr = ir.value_reference(v.name).unwrap_or(0U)
      writer.line("<Output valueReference=\"\{vr}\"/>")
    }
  }
  for vr in derivative_vrs {
    writer.line(
      "<ContinuousStateDerivative valueReference=\"\{vr.to_string()}\"/>",
    )
  }
  for v in ir.variables {
    if v.causality is @schema.Causality::Output {
      let vr = ir.value_reference(v.name).unwrap_or(0U)
      writer.line("<InitialUnknown valueReference=\"\{vr}\"/>")
    }
  }
  for vr in derivative_vrs {
    writer.line("<InitialUnknown valueReference=\"\{vr.to_string()}\"/>")
  }
  writer.close("ModelStructure")
  writer.indent -= 1
  writer.line("</fmiModelDescription>")
  writer.to_string()
}

///|
fn fmi3_write_variable(
  writer : XmlWriter,
  ir : ModelIr,
  v : IrVariable,
  vr : UInt32,
) -> Unit {
  let attrs = StringBuilder()
  attrs.write_string("<\{v.data_type.name()}")
  attrs.write_string(xml_attr("name", v.name))
  attrs.write_string(xml_attr("valueReference", vr.to_string()))
  attrs.write_string(xml_opt_string_attr("description", v.description))
  attrs.write_string(xml_attr("causality", v.causality.name()))
  attrs.write_string(xml_attr("variability", v.variability.name()))
  let initial : @schema.Initial? = match v.initial {
    Some(value) => Some(value)
    None => @schema.derive_initial(v.causality, v.variability)
  }
  match initial {
    Some(value) => attrs.write_string(xml_attr("initial", value.name()))
    None => ()
  }
  match v.data_type {
    IrDataType::Float64 | IrDataType::Float32 => {
      attrs.write_string(xml_opt_string_attr("quantity", v.quantity))
      attrs.write_string(xml_opt_string_attr("unit", v.unit))
      attrs.write_string(xml_opt_string_attr("displayUnit", v.display_unit))
      attrs.write_string(xml_opt_double_attr("min", v.min))
      attrs.write_string(xml_opt_double_attr("max", v.max))
      attrs.write_string(xml_opt_double_attr("nominal", v.nominal))
      match v.start {
        Some(start) =>
          attrs.write_string(xml_attr("start", ir_start_text(start)))
        None => ()
      }
    }
    IrDataType::Int32 | IrDataType::Int64 | IrDataType::UInt64 => {
      attrs.write_string(xml_opt_string_attr("quantity", v.quantity))
      attrs.write_string(xml_opt_double_attr("min", v.min))
      attrs.write_string(xml_opt_double_attr("max", v.max))
      match v.start {
        Some(start) =>
          attrs.write_string(xml_attr("start", ir_start_text(start)))
        None => ()
      }
    }
    IrDataType::Boolean =>
      match v.start {
        Some(start) =>
          attrs.write_string(xml_attr("start", ir_start_text(start)))
        None => ()
      }
    IrDataType::Str => {
      // String start values are child elements in FMI 3.
      attrs.write_string(">")
      writer.line(attrs.to_string())
      writer.indent += 1
      match v.start {
        Some(IrValue::Str(text)) =>
          writer.line("<Start value=\"\{XmlWriter::escape(text)}\"/>")
        _ => ()
      }
      writer.indent -= 1
      writer.line("</\{v.data_type.name()}>")
      return
    }
  }
  if v.dimensions.length() > 0 {
    attrs.write_string(">")
    writer.line(attrs.to_string())
    writer.indent += 1
    for dim in v.dimensions {
      writer.line("<Dimension start=\"\{dim.to_string()}\"/>")
    }
    writer.indent -= 1
    writer.line("</\{v.data_type.name()}>")
  } else {
    attrs.write_string("/>")
    writer.line(attrs.to_string())
  }
  let _ = ir
}

///|
/// buildDescription.xml for FMI 3 source FMUs (task E-05). The generated
/// FMU builds its single binary from `sources/` with CMake or any C99
/// compiler; we declare one SourceFileSet with the generated C files.
pub fn build_description_xml(ir : ModelIr) -> String {
  let writer = XmlWriter::new()
  writer.line("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
  writer.line("<fmiBuildDescription fmiVersion=\"3.0\">")
  writer.indent += 1
  let source_set = () => {
    writer.line("<SourceFileSet language=\"C99\">")
    writer.indent += 1
    for file in generated_c_source_names(ir) {
      writer.line("<SourceFile name=\"\{XmlWriter::escape(file)}\"/>")
    }
    writer.indent -= 1
    writer.line("</SourceFileSet>")
  }
  let cs = ir_find_interface(ir, @schema.InterfaceKind::CoSimulation)
  let me = ir_find_interface(ir, @schema.InterfaceKind::ModelExchange)
  match cs {
    Some(itf) => {
      writer.line(
        "<BuildConfiguration modelIdentifier=\"\{XmlWriter::escape(itf.model_identifier)}\">",
      )
      writer.indent += 1
      source_set()
      writer.indent -= 1
      writer.line("</BuildConfiguration>")
    }
    None => ()
  }
  match me {
    Some(itf) =>
      // Only emit a second configuration when the identifiers differ.
      if !(cs is Some(cs_itf) && cs_itf.model_identifier == itf.model_identifier) {
        writer.line(
          "<BuildConfiguration modelIdentifier=\"\{XmlWriter::escape(itf.model_identifier)}\">",
        )
        writer.indent += 1
        source_set()
        writer.indent -= 1
        writer.line("</BuildConfiguration>")
      }
    None => ()
  }
  writer.indent -= 1
  writer.line("</fmiBuildDescription>")
  writer.to_string()
}
