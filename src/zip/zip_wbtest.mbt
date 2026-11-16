///|
fn bytes_text(bytes : Bytes) -> String {
  @utf8.decode(bytes.exact_view()) catch {
    _ => "<invalid UTF-8>"
  }
}

///|
fn zip_bytes(entries : Array[(String, FixedArray[Byte])]) -> Bytes raise {
  Bytes::from_iter(@fzip.zip_sync_checked(entries).iter())
}

///|
fn text_entry(text : String) -> FixedArray[Byte] {
  @utf8.encode(text).to_fixedarray()
}

///|
test "valid archive lists and extracts entries" {
  let archive = ZipArchive::open(
    zip_bytes([
      ("modelDescription.xml", text_entry("<fmiModelDescription/>")),
      ("binaries/win64/test.dll", text_entry("MZ fake binary")),
    ]),
  )
  assert_eq(archive.entry_count(), 2)
  assert_true(archive.contains("modelDescription.xml"))
  let entry = archive.entry("binaries/win64/test.dll").unwrap()
  assert_eq(entry.name(), "binaries/win64/test.dll")
  assert_false(entry.is_directory())
  let files = archive.extract_all()
  assert_eq(files.length(), 2)
  assert_eq(files[0].0, "modelDescription.xml")
  assert_eq(files[0].1 |> bytes_text, "<fmiModelDescription/>")
  assert_eq(files[1].1 |> bytes_text, "MZ fake binary")
}

///|
test "directory entries are marked" {
  let archive = ZipArchive::open(
    zip_bytes([("resources/", FixedArray::make(0, b'\x00'))]),
  )
  let entry = archive.entries()[0]
  assert_true(entry.is_directory())
}

///|
test "path traversal is rejected with entry context" {
  let observed = try {
    let _ = ZipArchive::open(zip_bytes([("../evil.dll", text_entry("x"))]))
    None
  } catch {
    UnsafePath(entry~, reason~) => Some((entry, reason))
    _ => None
  }
  assert_true(observed is Some(("../evil.dll", _)))
}

///|
test "absolute and backslash paths are rejected" {
  let absolute = try {
    let _ = ZipArchive::open(zip_bytes([("/etc/passwd", text_entry("x"))]))
    false
  } catch {
    UnsafePath(..) => true
    _ => false
  }
  assert_true(absolute)
  let backslash = try {
    let _ = ZipArchive::open(
      zip_bytes([("binaries\\win64\\test.dll", text_entry("x"))]),
    )
    false
  } catch {
    UnsafePath(..) => true
    _ => false
  }
  assert_true(backslash)
}

///|
test "duplicate entries are rejected case-insensitively" {
  let observed = try {
    let _ = ZipArchive::open(
      zip_bytes([
        ("ModelDescription.xml", text_entry("a")),
        ("modeldescription.xml", text_entry("b")),
      ]),
    )
    false
  } catch {
    DuplicateEntry(entry~) => entry == "modeldescription.xml"
    _ => false
  }
  assert_true(observed)
}

///|
test "entry size and expansion limits are checked before extraction" {
  let big = FixedArray::make(1024 * 1024, b'\x00')
  let compressed = zip_bytes([("bomb.bin", big)])
  let too_large = try {
    let _ = ZipArchive::open(
      compressed,
      limits=ZipLimits::new(max_entry_bytes=1024),
    )
    false
  } catch {
    EntryTooLarge(entry~, size~, limit~) =>
      entry == "bomb.bin" && size == 1024 * 1024 && limit == 1024
    _ => false
  }
  assert_true(too_large)
  let too_much_ratio = try {
    let _ = ZipArchive::open(
      compressed,
      limits=ZipLimits::new(max_compression_ratio=4),
    )
    false
  } catch {
    CompressionRatioExceeded(entry~, ..) => entry == "bomb.bin"
    _ => false
  }
  assert_true(too_much_ratio)
}

