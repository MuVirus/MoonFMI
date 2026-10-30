///|
/// Placeholder for the WebAssembly backend (LS-WASM / component bindings).
pub struct WasmBackend {
  component_ready : Bool
}

///|
pub fn WasmBackend::new() -> WasmBackend {
  { component_ready: false, }
}

///|
pub fn WasmBackend::is_ready(self : WasmBackend) -> Bool {
  self.component_ready
}

///|
pub fn backend_tag(fmu : @fmi.Fmu) -> String {
  "wasm:" + fmu.name()
}
