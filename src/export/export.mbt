///|
pub(all) enum ExportTarget {
  Source
  Wasm
  Native
} derive(Eq, Debug)

///|
pub extend ExportTarget with Eq::{not_equal, equal}

///|
pub extend ExportTarget with @debug.Debug::{to_repr}

///|
pub fn ExportTarget::all() -> Array[ExportTarget] {
  [ExportTarget::Source, ExportTarget::Wasm, ExportTarget::Native]
}

///|
pub struct ExportRequest {
  version : @schema.FmiVersion
  archive : @zip.ZipArchive
  target : ExportTarget
}

///|
pub fn ExportRequest::source(version : @schema.FmiVersion) -> ExportRequest {
  { version, archive: @zip.ZipArchive::new(), target: ExportTarget::Source, }
}
