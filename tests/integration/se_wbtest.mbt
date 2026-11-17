///|
/// FMI 3 Scheduled Execution integration (roadmap: SE). The Clocks FMU from
/// Reference-FMUs is SE-only and exercises every clock flavour: a constant
/// input clock (inClock1, interval 1, priority 0), a triggered input clock
/// (inClock2, priority 1 — the host policy decides), a countdown input
/// clock (inClock3, priority 2 — armed by partition 1 at t=4), and an
/// output clock (outClock, set by the FMU, observed via GetClock).
///
/// Reference timeline from the model description (t = 0..9):
///   inClock1 + + + + + + + + + +
///   inClock2 + +         + +
///   inClock3         +
/// with outClock firing whenever totalInClockTicks % 5 == 0.
test "fmi3 se clocks reference timeline" {
  let data = @fs.read_file_to_bytes(fmu_path("fmi3/Clocks.fmu")) catch {
    error => abort("reading Clocks failed: " + io_message(error))
  }
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let directory = absolute_path(".moonfmi-tmp/se-clocks-\{@env.now()}")
  let platform = host()
  let loaded = @native_backend.load_fmi3_se_fmu(
    data,
    host=platform,
    temp_directory=directory,
  ) catch {
    error => abort("loading Clocks failed: " + error.message())
  }
  assert_true(
    loaded.instance().supports_scheduled_execution(),
    msg="Clocks exports the SE group",
  )
  // Loader-derived clock metadata: three host-driven input clocks.
  assert_eq(loaded.clocks.length(), 3)
  assert_eq(loaded.clocks[0].value_reference, 1001U)
  assert_eq(
    loaded.clocks[0].variability,
    @schema.ClockIntervalVariability::Constant,
  )
  assert_eq(loaded.clocks[1].value_reference, 1002U)
  assert_eq(
    loaded.clocks[1].variability,
    @schema.ClockIntervalVariability::Triggered,
  )
  assert_eq(loaded.clocks[2].value_reference, 1003U)
  assert_eq(
    loaded.clocks[2].variability,
    @schema.ClockIntervalVariability::Countdown,
  )
  assert_eq(loaded.output_clocks, [1005U])
  // Scheduler view: inClock1 has a known period; inClock2 is triggered;
  // inClock3 is a countdown polled through fmi3GetIntervalDecimal.
  let clocks = [
    @sim.SeClockInfo::new(value_reference=1001U, priority=0U, period=Some(1.0)),
    @sim.SeClockInfo::new(value_reference=1002U, priority=1U, triggered=true),
    @sim.SeClockInfo::new(value_reference=1003U, priority=2U, countdown=true),
  ]
  // Host policy for the triggered inClock2: fire at 0, 1, 8, 9 — exactly
  // the reference timeline of the model description.
  let fire_times : Array[Double] = [0.0, 1.0, 8.0, 9.0]
  let trigger = fn(t : Double) -> Array[UInt32] {
    let due : Array[UInt32] = []
    for f in fire_times {
      if (f - t).abs() <= 0.000000001 {
        due.push(1002U)
      }
    }
    due
  }
  let config = @sim.SeConfig::new(
    start_time=0.0,
    stop_time=10.0,
    step_size=1.0,
    record=[],
    trigger~,
    output_clocks=[1005U],
  )
  let result = @sim.run_se_simulation(loaded.instance(), clocks~, config~) catch {
    error => {
      let detail = error.message()
      loaded.dispose()
      abort("SE simulation failed: " + detail)
    }
  }
  // Grid: t = 0..10 with one record per point; 15 activations in total
  // (10 x inClock1 + 4 x inClock2 + 1 x inClock3).
  assert_eq(result.steps(), 10)
  assert_eq(result.times().length(), 11)
  assert_eq(result.events(), 15)
  // The FMU acknowledged the output-clock activations through clockUpdate.
  assert_eq(loaded.instance().clock_update_count(), 4L)
  // Final tick counters (GetInt32 is legal in the Terminated state).
  let ticks1 = loaded.instance().get_int32([2001U]) catch {
      error => abort("reading inClock1Ticks failed: " + error.message())
    }
  let ticks2 = loaded.instance().get_int32([2002U]) catch {
      error => abort("reading inClock2Ticks failed: " + error.message())
    }
  let ticks3 = loaded.instance().get_int32([2003U]) catch {
      error => abort("reading inClock3Ticks failed: " + error.message())
    }
  let total = loaded.instance().get_int32([2004U]) catch {
      error => abort("reading totalInClockTicks failed: " + error.message())
    }
  assert_eq(ticks1, [10], msg="inClock1Ticks")
  assert_eq(ticks2, [4], msg="inClock2Ticks (host policy 0,1,8,9)")
  assert_eq(ticks3, [1], msg="inClock3Ticks (countdown fired at t=4)")
  assert_eq(total, [15], msg="totalInClockTicks")
  loaded.dispose()
}

