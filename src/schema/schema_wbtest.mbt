///|
test "model description keeps its version" {
  let model = ModelDescription::empty(FmiVersion::V3)
  assert_eq(model.version, FmiVersion::V3)
  assert_eq(model.model_name, "")
}
