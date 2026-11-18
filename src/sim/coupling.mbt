///|
/// One participant of a coupled co-simulation run (the README "Known
/// limits" item "one FMU per run" — closed by the 2026-11-18 session).
/// The participant keeps its `CsInstance` borrowed: the coupled run drives
/// it but does not own it, so loading and `dispose()` stay with the caller.
pub struct CoupledParticipant {
  /// Unique participant name used by `Coupling` endpoints.
  name : String
  instance : &@fmi.CsInstance
  /// Value references recorded at every communication point, in series
  /// order. Real connections may only source recorded references, so this
  /// list is also the producer's observed Real-output set; Integer/Boolean
  /// connections observe their outputs through the typed surface directly
  /// and do not require the reference to be recorded here.
  record : Array[UInt32]
}

///|
pub fn CoupledParticipant::new(
  name~ : String,
  instance~ : &@fmi.CsInstance,
  record~ : Array[UInt32],
) -> CoupledParticipant {
  { name, instance, record, }
}

///|
/// The signal type one `Coupling` carries. Defaults to `Real`; Integer and
/// Boolean route through the typed `CsInstance` read/write methods instead
/// of `read_real`/`write_real`.
#derive(Eq)
pub(all) enum SignalType {
  Real
  Integer
  Boolean
}

///|
/// A directed signal connection: `from.(out_vr)` feeds `to.(in_vr)`.
/// Connections must not form a cycle unless loop solving is enabled via
/// `CoupledConfig::max_loop_iterations` — with constant extrapolation a
/// cycle is an algebraic loop, which is then solved by fixed-point
/// iteration instead of being rejected.
pub struct Coupling {
  from : String
  out_vr : UInt32
  to : String
  in_vr : UInt32
  /// Signal type carried by this connection. Both endpoints must expose
  /// variables of that type; the master cannot check the consumer's
  /// declared variable type statically, so a mismatch surfaces as an FMU
  /// error at runtime.
  signal : SignalType
}

///|
pub fn Coupling::new(
  from~ : String,
  out_vr~ : UInt32,
  to~ : String,
  in_vr~ : UInt32,
  signal~ : SignalType = Real,
) -> Coupling {
  { from, out_vr, to, in_vr, signal, }
}

///|
/// Configuration of one coupled run: several `CsInstance` participants on
/// a shared communication grid, wired by directed `Coupling` connections.
pub struct CoupledConfig {
  start_time : Double
  stop_time : Double
  step_size : Double
  participants : Array[CoupledParticipant]
  connections : Array[Coupling]
  /// Wall-clock deadline in the same unit as `@env.now()`; the loop
  /// aborts with `SimulationError::Timeout` once it is passed.
  deadline : UInt64?
  /// Maximum Jacobi iterations for solving an algebraic loop. `None`
  /// (the default) keeps the original behaviour: cycles are rejected with
  /// a `Config` error. `Some(n)` turns loop solving on; the loop block is
  /// iterated up to `n` times per communication point.
  max_loop_iterations : Int32?
  /// Convergence tolerance for loop solving: the iteration stops when
  /// every watched loop output moved by less than this (component-wise
  /// absolute difference) between two consecutive iterations.
  loop_tolerance : Double
}

///|
pub fn CoupledConfig::new(
  start_time~ : Double,
  stop_time~ : Double,
  step_size~ : Double,
  participants~ : Array[CoupledParticipant],
  connections~ : Array[Coupling],
  deadline~ : UInt64? = None,
  max_loop_iterations~ : Int32? = None,
  loop_tolerance~ : Double = 0.000000001,
) -> CoupledConfig {
  {
    start_time,
    stop_time,
    step_size,
    participants,
    connections,
    deadline,
    max_loop_iterations,
    loop_tolerance,
  }
}

///|
/// One unit of the coupled execution schedule: a single participant
/// stepped once, or — when loop solving is enabled — the participants
/// Kahn could not place (the algebraic loop together with everything
/// downstream of it), iterated to a fixed point at every communication
/// point. Simple scheme, documented in docs/design/coupling.md §3: the
/// block is the whole unplaced set, not the minimal strongly connected
/// component.
priv enum ExecUnit {
  Single(Int32)
  LoopBlock(Array[Int32])
}

