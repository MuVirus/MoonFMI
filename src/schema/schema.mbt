///|
pub(all) enum FmiVersion {
  V2
  V3
} derive(Eq, Debug)

///|
pub extend FmiVersion with Eq::{not_equal, equal}

///|
pub extend FmiVersion with @debug.Debug::{to_repr}

///|
pub fn FmiVersion::all() -> Array[FmiVersion] {
  [FmiVersion::V2, FmiVersion::V3]
}

///|
pub struct ModelDescription {
  version : FmiVersion
  model_name : String
}

///|
pub fn ModelDescription::empty(version : FmiVersion) -> ModelDescription {
  { version, model_name: "", }
}

///|
pub fn default_xml_limits() -> @xml.XmlLimits {
  @xml.XmlLimits::default()
}
