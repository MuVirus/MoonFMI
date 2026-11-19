///|
/// Export→reparse differential fuzz (security review R5). For every
/// generated model IR, exactly one of two things must hold:
///
/// 1. `ModelIr::check` reports an error diagnostic — the gate that makes
///    `export_source_fmu` refuse the IR; or
/// 2. the generated `modelDescription.xml` passes MoonFMI's own parser and
///    semantic validator (no error diagnostics).
///
/// A check-clean IR whose XML reparses with errors would be an exporter
/// defect; the fixed seed keeps any such finding reproducible. The
/// operator set exercises unknown references, unknown calls, element
/// coverage and identifier shapes the handwritten tests do not.
test "export to reparse differential fuzz with fixed seed (R5)" {
  // xorshift-style PRNG keeps the corpus deterministic across runs.
  let mut state : UInt64 = 0xA5A5A5A5DEADBEEFUL
  fn next() -> UInt64 {
    state = state * 6364136223846793005UL + 1442695040888963407UL
    let x = state
    (x ^ (x >> 29)) * 0xBF58476D1CE4E5B9UL
  }
  fn next_below(bound : UInt64) -> UInt64 {
    next() % bound
  }
  // Build one IR per operator; operator 0 is the clean baseline. Returns
  // the IR and the FMI version the XML must be validated against (arrays
  // are FMI 3 only).
  fn build(operator : UInt64) -> (ModelIr, @schema.FmiVersion) {
    let suffix = next_below(1000UL).to_string()
    let ir = match operator {
      11 =>
        // Clean scalar model with an explicit default experiment.
        ModelIr::new(
          model_name="Fuzz11_\{suffix}",
          generation_tool="moonfmi-reparse-fuzz",
          default_experiment=IrDefaultExperiment::new(
            start_time=0.0,
            stop_time=2.0,
            step_size=Some(0.1),
            tolerance=Some(0.0001),
          ),
        )
      _ =>
        ModelIr::new(
          model_name="Fuzz\{operator}_\{suffix}",
          generation_tool="moonfmi-reparse-fuzz",
        )
    }
    ir.add_interface(
      kind=@schema.InterfaceKind::CoSimulation,
      model_identifier="Fuzz\{operator}",
    )
    match operator {
      // 5: the state gets two derivative equations (double coverage).
      5 => {
        let state_var = ir.add_real_state(name="x", start=1.0)
        ignore(state_var)
        ir.add_derivative(
          state="x",
          expr=IrExpr::mul(IrExpr::v("x"), IrExpr::c(-2.0)),
        )
        ir.add_derivative(
          state="x",
          expr=IrExpr::mul(IrExpr::v("x"), IrExpr::c(-3.0)),
        )
        ignore(ir.add_real_output(name="y"))
        ir.add_output_equation(output="y", expr=IrExpr::v("x"))
      }
      // 6: output equation missing for a declared output.
      6 => {
        let state_var = ir.add_real_state(name="x", start=1.0)
        ignore(state_var)
        ir.add_derivative(
          state="x",
          expr=IrExpr::mul(IrExpr::c(-2.0), IrExpr::v("x")),
        )
        ignore(ir.add_real_output(name="y"))
      }
      // 7: unknown call in the expression.
      7 => {
        let state_var = ir.add_real_state(name="x", start=1.0)
        ignore(state_var)
        ir.add_derivative(
          state="x",
          expr=IrExpr::call("cbrt", [IrExpr::v("x")]),
        )
        ignore(ir.add_real_output(name="y"))
        ir.add_output_equation(output="y", expr=IrExpr::v("x"))
      }
      // 9: array state with an out-of-range element equation (FMI 3).
      9 => {
        ir.add_interface(
          kind=@schema.InterfaceKind::ModelExchange,
          model_identifier="Fuzz9",
        )
        let array_var = ir.add_real_state_array(name="x", size=3U, start=[
          1.0, 2.0, 3.0,
        ])
        ignore(array_var)
        ir.add_derivative_element(
          state="x",
          element=99L,
          expr=IrExpr::mul(IrExpr::elem("x", 0L), IrExpr::c(-1.0)),
        )
        return (ir, @schema.FmiVersion::V3)
      }
      // 10: array state with only element 0 covered (FMI 3).
      10 => {
        ir.add_interface(
          kind=@schema.InterfaceKind::ModelExchange,
          model_identifier="Fuzz10",
        )
        let array_var = ir.add_real_state_array(name="x", size=2U, start=[
          1.0, 2.0,
        ])
        ignore(array_var)
        ir.add_derivative_element(
          state="x",
          element=0L,
          expr=IrExpr::neg(IrExpr::elem("x", 0L)),
        )
        return (ir, @schema.FmiVersion::V3)
      }
      // 11: clean scalar model (the default experiment is passed to the
      // constructor above).
      11 => {
        let state_var = ir.add_real_state(name="x", start=1.0)
        ignore(state_var)
        ir.add_derivative(
          state="x",
          expr=IrExpr::mul(IrExpr::v("x"), IrExpr::c(-1.0)),
        )
        ignore(ir.add_real_output(name="y"))
        ir.add_output_equation(output="y", expr=IrExpr::v("x"))
      }
      // 12: array input → element-wise output with a leftover uncovered
      // element (FMI 3, negative case).
      12 => {
        ir.add_interface(
          kind=@schema.InterfaceKind::CoSimulation,
          model_identifier="Fuzz12",
        )
        let input_var = ir.add_real_input_array(name="u", size=2U, start=[
          0.0, 0.0,
        ])
        ignore(input_var)
        let output_var = ir.add_real_output_array(name="y", size=2U)
        ignore(output_var)
        ir.add_output_equation_element(
          output="y",
          element=0L,
          expr=IrExpr::elem("u", 0L),
        )
        return (ir, @schema.FmiVersion::V3)
      }
      // Operators 0 (clean), 1 (unknown derivative reference), 2 (mul
      // chain), 3 (unknown output reference), 4/8 (space in identifier)
      // all build the same scalar shape.
      _ => {
        let name = match operator {
          4 | 8 => "my x"
          _ => "x"
        }
        let state_var = ir.add_real_state(name~, start=1.0)
        ignore(state_var)
        let derivative = match operator {
          1 => IrExpr::v("ghost_\{suffix}")
          2 =>
            IrExpr::mul(
              IrExpr::mul(IrExpr::v(name), IrExpr::c(2.0)),
              IrExpr::c(-1.0),
            )
          _ => IrExpr::mul(IrExpr::v(name), IrExpr::c(-2.0))
        }
        ir.add_derivative(state=name, expr=derivative)
        ignore(ir.add_real_output(name="y"))
        let output = match operator {
          3 => IrExpr::v("ghost_out_\{suffix}")
          _ => IrExpr::v(name)
        }
        ir.add_output_equation(output="y", expr=output)
      }
    }
    (ir, @schema.FmiVersion::V2)
  }
  let mut accepted = 0
  let mut rejected = 0
  for _iteration = 0; _iteration < 240; _iteration = _iteration + 1 {
    let operator = next_below(13UL)
    let (ir, version) = build(operator)
    let diagnostics = ir.check()
    let has_error = diagnostics
      .iter()
      .any(fn(d) { d.severity is @schema.Severity::Error })
    if has_error {
      // The export gate refuses the IR; nothing further is required.
      rejected += 1
      continue
    }
    // Check-clean IR: the generated XML must reparse without errors.
    let xml = model_description_xml(ir, version) catch {
      error =>
        abort(
          "operator \{operator}: check-clean IR failed to generate XML: \{error.message()}",
        )
    }
    let (_, report) = @schema.parse_and_validate(@utf8.encode(xml))
    if report.error_count() > 0 {
      let rendered = report.diagnostics().map(fn(d) { d.render() }).join(" | ")
      abort(
        "operator \{operator}: check-clean IR produced invalid XML: \{rendered}",
      )
    }
    accepted += 1
  }
  // Both sides of the differential must be exercised by the corpus.
  assert_true(accepted > 0, msg="fuzz must accept some IRs")
  assert_true(rejected > 0, msg="fuzz must reject some IRs")
}