///|
test "total expansion budget is checked" {
  let observed = try {
    let _ = ZipArchive::open(
      zip_bytes([
        ("a.bin", FixedArray::make(1024, b'\x00')),
        ("b.bin", FixedArray::make(1024, b'\x00')),
      ]),
      limits=ZipLimits::new(max_total_bytes=1500),
    )
    false
  } catch {
    ArchiveTooLarge(size~, limit~) => size == 2048 && limit == 1500
    _ => false
  }
  assert_true(observed)
}

///|
test "entry count limit is checked" {
  let observed = try {
    let _ = ZipArchive::open(
      zip_bytes([("a", text_entry("a")), ("b", text_entry("b"))]),
      limits=ZipLimits::new(max_entries=1),
    )
    false
  } catch {
    TooManyEntries(count~, limit~) => count == 2 && limit == 1
    _ => false
  }
  assert_true(observed)
}

///|
test "truncated archive is rejected" {
  let data = zip_bytes([("a.txt", text_entry("hello"))])
  let cut = data.exact_view(end=data.length() - 8).to_owned()
  let observed = try {
    let _ = ZipArchive::open(cut)
    false
  } catch {
    Truncated(..) | InvalidArchive(..) => true
    _ => false
  }
  assert_true(observed)
}

///|
test "checksum mismatch names the damaged entry" {
  let data = zip_bytes([
    ("good.txt", text_entry("good")),
    ("bad.txt", text_entry("bad")),
  ]).to_fixedarray()
  let eocd = find_eocd(data).unwrap()
  let cd_offset = read_u32(data, eocd + 16).reinterpret_as_int()
  // Flip the last byte of the first entry's stored CRC.
  let first_crc_byte = cd_offset + 16 + 3
  data[first_crc_byte] = data[first_crc_byte].lnot()
  let archive = ZipArchive::open(Bytes::from_iter(data.iter()))
  let observed = try {
    let _ = archive.extract_all()
    ""
  } catch {
    ChecksumMismatch(entry~) => entry
    _ => "<other>"
  }
  assert_eq(observed, "good.txt")
}

///|
test "archive without entries is accepted" {
  let archive = ZipArchive::open(zip_bytes([]))
  assert_eq(archive.entry_count(), 0)
  assert_eq(archive.extract_all().length(), 0)
}

///|
test "fuzz regression with fixed seed does not panic (G-01)" {
  // xorshift-style PRNG keeps the corpus deterministic across runs. The
  // base archive is a valid FMU-shaped zip; mutations flip bytes, splice
  // truncations and inflate headers. The reader must either accept the
  // archive or raise a ZipError — never panic.
  let mut state : UInt64 = 0x2545F4914F6CDD1DUL
  fn next() -> UInt64 {
    state = state * 6364136223846793005UL + 1442695040888963407UL
    let x = state
    (x ^ (x >> 29)) * 0xBF58476D1CE4E5B9UL
  }
  let base = build_deterministic_zip([
    ("modelDescription.xml", @utf8.encode("<fmiModelDescription/>")),
    ("binaries/win64/model.dll", b"\x4d\x5a\x90\x00\x00\x00\x00\x00"),
  ])
  for _iteration = 0; _iteration < 400; _iteration = _iteration + 1 {
    let mutated = Bytes::from_iter(
      base
      .iter()
      .map(fn(b) {
        let roll = next() & 31UL
        if roll == 0 {
          (next() & 255UL).to_int().to_byte()
        } else {
          b
        }
      }),
    )
    // Truncate at a pseudo-random position roughly half the time.
    let cut = (next() & (mutated.length().to_uint64() / 2)) |> ignore
    let candidate = if (next() & 1UL) == 0UL {
      mutated
    } else {
      let position = (next() % mutated.length().to_uint64()).to_int()
      Bytes::from_iter(mutated.iter().take(position))
    }
    let _ = cut
    // The reader must never panic; any outcome below is fine.
    let outcome : Result[ZipArchive, ZipError] = Ok(ZipArchive::open(candidate)) catch {
      error => Err(error)
    }
    match outcome {
      Ok(archive) => {
        // If the archive parses, extraction must not panic either.
        let _ = archive.extract_all() catch { _ => [] }
      }
      Err(_) => ()
    }
  }
}
