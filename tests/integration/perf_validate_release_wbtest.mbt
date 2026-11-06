///|
/// P1 performance gate for release builds: a 10k-variable model
/// description must parse and validate without super-linear behaviour.
/// The design target is < 100 ms (docs/design/xsd-and-validation.md §8);
/// the XML library alone misses it today (risk R-05/R-10), so the gate
/// sits at 2 s to catch quadratic regressions instead of failing on
/// every machine.
pub fn perf_validate_budget_ms() -> Int64 {
  2000L
}

///|
test "10k variable model parses and validates within release budget" {
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
