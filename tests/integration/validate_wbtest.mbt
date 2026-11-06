///|
/// End-to-end validation of the real Reference-FMUs (P1 exit criterion:
/// every sample corpus FMU must parse and validate cleanly).
fn validate_cached_fmu(relative : String) -> @schema.ValidationReport {
  let data = @fs.read_file_to_bytes(fmu_path(relative)) catch {
    error => abort("reading " + relative + " failed: " + io_message(error))
  }
  let (_, report) = @fmi.validate_fmu_bytes(data)
  report
}

///|
fn render(report : @schema.ValidationReport) -> String {
  report.diagnostics().map(fn(d) { d.render() }).join("\n")
}

///|
test "FMI 2 samples validate without diagnostics" {
  for
    relative in [
      "fmi2/BouncingBall.fmu", "fmi2/Dahlquist.fmu", "fmi2/Feedthrough.fmu", "fmi2/Resource.fmu",
    ] {
    let report = validate_cached_fmu(relative)
    assert_eq(render(report), "", msg=relative)
  }
}

///|
test "FMI 3 samples validate without diagnostics" {
  for
    relative in [
      "fmi3/BouncingBall.fmu", "fmi3/Feedthrough.fmu", "fmi3/Resource.fmu", "fmi3/StateSpace.fmu",
    ] {
    let report = validate_cached_fmu(relative)
    assert_eq(render(report), "", msg=relative)
  }
}

///|
test "parsed summaries of the reference FMUs" {
  // Cross-check a couple of parsed summaries so P2 can build on them.
  let bouncing = read_model_description("fmi2/BouncingBall.fmu")
  let model = @schema.parse_model_description(@utf8.encode(bouncing)) catch {
    _ => abort("BouncingBall model description must parse")
  }
  assert_eq(model.model_name(), "BouncingBall")
  assert_eq(model.variable_count(), 8)
  let statespace = read_model_description("fmi3/StateSpace.fmu")
  let model3 = @schema.parse_model_description(@utf8.encode(statespace)) catch {
    _ => abort("StateSpace model description must parse")
  }
  assert_eq(model3.version(), @schema.FmiVersion::V3)
}
