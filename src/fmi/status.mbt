///|
/// The status code that an FMI 2 or FMI 3 call returns.
///
/// FMI 2.0.4 defines `fmi2OK` through `fmi2Pending` with these exact values;
/// FMI 3.0.2 uses the same first five codes. Anything unknown is reported as
/// `Error`, which is the only safe assumption for an unknown result.
pub(all) enum FmiStatus {
  Ok
  Warning
  Discard
  Error
  Fatal
  Pending
}

///|
pub fn FmiStatus::from_int32(value : Int32) -> FmiStatus {
  match value {
    0 => Ok
    1 => Warning
    2 => Discard
    3 => Error
    4 => Fatal
    5 => Pending
    _ => Error
  }
}

///|
pub fn FmiStatus::to_int32(self : FmiStatus) -> Int32 {
  match self {
    Ok => 0
    Warning => 1
    Discard => 2
    Error => 3
    Fatal => 4
    Pending => 5
  }
}

///|
pub fn FmiStatus::is_ok(self : FmiStatus) -> Bool {
  self is Ok
}

///|
/// A `Warning` is still a successful call; only `Error` and `Fatal` are
/// failures. `Discard` depends on the call: a discarded step can be retried
/// with a smaller step size.
pub fn FmiStatus::is_failure(self : FmiStatus) -> Bool {
  self is Error || self is Fatal
}

///|
pub fn FmiStatus::name(self : FmiStatus) -> String {
  match self {
    Ok => "ok"
    Warning => "warning"
    Discard => "discard"
    Error => "error"
    Fatal => "fatal"
    Pending => "pending"
  }
}
