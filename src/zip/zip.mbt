///|
/// Limits applied to a ZIP container before anything is extracted.
pub struct ZipLimits {
  max_archive_bytes : Int32
  max_entries : Int32
  max_entry_bytes : Int32
  max_total_bytes : Int32
  max_compression_ratio : Int32
}

///|
pub fn ZipLimits::default() -> ZipLimits {
  {
    max_archive_bytes: 256 * 1024 * 1024,
    max_entries: 4096,
    max_entry_bytes: 64 * 1024 * 1024,
    max_total_bytes: 256 * 1024 * 1024,
    max_compression_ratio: 200,
  }
}

///|
pub fn ZipLimits::new(
  max_archive_bytes~ : Int32 = 256 * 1024 * 1024,
  max_entries~ : Int32 = 4096,
  max_entry_bytes~ : Int32 = 64 * 1024 * 1024,
  max_total_bytes~ : Int32 = 256 * 1024 * 1024,
  max_compression_ratio~ : Int32 = 200,
) -> ZipLimits {
  {
    max_archive_bytes,
    max_entries,
    max_entry_bytes,
    max_total_bytes,
    max_compression_ratio,
  }
}

///|
pub fn ZipLimits::max_archive_bytes(self : ZipLimits) -> Int32 {
  self.max_archive_bytes
}

///|
pub fn ZipLimits::max_entries(self : ZipLimits) -> Int32 {
  self.max_entries
}

///|
pub fn ZipLimits::max_entry_bytes(self : ZipLimits) -> Int32 {
  self.max_entry_bytes
}

///|
pub fn ZipLimits::max_total_bytes(self : ZipLimits) -> Int32 {
  self.max_total_bytes
}

///|
pub fn ZipLimits::max_compression_ratio(self : ZipLimits) -> Int32 {
  self.max_compression_ratio
}

///|
/// One entry from the archive's central directory. Sizes are the values
/// declared by the archive; they are checked before extraction begins.
pub struct ZipEntry {
  name : String
  compressed_size : Int32
  uncompressed_size : Int32
  compression : Int32
}

///|
pub fn ZipEntry::name(self : ZipEntry) -> String {
  self.name
}

///|
pub fn ZipEntry::compressed_size(self : ZipEntry) -> Int32 {
  self.compressed_size
}

///|
pub fn ZipEntry::uncompressed_size(self : ZipEntry) -> Int32 {
  self.uncompressed_size
}

///|
pub fn ZipEntry::compression(self : ZipEntry) -> Int32 {
  self.compression
}

///|
pub fn ZipEntry::is_directory(self : ZipEntry) -> Bool {
  self.name.length() > 0 && self.name[self.name.length() - 1] == '/'
}

///|
pub(all) suberror ZipError {
  InvalidArchive(message~ : String)
  Truncated(message~ : String)
  UnsafePath(entry~ : String, reason~ : String)
  TooManyEntries(count~ : Int32, limit~ : Int32)
  EntryTooLarge(entry~ : String, size~ : Int32, limit~ : Int32)
  ArchiveTooLarge(size~ : Int32, limit~ : Int32)
  CompressionRatioExceeded(entry~ : String, ratio~ : Int32, limit~ : Int32)
  DuplicateEntry(entry~ : String)
  UnknownCompression(entry~ : String, compression_method~ : Int32)
  ChecksumMismatch(entry~ : String)
}

///|
pub fn ZipError::message(self : ZipError) -> String {
  match self {
    InvalidArchive(message~) => message
    Truncated(message~) => message
    UnsafePath(entry~, reason~) => "unsafe ZIP entry '" + entry + "': " + reason
    TooManyEntries(count~, limit~) =>
      "ZIP has " + count.to_string() + " entries, limit is " + limit.to_string()
    EntryTooLarge(entry~, size~, limit~) =>
      "ZIP entry '" +
      entry +
      "' is " +
      size.to_string() +
      " bytes, limit is " +
      limit.to_string()
    ArchiveTooLarge(size~, limit~) =>
      "ZIP expands to " +
      size.to_string() +
      " bytes, limit is " +
      limit.to_string()
    CompressionRatioExceeded(entry~, ratio~, limit~) =>
      "ZIP entry '" +
      entry +
      "' has compression ratio " +
      ratio.to_string() +
      ", limit is " +
      limit.to_string()
    DuplicateEntry(entry~) => "ZIP contains duplicate entry '" + entry + "'"
    UnknownCompression(entry~, compression_method~) =>
      "ZIP entry '" +
      entry +
      "' uses unsupported compression method " +
      compression_method.to_string()
    ChecksumMismatch(entry~) =>
      "ZIP entry '" + entry + "' failed its CRC-32 check"
  }
}

