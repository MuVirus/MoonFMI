///|
pub struct Fmu {
  name : String
  version : @schema.FmiVersion
  archive : @zip.ZipArchive
}

///|
pub fn Fmu::placeholder() -> Fmu {
  {
    name: "placeholder",
    version: @schema.FmiVersion::V2,
    archive: @zip.ZipArchive::new(),
  }
}

///|
pub fn Fmu::name(self : Fmu) -> String {
  self.name
}

///|
pub fn Fmu::version(self : Fmu) -> @schema.FmiVersion {
  self.version
}

///|
pub fn Fmu::entry_count(self : Fmu) -> Int32 {
  self.archive.entry_count()
}
