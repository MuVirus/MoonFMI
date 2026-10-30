///|
pub struct XmlLimits {
  max_bytes : Int32
  max_depth : Int32
}

///|
pub fn XmlLimits::default() -> XmlLimits {
  { max_bytes: 32 * 1024 * 1024, max_depth: 256, }
}

///|
pub fn XmlLimits::allows_size(self : XmlLimits, size : Int32) -> Bool {
  size >= 0 && size <= self.max_bytes
}
