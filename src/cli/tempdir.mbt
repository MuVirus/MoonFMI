///|
/// Hex-encode bytes (lowercase). Shared by the deterministic-sha256
/// helpers and the temporary-directory suffix.
fn bytes_hex(data : FixedArray[Byte]) -> String {
  let builder = StringBuilder()
  for byte in data {
    let value = byte.to_int()
    builder.write_char(UInt16::unsafe_to_char(hex_digits[(value / 16) & 0xF]))
    builder.write_char(UInt16::unsafe_to_char(hex_digits[value & 0xF]))
  }
  builder.to_string()
}

///|
/// Big-endian bytes of a `UInt64`, used to feed the wall clock into SHA-256
/// when the platform has no entropy source.
fn u64_be_bytes(value : UInt64) -> Bytes {
  let buf : FixedArray[Byte] = FixedArray::make(8, b'\x00')
  for i = 0; i < 8; i = i + 1 {
    buf[i] = ((value >> ((7 - i) * 8)) & 0xFFUL).to_int().to_byte()
  }
  Bytes::from_array(buf)
}

///|
/// Random suffix for private `.moonfmi-tmp` directory names (R7).
///
/// A wall-clock-only name (`...-<@env.now()>`) is predictable on a shared
/// host, which leaves a symlink-swap window between name selection and use
/// (docs/design/security-review.md R7). The suffix is 8 bytes from the
/// platform entropy source, hashed and truncated to 16 hex digits (64 bits
/// of entropy). Without platform entropy it degrades to hashing the wall
/// clock — still unique per call, but no longer attacker-unpredictable,
/// i.e. the pre-0.7.0 behavior.
fn temp_dir_suffix() -> String {
  let seed : Bytes = match @env.rand(8) {
    Some(bytes) => bytes
    None => u64_be_bytes(@env.now())
  }
  sha256_hex(seed)[0:16].to_owned()
}
