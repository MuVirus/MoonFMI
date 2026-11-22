///|
/// `--set name=value` input overrides (0.7.0): the typed value written to
/// the FMU instance before the master enters initialization, so the FMU
/// sees it as its start value.

///|
/// The typed value of a `--set` override. The FMI 2 binding only ever
/// produces `RealValue`/`Int32Value`/`BoolValue`/`StrValue`; the narrower
/// FMI 3 kinds carry their own target type so the writer is unambiguous —
/// an FMU rejects a typed write whose width does not match the variable.
priv enum SetValueKind {
  RealValue(Double)
  Float32Value(Double)
  Int8Value(Int32)
  UInt8Value(Int32)
  Int16Value(Int32)
  UInt16Value(Int32)
  Int32Value(Int32)
  UInt32Value(UInt32)
  Int64Value(Int64)
  UInt64Value(UInt64)
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
          Integer(_) => Some(SetPayloadKind::Int32)
          Boolean(_) => Some(SetPayloadKind::Bool)
          Str(_) => Some(SetPayloadKind::Str)
          Enumeration(_) => Some(SetPayloadKind::Int32)
        },
        "Real, Integer, Boolean, String or Enumeration",
      )
    }
  }
}

///|
/// Resolve a `--set` operand against an FMI 3 typed model description.
/// Every numeric kind the binding layer can write is settable (Float32
/// rides Double, Int8/UInt8/Int16/UInt16/Int32 and enumerations ride
/// Int32); Binary and Clock have no scalar `--set` form.
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
          Float32 => Some(SetPayloadKind::Float32)
          Float64 => Some(SetPayloadKind::Real)
          Int8 => Some(SetPayloadKind::Int8)
          UInt8 => Some(SetPayloadKind::UInt8)
          Int16 => Some(SetPayloadKind::Int16)
          UInt16 => Some(SetPayloadKind::UInt16)
          Int32 | Enumeration => Some(SetPayloadKind::Int32)
          UInt32 => Some(SetPayloadKind::UInt32)
          Int64 => Some(SetPayloadKind::Int64)
          UInt64 => Some(SetPayloadKind::UInt64)
          Boolean => Some(SetPayloadKind::Bool)
          Str => Some(SetPayloadKind::Str)
          Binary | Clock => None
        },
        "Float32, Float64, Int8, UInt8, Int16, UInt16, Int32, UInt32, Int64, UInt64, Boolean, String or Enumeration",
      )
    }
  }
}

///|
/// The payload kinds a `--set` override can target, shared by both FMI
/// versions' resolution paths.
priv enum SetPayloadKind {
  Real
  Float32
  Int8
  UInt8
  Int16
  UInt16
  Int32
  UInt32
  Int64
  UInt64
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
        Float32 => {
          let parsed = @string.parse_double(raw) catch {
            _ => return Err("'" + raw + "' is not a number for '" + name + "'")
          }
          Float32Value(parsed)
        }
        Int8 => {
          let parsed = @string.parse_int(raw) catch {
            _ =>
              return Err("'" + raw + "' is not an integer for '" + name + "'")
          }
          Int8Value(parsed)
        }
        UInt8 => {
          let parsed = @string.parse_int(raw) catch {
            _ =>
              return Err("'" + raw + "' is not an integer for '" + name + "'")
          }
          UInt8Value(parsed)
        }
        Int16 => {
          let parsed = @string.parse_int(raw) catch {
            _ =>
              return Err("'" + raw + "' is not an integer for '" + name + "'")
          }
          Int16Value(parsed)
        }
        UInt16 => {
          let parsed = @string.parse_int(raw) catch {
            _ =>
              return Err("'" + raw + "' is not an integer for '" + name + "'")
          }
          UInt16Value(parsed)
        }
        Int32 => {
          let parsed = @string.parse_int(raw) catch {
            _ =>
              return Err("'" + raw + "' is not an integer for '" + name + "'")
          }
          Int32Value(parsed)
        }
        UInt32 => {
          let parsed = @string.parse_uint(raw) catch {
            _ =>
              return Err(
                "'" + raw + "' is not an unsigned integer for '" + name + "'",
              )
          }
          UInt32Value(parsed)
        }
        Int64 => {
          let parsed = @string.parse_int64(raw) catch {
            _ =>
              return Err("'" + raw + "' is not an integer for '" + name + "'")
          }
          Int64Value(parsed)
        }
        UInt64 => {
          let parsed = @string.parse_uint64(raw) catch {
            _ =>
              return Err(
                "'" + raw + "' is not an unsigned integer for '" + name + "'",
              )
          }
          UInt64Value(parsed)
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
        Float32Value(_)
        | Int8Value(_)
        | UInt8Value(_)
        | Int16Value(_)
        | UInt16Value(_)
        | UInt32Value(_)
        | Int64Value(_)
        | UInt64Value(_) =>
          abort("FMI 2 --set resolution cannot produce this value kind")
        Int32Value(value) => {
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
        Float32Value(value) => {
          instance.set_float32_one(entry.value_reference, value)
          None
        }
        Int8Value(value) => {
          instance.set_int8_one(entry.value_reference, value)
          None
        }
        UInt8Value(value) => {
          instance.set_uint8_one(entry.value_reference, value)
          None
        }
        Int16Value(value) => {
          instance.set_int16_one(entry.value_reference, value)
          None
        }
        UInt16Value(value) => {
          instance.set_uint16_one(entry.value_reference, value)
          None
        }
        Int32Value(value) => {
          instance.set_int32_one(entry.value_reference, value)
          None
        }
        UInt32Value(value) => {
          instance.set_uint32_one(entry.value_reference, value)
          None
        }
        Int64Value(value) => {
          instance.set_int64_one(entry.value_reference, value)
          None
        }
        UInt64Value(value) => {
          instance.set_uint64([entry.value_reference], [value])
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
