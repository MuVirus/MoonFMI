///|
/// Configuration of one co-simulation run (task C-10). Times follow the
/// master-algorithm design: the grid is `start_time + k * step_size`, the
/// final step is truncated to `stop_time`.
pub struct CsConfig {
  start_time : Double
  stop_time : Double
  step_size : Double
  /// Value references to record after every communication point.
  record : Array[UInt32]
}

///|
pub fn CsConfig::new(
  start_time~ : Double,
  stop_time~ : Double,
  step_size~ : Double,
  record~ : Array[UInt32],
) -> CsConfig {
  { start_time, stop_time, step_size, record, }
}

///|
/// Recorded samples: one timestamp per row, one value series per recorded
/// variable (task C-12).
pub(all) struct SimulationResult {
  times : Array[Double]
  series : Array[Array[Double]]
  steps : Int32
}

///|
pub fn SimulationResult::times(self : SimulationResult) -> Array[Double] {
  self.times
}

///|
pub fn SimulationResult::series(
  self : SimulationResult,
) -> Array[Array[Double]] {
  self.series
}

///|
pub fn SimulationResult::steps(self : SimulationResult) -> Int32 {
  self.steps
}

///|
/// Tolerance for "reached stop_time" comparisons; communication points
/// accumulate floating point error, so exact equality is wrong here.
let time_epsilon : Double = 0.000000001

///|
/// The FMI 2 co-simulation master algorithm:
/// `setup → initialize → record(t0) → loop { doStep; record(t+h) } → finish`.
/// The final step is truncated to `stop_time`; errors abort the run.
pub fn run_cs_simulation(
  instance : &@fmi.CsInstance,
  config~ : CsConfig,
) -> SimulationResult raise @fmi.SimulationError {
  if !(config.stop_time > config.start_time) {
    raise @fmi.Config(
      detail="stop_time (\{config.stop_time}) must be greater than start_time (\{config.start_time})",
    )
  }
  if !(config.step_size > 0.0) {
    raise @fmi.Config(detail="step_size must be positive")
  }
  instance.setup_experiment(
    start=config.start_time,
    stop=Some(config.stop_time),
  )
  instance.initialize()
  let times : Array[Double] = []
  let series : Array[Array[Double]] = []
  for _ in config.record {
    series.push([])
  }
  let record = fn(t) raise @fmi.SimulationError {
    times.push(t)
    for index, value_reference in config.record {
      series[index].push(instance.read_real(value_reference))
    }
  }
  record(config.start_time)
  let mut t = config.start_time
  let mut steps = 0
  while t < config.stop_time - time_epsilon {
    let mut h = config.step_size
    if t + h > config.stop_time {
      h = config.stop_time - t
    }
    instance.step(t, h)
    t = t + h
    record(t)
    steps += 1
  }
  instance.finish()
  { times, series, steps, }
}
