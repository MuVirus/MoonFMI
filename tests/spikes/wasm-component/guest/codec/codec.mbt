///|
pub fn echo_string(text : String) -> String {
  text
}

///|
pub fn echo_bytes(data : FixedArray[Byte]) -> FixedArray[Byte] {
  let out = FixedArray::make(data.length(), (0).to_byte())
  for index, byte in data {
    out[index] = byte
  }
  out
}

///|
pub fn summarize(input : Sample) -> String {
  let mut total = 0.0
  for value in input.values {
    total = total + value
  }
  input.name + "/" + input.values.length().to_string() + "/" + total.to_string()
}
