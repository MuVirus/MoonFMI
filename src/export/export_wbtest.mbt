///|
test "model description generation is deterministic and version tagged" {
  let ir = dahlquist_ir()
  let xml_a = model_description_xml(ir, @schema.FmiVersion::V2)
  let xml_b = model_description_xml(ir, @schema.FmiVersion::V2)
  assert_eq(xml_a, xml_b)
  // FMI 2 roots carry guid, FMI 3 roots carry instantiationToken.
  assert_true(xml_a.contains("fmiVersion=\"2.0\""))
  assert_true(xml_a.contains("guid=\"{"))
  let xml3 = model_description_xml(ir, @schema.FmiVersion::V3)
  assert_true(xml3.contains("instantiationToken=\"{"))
  assert_true(xml3.contains("<ContinuousStateDerivative"))
}

///|
test "derived guid is stable and uuid shaped" {
  let ir = dahlquist_ir()
  let guid_a = ir.derived_guid()
  let guid_b = ir.derived_guid()
  assert_eq(guid_a, guid_b)
  assert_eq(guid_a.length(), 36)
  // Changing the IR changes the identity.
  let other = dahlquist_ir()
  other.variables[0].start = Some(IrValue::Real(2.5))
  assert_true(other.derived_guid() != guid_a)
}

///|
test "ir check reports unknown equation targets" {
  let ir = dahlquist_ir()
  assert_eq(ir.check().length(), 0)
  let broken = dahlquist_ir()
  broken.add_derivative(state="missing", expr=IrExpr::Const(1.0))
  let diagnostics = broken.check()
  assert_true(diagnostics.length() > 0)
  assert_true(diagnostics[0].code == "EX-010")
}

///|
/// Shared fixture (lives in ir.mbt as the public example builder):
/// `x' = -k*x, y = x` with k parameter, one state, one output.
pub fn dahlquist_ir() -> ModelIr {
  dahlquist_example_ir()
}

///|
test "units are written for both schema versions" {
  let ir = dahlquist_example_ir()
  ir.units.push(
    @schema.UnitDef::simple(
      name="1/s",
      base=@schema.BaseUnit::of(s=1, factor=-1.0),
    ),
  )
  match ir.index_of("k") {
    Some(index) => ir.variables[index].unit = Some("1/s")
    None => abort("k must exist")
  }
  let xml = model_description_xml(ir, @schema.FmiVersion::V2)
  assert_true(xml.contains("<UnitDefinitions>"))
  assert_true(xml.contains("<Unit name=\"1/s\">"))
  assert_true(xml.contains("<BaseUnit s=\"1\" factor=\"-1\""))
  assert_true(xml.contains("unit=\"1/s\""))
  let xml3 = model_description_xml(ir, @schema.FmiVersion::V3)
  assert_true(xml3.contains("<UnitDefinitions>"))
}

///|
test "fmi 3 arrays emit dimension elements and fmi 2 rejects them" {
  let ir = array_passthrough_example_ir()
  let xml3 = model_description_xml(ir, @schema.FmiVersion::V3)
  assert_true(xml3.contains("<Float64 name=\"u\" valueReference=\"0\""))
  assert_true(xml3.contains("start=\"1 2 3\""))
  assert_true(xml3.contains("<Dimension start=\"3\"/>"))
  assert_true(xml3.contains("<Float64 name=\"y\" valueReference=\"1\""))
  // FMI 2 has no dimensions: the export must refuse the model instead of
  // emitting invalid XML.
  let outcome : Result[ExportResult, ExportError] = Ok(
    export_source_fmu(
      ir,
      ExportOptions::new(fmi_version=@schema.FmiVersion::V2, write_fmu=false),
    ),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Ok(_) => abort("FMI 2 export must reject arrays")
    Err(error) => assert_true(error.message().contains("dimension"))
  }
}

///|
test "wasm export writes the component tree" {
  let ir = dahlquist_ir()
  let result = export_wasm_fmu(
    ir,
    ExportOptions::new(
      fmi_version=@schema.FmiVersion::V3,
      output_dir=Some(".moonfmi-tmp/wasm-export-unit"),
      write_fmu=false,
    ),
  )
  let names = result.files.map(fn(entry) { entry.0 })
  assert_true(names.contains("modelDescription.xml"))
  assert_true(names.contains("wit/moonfmidahlquist.wit"))
  assert_true(names.contains("guest/fmu_impl.mbt"))
  assert_true(names.contains("extra/org.modelica.fmi-ls-wasm/manifest.xml"))
  assert_true(names.contains("build.mjs"))
  // The model description is the FMI 3 one (LS-WASM is FMI 3 only).
  let xml = @utf8.decode_lossy(result.files[0].1.exact_view())
  assert_true(xml.contains("fmiVersion=\"3.0\""))
  // The WIT world carries the CS resource and the host log import.
  let wit = @utf8.decode_lossy(result.files[1].1.exact_view())
  assert_true(wit.contains("world moonfmidahlquist"))
  assert_true(wit.contains("resource fmu"))
  assert_true(wit.contains("do-step"))
  assert_true(wit.contains("log: func"))
  // The guest implements Euler integration and the output equation.
  let guest = @utf8.decode_lossy(result.files[2].1.exact_view())
  assert_true(guest.contains("fn State::integrate"))
  assert_true(guest.contains("dx[0]"))
  assert_true(guest.contains("s.v_y = s.v_x"))
}

///|
test "wasm export rejects non-float and array variables" {
  let ir = dahlquist_ir()
  ignore(ir.add_int_parameter(name="n", start=1L))
  let outcome : Result[ExportResult, ExportError] = Ok(
    export_wasm_fmu(
      ir,
      ExportOptions::new(
        fmi_version=@schema.FmiVersion::V3,
        output_dir=Some(".moonfmi-tmp/wasm-export-reject"),
        write_fmu=false,
      ),
    ),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Ok(_) => abort("non-float variable must be rejected")
    Err(error) =>
      assert_true(
        error.message().contains("EX-030"),
        msg="error carries EX-030: " + error.message(),
      )
  }
}