///|
/// Validates the coupling and builds the execution schedule. Without loop
/// solving the schedule is the Kahn topological order (sources before
/// consumers, stable by declaration order). With `max_loop_iterations =
/// Some(n)`, a Kahn stall no longer raises: the participants Kahn could
/// not place become one `LoopBlock`, iterated to a fixed point, and a
/// self connection becomes a one-member loop block. Raises `Config` for
/// duplicate names, unknown endpoints, self connections and cycles (when
/// loop solving is off).
fn build_schedule(
  participants : Array[CoupledParticipant],
  connections : Array[Coupling],
  max_loop_iterations : Int32?,
) -> Array[ExecUnit] raise @fmi.SimulationError {
  let index_of : Map[String, Int32] = Map([])
  for index, participant in participants {
    if index_of.contains(participant.name) {
      raise @fmi.Config(
        detail="duplicate participant name '\{participant.name}'",
      )
    }
    index_of[participant.name] = index
  }
  let edges : Array[(Int32, Int32)] = []
  for connection in connections {
    let from = match index_of.get(connection.from) {
      Some(index) => index
      None =>
        raise @fmi.Config(
          detail="connection source '\{connection.from}' is not a participant",
        )
    }
    let to = match index_of.get(connection.to) {
      Some(index) => index
      None =>
        raise @fmi.Config(
          detail="connection target '\{connection.to}' is not a participant",
        )
    }
    if from == to {
      match max_loop_iterations {
        // Without loop solving a self connection is rejected upfront;
        // with loop solving it is a one-member algebraic loop the
        // fixed-point iteration below can solve.
        None =>
          raise @fmi.Config(
            detail="participant '\{connection.from}' feeds its own input; that is an algebraic loop",
          )
        Some(_) => ()
      }
    }
    edges.push((from, to))
  }
  // Kahn's algorithm, stable by declaration order: repeatedly take the
  // first participant whose inputs are all satisfied.
  let remaining_incoming : Array[Int32] = Array::make(participants.length(), 0)
  for edge in edges {
    remaining_incoming[edge.1] += 1
  }
  let order : Array[Int32] = []
  let placed : Array[Bool] = Array::make(participants.length(), false)
  let mut stalled = false
  while order.length() < participants.length() {
    let mut picked = -1
    for index, count in remaining_incoming {
      if count == 0 && !placed[index] {
        picked = index
        break
      }
    }
    if picked < 0 {
      // Kahn stalled: every unplaced participant waits on a connection
      // from another unplaced one — an algebraic loop.
      match max_loop_iterations {
        None =>
          raise @fmi.Config(
            detail="the connection graph has a cycle; constant extrapolation cannot solve algebraic loops",
          )
        Some(_) => {
          stalled = true
          break
        }
      }
    }
    placed[picked] = true
    order.push(picked)
    for edge in edges {
      if edge.0 == picked {
        remaining_incoming[edge.1] -= 1
      }
    }
  }
  let schedule : Array[ExecUnit] = []
  for index in order {
    schedule.push(Single(index))
  }
  if stalled {
    let members : Array[Int32] = []
    for index, is_placed in placed {
      if !is_placed {
        members.push(index)
      }
    }
    schedule.push(LoopBlock(members))
  }
  schedule
}

