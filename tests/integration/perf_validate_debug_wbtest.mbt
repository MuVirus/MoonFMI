///|
/// Debug-build counterpart of the 10k-variable performance gate.
pub fn perf_validate_budget_ms() -> Int64 {
  10000L
}

///|
test "10k variable model parses and validates within debug budget" {
  let xml = generate_large_model(10000)
  let data = @utf8.encode(xml)
  let start = @env.now()
  let (model, report) = @fmi.validate_fmu_bytes(data)
  let elapsed = @env.now() - start
  assert_true(model is Some(_))
  assert_eq(report.error_count(), 0)
  assert_eq(report.warning_count(), 0)
  assert_true(elapsed < perf_validate_budget_ms().reinterpret_as_uint64())
}