///|
/// The export gate itself: an IR that fails its own check must make
/// `export_source_fmu` refuse before anything is generated.
test "export_source_fmu refuses a check-failing IR (R5 gate)" {
  let ir = ModelIr::new(
    model_name="GateRefusal",
    generation_tool="moonfmi-reparse-fuzz",
  )
  ir.add_interface(
    kind=@schema.InterfaceKind::CoSimulation,
    model_identifier="GateRefusal",
  )
  let state_var = ir.add_real_state(name="x", start=1.0)
  ignore(state_var)
  ir.add_derivative(state="x", expr=IrExpr::v("ghost"))
  ignore(ir.add_real_output(name="y"))
  ir.add_output_equation(output="y", expr=IrExpr::v("x"))
  let diagnostics = ir.check()
  assert_true(
    diagnostics.iter().any(fn(d) { d.severity is @schema.Severity::Error }),
    msg="the unknown reference must be a check error",
  )
  let stamp = @env.now()
  let options = ExportOptions::new(
    fmi_version=@schema.FmiVersion::V2,
    output_dir=Some(".moonfmi-tmp/export-gate-\{stamp}"),
  )
  let outcome = Ok(export_source_fmu(ir, options)) catch {
    error => Err(error.message())
  }
  match outcome {
    Ok(_) => abort("export must refuse the check-failing IR")
    Err(_) => ()
  }
}