///|
/// A read-only, already validated view of a ZIP container.
///
/// The central directory is parsed and checked when the archive is opened.
/// Extraction is a separate step so callers can reject a container without
/// ever inflating its contents.
pub struct ZipArchive {
  data : FixedArray[Byte]
  limits : ZipLimits
  entries : Array[ZipEntry]
}

///|
pub fn ZipArchive::empty() -> ZipArchive {
  {
    data: FixedArray::make(0, b'\x00'),
    limits: ZipLimits::default(),
    entries: [],
  }
}

///|
pub fn ZipArchive::open(
  data : Bytes,
  limits~ : ZipLimits = ZipLimits::default(),
) -> ZipArchive raise ZipError {
  if data.length() > limits.max_archive_bytes {
    raise ArchiveTooLarge(size=data.length(), limit=limits.max_archive_bytes)
  }
  if data.length() == 0 {
    raise Truncated(message="ZIP archive is empty")
  }
  let raw = data.to_fixedarray()
  let infos = @fzip.unzip_list(raw) catch {
    error => raise map_fzip_error(error)
  }
  if infos.length() > limits.max_entries {
    raise TooManyEntries(count=infos.length(), limit=limits.max_entries)
  }
  let entries : Array[ZipEntry] = []
  let seen : Map[String, Unit] = Map([])
  let mut total = 0
  for info in infos {
    validate_entry_path(info.name)
    let key = info.name.to_lower()
    if seen.contains(key) {
      raise DuplicateEntry(entry=info.name)
    }
    seen.set(key, ())
    let compressed = info.size
    let uncompressed = info.original_size
    if compressed < 0 || uncompressed < 0 {
      raise InvalidArchive(
        message="ZIP entry '" + info.name + "' has a negative size",
      )
    }
    if uncompressed > limits.max_entry_bytes {
      raise EntryTooLarge(
        entry=info.name,
        size=uncompressed,
        limit=limits.max_entry_bytes,
      )
    }
    let ratio = compression_ratio(compressed, uncompressed)
    if ratio > limits.max_compression_ratio {
      raise CompressionRatioExceeded(
        entry=info.name,
        ratio~,
        limit=limits.max_compression_ratio,
      )
    }
    total = total + uncompressed
    if total > limits.max_total_bytes {
      raise ArchiveTooLarge(size=total, limit=limits.max_total_bytes)
    }
    if info.compression != 0 && info.compression != 8 {
      raise UnknownCompression(
        entry=info.name,
        compression_method=info.compression,
      )
    }
    entries.push({
      name: info.name,
      compressed_size: compressed,
      uncompressed_size: uncompressed,
      compression: info.compression,
    })
  }
  { data: raw, limits, entries, }
}

///|
pub fn ZipArchive::limits(self : ZipArchive) -> ZipLimits {
  self.limits
}

///|
pub fn ZipArchive::entry_count(self : ZipArchive) -> Int32 {
  self.entries.length()
}

///|
pub fn ZipArchive::entries(self : ZipArchive) -> Array[ZipEntry] {
  self.entries
}

///|
pub fn ZipArchive::entry(self : ZipArchive, name : String) -> ZipEntry? {
  for entry in self.entries {
    if entry.name == name {
      return Some(entry)
    }
  }
  None
}

///|
pub fn ZipArchive::contains(self : ZipArchive, name : String) -> Bool {
  self.entry(name) is Some(_)
}

///|
/// Inflate every entry once, in central-directory order, and verify each
/// entry's CRC-32 before returning it.
pub fn ZipArchive::extract_all(
  self : ZipArchive,
) -> Array[(String, Bytes)] raise ZipError {
  if self.entries.length() == 0 {
    return []
  }
  let expected_crcs = central_directory_crcs(self.data)
  let verify_with_fzip = expected_crcs is None
  let files = @fzip.unzip_sync(self.data, opts={
    verify_checksum: verify_with_fzip,
  }) catch {
    error => raise map_fzip_error(error)
  }
  if files.length() != self.entries.length() {
    raise InvalidArchive(
      message="ZIP entry count changed between listing and extraction",
    )
  }
  let result : Array[(String, Bytes)] = []
  for index = 0; index < files.length(); index = index + 1 {
    let (name, bytes) = files[index]
    if expected_crcs is Some(crcs) && index < crcs.length() {
      if @fzip.crc32(bytes) != crcs[index] {
        raise ChecksumMismatch(entry=name)
      }
    }
    result.push((name, Bytes::from_iter(bytes.iter())))
  }
  result
}

///|
pub fn ZipArchive::read(
  self : ZipArchive,
  name : String,
) -> Bytes raise ZipError {
  if !self.contains(name) {
    raise InvalidArchive(message="ZIP has no entry '" + name + "'")
  }
  for pair in self.extract_all() {
    if pair.0 == name {
      return pair.1
    }
  }
  raise InvalidArchive(message="ZIP has no entry '" + name + "'")
}

