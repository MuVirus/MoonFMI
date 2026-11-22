///|
/// The self-built clock fixture (0.8.2): `tests/clock-fmu/model.c` is a
/// minimal FMI 3 FMU with CS **and** ME interfaces plus input/output
/// clocks — the combination the official corpus lacks, since Clocks.fmu
/// is Scheduled-Execution-only. The tests compile it with clang, package
/// a deterministic zip, load it through MoonFMI's own backend and drive
/// the clock scheduling, the intermediate-update channel and a cross-FMU
/// clock connection for real. Without a compiler the whole group skips.

///|
/// Compile and package MoonfmiClocks for the running host. The C source
/// stays in `tests/clock-fmu/` (its include path is relative to the file),
/// only the binary lands in the build tree.
fn build_clock_fmu(tag : String) -> Bytes {
  let xml = @fs.read_file_to_bytes("tests/clock-fmu/modelDescription.xml") catch {
    error =>
      abort("reading clock modelDescription failed: " + io_message(error))
  }
  let (_, report) = @schema.parse_and_validate(xml)
  if report.error_count() > 0 {
    abort(
      "clock modelDescription failed validation: \{report.diagnostics[0].render()}",
    )
  }
  let host_platform = host()
  let extension = match host_platform.os {
    @fmi.Windows => "dll"
    @fmi.Darwin => "dylib"
    @fmi.Linux => "so"
  }
  let platform = @fmi.fmi3_platform_dir(host_platform)
  let build_dir = absolute_path(".moonfmi-tmp/clock-build-\{tag}-\{@env.now()}")
  let binary_path = "\{build_dir}/binaries/\{platform}/MoonfmiClocks.\{extension}"
  ensure_test_dir("\{build_dir}/binaries/\{platform}")
  let flags = match host_platform.os {
    @fmi.Windows => "-O1 -shared"
    @fmi.Darwin => "-O1 -dynamiclib"
    @fmi.Linux => "-O1 -shared -fPIC"
  }
  let command = "clang \{flags} -o \"\{binary_path}\" \"tests/clock-fmu/model.c\""
  if run_shell(command) != 0L {
    abort("clang failed: \{command}")
  }
  let binary = @fs.read_file_to_bytes(binary_path) catch {
    error => abort("reading compiled clock FMU failed: " + io_message(error))
  }
  let entries : Array[(String, Bytes)] = [
    ("modelDescription.xml", xml),
    ("binaries/\{platform}/MoonfmiClocks.\{extension}", binary),
  ]
  @zip.build_deterministic_zip(entries) catch {
    error => abort("clock packaging failed: " + error.message())
  }
}

///|
fn load_clocks(
  data : Bytes,
  tag : String,
  on_intermediate_update : (@native_backend.Fmi3IntermediateUpdate) -> Bool,
) -> @native_backend.LoadedFmu3 {
  let host = host()
  @native_backend.load_fmi3_fmu(
    data,
    host~,
    temp_directory=absolute_path(".moonfmi-tmp/clock-load-\{tag}-\{@env.now()}"),
    on_intermediate_update~,
  ) catch {
    error => abort("loading MoonfmiClocks failed: " + error.message())
  }
}

///|
/// Scheduler view of the fixture's clocks, bound to one loaded instance —
/// the same shape the CLI wires for FMI 3 models with clocks.
fn clocks_scheduling(
  instance : @native_backend.Fmi3Instance,
  clocks : Array[@native_backend.SeClock],
  output_clocks : Array[UInt32],
) -> @sim.ClockScheduling {
  let infos : Array[@sim.SeClockInfo] = []
  for clock in clocks {
    let countdown = clock.variability
      is @schema.ClockIntervalVariability::Countdown
    let period : Double? = if countdown || clock.triggered {
      None
    } else {
      clock.interval_decimal
    }
    infos.push(
      @sim.SeClockInfo::new(
        value_reference=clock.value_reference,
        priority=clock.priority,
        period~,
        shift=clock.shift_decimal.unwrap_or(0.0),
        triggered=clock.triggered,
        countdown~,
      ),
    )
  }
  let trigger = @sim.ClockScheduling::trigger_all_each_step(clocks=infos)
  @sim.ClockScheduling::new(
    clocks=infos,
    trigger~,
    output_clocks~,
    get_interval=vr => {
      instance.get_interval_decimal(vr) catch {
        error =>
          raise @fmi.FmiCall(
            operation="fmi3GetIntervalDecimal",
            detail=error.message(),
          )
      }
    },
    activate_partition=(vr, activation_time) => {
      instance.activate_model_partition(vr, activation_time) catch {
        error =>
          raise @fmi.FmiCall(
            operation="fmi3ActivateModelPartition",
            detail=error.message(),
          )
      }
    },
    get_clock=vr => {
      instance.get_clock_one(vr) catch {
        error =>
          raise @fmi.FmiCall(operation="fmi3GetClock", detail=error.message())
      }
    },
  )
}

