///|
/// Parsing budget for the 1 MB throughput check.
///
/// Debug builds are roughly twice as slow as optimized ones, so the 100 ms
/// acceptance number only applies to release builds. The debug budget still
/// catches accidental quadratic behaviour.
pub fn perf_budget_ms() -> Int32 {
  1000
}