///|
fn compression_ratio(compressed : Int32, uncompressed : Int32) -> Int32 {
  if uncompressed == 0 {
    0
  } else if compressed == 0 {
    uncompressed
  } else {
    uncompressed / compressed
  }
}

///|
fn map_fzip_error(error : @fzip.FzipError) -> ZipError {
  match error {
    @fzip.FzipError(code~, message~) =>
      match code {
        @fzip.UnexpectedEOF => Truncated(message~)
        @fzip.InvalidChecksum => ChecksumMismatch(entry="<unknown>")
        @fzip.InvalidZipData => InvalidArchive(message~)
        @fzip.UnknownCompressionMethod => InvalidArchive(message~)
        @fzip.InvalidUTF8 => InvalidArchive(message~)
        @fzip.FilenameTooLong => InvalidArchive(message~)
        @fzip.Zip64ValueTooLarge => InvalidArchive(message~)
        _ => InvalidArchive(message~)
      }
  }
}

///|
fn validate_entry_path(name : String) -> Unit raise ZipError {
  if name.length() == 0 {
    raise UnsafePath(entry=name, reason="empty entry name")
  }
  if name.length() > 4096 {
    raise UnsafePath(entry=name, reason="entry name is too long")
  }
  for index = 0; index < name.length(); index = index + 1 {
    let code = name[index].to_int()
    if code == '\\'.to_int() {
      raise UnsafePath(entry=name, reason="backslashes are not allowed")
    }
    if code < 0x20 || code == 0x7F {
      raise UnsafePath(
        entry=name,
        reason="entry name contains a control character",
      )
    }
  }
  if name[0] == '/' {
    raise UnsafePath(entry=name, reason="absolute paths are not allowed")
  }
  if name.length() >= 2 && name[1] == ':' {
    raise UnsafePath(entry=name, reason="drive-letter paths are not allowed")
  }
  for part in name.split("/") {
    if part == ".." {
      raise UnsafePath(
        entry=name,
        reason="parent-directory components are not allowed",
      )
    }
    if part == "." {
      raise UnsafePath(entry=name, reason="dot components are not allowed")
    }
  }
}

///|
/// Read the CRC-32 values from a classic (non-ZIP64) central directory.
///
/// `unzip_list` intentionally does not expose CRC values, so this small pass
/// exists only to attach an entry name to checksum failures. When the archive
/// uses ZIP64 metadata we return `None` and let fzip verify checksums instead.
fn central_directory_crcs(data : FixedArray[Byte]) -> Array[UInt32]? {
  let eocd = match find_eocd(data) {
    Some(offset) => offset
    None => return None
  }
  let entries = read_u16(data, eocd + 10)
  let cd_size = read_u32(data, eocd + 12)
  let cd_offset = read_u32(data, eocd + 16)
  if entries == 0xFFFF || cd_size == 0xFFFFFFFF || cd_offset == 0xFFFFFFFF {
    return None
  }
  let crcs : Array[UInt32] = []
  let mut offset = cd_offset.reinterpret_as_int()
  let end = offset + cd_size.reinterpret_as_int()
  if offset < 0 || end > data.length() || end < offset {
    return None
  }
  for _ in 0..<entries.reinterpret_as_int() {
    if offset + 46 > end || read_u32(data, offset) != 0x02014B50 {
      return None
    }
    crcs.push(read_u32(data, offset + 16))
    let name_length = read_u16(data, offset + 28).reinterpret_as_int()
    let extra_length = read_u16(data, offset + 30).reinterpret_as_int()
    let comment_length = read_u16(data, offset + 32).reinterpret_as_int()
    offset = offset + 46 + name_length + extra_length + comment_length
  }
  if offset != end {
    return None
  }
  Some(crcs)
}

///|
fn find_eocd(data : FixedArray[Byte]) -> Int32? {
  if data.length() < 22 {
    return None
  }
  let mut offset = data.length() - 22
  let lowest = if data.length() > 65557 { data.length() - 65557 } else { 0 }
  while offset >= lowest {
    if read_u32(data, offset) == 0x06054B50 {
      return Some(offset)
    }
    offset = offset - 1
  }
  None
}

///|
fn read_u16(data : FixedArray[Byte], offset : Int32) -> UInt32 {
  data[offset].to_uint() | (data[offset + 1].to_uint() << 8)
}

///|
fn read_u32(data : FixedArray[Byte], offset : Int32) -> UInt32 {
  data[offset].to_uint() |
  (data[offset + 1].to_uint() << 8) |
  (data[offset + 2].to_uint() << 16) |
  (data[offset + 3].to_uint() << 24)
}