///|
/// The clock metadata is collected from the model description through the
/// same helper the loader uses for Scheduled Execution.
fn clock_fixture_metadata(
  model : @schema.Fmi3ModelDescription,
) -> (Array[@native_backend.SeClock], Array[UInt32]) {
  @native_backend.fmi3_clock_metadata(model)
}

///|
test "moonfmi clocks cs drives constant triggered and countdown clocks" {
  match compiler_probe_skip() {
    Some(reason) => {
      println("SKIP: \{reason}")
      return
    }
    None => ()
  }
  let data = build_clock_fmu("cs")
  let loaded = load_clocks(data, "cs", fn(_) { false })
  let instance = loaded.instance()
  let (metas, output_clocks) = clock_fixture_metadata(loaded.model())
  assert_eq(metas.length(), 3)
  assert_eq(output_clocks.length(), 1)
  let scheduling = clocks_scheduling(instance, metas, output_clocks)
  let config = @sim.CsConfig::new(
    start_time=0.0,
    stop_time=0.5,
    step_size=0.1,
    record=[10U, 11U, 12U],
    clocks=Some(scheduling),
  )
  let result = @sim.run_cs_simulation(instance, config~) catch {
    error => {
      let detail = error.message()
      loaded.dispose()
      abort("simulation failed: " + detail)
    }
  }
  assert_eq(result.steps(), 5)
  assert_eq(result.times().length(), 6)
  // The constant clock ticks on the grid, the triggered policy fires
  // every point, the countdown re-arms 0.2 s after each firing.
  let expected : Array[(Double, Double, Double)] = [
    (0.0, 0.0, 0.0),
    (1.0, 1.0, 0.0),
    (2.0, 2.0, 0.0),
    (3.0, 3.0, 1.0),
    (4.0, 4.0, 1.0),
    (5.0, 5.0, 2.0),
  ]
  for row, (constant, triggered, countdown) in expected {
    assert_true(
      close_enough(result.series()[0][row], constant, 0.000000000001),
      msg="constant@\{row}=\{result.series()[0][row]} vs \{constant}",
    )
    assert_true(
      close_enough(result.series()[1][row], triggered, 0.000000000001),
      msg="triggered@\{row}=\{result.series()[1][row]} vs \{triggered}",
    )
    assert_true(
      close_enough(result.series()[2][row], countdown, 0.000000000001),
      msg="countdown@\{row}=\{result.series()[2][row]} vs \{countdown}",
    )
  }
  // One intermediate update per internal 0.05 solver step; the default
  // policy never requests an early return.
  assert_true(
    instance.intermediate_update_count() == 10,
    msg="intermediate updates=\{instance.intermediate_update_count()}",
  )
  assert_eq(instance.get_int32([3U])[0], 0)
  instance.terminate()
  loaded.dispose()
}

///|
test "moonfmi clocks me runs clock rounds in event mode" {
  match compiler_probe_skip() {
    Some(reason) => {
      println("SKIP: \{reason}")
      return
    }
    None => ()
  }
  let data = build_clock_fmu("me")
  let loaded = load_clocks(data, "me", fn(_) { false })
  let instance = loaded.instance()
  let (metas, output_clocks) = clock_fixture_metadata(loaded.model())
  let scheduling = clocks_scheduling(instance, metas, output_clocks)
  let config = @sim.MeConfig::new(
    start_time=0.0,
    stop_time=0.5,
    step_size=0.1,
    record=[4U, 10U, 11U, 12U],
    clocks=Some(scheduling),
    solver=Rk4,
    state_count=1,
    event_indicator_count=0,
  )
  let result = @sim.run_me_simulation(instance, config~) catch {
    error => {
      let detail = error.message()
      loaded.dispose()
      abort("simulation failed: " + detail)
    }
  }
  // Rounds run after the initial settlement and at the one scheduled
  // event (t = 0.3, requested through completedIntegratorStep). The
  // constant clock catches up on every tick it missed (0.1/0.2/0.3 at the
  // event), the triggered clock fires once per rounds-run, clock_time
  // integrates to t.
  assert_eq(result.steps(), 5)
  assert_eq(result.events(), 1)
  assert_true(
    close_enough(result.series()[0][5], 0.5, 0.000000001),
    msg="clock_time(0.5)=\{result.series()[0][5]}",
  )
  assert_true(
    close_enough(result.series()[1][0], 1.0, 0.000000000001),
    msg="constant after initial rounds=\{result.series()[1][0]}",
  )
  assert_true(
    close_enough(result.series()[2][0], 1.0, 0.000000000001),
    msg="triggered after initial rounds=\{result.series()[2][0]}",
  )
  assert_true(
    close_enough(result.series()[1][5], 4.0, 0.000000000001),
    msg="constant after the event=\{result.series()[1][5]}",
  )
  assert_true(
    close_enough(result.series()[2][5], 2.0, 0.000000000001),
    msg="triggered after the event=\{result.series()[2][5]}",
  )
  assert_true(
    close_enough(result.series()[3][5], 1.0, 0.000000000001),
    msg="countdown after the event=\{result.series()[3][5]}",
  )
  instance.terminate()
  loaded.dispose()
}

