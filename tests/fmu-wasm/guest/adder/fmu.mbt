// MoonBit guest for the Adder CS FMU component (roadmap P7, F-02/F-04/F-05).
//
// Model: y = u1 + u2 (the Reference-FMUs Adder without states). Value
// references follow the exported modelDescription.xml: u1 = 0, u2 = 1,
// y = 2. Each host handle owns one slot in the instance table, mirroring
// what a real FMU resource would do with an instance pointer.
//
// Logging goes through the imported `host.log` callback (F-05): a component
// must not print; the host decides where messages go.

///|
/// Per-instance state. A full FMU would carry the model struct here; the
/// Adder only needs its two inputs and the computed output.
priv struct AdderState {
  mut u1 : Double
  mut u2 : Double
  mut y : Double
  mut time : Double
  mut terminated : Bool
}

///|
let instances : Array[AdderState] = []

///|
/// Instantiate: allocate one slot and announce it through the host log.
pub fn Fmu::fmu() -> Fmu {
  let rep = instances.length()
  instances.push({
    u1: 0.0,
    u2: 0.0,
    y: 0.0,
    time: 0.0,
    terminated: false,
  })
  @host.log(1, "Adder: instantiated (vr map: u1=0, u2=1, y=2)")
  Fmu::new(rep)
}

///|
/// FMI get-version for this component build.
pub fn Fmu::get_version(self : Fmu) -> String {
  let _ = self
  "3.0"
}

///|
pub fn get_version() -> String {
  "3.0"
}

///|
/// Set inputs by value reference. Unknown references are logged, not
/// crashed on — a component returns fmi3Error through the state machine in
/// the real binding; this minimal surface keeps the demo honest by logging.
pub fn Fmu::set_real(self : Fmu, vr : UInt, value : Double) -> Unit {
  let Fmu(rep) = self
  let state = instances[rep]
  if vr == 0U {
    state.u1 = value
  } else if vr == 1U {
    state.u2 = value
  } else {
    @host.log(3, "Adder: set-real ignored for unknown vr \{vr}")
  }
}

///|
pub fn Fmu::get_real(self : Fmu, vr : UInt) -> Double {
  let Fmu(rep) = self
  let state = instances[rep]
  if vr == 0U {
    state.u1
  } else if vr == 1U {
    state.u2
  } else if vr == 2U {
    state.y
  } else {
    @host.log(3, "Adder: get-real for unknown vr \{vr}")
    0.0
  }
}

///|
/// One communication step: recompute the output at the end of the interval.
pub fn Fmu::do_step(
  self : Fmu,
  current : Double,
  step : Double,
) -> Result[Unit, String] {
  let Fmu(rep) = self
  let state = instances[rep]
  if state.terminated {
    return Err("do-step called after terminate")
  }
  if step < 0.0 {
    return Err("negative step size")
  }
  state.time = current + step
  state.y = state.u1 + state.u2
  @host.log(1, "Adder: step to t={state.time}, y={state.y}")
  Ok(())
}

///|
pub fn Fmu::terminate(self : Fmu) -> Unit {
  let Fmu(rep) = self
  instances[rep].terminated = true
  @host.log(1, "Adder: terminated")
}

///|
/// Guest destructor: runs when the host drops the resource handle.
pub fn Fmu::dtor(self : Fmu) -> Unit {
  let Fmu(rep) = self
  if rep >= 0 && rep < instances.length() {
    @host.log(1, "Adder: instance \{rep} destroyed")
  }
}
