///|
/// The supported FMI standard versions.
#derive(Eq, Debug)
pub(all) enum FmiVersion {
  V2
  V3
}

///|
pub extend FmiVersion with Eq::{not_equal, equal}

///|
pub extend FmiVersion with @debug.Debug::{to_repr}

///|
pub fn FmiVersion::all() -> Array[FmiVersion] {
  [FmiVersion::V2, FmiVersion::V3]
}

///|
/// The FMI version-specific name of the root identity attribute:
/// `guid` for FMI 2, `instantiationToken` for FMI 3.
pub fn FmiVersion::identity_attribute(self : FmiVersion) -> String {
  match self {
    V2 => "guid"
    V3 => "instantiationToken"
  }
}

///|
/// A parsed model description of either supported version. The two models
/// stay separate on purpose: FMI 3 adds arrays, new types, and aliases
/// that have no meaningful FMI 2 representation.
pub(all) enum ModelDescription {
  V2(Fmi2ModelDescription)
  V3(Fmi3ModelDescription)
}

///|
pub fn ModelDescription::version(self : ModelDescription) -> FmiVersion {
  match self {
    V2(_) => V2
    V3(_) => V3
  }
}

///|
pub fn ModelDescription::model_name(self : ModelDescription) -> String {
  match self {
    V2(model) => model.model_name
    V3(model) => model.model_name
  }
}

///|
/// Raw `fmiVersion` attribute text as written in the document.
pub fn ModelDescription::fmi_version_text(self : ModelDescription) -> String {
  match self {
    V2(model) => model.fmi_version
    V3(model) => model.fmi_version
  }
}

///|
/// Variable count across both versions (aliases excluded).
pub fn ModelDescription::variable_count(self : ModelDescription) -> Int32 {
  match self {
    V2(model) => model.variables.length()
    V3(model) => model.variables.length()
  }
}

///|
pub fn default_xml_limits() -> @xml.XmlLimits {
  @xml.XmlLimits::default()
}
