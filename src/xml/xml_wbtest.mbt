///|
test "default limits allow a normal model description" {
  let limits = XmlLimits::default()
  assert_true(limits.allows_size(1024))
  assert_false(limits.allows_size(limits.max_bytes + 1))
}
