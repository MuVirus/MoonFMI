///|
/// Placeholder for the native backend (dlopen / LoadLibraryW + C shim).
pub struct NativeBackend {
  loaded : Bool
}

///|
pub fn NativeBackend::new() -> NativeBackend {
  { loaded: false, }
}

///|
pub fn NativeBackend::is_loaded(self : NativeBackend) -> Bool {
  self.loaded
}

///|
pub fn backend_tag(fmu : @fmi.Fmu) -> String {
  "native:" + fmu.name()
}
