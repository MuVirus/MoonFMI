///|
pub(all) enum Command {
  Validate
  Info
  Simulate
}

///|
pub fn Command::all() -> Array[Command] {
  [Command::Validate, Command::Info, Command::Simulate]
}

///|
pub fn Command::name(self : Command) -> String {
  match self {
    Validate => "validate"
    Info => "info"
    Simulate => "simulate"
  }
}

///|
pub fn default_stop_time() -> Double {
  @sim.SimulationConfig::default().stop_time
}

///|
pub fn default_export_target() -> @export.ExportTarget {
  @export.ExportTarget::Source
}
