///|
/// O(n) indexes over a parsed model (task B-10). Positions are 1-based
/// `ScalarVariable` indices for FMI 2 and 1-based document positions for
/// FMI 3; both models keep document order, so position lookup is an array
/// index.
/// Indexes for an FMI 2 model. FMI 2 value references may repeat, so
/// `by_value_reference` maps a reference to every variable position that
/// declares it.
pub struct Fmi2Index {
  by_name : Map[String, Int32]
  by_value_reference : Map[UInt32, Array[Int32]]
}

///|
pub fn build_fmi2_index(model : Fmi2ModelDescription) -> Fmi2Index {
  let by_name : Map[String, Int32] = Map([])
  let by_value_reference : Map[UInt32, Array[Int32]] = Map([])
  for position, variable in model.variables {
    let index = position + 1
    by_name.set(variable.name, index)
    match by_value_reference.get(variable.value_reference) {
      Some(list) => list.push(index)
      None => by_value_reference.set(variable.value_reference, [index])
    }
  }
  { by_name, by_value_reference, }
}

///|
/// 1-based index lookup by variable name.
pub fn Fmi2Index::position_of_name(self : Fmi2Index, name : String) -> Int32? {
  self.by_name.get(name)
}

///|
/// 1-based positions of every variable with this value reference.
pub fn Fmi2Index::positions_of_value_reference(
  self : Fmi2Index,
  value_reference : UInt32,
) -> Array[Int32]? {
  self.by_value_reference.get(value_reference)
}

///|
/// Indexes for an FMI 3 model. Aliases share their owner's value
/// reference; `alias_positions` maps each alias name to its owner
/// position.
pub struct Fmi3Index {
  by_name : Map[String, Int32]
  by_value_reference : Map[UInt32, Array[Int32]]
  alias_positions : Map[String, Int32]
}

///|
pub fn build_fmi3_index(model : Fmi3ModelDescription) -> Fmi3Index {
  let by_name : Map[String, Int32] = Map([])
  let by_value_reference : Map[UInt32, Array[Int32]] = Map([])
  let alias_positions : Map[String, Int32] = Map([])
  for position, variable in model.variables {
    let index = position + 1
    by_name.set(variable.name, index)
    match by_value_reference.get(variable.value_reference) {
      Some(list) => list.push(index)
      None => by_value_reference.set(variable.value_reference, [index])
    }
    for alias_item in variable.aliases {
      alias_positions.set(alias_item.name, index)
    }
  }
  { by_name, by_value_reference, alias_positions, }
}

///|
/// 1-based document position by variable name.
pub fn Fmi3Index::position_of_name(self : Fmi3Index, name : String) -> Int32? {
  self.by_name.get(name)
}

///|
/// 1-based document positions of the variable (and aliases) with this
/// value reference.
pub fn Fmi3Index::positions_of_value_reference(
  self : Fmi3Index,
  value_reference : UInt32,
) -> Array[Int32]? {
  self.by_value_reference.get(value_reference)
}

///|
/// Owner position of an alias name, if present.
pub fn Fmi3Index::position_of_alias(self : Fmi3Index, name : String) -> Int32? {
  self.alias_positions.get(name)
}
