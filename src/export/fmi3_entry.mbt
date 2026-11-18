// FMI 3 entry-point code generation (roadmap P6 / task E-03).
//
// Signatures mirror the FMI 3.0.2 standard header exactly
// (docs/standards/headers/fmi3/fmi3FunctionTypes.h). Array variables use the
// offset/required-count two-pass pattern so multi-reference calls stay
// within the caller's buffer.

///|
fn fmi3_buffer_type(data_type : IrDataType) -> String {
  match data_type {
    IrDataType::Float64 => "fmi3Float64"
    IrDataType::Float32 => "fmi3Float32"
    IrDataType::Int32 => "fmi3Int32"
    IrDataType::Int64 => "fmi3Int64"
    IrDataType::UInt64 => "fmi3UInt64"
    IrDataType::Boolean => "fmi3Boolean"
    IrDataType::Str => "fmi3String"
  }
}

///|
fn fmi3_type_suffix(data_type : IrDataType) -> String {
  match data_type {
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
/// Element count of a variable (1 for scalars, product of dimensions).
fn ir_element_count(v : IrVariable) -> Int32 {
  let mut count = 1
  for d in v.dimensions {
    count = count * d.reinterpret_as_int()
  }
  count
}

///|
/// Size switch body: `total += <count>` per reference of this type.
/// Synthetic `der(x)` references (FMI 3 model description) are 1 element
/// each and come after the declared variables.
fn fmi3_size_cases(ir : ModelIr, data_type : IrDataType) -> Array[String] {
  let lines = []
  let mut index = 0
  for v in ir.variables {
    if v.data_type == data_type {
      lines.push(
        "        case \{index.to_string()}: total += \{ir_element_count(v).to_string()}; break; /* \{variable_role_of(ir, v)} */",
      )
    }
    index += 1
  }
  if data_type is IrDataType::Float64 {
    let declared_count = ir.variables.length()
    let mut i = 0
    for name in ir.state_names() {
      // One der(x) VR per state variable; an array state's der(x) carries
      // the same dimensions as the state, so the required count is its
      // scalar element count.
      let count = match ir.index_of(name) {
        Some(state_index) => ir_element_count(ir.variables[state_index])
        None => 1
      }
      lines.push(
        "        case \{(declared_count + i).to_string()}: total += \{count.to_string()}; break; /* der(\{name}) */",
      )
      i += 1
    }
  }
  lines
}

///|
/// Copy switch body for get or set with running `offset`.
fn fmi3_copy_cases(
  ir : ModelIr,
  data_type : IrDataType,
  mode : String,
) -> Array[String] {
  let lines = []
  let mut index = 0
  for v in ir.variables {
    if v.data_type == data_type {
      let cfield = c_member_of(v.name)
      let count = ir_element_count(v)
      if v.dimensions.is_empty() {
        if mode == "get" {
          match data_type {
            IrDataType::Boolean =>
              lines.push(
                "            case \{index.to_string()}: values[offset] = (fmi3Boolean) m->\{cfield}; offset += 1; break;",
              )
            IrDataType::Str =>
              lines.push(
                "            case \{index.to_string()}: values[offset] = m->\{cfield}; offset += 1; break;",
              )
            other =>
              lines.push(
                "            case \{index.to_string()}: values[offset] = (fmi3\{fmi3_type_suffix(other)}) m->\{cfield}; offset += 1; break;",
              )
          }
        } else {
          match data_type {
            IrDataType::Boolean =>
              lines.push(
                "            case \{index.to_string()}: m->\{cfield} = (values[offset] != fmi3False); offset += 1; break;",
              )
            IrDataType::Str =>
              lines.push(
                "            case \{index.to_string()}: moonfmi_set_string(&m->\{cfield}, values[offset]); offset += 1; break;",
              )
            _ =>
              lines.push(
                "            case \{index.to_string()}: m->\{cfield} = (\{data_type.c_type()}) values[offset]; offset += 1; break;",
              )
          }
        }
      } else {
        // Array: element-wise copy with the generated FMI 3 buffer type.
        let buffer = fmi3_buffer_type(data_type)
        if mode == "get" {
          lines.push(
            "            case \{index.to_string()}: /* \{variable_role_of(ir, v)} */",
          )
          lines.push(
            "                for (size_t i = 0; i < \{count.to_string()}; ++i) { values[offset + i] = (\{buffer}) m->\{cfield}[i]; }",
          )
          lines.push("                offset += \{count.to_string()};")
          lines.push("                break;")
        } else {
          let inner : String = match data_type {
            IrDataType::Boolean =>
              "m->\{cfield}[i] = (values[offset + i] != fmi3False);"
            IrDataType::Str =>
              "moonfmi_set_string(&m->\{cfield}[i], values[offset + i]);"
            _ => "m->\{cfield}[i] = (\{data_type.c_type()}) values[offset + i];"
          }
          lines.push(
            "            case \{index.to_string()}: /* \{variable_role_of(ir, v)} */",
          )
          lines.push(
            "                for (size_t i = 0; i < \{count.to_string()}; ++i) { \{inner} }",
          )
          lines.push("                offset += \{count.to_string()};")
          lines.push("                break;")
        }
      }
    }
    index += 1
  }
  // Synthetic der(x) reads (get only, Float64 only): recompute on demand.
  if data_type is IrDataType::Float64 && mode == "get" {
    let declared_count = ir.variables.length()
    let mut i = 0
    for name in ir.state_names() {
      // Flattened dx offset of this state among the derivative equations.
      let mut flat = 0
      for slot in ir.state_slots() {
        if slot.name == name {
          break
        }
        flat += 1
      }
      let count = match ir.index_of(name) {
        Some(state_index) => ir_element_count(ir.variables[state_index])
        None => 1
      }
      lines.push(
        "            case \{(declared_count + i).to_string()}: /* der(\{name}) */",
      )
      lines.push("            {")
      lines.push("                double dx[MOONFMI_STATE_COUNT];")
      lines.push(
        "                MoonfmiModel_compute_derivatives(m, inst->time, dx);",
      )
      if count == 1 {
        lines.push("                values[offset] = dx[\{flat.to_string()}];")
        lines.push("                offset += 1;")
      } else {
        lines.push(
          "                for (size_t k = 0; k < \{count.to_string()}; ++k) { values[offset + k] = dx[\{flat.to_string()} + k]; }",
        )
        lines.push("                offset += \{count.to_string()};")
      }
      lines.push("            }")
      lines.push("            break;")
      i += 1
    }
  }
  lines
}

///|
/// Get/Set pair for one FMI 3 value type, including the required-count
/// helper shared by both.
fn fmi3_get_set_pair(ir : ModelIr, data_type : IrDataType) -> Array[String] {
  // Emit every typed pair even when this model has no variable of that
  // type: FMPy resolves the whole fmi3Get*/fmi3Set* family when loading,
  // and unknown references are rejected by the switch default.
  let size_cases = fmi3_size_cases(ir, data_type)
  let get_cases = fmi3_copy_cases(ir, data_type, "get")
  let set_cases = fmi3_copy_cases(ir, data_type, "set")
  let suffix = fmi3_type_suffix(data_type)
  let buffer = fmi3_buffer_type(data_type)
  let writer = XmlWriter::new()
  writer.line(
    "static size_t Moonfmi_required_\{suffix}(const fmi3ValueReference vrs[], size_t nvr) {",
  )
  writer.line("    size_t total = 0;")
  writer.line("    for (size_t k = 0; k < nvr; ++k) {")
  writer.line("        switch (vrs[k]) {")
  for line in size_cases {
    writer.line(line)
  }
  writer.line("            default: break;")
  writer.line("        }")
  writer.line("    }")
  writer.line("    return total;")
  writer.line("}")
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3Get\{suffix}(fmi3Instance instance, const fmi3ValueReference valueReferences[], size_t nValueReferences, \{buffer} values[], size_t nValues) {",
  )
  writer.line("    MoonfmiInstance* inst = (MoonfmiInstance*) instance;")
  writer.line("    if (!inst || !valueReferences || !values) {")
  writer.line("        return fmi3Error;")
  writer.line("    }")
  if data_type is IrDataType::Float64 {
    writer.line("    MoonfmiModel_compute_outputs(&inst->model, inst->time);")
  }
  writer.line(
    "    if (nValues < Moonfmi_required_\{suffix}(valueReferences, nValueReferences)) {",
  )
  writer.line(
    "        moonfmi_log(inst, fmi3Error, \"error\", \"fmi3Get\{suffix}: values buffer too small\");",
  )
  writer.line("        return fmi3Error;")
  writer.line("    }")
  writer.line("    size_t offset = 0;")
  writer.line("    for (size_t k = 0; k < nValueReferences; ++k) {")
  writer.line("        MoonfmiModel* m = &inst->model;")
  writer.line("        switch (valueReferences[k]) {")
  for line in get_cases {
    writer.line(line)
  }
  writer.line("            default:")
  writer.line(
    "                moonfmi_log(inst, fmi3Error, \"error\", \"fmi3Get\{suffix}: unknown value reference\");",
  )
  writer.line("                return fmi3Error;")
  writer.line("        }")
  writer.line("    }")
  writer.line("    return fmi3OK;")
  writer.line("}")
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3Set\{suffix}(fmi3Instance instance, const fmi3ValueReference valueReferences[], size_t nValueReferences, const \{buffer} values[], size_t nValues) {",
  )
  writer.line("    MoonfmiInstance* inst = (MoonfmiInstance*) instance;")
  writer.line("    if (!inst || !valueReferences || !values) {")
  writer.line("        return fmi3Error;")
  writer.line("    }")
  writer.line(
    "    if (nValues < Moonfmi_required_\{suffix}(valueReferences, nValueReferences)) {",
  )
  writer.line(
    "        moonfmi_log(inst, fmi3Error, \"error\", \"fmi3Set\{suffix}: values buffer too small\");",
  )
  writer.line("        return fmi3Error;")
  writer.line("    }")
  writer.line("    size_t offset = 0;")
  writer.line("    for (size_t k = 0; k < nValueReferences; ++k) {")
  writer.line("        MoonfmiModel* m = &inst->model;")
  writer.line("        switch (valueReferences[k]) {")
  for line in set_cases {
    writer.line(line)
  }
  writer.line("            default:")
  writer.line(
    "                moonfmi_log(inst, fmi3Error, \"error\", \"fmi3Set\{suffix}: value reference is not a parameter or input\");",
  )
  writer.line("                return fmi3Error;")
  writer.line("        }")
  writer.line("    }")
  writer.line("    return fmi3OK;")
  writer.line("}")
  writer.line("")
  writer.to_string().split("\n").map(fn(v) { v.to_owned() }).collect()
}

///|
fn fmi3_type_pairs(ir : ModelIr) -> Array[IrDataType] {
  let _ = ir
  [
    IrDataType::Float64,
    IrDataType::Float32,
    IrDataType::Int32,
    IrDataType::Int64,
    IrDataType::UInt64,
    IrDataType::Boolean,
    IrDataType::Str,
  ]
}

///|
/// The FMI 3 entry file for the declared interfaces.
pub fn generate_fmi3_entry(ir : ModelIr) -> String {
  let cs = ir_find_interface(ir, @schema.InterfaceKind::CoSimulation)
  let me = ir_find_interface(ir, @schema.InterfaceKind::ModelExchange)
  let states = ir.state_slots()
  let string_variables = ir.variables
    .iter()
    .filter(fn(v) { v.data_type is IrDataType::Str })
    .collect()
  let writer = XmlWriter::new()
  writer.line("/* Generated by \{ir.generation_tool} â DO NOT EDIT.")
  writer.line(
    " * FMI 3.0 entry points for model '\{ir.model_name}' (instantiationToken \{ir.guid_value()}).",
  )
  writer.line(" */")
  writer.line("#include \"moonfmi_fmi3.h\"")
  writer.line("#include \"moonfmi_model.h\"")
  writer.line("#include <stdlib.h>")
  writer.line("#include <string.h>")
  writer.line("")
  writer.line("#if defined(_WIN32)")
  writer.line("#define MOONFMI_EXPORT __declspec(dllexport)")
  writer.line("#else")
  writer.line("#define MOONFMI_EXPORT __attribute__((visibility(\"default\")))")
  writer.line("#endif")
  writer.line("")
  writer.line("enum {")
  writer.line("    moonfmi_state_instantiated = 0,")
  writer.line("    moonfmi_state_initialization = 1,")
  writer.line("    moonfmi_state_event_mode = 2,")
  writer.line("    moonfmi_state_step_mode = 3,   /* CS: ready for DoStep */")
  writer.line("    moonfmi_state_continuous = 4,  /* ME: integrating */")
  writer.line("    moonfmi_state_terminated = 5")
  writer.line("};")
  writer.line("")
  writer.line("typedef struct MoonfmiInstance {")
  writer.line("    MoonfmiModel model;")
  writer.line("    double time;")
  writer.line("    char* instance_name;")
  writer.line("    fmi3InstanceEnvironment environment;")
  writer.line("    fmi3LogMessageCallback log;")
  writer.line("    fmi3IntermediateUpdateCallback intermediate_update;")
  writer.line("    int state;")
  writer.line("    int supports_cs;")
  writer.line("    int supports_me;")
  writer.line("    int event_mode_used;")
  writer.line("    int early_return_allowed;")
  writer.line("} MoonfmiInstance;")
  writer.line("")
  writer.line("char* moonfmi_strdup(const char* text) {")
  writer.line("    size_t length = strlen(text) + 1;")
  writer.line("    char* copy = (char*) malloc(length);")
  writer.line("    if (copy) {")
  writer.line("        memcpy(copy, text, length);")
  writer.line("    }")
  writer.line("    return copy;")
  writer.line("}")
  writer.line("")
  writer.line(
    "static void moonfmi_set_string(char** slot, const char* value) {",
  )
  writer.line("    char* copy = value ? moonfmi_strdup(value) : NULL;")
  writer.line("    free((void*) *slot);")
  writer.line("    *slot = copy;")
  writer.line("}")
  writer.line("")
  writer.line(
    "static void moonfmi_log(MoonfmiInstance* inst, fmi3Status status, const char* category, const char* message) {",
  )
  writer.line("    if (inst && inst->log) {")
  writer.line(
    "        inst->log(inst->environment, status, category, message);",
  )
  writer.line("    }")
  writer.line("}")
  writer.line("")
  writer.line(
    "static void* moonfmi_new_instance(const char* instanceName, fmi3InstanceEnvironment environment, fmi3LogMessageCallback logMessage) {",
  )
  writer.line(
    "    MoonfmiInstance* inst = (MoonfmiInstance*) calloc(1, sizeof(MoonfmiInstance));",
  )
  writer.line("    if (!inst) {")
  writer.line("        return NULL;")
  writer.line("    }")
  writer.line(
    "    inst->instance_name = moonfmi_strdup(instanceName ? instanceName : \"\");",
  )
  writer.line("    if (!inst->instance_name) {")
  writer.line("        free(inst);")
  writer.line("        return NULL;")
  writer.line("    }")
  writer.line("    inst->environment = environment;")
  writer.line("    inst->log = logMessage;")
  writer.line("    inst->state = moonfmi_state_instantiated;")
  writer.line("    MoonfmiModel_reset(&inst->model, 0.0);")
  writer.line("    moonfmi_log(inst, fmi3OK, \"info\", \"Instantiated\");")
  writer.line("    return inst;")
  writer.line("}")
  writer.line("")
  if states.length() > 0 {
    writer.line(
      "static void Moonfmi_step_states(MoonfmiModel* m, double t, double h) {",
    )
    writer.line("    double dx[MOONFMI_STATE_COUNT];")
    writer.line("    MoonfmiModel_compute_derivatives(m, t, dx);")
    let mut i = 0
    for slot in states {
      let cfield = c_member_of(slot.name)
      let is_array = match ir.index_of(slot.name) {
        Some(variable_index) =>
          ir.variables[variable_index].dimensions.length() > 0
        None => false
      }
      if is_array {
        writer.line(
          "    m->\{cfield}[\{slot.element.to_string()}] = m->\{cfield}[\{slot.element.to_string()}] + h * dx[\{i.to_string()}];",
        )
      } else {
        writer.line(
          "    m->\{cfield} = m->\{cfield} + h * dx[\{i.to_string()}];",
        )
      }
      i += 1
    }
    writer.line("}")
    writer.line("")
  }
  writer.line("MOONFMI_EXPORT const char* fmi3GetVersion(void) {")
  writer.line("    return \"3.0\";")
  writer.line("}")
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3SetDebugLogging(fmi3Instance instance, fmi3Boolean loggingOn, size_t nCategories, const fmi3String categories[]) {",
  )
  writer.line(
    "    (void)instance; (void)loggingOn; (void)nCategories; (void)categories;",
  )
  writer.line("    return fmi3OK;")
  writer.line("}")
  writer.line("")
  match cs {
    Some(_) => {
      writer.line(
        "MOONFMI_EXPORT fmi3Instance fmi3InstantiateCoSimulation(fmi3String instanceName, fmi3String instantiationToken, fmi3String resourcePath, fmi3Boolean visible, fmi3Boolean loggingOn, fmi3Boolean eventModeUsed, fmi3Boolean earlyReturnAllowed, const fmi3ValueReference requiredIntermediateVariables[], size_t nRequiredIntermediateVariables, fmi3InstanceEnvironment instanceEnvironment, fmi3LogMessageCallback logMessage, fmi3IntermediateUpdateCallback intermediateUpdate) {",
      )
      writer.line(
        "    (void)instantiationToken; (void)resourcePath; (void)visible; (void)loggingOn; (void)requiredIntermediateVariables; (void)nRequiredIntermediateVariables;",
      )
      writer.line(
        "    MoonfmiInstance* inst = (MoonfmiInstance*) moonfmi_new_instance(instanceName, instanceEnvironment, logMessage);",
      )
      writer.line("    if (inst) {")
      writer.line("        inst->supports_cs = 1;")
      writer.line("        inst->event_mode_used = eventModeUsed ? 1 : 0;")
      writer.line(
        "        inst->early_return_allowed = earlyReturnAllowed ? 1 : 0;",
      )
      writer.line("        inst->intermediate_update = intermediateUpdate;")
      writer.line("    }")
      writer.line("    return (fmi3Instance) inst;")
      writer.line("}")
      writer.line("")
    }
    None => ()
  }
  match me {
    Some(_) => {
      writer.line(
        "MOONFMI_EXPORT fmi3Instance fmi3InstantiateModelExchange(fmi3String instanceName, fmi3String instantiationToken, fmi3String resourcePath, fmi3Boolean visible, fmi3Boolean loggingOn, fmi3InstanceEnvironment instanceEnvironment, fmi3LogMessageCallback logMessage) {",
      )
      writer.line(
        "    (void)instantiationToken; (void)resourcePath; (void)visible; (void)loggingOn;",
      )
      writer.line(
        "    MoonfmiInstance* inst = (MoonfmiInstance*) moonfmi_new_instance(instanceName, instanceEnvironment, logMessage);",
      )
      writer.line("    if (inst) {")
      writer.line("        inst->supports_me = 1;")
      writer.line("    }")
      writer.line("    return (fmi3Instance) inst;")
      writer.line("}")
      writer.line("")
    }
    None => ()
  }
  writer.line("MOONFMI_EXPORT void fmi3FreeInstance(fmi3Instance instance) {")
  writer.line("    MoonfmiInstance* inst = (MoonfmiInstance*) instance;")
  writer.line("    if (!inst) {")
  writer.line("        return;")
  writer.line("    }")
  for v in string_variables {
    writer.line("    free((void*) inst->model.\{c_member_of(v.name)});")
  }
  writer.line("    free((void*) inst->instance_name);")
  writer.line("    free(inst);")
  writer.line("}")
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3EnterInitializationMode(fmi3Instance instance, fmi3Boolean toleranceDefined, fmi3Float64 tolerance, fmi3Float64 startTime, fmi3Boolean stopTimeDefined, fmi3Float64 stopTime) {",
  )
  writer.line("    MoonfmiInstance* inst = (MoonfmiInstance*) instance;")
  writer.line(
    "    (void)toleranceDefined; (void)tolerance; (void)stopTimeDefined; (void)stopTime;",
  )
  writer.line("    if (!inst || inst->state != moonfmi_state_instantiated) {")
  writer.line("        return fmi3Error;")
  writer.line("    }")
  writer.line("    inst->time = startTime;")
  writer.line("    MoonfmiModel_reset(&inst->model, startTime);")
  writer.line("    inst->state = moonfmi_state_initialization;")
  writer.line("    return fmi3OK;")
  writer.line("}")
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3ExitInitializationMode(fmi3Instance instance) {",
  )
  writer.line("    MoonfmiInstance* inst = (MoonfmiInstance*) instance;")
  writer.line("    if (!inst || inst->state != moonfmi_state_initialization) {")
  writer.line("        return fmi3Error;")
  writer.line("    }")
  writer.line("    MoonfmiModel_compute_outputs(&inst->model, inst->time);")
  writer.line(
    "    if ((inst->supports_cs && inst->event_mode_used) || inst->supports_me) {",
  )
  writer.line("        inst->state = moonfmi_state_event_mode;")
  writer.line("    } else {")
  writer.line("        inst->state = moonfmi_state_step_mode;")
  writer.line("    }")
  writer.line("    return fmi3OK;")
  writer.line("}")
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3EnterEventMode(fmi3Instance instance) {",
  )
  writer.line("    MoonfmiInstance* inst = (MoonfmiInstance*) instance;")
  writer.line("    if (!inst) {")
  writer.line("        return fmi3Error;")
  writer.line("    }")
  writer.line("    inst->state = moonfmi_state_event_mode;")
  writer.line("    return fmi3OK;")
  writer.line("}")
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3UpdateDiscreteStates(fmi3Instance instance, fmi3Boolean* discreteStatesNeedUpdate, fmi3Boolean* terminateSimulation, fmi3Boolean* nominalsOfContinuousStatesChanged, fmi3Boolean* valuesOfContinuousStatesChanged, fmi3Boolean* nextEventTimeDefined, fmi3Float64* nextEventTime) {",
  )
  writer.line("    MoonfmiInstance* inst = (MoonfmiInstance*) instance;")
  writer.line(
    "    if (!inst || !discreteStatesNeedUpdate || !terminateSimulation || !nominalsOfContinuousStatesChanged || !valuesOfContinuousStatesChanged || !nextEventTimeDefined || !nextEventTime) {",
  )
  writer.line("        return fmi3Error;")
  writer.line("    }")
  writer.line("    /* This model has no events: settle in one iteration. */")
  writer.line("    *discreteStatesNeedUpdate = fmi3False;")
  writer.line("    *terminateSimulation = fmi3False;")
  writer.line("    *nominalsOfContinuousStatesChanged = fmi3False;")
  writer.line("    *valuesOfContinuousStatesChanged = fmi3False;")
  writer.line("    *nextEventTimeDefined = fmi3False;")
  writer.line("    *nextEventTime = 0.0;")
  writer.line("    return fmi3OK;")
  writer.line("}")
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3EnterStepMode(fmi3Instance instance) {",
  )
  writer.line("    MoonfmiInstance* inst = (MoonfmiInstance*) instance;")
  writer.line("    if (!inst) {")
  writer.line("        return fmi3Error;")
  writer.line("    }")
  writer.line("    inst->state = moonfmi_state_step_mode;")
  writer.line("    return fmi3OK;")
  writer.line("}")
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3EnterConfigurationMode(fmi3Instance instance) { (void)instance; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3ExitConfigurationMode(fmi3Instance instance) { (void)instance; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3Terminate(fmi3Instance instance) {",
  )
  writer.line("    MoonfmiInstance* inst = (MoonfmiInstance*) instance;")
  writer.line("    if (!inst) {")
  writer.line("        return fmi3Error;")
  writer.line("    }")
  writer.line("    inst->state = moonfmi_state_terminated;")
  writer.line("    return fmi3OK;")
  writer.line("}")
  writer.line("")
  writer.line("MOONFMI_EXPORT fmi3Status fmi3Reset(fmi3Instance instance) {")
  writer.line("    MoonfmiInstance* inst = (MoonfmiInstance*) instance;")
  writer.line("    if (!inst) {")
  writer.line("        return fmi3Error;")
  writer.line("    }")
  writer.line("    inst->time = 0.0;")
  writer.line("    MoonfmiModel_reset(&inst->model, 0.0);")
  writer.line("    inst->state = moonfmi_state_instantiated;")
  writer.line("    return fmi3OK;")
  writer.line("}")
  writer.line("")
  // Get/set pairs per declared value type.
  for t in fmi3_type_pairs(ir) {
    let block = fmi3_get_set_pair(ir, t)
    for line in block {
      writer.line(line)
    }
  }
  // Value types the IR cannot express: FMPy resolves them on load.
  for
    pair in [
      ("fmi3Int8", "Int8"),
      ("fmi3UInt8", "UInt8"),
      ("fmi3Int16", "Int16"),
      ("fmi3UInt16", "UInt16"),
      ("fmi3UInt32", "UInt32"),
    ] {
    for line in fmi3_foreign_pair(pair.0, pair.1) {
      writer.line(line)
    }
  }
  // CS -------------------------------------------------------------------------
  match cs {
    Some(_) => {
      writer.line(
        "MOONFMI_EXPORT fmi3Status fmi3DoStep(fmi3Instance instance, fmi3Float64 currentCommunicationPoint, fmi3Float64 communicationStepSize, fmi3Boolean noSetFMUStatePriorToCurrentPoint, fmi3Boolean* eventHandlingNeeded, fmi3Boolean* terminateSimulation, fmi3Boolean* earlyReturn, fmi3Float64* lastSuccessfulTime) {",
      )
      writer.line("    MoonfmiInstance* inst = (MoonfmiInstance*) instance;")
      writer.line("    (void)noSetFMUStatePriorToCurrentPoint;")
      writer.line(
        "    if (!inst || !eventHandlingNeeded || !terminateSimulation || !earlyReturn || !lastSuccessfulTime) {",
      )
      writer.line("        return fmi3Error;")
      writer.line("    }")
      writer.line(
        "    if (!inst->supports_cs || inst->state != moonfmi_state_step_mode) {",
      )
      writer.line(
        "        moonfmi_log(inst, fmi3Error, \"error\", \"fmi3DoStep: not in Step Mode\");",
      )
      writer.line("        return fmi3Error;")
      writer.line("    }")
      writer.line("    if (communicationStepSize < 0.0) {")
      writer.line(
        "        moonfmi_log(inst, fmi3Error, \"error\", \"fmi3DoStep: negative step size\");",
      )
      writer.line("        return fmi3Error;")
      writer.line("    }")
      if states.length() > 0 {
        writer.line(
          "    Moonfmi_step_states(&inst->model, currentCommunicationPoint, communicationStepSize);",
        )
      }
      writer.line(
        "    inst->time = currentCommunicationPoint + communicationStepSize;",
      )
      writer.line("    *eventHandlingNeeded = fmi3False;")
      writer.line("    *terminateSimulation = fmi3False;")
      writer.line("    *earlyReturn = fmi3False;")
      writer.line("    *lastSuccessfulTime = inst->time;")
      writer.line("    return fmi3OK;")
      writer.line("}")
      writer.line("")
    }
    None => ()
  }
  // ME -------------------------------------------------------------------------
  match me {
    Some(_) if states.length() > 0 => {
      writer.line(
        "MOONFMI_EXPORT fmi3Status fmi3SetTime(fmi3Instance instance, fmi3Float64 time) {",
      )
      writer.line("    MoonfmiInstance* inst = (MoonfmiInstance*) instance;")
      writer.line("    if (!inst) {")
      writer.line("        return fmi3Error;")
      writer.line("    }")
      writer.line("    inst->time = time;")
      writer.line("    return fmi3OK;")
      writer.line("}")
      writer.line("")
      writer.line(
        "MOONFMI_EXPORT fmi3Status fmi3GetNumberOfContinuousStates(fmi3Instance instance, size_t* nContinuousStates) {",
      )
      writer.line("    MoonfmiInstance* inst = (MoonfmiInstance*) instance;")
      writer.line("    if (!inst || !nContinuousStates) {")
      writer.line("        return fmi3Error;")
      writer.line("    }")
      writer.line("    *nContinuousStates = MOONFMI_STATE_COUNT;")
      writer.line("    return fmi3OK;")
      writer.line("}")
      writer.line("")
      writer.line(
        "MOONFMI_EXPORT fmi3Status fmi3GetContinuousStates(fmi3Instance instance, fmi3Float64 continuousStates[], size_t nContinuousStates) {",
      )
      writer.line("    MoonfmiInstance* inst = (MoonfmiInstance*) instance;")
      writer.line("    if (!inst) {")
      writer.line("        return fmi3Error;")
      writer.line("    }")
      writer.line("    if (nContinuousStates != MOONFMI_STATE_COUNT) {")
      writer.line("        return fmi3Error;")
      writer.line("    }")
      emit_fmi3_state_reads(writer, ir, states, "continuousStates")
      writer.line("    return fmi3OK;")
      writer.line("}")
      writer.line("")
      writer.line(
        "MOONFMI_EXPORT fmi3Status fmi3SetContinuousStates(fmi3Instance instance, const fmi3Float64 continuousStates[], size_t nContinuousStates) {",
      )
      writer.line("    MoonfmiInstance* inst = (MoonfmiInstance*) instance;")
      writer.line("    if (!inst) {")
      writer.line("        return fmi3Error;")
      writer.line("    }")
      writer.line("    if (nContinuousStates != MOONFMI_STATE_COUNT) {")
      writer.line("        return fmi3Error;")
      writer.line("    }")
      emit_fmi3_state_writes(writer, ir, states, "continuousStates")
      writer.line("    return fmi3OK;")
      writer.line("}")
      writer.line("")
      writer.line(
        "MOONFMI_EXPORT fmi3Status fmi3GetContinuousStateDerivatives(fmi3Instance instance, fmi3Float64 derivatives[], size_t nContinuousStates) {",
      )
      writer.line("    MoonfmiInstance* inst = (MoonfmiInstance*) instance;")
      writer.line("    if (!inst) {")
      writer.line("        return fmi3Error;")
      writer.line("    }")
      writer.line("    if (nContinuousStates != MOONFMI_STATE_COUNT) {")
      writer.line("        return fmi3Error;")
      writer.line("    }")
      writer.line("    double dx[MOONFMI_STATE_COUNT];")
      writer.line(
        "    MoonfmiModel_compute_derivatives(&inst->model, inst->time, dx);",
      )
      writer.line("    for (size_t k = 0; k < nContinuousStates; ++k) {")
      writer.line("        derivatives[k] = dx[k];")
      writer.line("    }")
      writer.line("    return fmi3OK;")
      writer.line("}")
      writer.line("")
      writer.line(
        "MOONFMI_EXPORT fmi3Status fmi3GetNumberOfEventIndicators(fmi3Instance instance, size_t* nEventIndicators) {",
      )
      writer.line("    MoonfmiInstance* inst = (MoonfmiInstance*) instance;")
      writer.line("    if (!inst || !nEventIndicators) {")
      writer.line("        return fmi3Error;")
      writer.line("    }")
      writer.line("    *nEventIndicators = MOONFMI_EVENT_INDICATOR_COUNT;")
      writer.line("    return fmi3OK;")
      writer.line("}")
      writer.line("")
      writer.line(
        "MOONFMI_EXPORT fmi3Status fmi3GetEventIndicators(fmi3Instance instance, fmi3Float64 eventIndicators[], size_t nEventIndicators) {",
      )
      writer.line("    MoonfmiInstance* inst = (MoonfmiInstance*) instance;")
      writer.line("    (void)eventIndicators;")
      writer.line("    if (!inst) {")
      writer.line("        return fmi3Error;")
      writer.line("    }")
      writer.line(
        "    if (nEventIndicators != MOONFMI_EVENT_INDICATOR_COUNT) {",
      )
      writer.line("        return fmi3Error;")
      writer.line("    }")
      writer.line("    return fmi3OK;")
      writer.line("}")
      writer.line("")
      writer.line(
        "MOONFMI_EXPORT fmi3Status fmi3GetNominalsOfContinuousStates(fmi3Instance instance, fmi3Float64 nominals[], size_t nContinuousStates) {",
      )
      writer.line("    MoonfmiInstance* inst = (MoonfmiInstance*) instance;")
      writer.line("    if (!inst) {")
      writer.line("        return fmi3Error;")
      writer.line("    }")
      writer.line("    if (nContinuousStates != MOONFMI_STATE_COUNT) {")
      writer.line("        return fmi3Error;")
      writer.line("    }")
      writer.line("    for (size_t k = 0; k < nContinuousStates; ++k) {")
      writer.line("        nominals[k] = 1.0;")
      writer.line("    }")
      writer.line("    return fmi3OK;")
      writer.line("}")
      writer.line("")
      writer.line(
        "MOONFMI_EXPORT fmi3Status fmi3EnterContinuousTimeMode(fmi3Instance instance) {",
      )
      writer.line("    MoonfmiInstance* inst = (MoonfmiInstance*) instance;")
      writer.line("    if (!inst) {")
      writer.line("        return fmi3Error;")
      writer.line("    }")
      writer.line("    inst->state = moonfmi_state_continuous;")
      writer.line("    return fmi3OK;")
      writer.line("}")
      writer.line("")
      writer.line(
        "MOONFMI_EXPORT fmi3Status fmi3CompletedIntegratorStep(fmi3Instance instance, fmi3Boolean noSetFMUStatePriorToCurrentPoint, fmi3Boolean* enterEventMode, fmi3Boolean* terminateSimulation) {",
      )
      writer.line("    MoonfmiInstance* inst = (MoonfmiInstance*) instance;")
      writer.line("    (void)noSetFMUStatePriorToCurrentPoint;")
      writer.line("    if (!inst || !enterEventMode || !terminateSimulation) {")
      writer.line("        return fmi3Error;")
      writer.line("    }")
      writer.line("    *enterEventMode = fmi3False;")
      writer.line("    *terminateSimulation = fmi3False;")
      writer.line("    return fmi3OK;")
      writer.line("}")
      writer.line("")
    }
    Some(_) => {
      writer.line(
        "/* ModelExchange declared but the IR has no continuous states; ME entry points are not generated. */",
      )
      writer.line("")
    }
    None => ()
  }
  // Cross-interface stubs: hosts such as FMPy resolve the entire fmi3*
  // family when loading, so a CS-only (or ME-only) FMU must still export
  // the other interface's symbols. They return fmi3Error.
  if cs is Some(_) && me is None {
    writer.line(
      "MOONFMI_EXPORT fmi3Status fmi3SetTime(fmi3Instance instance, fmi3Float64 time) { (void)instance; (void)time; return fmi3Error; }",
    )
    writer.line("")
    writer.line(
      "MOONFMI_EXPORT fmi3Status fmi3GetNumberOfContinuousStates(fmi3Instance instance, size_t* n) { (void)instance; (void)n; return fmi3Error; }",
    )
    writer.line("")
    writer.line(
      "MOONFMI_EXPORT fmi3Status fmi3GetContinuousStates(fmi3Instance instance, fmi3Float64 states[], size_t n) { (void)instance; (void)states; (void)n; return fmi3Error; }",
    )
    writer.line("")
    writer.line(
      "MOONFMI_EXPORT fmi3Status fmi3SetContinuousStates(fmi3Instance instance, const fmi3Float64 states[], size_t n) { (void)instance; (void)states; (void)n; return fmi3Error; }",
    )
    writer.line("")
    writer.line(
      "MOONFMI_EXPORT fmi3Status fmi3GetContinuousStateDerivatives(fmi3Instance instance, fmi3Float64 derivatives[], size_t n) { (void)instance; (void)derivatives; (void)n; return fmi3Error; }",
    )
    writer.line("")
    writer.line(
      "MOONFMI_EXPORT fmi3Status fmi3GetNumberOfEventIndicators(fmi3Instance instance, size_t* n) { (void)instance; (void)n; return fmi3Error; }",
    )
    writer.line("")
    writer.line(
      "MOONFMI_EXPORT fmi3Status fmi3GetEventIndicators(fmi3Instance instance, fmi3Float64 indicators[], size_t n) { (void)instance; (void)indicators; (void)n; return fmi3Error; }",
    )
    writer.line("")
    writer.line(
      "MOONFMI_EXPORT fmi3Status fmi3GetNominalsOfContinuousStates(fmi3Instance instance, fmi3Float64 nominals[], size_t n) { (void)instance; (void)nominals; (void)n; return fmi3Error; }",
    )
    writer.line("")
    writer.line(
      "MOONFMI_EXPORT fmi3Status fmi3EnterContinuousTimeMode(fmi3Instance instance) { (void)instance; return fmi3Error; }",
    )
    writer.line("")
    writer.line(
      "MOONFMI_EXPORT fmi3Status fmi3CompletedIntegratorStep(fmi3Instance instance, fmi3Boolean noSet, fmi3Boolean* enterEventMode, fmi3Boolean* terminate) { (void)instance; (void)noSet; (void)enterEventMode; (void)terminate; return fmi3Error; }",
    )
    writer.line("")
  }
  if me is Some(_) && cs is None {
    writer.line(
      "MOONFMI_EXPORT fmi3Status fmi3DoStep(fmi3Instance instance, fmi3Float64 current, fmi3Float64 step, fmi3Boolean noSet, fmi3Boolean* eventNeeded, fmi3Boolean* terminate, fmi3Boolean* earlyReturn, fmi3Float64* lastSuccessfulTime) { (void)instance; (void)current; (void)step; (void)noSet; (void)eventNeeded; (void)terminate; (void)earlyReturn; (void)lastSuccessfulTime; return fmi3Error; }",
    )
    writer.line("")
    writer.line(
      "MOONFMI_EXPORT fmi3Status fmi3EnterStepMode(fmi3Instance instance) { (void)instance; return fmi3Error; }",
    )
    writer.line("")
  }
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3GetOutputDerivatives(fmi3Instance instance, const fmi3ValueReference vrs[], size_t nvr, const fmi3Int32 orders[], fmi3Float64 values[], size_t nValues) { (void)instance; (void)vrs; (void)nvr; (void)orders; (void)values; (void)nValues; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3SetIntervalDecimal(fmi3Instance instance, const fmi3ValueReference vrs[], size_t nvr, const fmi3Float64 intervals[]) { (void)instance; (void)vrs; (void)nvr; (void)intervals; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3SetIntervalFraction(fmi3Instance instance, const fmi3ValueReference vrs[], size_t nvr, const fmi3UInt64 counters[], const fmi3UInt64 resolutions[]) { (void)instance; (void)vrs; (void)nvr; (void)counters; (void)resolutions; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3SetShiftDecimal(fmi3Instance instance, const fmi3ValueReference vrs[], size_t nvr, const fmi3Float64 shifts[]) { (void)instance; (void)vrs; (void)nvr; (void)shifts; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3SetShiftFraction(fmi3Instance instance, const fmi3ValueReference vrs[], size_t nvr, const fmi3UInt64 counters[], const fmi3UInt64 resolutions[]) { (void)instance; (void)vrs; (void)nvr; (void)counters; (void)resolutions; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3SerializedFMUStateSize(fmi3Instance instance, fmi3FMUState FMUState, size_t* size) { (void)instance; (void)FMUState; (void)size; return fmi3Error; }",
  )
  writer.line("")
  // Optional families: optional per FMI 3 and declared absent in
  // modelDescription.xml. The stubs exist because hosts such as FMPy resolve
  // every fmi3* symbol when loading; MoonFMI decides capabilities from the
  // model description (Fmi3Instance::declare_fmu_state), not symbol presence.
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3GetIntervalDecimal(fmi3Instance instance, const fmi3ValueReference vrs[], size_t nvr, fmi3Float64 intervals[], fmi3IntervalQualifier qualifiers[]) { (void)instance; (void)vrs; (void)nvr; (void)intervals; (void)qualifiers; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3GetIntervalFraction(fmi3Instance instance, const fmi3ValueReference vrs[], size_t nvr, fmi3UInt64 counters[], fmi3UInt64 resolutions[], fmi3IntervalQualifier qualifiers[]) { (void)instance; (void)vrs; (void)nvr; (void)counters; (void)resolutions; (void)qualifiers; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3GetShiftDecimal(fmi3Instance instance, const fmi3ValueReference vrs[], size_t nvr, fmi3Float64 shifts[]) { (void)instance; (void)vrs; (void)nvr; (void)shifts; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3GetShiftFraction(fmi3Instance instance, const fmi3ValueReference vrs[], size_t nvr, fmi3UInt64 counters[], fmi3UInt64 resolutions[]) { (void)instance; (void)vrs; (void)nvr; (void)counters; (void)resolutions; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3GetClock(fmi3Instance instance, const fmi3ValueReference vrs[], size_t nvr, fmi3Clock values[]) { (void)instance; (void)vrs; (void)nvr; (void)values; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3SetClock(fmi3Instance instance, const fmi3ValueReference vrs[], size_t nvr, const fmi3Clock values[]) { (void)instance; (void)vrs; (void)nvr; (void)values; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3GetBinary(fmi3Instance instance, const fmi3ValueReference vrs[], size_t nvr, size_t sizes[], fmi3Binary values[], size_t nValues) { (void)instance; (void)vrs; (void)nvr; (void)sizes; (void)values; (void)nValues; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3SetBinary(fmi3Instance instance, const fmi3ValueReference vrs[], size_t nvr, const size_t sizes[], const fmi3Binary values[], size_t nValues) { (void)instance; (void)vrs; (void)nvr; (void)sizes; (void)values; (void)nValues; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3GetNumberOfVariableDependencies(fmi3Instance instance, fmi3ValueReference vr, size_t* nDependencies) { (void)instance; (void)vr; (void)nDependencies; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3GetVariableDependencies(fmi3Instance instance, fmi3ValueReference dependent, size_t elementIndices[], fmi3ValueReference independents[], fmi3DependencyKind dependencyKinds[], size_t nDependencies) { (void)instance; (void)dependent; (void)elementIndices; (void)independents; (void)dependencyKinds; (void)nDependencies; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3EvaluateDiscreteStates(fmi3Instance instance) { (void)instance; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3ActivateModelPartition(fmi3Instance instance, fmi3ValueReference clockReference, fmi3Float64 activationTime) { (void)instance; (void)clockReference; (void)activationTime; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Instance fmi3InstantiateScheduledExecution(fmi3String instanceName, fmi3String instantiationToken, fmi3String resourcePath, fmi3Boolean visible, fmi3Boolean loggingOn, fmi3InstanceEnvironment instanceEnvironment, fmi3LogMessageCallback logMessage, fmi3ClockUpdateCallback clockUpdate, fmi3LockPreemptionCallback lockPreemption, fmi3UnlockPreemptionCallback unlockPreemption) { (void)instanceName; (void)instantiationToken; (void)resourcePath; (void)visible; (void)loggingOn; (void)instanceEnvironment; (void)logMessage; (void)clockUpdate; (void)lockPreemption; (void)unlockPreemption; return NULL; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3GetFMUState(fmi3Instance instance, fmi3FMUState* FMUState) { (void)instance; (void)FMUState; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3SetFMUState(fmi3Instance instance, fmi3FMUState FMUState) { (void)instance; (void)FMUState; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3FreeFMUState(fmi3Instance instance, fmi3FMUState* FMUState) { (void)instance; (void)FMUState; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3SerializeFMUState(fmi3Instance instance, fmi3FMUState FMUState, fmi3Byte serializedState[], size_t size) { (void)instance; (void)FMUState; (void)serializedState; (void)size; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3DeserializeFMUState(fmi3Instance instance, const fmi3Byte serializedState[], size_t size, fmi3FMUState* FMUState) { (void)instance; (void)serializedState; (void)size; (void)FMUState; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3GetSizeOfSerializedFMUState(fmi3Instance instance, fmi3FMUState FMUState, size_t* size) { (void)instance; (void)FMUState; (void)size; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3GetDirectionalDerivative(fmi3Instance instance, const fmi3ValueReference unknowns[], size_t nUnknowns, const fmi3ValueReference knowns[], size_t nKnowns, const fmi3Float64 dvKnown[], fmi3Float64 dvUnknown[]) { (void)instance; (void)unknowns; (void)nUnknowns; (void)knowns; (void)nKnowns; (void)dvKnown; (void)dvUnknown; return fmi3Error; }",
  )
  writer.line("")
  writer.line(
    "MOONFMI_EXPORT fmi3Status fmi3GetAdjointDerivative(fmi3Instance instance, const fmi3ValueReference unknowns[], size_t nUnknowns, const fmi3ValueReference knowns[], size_t nKnowns, const fmi3Float64 dvUnknown[], fmi3Float64 dvKnown[]) { (void)instance; (void)unknowns; (void)nUnknowns; (void)knowns; (void)nKnowns; (void)dvUnknown; (void)dvKnown; return fmi3Error; }",
  )
  writer.line("")
  // Optional capabilities: not exported at all. The XML declares
  // canGetAndSetFMUstate/canSerializeFMUstate/providesDirectionalDerivative
  // as false, and per FMI 3 the corresponding symbols may be absent when a
  // capability is false — hosts resolve them optionally. Exporting stub
  // functions that return fmi3Error would make symbol-presence checks
  // (MoonFMI's shim) believe the capability exists.
  writer.to_string()
}

///|
fn emit_fmi3_state_reads(
  writer : XmlWriter,
  ir : ModelIr,
  states : Array[StateSlot],
  buffer : String,
) -> Unit {
  let mut i = 0
  for slot in states {
    let cfield = c_member_of(slot.name)
    let is_array = match ir.index_of(slot.name) {
      Some(variable_index) =>
        ir.variables[variable_index].dimensions.length() > 0
      None => false
    }
    if is_array {
      writer.line(
        "    \{buffer}[\{i.to_string()}] = inst->model.\{cfield}[\{slot.element.to_string()}];",
      )
    } else {
      writer.line("    \{buffer}[\{i.to_string()}] = inst->model.\{cfield};")
    }
    i += 1
  }
}

///|
fn emit_fmi3_state_writes(
  writer : XmlWriter,
  ir : ModelIr,
  states : Array[StateSlot],
  buffer : String,
) -> Unit {
  let mut i = 0
  for slot in states {
    let cfield = c_member_of(slot.name)
    let is_array = match ir.index_of(slot.name) {
      Some(variable_index) =>
        ir.variables[variable_index].dimensions.length() > 0
      None => false
    }
    if is_array {
      writer.line(
        "    inst->model.\{cfield}[\{slot.element.to_string()}] = \{buffer}[\{i.to_string()}];",
      )
    } else {
      writer.line("    inst->model.\{cfield} = \{buffer}[\{i.to_string()}];")
    }
    i += 1
  }
}

///|
/// moonfmi_fmi3.h: minimal self-contained FMI 3 types matching the standard
/// header (bool = 1 byte, fmi3ValueReference = uint32).
pub fn generate_fmi3_header(ir : ModelIr) -> String {
  let writer = XmlWriter::new()
  writer.line(
    "/* Generated by \{ir.generation_tool} â minimal FMI 3.0 types (self-contained). */",
  )
  writer.line("#ifndef MOONFMI_FMI3_H")
  writer.line("#define MOONFMI_FMI3_H")
  writer.line("")
  writer.line("#include <stdbool.h>")
  writer.line("#include <stddef.h>")
  writer.line("#include <stdint.h>")
  writer.line("")
  writer.line("typedef void* fmi3Instance;")
  writer.line("typedef void* fmi3InstanceEnvironment;")
  writer.line("typedef uint32_t fmi3ValueReference;")
  writer.line("typedef float fmi3Float32;")
  writer.line("typedef double fmi3Float64;")
  writer.line("typedef int8_t fmi3Int8;")
  writer.line("typedef uint8_t fmi3UInt8;")
  writer.line("typedef int16_t fmi3Int16;")
  writer.line("typedef uint16_t fmi3UInt16;")
  writer.line("typedef int32_t fmi3Int32;")
  writer.line("typedef uint32_t fmi3UInt32;")
  writer.line("typedef int64_t fmi3Int64;")
  writer.line("typedef uint64_t fmi3UInt64;")
  writer.line("typedef bool fmi3Boolean;")
  writer.line("typedef char fmi3Char;")
  writer.line("typedef const fmi3Char* fmi3String;")
  writer.line("typedef const unsigned char* fmi3Byte;")
  writer.line("typedef unsigned char fmi3Clock;")
  writer.line("")
  writer.line("typedef enum {")
  writer.line("    fmi3OK = 0,")
  writer.line("    fmi3Warning = 1,")
  writer.line("    fmi3Discard = 2,")
  writer.line("    fmi3Error = 3,")
  writer.line("    fmi3Fatal = 4,")
  writer.line("    fmi3Pending = 5")
  writer.line("} fmi3Status;")
  writer.line("")
  writer.line("typedef enum {")
  writer.line("    fmi3IntervalNotYetKnown,")
  writer.line("    fmi3IntervalUnchanged,")
  writer.line("    fmi3IntervalChanged")
  writer.line("} fmi3IntervalQualifier;")
  writer.line("")
  writer.line(
    "typedef void (*fmi3LogMessageCallback)(fmi3InstanceEnvironment instanceEnvironment, fmi3Status status, fmi3String category, fmi3String message);",
  )
  writer.line("typedef void* fmi3FMUState;")
  writer.line("typedef const unsigned char* fmi3Binary;")
  writer.line("")
  writer.line("typedef enum {")
  writer.line("    fmi3Independent,")
  writer.line("    fmi3Constant,")
  writer.line("    fmi3Fixed,")
  writer.line("    fmi3Tunable,")
  writer.line("    fmi3Discrete,")
  writer.line("    fmi3Dependent")
  writer.line("} fmi3DependencyKind;")
  writer.line("")
  writer.line(
    "typedef void (*fmi3ClockUpdateCallback)(fmi3InstanceEnvironment instanceEnvironment);",
  )
  writer.line("typedef void (*fmi3LockPreemptionCallback)(void);")
  writer.line("typedef void (*fmi3UnlockPreemptionCallback)(void);")
  writer.line("")
  writer.line("")
  writer.line("typedef void (*fmi3IntermediateUpdateCallback)(")
  writer.line("    fmi3InstanceEnvironment instanceEnvironment,")
  writer.line("    fmi3Float64  intermediateUpdateTime,")
  writer.line("    fmi3Boolean  intermediateVariableSetRequested,")
  writer.line("    fmi3Boolean  intermediateVariableGetAllowed,")
  writer.line("    fmi3Boolean  intermediateStepFinished,")
  writer.line("    fmi3Boolean  canReturnEarly,")
  writer.line("    fmi3Boolean* earlyReturnRequested,")
  writer.line("    fmi3Float64* earlyReturnTime);")
  writer.line("")
  writer.line("#define fmi3False false")
  writer.line("#define fmi3True true")
  writer.line("")
  writer.line("#endif /* MOONFMI_FMI3_H */")
  writer.to_string()
}

///|
/// Typed get/set pair for value types the IR cannot express (Int8…UInt32).
/// FMPy resolves the whole fmi3Get*/fmi3Set* family on load, so these must
/// exist even though the model declares no such variables; every reference
/// is rejected by the switch default.
fn fmi3_foreign_pair(c_type : String, suffix : String) -> Array[String] {
  let lines = []
  lines.push(
    "static size_t Moonfmi_required_\{suffix}(const fmi3ValueReference vrs[], size_t nvr) { (void)vrs; (void)nvr; return 0; }",
  )
  lines.push("")
  lines.push(
    "MOONFMI_EXPORT fmi3Status fmi3Get\{suffix}(fmi3Instance instance, const fmi3ValueReference valueReferences[], size_t nValueReferences, \{c_type} values[], size_t nValues) { (void)instance; (void)valueReferences; (void)nValueReferences; (void)values; (void)nValues; return fmi3Error; }",
  )
  lines.push("")
  lines.push(
    "MOONFMI_EXPORT fmi3Status fmi3Set\{suffix}(fmi3Instance instance, const fmi3ValueReference valueReferences[], size_t nValueReferences, const \{c_type} values[], size_t nValues) { (void)instance; (void)valueReferences; (void)nValueReferences; (void)values; (void)nValues; return fmi3Error; }",
  )
  lines.push("")
  lines
}
