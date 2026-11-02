///| State table for the demo resource. A real FMU resource would hold an
///| instance pointer instead; the point here is lifetime, not the payload.
let states : Array[Int] = []

///| Number of guest destructors that have run.
let drops : Ref[Int] = { val: 0 }

///|
fn alloc_state(start : UInt) -> Int {
  let rep = states.length()
  states.push(start.reinterpret_as_int())
  rep
}

///|
pub fn Counter::counter(start : UInt) -> Counter {
  Counter::new(alloc_state(start))
}

///|
pub fn Counter::bump(self : Counter, by : UInt) -> UInt {
  let Counter(rep) = self
  let next = states[rep] + by.reinterpret_as_int()
  states[rep] = next
  next.reinterpret_as_uint()
}

///|
pub fn Counter::value(self : Counter) -> UInt {
  let Counter(rep) = self
  states[rep].reinterpret_as_uint()
}

///|
pub fn Counter::dtor(self : Counter) -> Unit {
  let Counter(rep) = self
  if rep >= 0 && rep < states.length() && states[rep] != -1 {
    states[rep] = -1
    drops.val = drops.val + 1
  }
}

///|
pub fn dropped() -> UInt {
  drops.val.reinterpret_as_uint()
}
