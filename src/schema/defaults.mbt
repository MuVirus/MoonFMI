///|
/// Default-value derivation (task B-09). Parsed models keep causality,
/// variability, and initial exactly as written; the effective values are
/// derived here so diagnostics can tell "user wrote it" from "default
/// applied" apart.
///
/// The tables follow the FMI 2.0.4 / FMI 3.0.2 specification tables and
/// mirror FMPy's `initial_defaults` / `legal_combinations` so MoonFMI and
/// FMPy agree on real-world FMUs (Reference-FMUs write
/// `output` + `continuous` + `initial="exact"`, which is legal).

///|
/// Effective causality: the XSD default is `local`.
pub fn default_causality(causality : Causality?) -> Causality {
  match causality {
    Some(value) => value
    None => Local
  }
}

///|
/// Effective variability. FMI 2 defaults to `continuous`.
pub fn default_variability_fmi2(variability : Variability?) -> Variability {
  match variability {
    Some(value) => value
    None => Continuous
  }
}

///|
/// Effective variability for FMI 3, where the attribute has no XSD
/// default: it is inferred from the variable type (`continuous` for the
/// float kinds, `discrete` for everything else, including `Clock`).
pub fn default_variability_fmi3(type_kind : Fmi3TypeKind) -> Variability {
  if type_kind.is_float() {
    Continuous
  } else {
    Discrete
  }
}

///|
/// Derive the default `initial` from causality and variability. Mirrors
/// FMPy's `initial_defaults` table (identical for FMI 2 and FMI 3).
/// Returns `None` where no initial is defined (`independent`) and for
/// illegal combinations, which rule MD-012 reports instead.
pub fn derive_initial(
  causality : Causality,
  variability : Variability,
) -> Initial? {
  match (causality, variability) {
    (StructuralParameter, Fixed) | (StructuralParameter, Tunable) => Some(Exact)
    (Parameter, Fixed) | (Parameter, Tunable) => Some(Exact)
    (CalculatedParameter, Fixed) | (CalculatedParameter, Tunable) =>
      Some(Calculated)
    (Input, Discrete) | (Input, Continuous) => Some(Exact)
    (Output, Constant) => Some(Exact)
    (Output, Discrete) | (Output, Continuous) => Some(Calculated)
    (Local, Constant) => Some(Exact)
    (Local, Fixed) | (Local, Tunable) => Some(Calculated)
    (Local, Discrete) | (Local, Continuous) => Some(Calculated)
    (Independent, _) => None
    _ => None
  }
}

///|
/// The variability values allowed for a causality.
pub fn allowed_variabilities(causality : Causality) -> Array[Variability] {
  match causality {
    StructuralParameter => [Fixed, Tunable]
    Parameter => [Fixed, Tunable]
    CalculatedParameter => [Fixed, Tunable]
    Input => [Discrete, Continuous]
    Output => [Constant, Discrete, Continuous]
    Local => [Constant, Fixed, Tunable, Discrete, Continuous]
    Independent => [Continuous]
  }
}

///|
/// The `initial` values allowed for a legal causality/variability pair,
/// mirroring FMPy's `legal_combinations` set. `None` marks pairs where an
/// explicit initial is forbidden (`independent`) or illegal outright.
pub fn allowed_initials(
  causality : Causality,
  variability : Variability,
) -> Array[Initial]? {
  match (causality, variability) {
    (StructuralParameter, Fixed) | (StructuralParameter, Tunable) =>
      Some([Exact])
    (Parameter, Fixed) | (Parameter, Tunable) => Some([Exact])
    (CalculatedParameter, Fixed) | (CalculatedParameter, Tunable) =>
      Some([Calculated, Approx])
    (Input, Discrete) | (Input, Continuous) => Some([Exact])
    (Output, Constant) => Some([Exact])
    (Output, Discrete) | (Output, Continuous) =>
      Some([Calculated, Exact, Approx])
    (Local, Constant) => Some([Exact])
    (Local, Fixed) | (Local, Tunable) => Some([Calculated, Approx])
    (Local, Discrete) | (Local, Continuous) => Some([Calculated, Exact, Approx])
    (Independent, Continuous) => None
    _ => None
  }
}

///|
/// Whether the causality/variability pair itself is legal, ignoring
/// `initial`. Used by rule MD-012.
pub fn causality_allows_variability(
  causality : Causality,
  variability : Variability,
) -> Bool {
  let allowed = allowed_variabilities(causality)
  for candidate in allowed {
    if candidate == variability {
      return true
    }
  }
  false
}

///|
/// Effective variability of an FMI 2 variable (defaults to `continuous`).
pub fn Fmi2ScalarVariable::effective_variability(
  self : Fmi2ScalarVariable,
) -> Variability {
  default_variability_fmi2(self.variability)
}

///|
/// Effective causality of an FMI 2 variable (defaults to `local`).
pub fn Fmi2ScalarVariable::effective_causality(
  self : Fmi2ScalarVariable,
) -> Causality {
  default_causality(self.causality)
}

///|
/// Effective `initial`: the explicit value or the derived default.
pub fn Fmi2ScalarVariable::effective_initial(
  self : Fmi2ScalarVariable,
) -> Initial? {
  match self.initial {
    Some(value) => Some(value)
    None =>
      derive_initial(self.effective_causality(), self.effective_variability())
  }
}

///|
/// Effective causality of an FMI 3 variable (defaults to `local`).
pub fn Fmi3Variable::effective_causality(self : Fmi3Variable) -> Causality {
  default_causality(self.causality)
}

///|
/// Effective variability of an FMI 3 variable: explicit, or inferred from
/// the type kind when the document omits it.
pub fn Fmi3Variable::effective_variability(self : Fmi3Variable) -> Variability {
  match self.variability {
    Some(value) => value
    None => default_variability_fmi3(self.type_kind)
  }
}

///|
/// Effective `initial` of an FMI 3 variable: explicit, or derived from
/// causality and effective variability.
pub fn Fmi3Variable::effective_initial(self : Fmi3Variable) -> Initial? {
  match self.initial {
    Some(value) => Some(value)
    None =>
      derive_initial(self.effective_causality(), self.effective_variability())
  }
}
