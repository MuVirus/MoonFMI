///|
test "native backend starts unloaded" {
  let backend = NativeBackend::new()
  assert_false(backend.is_loaded())
  assert_eq(backend_tag(@fmi.Fmu::placeholder()), "native:placeholder")
}
