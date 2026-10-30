///|
/// A read-only view over a ZIP container.
///
/// P0 only needs the type to exist: the real directory parser and safety
/// checks arrive in week 2.
pub struct ZipArchive {
  entries : Int32
}

///|
pub fn ZipArchive::new() -> ZipArchive {
  { entries: 0, }
}

///|
pub fn ZipArchive::entry_count(self : ZipArchive) -> Int32 {
  self.entries
}
