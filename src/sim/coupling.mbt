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
  /// order. A connection may only source recorded references, so this list
  /// is also the producer's observed-output set.
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
/// A directed signal connection: `from.(out_vr)` feeds `to.(in_vr)`.
/// Connections must not form a cycle — with constant extrapolation a cycle
/// is an algebraic loop, which this MVP rejects instead of solving.
pub struct Coupling {
  from : String
  out_vr : UInt32
  to : String
  in_vr : UInt32
}

///|
pub fn Coupling::new(
  from~ : String,
  out_vr~ : UInt32,
  to~ : String,
  in_vr~ : UInt32,
) -> Coupling {
  { from, out_vr, to, in_vr, }
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
}

///|
pub fn CoupledConfig::new(
  start_time~ : Double,
  stop_time~ : Double,
  step_size~ : Double,
  participants~ : Array[CoupledParticipant],
  connections~ : Array[Coupling],
  deadline~ : UInt64? = None,
) -> CoupledConfig {
  { start_time, stop_time, step_size, participants, connections, deadline, }
}

///|
/// Validates the coupling and returns participant indices in topological
/// order (sources before consumers, stable by declaration order). Raises
/// `Config` for duplicate names, unknown endpoints, self connections and
/// cycles (algebraic loops).
fn coupled_topological_order(
  participants : Array[CoupledParticipant],
  connections : Array[Coupling],
) -> Array[Int32] raise @fmi.SimulationError {
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
      raise @fmi.Config(
        detail="participant '\{connection.from}' feeds its own input; that is an algebraic loop",
      )
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
  while order.length() < participants.length() {
    let mut picked = -1
    for index, count in remaining_incoming {
      if count == 0 && !placed[index] {
        picked = index
        break
      }
    }
    if picked < 0 {
      raise @fmi.Config(
        detail="the connection graph has a cycle; constant extrapolation cannot solve algebraic loops",
      )
    }
    placed[picked] = true
    order.push(picked)
    for edge in edges {
      if edge.0 == picked {
        remaining_incoming[edge.1] -= 1
      }
    }
  }
  order
}

///|
/// The coupled co-simulation master. Participants run on one shared
/// communication grid (`start_time + k * step_size`, final step truncated
/// to `stop_time`) and are stepped in topological order, so every consumer
/// steps with the producer's output from the same communication point —
/// no one-step lag; docs/design/coupling.md §3. Inputs are written from the
/// producer's freshly read outputs before the consumer steps: constant
/// extrapolation over the incoming step. Cycles are rejected upfront.
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
  let order = coupled_topological_order(config.participants, config.connections)
  // Resolve connections into per-participant input plans: for participant
  // index p, the plan lists (local input vr, producer index, producer vr).
  let index_of : Map[String, Int32] = Map([])
  for index, participant in config.participants {
    index_of[participant.name] = index
  }
  let input_plans : Array[Array[(UInt32, Int32, UInt32)]] = []
  for _ in config.participants {
    input_plans.push([])
  }
  for connection in config.connections {
    let from = index_of[connection.from]
    let to = index_of[connection.to]
    input_plans[to].push((connection.in_vr, from, connection.out_vr))
  }
  // Setup and initialize everyone in declaration order.
  for participant in config.participants {
    participant.instance.setup_experiment(
      start=config.start_time,
      stop=Some(config.stop_time),
    )
    participant.instance.initialize()
  }
  // Latest observed outputs per participant: the record list is the
  // observed set, read once up front so the initial inputs and the initial
  // row come from the same state.
  let observed : Array[Map[UInt32, Double]] = []
  for participant in config.participants {
    let map : Map[UInt32, Double] = Map([])
    for value_reference in participant.record {
      map[value_reference] = participant.instance.read_real(value_reference)
    }
    observed.push(map)
  }
  let write_inputs = fn(producer_index : Int32) raise @fmi.SimulationError {
    for plan in input_plans[producer_index] {
      let (input_vr, from, out_vr) = plan
      match observed[from].get(out_vr) {
        Some(value) =>
          config.participants[producer_index].instance.write_real(
            input_vr, value,
          )
        None =>
          raise @fmi.Config(
            detail="connection out_vr \{out_vr} of '\{config.participants[from].name}' is not in its record list, so the coupled run cannot observe it",
          )
      }
    }
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
  // Initial grid point: propagate initial outputs to the inputs, record.
  for producer_index in order {
    write_inputs(producer_index)
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
    for producer_index in order {
      write_inputs(producer_index)
      config.participants[producer_index].instance.step(t, h)
      let participant = config.participants[producer_index]
      for value_reference in participant.record {
        observed[producer_index][value_reference] = participant.instance.read_real(
          value_reference,
        )
      }
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