///|
/// Instance level: the host asks for an early return through the
/// intermediate-update callback from t = 0.05 on; the FMU answers with
/// `earlyReturn = true` at the update time and the step body resumes
/// from `lastSuccessfulTime` until the communication point.
test "moonfmi clocks negotiates an early return through the callback" {
  match compiler_probe_skip() {
    Some(reason) => {
      println("SKIP: \{reason}")
      return
    }
    None => ()
  }
  let data = build_clock_fmu("early")
  let loaded = load_clocks(data, "early", fn(update) { update.time >= 0.05 })
  let instance = loaded.instance()
  instance.setup_experiment(start_time=0.0, stop_time=0.2)
  init_fmi3_cs(instance)
  let reached = @fmi.CsInstance::try_step(instance, 0.0, 0.1)
  assert_true(
    close_enough(reached, 0.1, 0.000000001),
    msg="reached \{reached} instead of 0.1",
  )
  // Two internal steps (0.05, 0.10), both past the 0.05 threshold: the
  // host requested an early return twice and the FMU honored each one.
  assert_true(
    instance.intermediate_update_count() == 2,
    msg="intermediate updates=\{instance.intermediate_update_count()}",
  )
  assert_eq(instance.get_int32([3U])[0], 2)
  instance.terminate()
  loaded.dispose()
}

///|
/// Cross-FMU clock connection over real FMUs: producer A pulses its
/// output clock on every internal solver step; after each communication
/// step the couple master observes the pulse and fires consumer B's
/// triggered input clock.
test "moonfmi clocks couple fires a real clock connection" {
  match compiler_probe_skip() {
    Some(reason) => {
      println("SKIP: \{reason}")
      return
    }
    None => ()
  }
  let data = build_clock_fmu("couple")
  let producer = load_clocks(data, "couple-a", fn(_) { false })
  let consumer = load_clocks(data, "couple-b", fn(_) { false })
  let producer_instance = producer.instance()
  let consumer_instance = consumer.instance()
  let config = @sim.CoupledConfig::new(
    start_time=0.0,
    stop_time=0.2,
    step_size=0.1,
    participants=[
      @sim.CoupledParticipant::new(
        name="producer",
        instance=producer_instance,
        record=[],
      ),
      @sim.CoupledParticipant::new(
        name="consumer",
        instance=consumer_instance,
        record=[],
      ),
    ],
    connections=[
      @sim.Coupling::new(
        from="producer",
        out_vr=9U,
        to="consumer",
        in_vr=7U,
        signal=@sim.SignalType::Clock,
      ),
    ],
    clock_hooks=[
      {
        participant: "producer",
        get_clock: vr => {
          producer_instance.get_clock_one(vr) catch {
            _ => false
          }
        },
        fire_input_clock: fn(_vr, _t) { () },
      },
      {
        participant: "consumer",
        get_clock: fn(_vr) { false },
        fire_input_clock: (vr, t) => {
          consumer_instance.activate_model_partition(vr, t) catch {
            _ => ()
          }
        },
      },
    ],
  )
  let result = @sim.run_coupled_simulation(config~) catch {
    error => {
      let detail = error.message()
      producer.dispose()
      consumer.dispose()
      abort("coupled clock run failed: " + detail)
    }
  }
  assert_eq(result.steps(), 2)
  // One pulse per communication step, one firing each: consumer B's
  // triggered counter counts the firings (vr 1).
  assert_eq(consumer_instance.get_int32([1U])[0], 2)
  // The producer never asked for an early return (default policy).
  assert_eq(producer_instance.get_int32([3U])[0], 0)
  producer.dispose()
  consumer.dispose()
}
