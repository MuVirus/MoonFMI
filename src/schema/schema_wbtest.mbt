///|
test "fmi version identity attribute" {
  assert_eq(FmiVersion::V2.identity_attribute(), "guid")
  assert_eq(FmiVersion::V3.identity_attribute(), "instantiationToken")
}