///|
/// The coupled co-simulation master. Participants run on one shared
/// communication grid (`start_time + k * step_size`, final step truncated
/// to `stop_time`) and are stepped in topological order, so every consumer
/// steps with the producer's output from the same communication point —
/// no one-step lag; docs/design/coupling.md §3. Inputs are written from the
/// producer's freshly read outputs before the consumer steps: constant
/// extrapolation over the incoming step.
///
/// Three behaviours sit on top of that base algorithm, each opt-in:
///
/// - **Coordinated rollback** (automatic): when every participant reports
///   `supports_state_capture()`, the grid point is armed on all of them;
///   any participant discarding rolls everyone back in reverse schedule
///   order and the whole grid step is halved and retried (capped at 5
///   attempts). Without full capture support, participants keep their own
///   `step` semantics and there is no retry.
/// - **Typed signal connections** (per connection): `SignalType::Integer`
///   / `Boolean` route through `read_integer`/`write_integer` and
///   `read_boolean`/`write_boolean` instead of the Real surface.
/// - **Loop solving** (`max_loop_iterations = Some(n)`): participants Kahn
///   cannot place form one block, iterated Jacobi-style to a fixed point
///   at every communication point; without it, cycles are rejected.
///
/// The recorded series of the result concatenate every participant's
/// `record` list in declaration order; the caller knows the layout from
/// its own configuration.
pub fn run_coupled_simulation(
  config~ : CoupledConfig,
) -> SimulationResult raise @fmi.SimulationError {
  if !(config.stop_time > config.start_time) {
    raise @fmi.Config(
      detail="stop_time (\{config.stop_time}) must be greater than start_time (\{config.start_time})",
    )
  }
  if !(config.step_size > 0.0) {
    raise @fmi.Config(detail="step_size must be positive")
  }
  match config.max_loop_iterations {
    Some(iterations) =>
      if iterations <= 0 {
        raise @fmi.Config(detail="max_loop_iterations must be positive")
      }
    None => ()
  }
  if !(config.loop_tolerance >= 0.0) {
    raise @fmi.Config(detail="loop_tolerance must not be negative")
  }
  let schedule = build_schedule(
    config.participants,
    config.connections,
    config.max_loop_iterations,
  )
  // Resolve connections into per-participant input plans: for participant
  // index p, the plan lists (local input vr, producer index, producer vr,
  // signal type). The same pass collects, per producer, the outputs its
  // connections source with their types — the observed-output set — and
  // rejects one output sourced with different signal types.
  let index_of : Map[String, Int32] = Map([])
  for index, participant in config.participants {
    index_of[participant.name] = index
  }
  let input_plans : Array[Array[(UInt32, Int32, UInt32, SignalType)]] = []
  let watch : Array[Array[(UInt32, SignalType)]] = []
  let source_types : Array[Map[UInt32, SignalType]] = []
  for _ in config.participants {
    input_plans.push([])
    watch.push([])
    source_types.push(Map([]))
  }
  for connection in config.connections {
    let from = index_of[connection.from]
    let to = index_of[connection.to]
    input_plans[to].push(
      (connection.in_vr, from, connection.out_vr, connection.signal),
    )
    watch[from].push((connection.out_vr, connection.signal))
    match source_types[from].get(connection.out_vr) {
      Some(existing) =>
        if existing != connection.signal {
          raise @fmi.Config(
            detail="output vr \{connection.out_vr} of '\{connection.from}' is sourced by connections with different signal types",
          )
        }
      None => source_types[from][connection.out_vr] = connection.signal
    }
  }
  // Setup and initialize everyone in declaration order.
  for participant in config.participants {
    participant.instance.setup_experiment(
      start=config.start_time,
      stop=Some(config.stop_time),
    )
    participant.instance.initialize()
  }
  // Latest observed outputs per participant. The Real map covers the
  // record list (read once up front so the initial inputs and the initial
  // row come from the same state); the typed maps cover the outputs
  // sourced by Integer/Boolean connections, read through the typed
  // surface.
  let observed_real : Array[Map[UInt32, Double]] = []
  let observed_integer : Array[Map[UInt32, Int32]] = []
  let observed_boolean : Array[Map[UInt32, Bool]] = []
  for participant in config.participants {
    let map : Map[UInt32, Double] = Map([])
    for value_reference in participant.record {
      map[value_reference] = participant.instance.read_real(value_reference)
    }
    observed_real.push(map)
    observed_integer.push(Map([]))
    observed_boolean.push(Map([]))
  }
  for index, participant in config.participants {
    for entry in watch[index] {
      let (value_reference, signal) = entry
      match signal {
        Real => () // observed through the record list above
        Integer =>
          observed_integer[index][value_reference] = participant.instance.read_integer(
            value_reference,
          )
        Boolean =>
          observed_boolean[index][value_reference] = participant.instance.read_boolean(
            value_reference,
          )
      }
    }
  }
  let write_inputs = fn(producer_index : Int32) raise @fmi.SimulationError {
    for plan in input_plans[producer_index] {
      let (input_vr, from, out_vr, signal) = plan
      match signal {
        Real =>
          match observed_real[from].get(out_vr) {
            Some(value) =>
              config.participants[producer_index].instance.write_real(
                input_vr, value,
              )
            None =>
              raise @fmi.Config(
                detail="connection out_vr \{out_vr} of '\{config.participants[from].name}' is not in its record list, so the coupled run cannot observe it",
              )
          }
        Integer =>
          match observed_integer[from].get(out_vr) {
            Some(value) =>
              config.participants[producer_index].instance.write_integer(
                input_vr, value,
              )
            None =>
              raise @fmi.Config(
                detail="connection out_vr \{out_vr} of '\{config.participants[from].name}' is not observable by the coupled run",
              )
          }
        Boolean =>
          match observed_boolean[from].get(out_vr) {
            Some(value) =>
              config.participants[producer_index].instance.write_boolean(
                input_vr, value,
              )
            None =>
              raise @fmi.Config(
                detail="connection out_vr \{out_vr} of '\{config.participants[from].name}' is not observable by the coupled run",
              )
          }
      }
    }
  }
  let refresh_observed = fn(producer_index : Int32) raise @fmi.SimulationError {
    let participant = config.participants[producer_index]
    let instance = participant.instance
    for value_reference in participant.record {
      observed_real[producer_index][value_reference] = instance.read_real(
        value_reference,
      )
    }
    for entry in watch[producer_index] {
      let (value_reference, signal) = entry
      match signal {
        Real => () // the record refresh above covers Real outputs
        Integer =>
          observed_integer[producer_index][value_reference] = instance.read_integer(
            value_reference,
          )
        Boolean =>
          observed_boolean[producer_index][value_reference] = instance.read_boolean(
            value_reference,
          )
      }
    }
  }
  // One watched output as a number, for the loop residual: Real from the
  // record-observed map, Integer/Boolean through their typed maps.
  let loop_component = fn(
    producer_index : Int32,
    value_reference : UInt32,
    signal : SignalType,
  ) -> Double {
    match signal {
      Real =>
        match observed_real[producer_index].get(value_reference) {
          Some(value) => value
          None => 0.0
        }
      Integer =>
        match observed_integer[producer_index].get(value_reference) {
          Some(value) => value.to_double()
          None => 0.0
        }
      Boolean =>
        match observed_boolean[producer_index].get(value_reference) {
          Some(value) => if value { 1.0 } else { 0.0 }
          None => 0.0
        }
    }
  }
  // Coordinated rollback applies only when EVERY participant can capture
  // and restore FMU state; otherwise every participant keeps its own
  // `step` semantics (no coordinated retry, per-participant Discard
  // handling stays with the backend).
  let mut coordinated = true
  for participant in config.participants {
    if !participant.instance.supports_state_capture() {
      coordinated = false
      break
    }
  }
  let step_participant = fn(
    producer_index : Int32,
    t : Double,
    h : Double,
  ) raise @fmi.SimulationError {
    let instance = config.participants[producer_index].instance
    if coordinated {
      // Coordinated mode steps through `try_step` so a Discard surfaces
      // as `Discarded` for the master instead of the backend reacting on
      // its own.
      let _ = instance.try_step(t, h)
    } else {
      instance.step(t, h)
    }
  }
  // Participants in schedule order and its reverse, for the coordinated
  // begin/commit (schedule order) and rollback (reverse) passes.
  let schedule_order : Array[Int32] = []
  for unit in schedule {
    match unit {
      Single(index) => schedule_order.push(index)
      LoopBlock(members) =>
        for peer in members {
          schedule_order.push(peer)
        }
    }
  }
  let rollback_order : Array[Int32] = []
  let mut cursor = schedule_order.length() - 1
  while cursor >= 0 {
    rollback_order.push(schedule_order[cursor])
    cursor -= 1
  }
  // Recording: one timestamp per row; the series are laid out per
  // participant (declaration order), each with `record.length()` slots.
  let times : Array[Double] = []
  let series : Array[Array[Double]] = []
  let series_offset : Array[Int32] = []
  let mut width = 0
  for participant in config.participants {
    series_offset.push(width)
    for _ in participant.record {
      series.push([])
    }
    width += participant.record.length()
  }
  let record_row = fn(t : Double) raise @fmi.SimulationError {
    times.push(t)
    let mut slot = 0
    for participant in config.participants {
      for value_reference in participant.record {
        series[slot].push(participant.instance.read_real(value_reference))
        slot += 1
      }
    }
    let _ = width
  }
  // One pass over the schedule at communication point t with step h.
  // Loop blocks iterate to a fixed point here (Jacobi): every block
  // member's inputs are written from the current snapshots, then all
  // members step, then the watched outputs are compared against the
  // previous iteration; converged when none moved by more than
  // `loop_tolerance`, capped at `max_loop_iterations` iterations.
  let execute_grid_point = fn(
    t : Double,
    h : Double,
  ) raise @fmi.SimulationError {
    for unit in schedule {
      match unit {
        Single(producer_index) => {
          write_inputs(producer_index)
          step_participant(producer_index, t, h)
          refresh_observed(producer_index)
        }
        LoopBlock(members) => {
          let max_iterations = match config.max_loop_iterations {
            Some(iterations) => iterations
            // unreachable: a block exists only when loop solving is on
            None => 0
          }
          let mut iterations = 0
          let mut residual = 0.0
          let mut settled = false
          while !settled {
            iterations += 1
            let baseline : Array[(Int32, UInt32, SignalType, Double)] = []
            for peer in members {
              for entry in watch[peer] {
                let (value_reference, signal) = entry
                baseline.push(
                  (
                    peer,
                    value_reference,
                    signal,
                    loop_component(peer, value_reference, signal),
                  ),
                )
              }
            }
            for peer in members {
              write_inputs(peer)
            }
            for peer in members {
              step_participant(peer, t, h)
              refresh_observed(peer)
            }
            residual = 0.0
            for entry in baseline {
              let (peer, value_reference, signal, before) = entry
              let delta = (loop_component(peer, value_reference, signal) -
              before).abs()
              if delta > residual {
                residual = delta
              }
            }
            if residual <= config.loop_tolerance {
              settled = true
            } else if iterations >= max_iterations {
              let mut names = ""
              for index, peer in members {
                if index > 0 {
                  names = names + ", "
                }
                names = names + config.participants[peer].name
              }
              raise @fmi.Config(
                detail="the algebraic loop over [\{names}] did not converge within \{iterations} iterations (last residual \{residual}, tolerance \{config.loop_tolerance})",
              )
            }
          }
        }
      }
    }
  }
  // Initial grid point: propagate initial outputs to the inputs, record.
  // Loop blocks are not solved at t0 — the FMU-provided initial outputs
  // are used as-is (no stepping happens at t0 to iterate against).
  for unit in schedule {
    match unit {
      Single(producer_index) => write_inputs(producer_index)
      LoopBlock(members) =>
        for peer in members {
          write_inputs(peer)
        }
    }
  }
  record_row(config.start_time)
  let mut t = config.start_time
  let mut steps = 0
  while t < config.stop_time - time_epsilon {
    match config.deadline {
      Some(deadline) =>
        if @env.now() > deadline {
          raise @fmi.Timeout(detail="t=\{t}")
        }
      None => ()
    }
    let mut h = config.step_size
    if t + h > config.stop_time {
      h = config.stop_time - t
    }
    if coordinated {
      // Coordinated rollback (all participants capture): one rollback
      // point per participant arms the whole grid point; any participant
      // discarding rolls EVERYONE back in reverse schedule order and the
      // entire grid step is halved and retried — no participant is halved
      // on its own in this mode. Capped at `max_discard_retries` with the
      // `min_retry_step` floor, like the single-FMU master.
      let mut attempts = 0
      let mut settled = false
      while !settled {
        attempts += 1
        if attempts > max_discard_retries {
          raise @fmi.Config(
            detail="the coupled step at t=\{t} was discarded \{max_discard_retries} times without converging",
          )
        }
        for index in schedule_order {
          config.participants[index].instance.begin_rollback_point()
        }
        let mut completed = true
        execute_grid_point(t, h) catch {
          error =>
            match error {
              Discarded(..) => {
                for index in rollback_order {
                  config.participants[index].instance.rollback()
                }
                completed = false
              }
              other => {
                // The run aborts; release every armed capture so the
                // state handles do not outlive the step (backends also
                // free an armed state when the instance is torn down).
                for index in schedule_order {
                  config.participants[index].instance.commit_rollback_point() catch {
                    _ => ()
                  }
                }
                raise other
              }
            }
        }
        if completed {
          for index in schedule_order {
            config.participants[index].instance.commit_rollback_point()
          }
          settled = true
        } else {
          let retried = h / 2.0
          if !(retried >= min_retry_step) {
            raise @fmi.Config(
              detail="coupled discarded step at t=\{t}: halved step \{retried} is below the \{min_retry_step} retry floor",
            )
          }
          h = retried
        }
      }
    } else {
      execute_grid_point(t, h)
    }
    t = t + h
    record_row(t)
    steps += 1
  }
  for participant in config.participants {
    participant.instance.finish()
  }
  { times, series, steps, events: 0, }
}
