///|
/// `--set name=value` input overrides (0.7.0): the typed value written to
/// the FMU instance before the master enters initialization, so the FMU
/// sees it as its start value.

///|
/// The typed value of a `--set` override.
priv enum SetValueKind {
  RealValue(Double)
  IntValue(Int32)
  BoolValue(Bool)
  StrValue(String)
}

///|
/// A resolved `--set` operand: the target value reference and the parsed
/// value.
priv struct ResolvedSet {
  value_reference : UInt32
  value : SetValueKind
}

///|
/// Parse a boolean `--set` value. Strict but forgiving on case and the
/// common `1`/`0` spellings.
fn parse_set_boolean(text : String) -> Bool? {
  match text {
    "true" | "True" | "TRUE" | "1" => Some(true)
    "false" | "False" | "FALSE" | "0" => Some(false)
    _ => None
  }
}

///|
/// Resolve a `--set` operand against an FMI 2 typed model description.
/// The kind is inferred from the variable's payload; only inputs and
/// parameters are settable.
fn resolve_set_fmi2(
  model : @schema.Fmi2ModelDescription,
  name : String,
  raw : String,
) -> Result[ResolvedSet, String] {
  let index = @schema.build_fmi2_index(model)
  match index.position_of_name(name) {
    None =>
      Err("variable '" + name + "' is not declared in the model description")
    Some(position) => {
      let variable = model.variables[position - 1]
      resolve_set_common(
        name,
        raw,
        variable.value_reference,
        variable.effective_causality(),
        match variable.payload {
          Real(_) => Some(SetPayloadKind::Real)
          Integer(_) => Some(SetPayloadKind::Int)
          Boolean(_) => Some(SetPayloadKind::Bool)
          Str(_) => Some(SetPayloadKind::Str)
          Enumeration(_) => Some(SetPayloadKind::Int)
        },
        "Real, Integer, Boolean, String or Enumeration",
      )
    }
  }
}

///|
/// Resolve a `--set` operand against an FMI 3 typed model description.
/// Only kinds the binding layer can write are settable (Float64, Int32,
/// Boolean, String; enumerations ride Int32).
fn resolve_set_fmi3(
  model : @schema.Fmi3ModelDescription,
  name : String,
  raw : String,
) -> Result[ResolvedSet, String] {
  let index = @schema.build_fmi3_index(model)
  match index.position_of_name(name) {
    None =>
      Err("variable '" + name + "' is not declared in the model description")
    Some(position) => {
      let variable = model.variables[position - 1]
      if !variable.dimensions.is_empty() {
        return Err(
          "variable '" + name + "' is an array; --set supports scalars only",
        )
      }
      resolve_set_common(
        name,
        raw,
        variable.value_reference,
        variable.effective_causality(),
        match variable.type_kind {
          Float64 => Some(SetPayloadKind::Real)
          Int32 => Some(SetPayloadKind::Int)
          Enumeration => Some(SetPayloadKind::Int)
          Boolean => Some(SetPayloadKind::Bool)
          Str => Some(SetPayloadKind::Str)
          _ => None
        },
        "Float64, Int32, Boolean, String or Enumeration",
      )
    }
  }
}

///|
/// The payload kinds a `--set` override can target, shared by both FMI
/// versions' resolution paths.
priv enum SetPayloadKind {
  Real
  Int
  Bool
  Str
}