///|
/// A mock SE instance for scheduler unit tests: the activation log makes
/// priority ordering and the countdown cascade observable without a native
/// FMU.
struct MockSeInstance {
  activations : Array[(UInt32, Double)]
  countdown : Map[UInt32, Double]
  /// Clocks whose Changed qualifier has already been reported once;
  /// subsequent polls report Unchanged (like a real FMU).
  reported_changed : Map[UInt32, Bool]
  mut finished : Bool
}

///|
fn MockSeInstance::new(
  activations~ : Array[(UInt32, Double)],
  countdown~ : Map[UInt32, Double],
) -> MockSeInstance {
  { activations, countdown, reported_changed: Map([]), finished: false, }
}

///|
pub impl @fmi.SeInstance for MockSeInstance with fn setup_experiment(
  self,
  start~,
  stop~,
) {
  let _ = self
  let _ = start
  let _ = stop
}

///|
pub impl @fmi.SeInstance for MockSeInstance with fn initialize(self) {
  let _ = self
}

///|
pub impl @fmi.SeInstance for MockSeInstance with fn activate_partition(
  self,
  clock_reference,
  activation_time,
) {
  self.activations.push((clock_reference, activation_time))
}

///|
pub impl @fmi.SeInstance for MockSeInstance with fn set_clock(
  self,
  reference,
  active,
) {
  let _ = self
  let _ = reference
  let _ = active
}

///|
pub impl @fmi.SeInstance for MockSeInstance with fn get_clock(self, reference) {
  let _ = self
  let _ = reference
  false
}

///|
pub impl @fmi.SeInstance for MockSeInstance with fn get_interval(
  self,
  reference,
) {
  match self.countdown.get(reference) {
    Some(remaining) =>
      match self.reported_changed.get(reference) {
        Some(true) => Some((remaining, @fmi.IntervalQualifier::Unchanged))
        _ => {
          self.reported_changed[reference] = true
          Some((remaining, @fmi.IntervalQualifier::Changed))
        }
      }
    None => None
  }
}

///|
pub impl @fmi.SeInstance for MockSeInstance with fn read_real(
  self,
  value_reference,
) {
  let _ = self
  let _ = value_reference
  0.0
}

///|
pub impl @fmi.SeInstance for MockSeInstance with fn write_real(
  self,
  value_reference,
  value,
) {
  let _ = self
  let _ = value_reference
  let _ = value
}

///|
pub impl @fmi.SeInstance for MockSeInstance with fn finish(self) {
  self.finished = true
}

///|
test "se scheduler orders same-instant activations by priority" {
  // Three clocks due at t=0: two constant (priority 0 and 1) and one
  // countdown that has already expired (priority 2). The mock records the
  // activation order; the scheduler must sort by priority, not by
  // declaration order.
  let activations : Array[(UInt32, Double)] = []
  let countdown : Map[UInt32, Double] = { 3U: 0.0 }
  let instance = MockSeInstance::new(activations~, countdown~)
  let clocks = [
    @sim.SeClockInfo::new(value_reference=2U, priority=1U, period=Some(10.0)),
    @sim.SeClockInfo::new(value_reference=1U, priority=0U, period=Some(10.0)),
    @sim.SeClockInfo::new(value_reference=3U, priority=2U, countdown=true),
  ]
  let config = @sim.SeConfig::new(
    start_time=0.0,
    stop_time=1.0,
    step_size=1.0,
    record=[],
  )
  let result = @sim.run_se_simulation(instance, clocks~, config~)
  assert_eq(
    instance.activations,
    [(1U, 0.0), (2U, 0.0), (3U, 0.0)],
    msg="activation order",
  )
  assert_eq(result.events(), 3)
  assert_true(instance.finished, msg="scheduler terminates the instance")
}

///|
test "se scheduler rejects broken configuration" {
  let activations : Array[(UInt32, Double)] = []
  let countdown : Map[UInt32, Double] = Map([])
  let instance = MockSeInstance::new(activations~, countdown~)
  let outcome : Result[@sim.SimulationResult, @fmi.SimulationError] = Ok(
    @sim.run_se_simulation(
      instance,
      clocks=[],
      config=@sim.SeConfig::new(start_time=0.0, stop_time=1.0, step_size=0.0, record=[]),
    ),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Ok(_) => abort("zero step must be rejected")
    Err(@fmi.SimulationError::Config(_)) => ()
    Err(other) => abort("unexpected error: " + other.message())
  }
}
