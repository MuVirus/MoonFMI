///|
test "wasm backend starts not ready" {
  let backend = WasmBackend::new()
  assert_false(backend.is_ready())
  assert_eq(backend_tag(@fmi.Fmu::placeholder()), "wasm:placeholder")
}