///|
/// Shared tail of the `--set` resolution: causality gate and value
/// parsing for the inferred payload kind.
fn resolve_set_common(
  name : String,
  raw : String,
  value_reference : UInt32,
  causality : @schema.Causality,
  kind : SetPayloadKind?,
  supported : String,
) -> Result[ResolvedSet, String] {
  if !(causality is @schema.Causality::Input ||
    causality is @schema.Causality::Parameter) {
    return Err(
      "variable '" +
      name +
      "' has causality '" +
      @schema.Causality::name(causality) +
      "', expected input or parameter",
    )
  }
  match kind {
    None =>
      Err(
        "variable '" +
        name +
        "' is not a settable scalar (" +
        supported +
        " are supported by --set)",
      )
    Some(kind) => {
      let value : SetValueKind = match kind {
        Real => {
          let parsed = @string.parse_double(raw) catch {
            _ => return Err("'" + raw + "' is not a number for '" + name + "'")
          }
          RealValue(parsed)
        }
        Int => {
          let parsed = @string.parse_int(raw) catch {
            _ =>
              return Err("'" + raw + "' is not an integer for '" + name + "'")
          }
          IntValue(parsed)
        }
        Bool =>
          match parse_set_boolean(raw) {
            Some(parsed) => BoolValue(parsed)
            None =>
              return Err(
                "'" +
                raw +
                "' is not a boolean for '" +
                name +
                "' (expected true or false)",
              )
          }
        Str => StrValue(raw)
      }
      Ok({ value_reference, value, })
    }
  }
}

///|
/// Write every resolved `--set` value to the FMI 2 instance before
/// initialization. Returns the first failure message, if any.
fn apply_sets_fmi2(
  instance : @native.Fmi2Instance,
  sets : Array[ResolvedSet],
) -> String? {
  for entry in sets {
    let outcome = try {
      match entry.value {
        RealValue(value) => {
          instance.set_real_one(entry.value_reference, value)
          None
        }
        IntValue(value) => {
          instance.set_integer_one(entry.value_reference, value)
          None
        }
        BoolValue(value) => {
          instance.set_boolean_one(entry.value_reference, value)
          None
        }
        StrValue(value) => {
          instance.set_string_one(entry.value_reference, value)
          None
        }
      }
    } catch {
      error => Some(error.message())
    }
    if outcome is Some(_) {
      return outcome
    }
  }
  None
}

///|
/// Write every resolved `--set` value to the FMI 3 instance before
/// initialization. Returns the first failure message, if any.
fn apply_sets_fmi3(
  instance : @native.Fmi3Instance,
  sets : Array[ResolvedSet],
) -> String? {
  for entry in sets {
    let outcome = try {
      match entry.value {
        RealValue(value) => {
          instance.set_float64_one(entry.value_reference, value)
          None
        }
        IntValue(value) => {
          instance.set_int32_one(entry.value_reference, value)
          None
        }
        BoolValue(value) => {
          instance.set_boolean_one(entry.value_reference, value)
          None
        }
        StrValue(value) => {
          instance.set_string_one(entry.value_reference, value)
          None
        }
      }
    } catch {
      error => Some(error.message())
    }
    if outcome is Some(_) {
      return outcome
    }
  }
  None
}

///|
/// Resolve and apply every `--set` override against a loaded FMI 2 FMU.
/// `None` on success; a diagnostic message (already phrased for the CLI)
/// on the first failure.
fn apply_set_overrides_fmi2(
  model : @schema.Fmi2ModelDescription,
  instance : @native.Fmi2Instance,
  sets : Array[(String, String)],
) -> String? {
  for entry in sets {
    match resolve_set_fmi2(model, entry.0, entry.1) {
      Err(message) => return Some(message)
      Ok(resolved) =>
        match apply_sets_fmi2(instance, [resolved]) {
          Some(message) => return Some(message)
          None => ()
        }
    }
  }
  None
}

///|
/// Resolve and apply every `--set` override against a loaded FMI 3 FMU.
fn apply_set_overrides_fmi3(
  model : @schema.Fmi3ModelDescription,
  instance : @native.Fmi3Instance,
  sets : Array[(String, String)],
) -> String? {
  for entry in sets {
    match resolve_set_fmi3(model, entry.0, entry.1) {
      Err(message) => return Some(message)
      Ok(resolved) =>
        match apply_sets_fmi3(instance, [resolved]) {
          Some(message) => return Some(message)
          None => ()
        }
    }
  }
  None
}
