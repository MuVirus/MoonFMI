///|
/// Options for deterministic archive building (task B-05). Entries are
/// sorted by name, timestamps and attributes are fixed, so two runs on the
/// same input produce byte-identical archives.
pub struct ZipWriteOptions {
  /// Raw 4-byte DOS timestamp written into the headers
  /// (`date << 16 | time`); the default is 1980-01-01 00:00:00.
  mtime : Int32
  /// Compression level 0..9; 0 stores entries without DEFLATE.
  level : Int32
}

///|
pub fn ZipWriteOptions::default() -> ZipWriteOptions {
  // 1980-01-01 00:00:00 in DOS format: date = (1 << 5) | 1.
  { mtime: 0x00210000, level: 0, }
}

///|
/// ZIP building failures, wrapping the underlying writer error.
pub(all) suberror ZipWriteError {
  Failed(String)
}

///|
pub fn ZipWriteError::message(self : ZipWriteError) -> String {
  match self {
    Failed(detail) => detail
  }
}

///|
fn zip_bytes_from_fixed(data : FixedArray[Byte]) -> Bytes {
  Bytes::from_iter(data.iter())
}

///|
fn zip_fixed_from_bytes(data : Bytes) -> FixedArray[Byte] {
  let result : FixedArray[Byte] = FixedArray::make(data.length(), b'\x00')
  for index, byte in data {
    result[index] = byte
  }
  result
}

///|
/// Build a deterministic ZIP archive from `(name, data)` entries
/// (task B-05). Names are sorted, the timestamp/attributes come from
/// `options`, and the same input always yields the same bytes.
pub fn build_deterministic_zip(
  entries : Array[(String, Bytes)],
  options~ : ZipWriteOptions = ZipWriteOptions::default(),
) -> Bytes raise ZipWriteError {
  // Deterministic order: sort by entry name.
  let sorted = entries.copy()
  sorted.sort_by(fn(a, b) { a.0.compare(b.0) })
  let files : Array[(String, FixedArray[Byte])] = []
  for entry in sorted {
    files.push((entry.0, zip_fixed_from_bytes(entry.1)))
  }
  let archive_options : @fzip.ZipEntryOptions = {
    level: options.level,
    mem: 0,
    os: 0,
    attrs: 0,
    extra: [],
    comment: "",
    mtime: options.mtime,
  }
  let built = @fzip.zip_sync_checked(files, opts=archive_options) catch {
    error =>
      match error {
        FzipError(message~, ..) => raise Failed(message)
      }
  }
  zip_bytes_from_fixed(built)
}
