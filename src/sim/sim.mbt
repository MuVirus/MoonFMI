///|
pub struct SimulationConfig {
  fmu : @fmi.Fmu
  stop_time : Double
}

///|
pub fn SimulationConfig::default() -> SimulationConfig {
  { fmu: @fmi.Fmu::placeholder(), stop_time: 10.0, }
}

///|
pub fn SimulationConfig::new(
  fmu : @fmi.Fmu,
  stop_time : Double,
) -> SimulationConfig {
  { fmu, stop_time, }
}
