///|
/// `moonfmi package <dir>` (task D-06): build a deterministic FMU archive
/// from a directory that contains a valid `modelDescription.xml`.
///
/// Exit codes: 0 success, 1 invalid (validation failed or platform missing),
/// 2 usage, 3 unreadable input, 4 the requested platform is not present.

///|
let hex_digits : String = "0123456789abcdef"

///|
fn sha256_hex(data : Bytes) -> String {
  bytes_hex(@crypto.sha256(data))
}

///|
/// Recursively collect `(archive-name, bytes)` pairs below `root`.
/// Archive names always use `/` separators, whatever the host prefers.
fn collect_entries(
  root : String,
  prefix : String,
) -> Array[(String, Bytes)] raise @fs.IOError {
  let entries : Array[(String, Bytes)] = []
  for name in @fs.read_dir(root) {
    if name == "." || name == ".." {
      continue
    }
    let child = root + "/" + name
    let archive_name = if prefix == "" { name } else { prefix + "/" + name }
    if @fs.is_dir(child) {
      for pair in collect_entries(child, archive_name) {
        entries.push(pair)
      }
    } else {
      let data = @fs.read_file_to_bytes(child)
      entries.push((archive_name, data))
    }
  }
  entries
}

///|
fn package_result_json(
  directory : String,
  output : String,
  entry_count : Int32,
  bytes : Int32,
  checksum : String,
  valid : Bool,
  warnings : Array[String],
) -> String {
  let builder = StringBuilder()
  builder.write_string(
    "{\n  \"schema\": \"moonfmi.package/v1\",\n  \"directory\": ",
  )
  builder.write_string(json_string(directory))
  builder.write_string(",\n  \"output\": ")
  builder.write_string(json_string(output))
  builder.write_string(",\n  \"entries\": ")
  builder.write_string(entry_count.to_string())
  builder.write_string(",\n  \"bytes\": ")
  builder.write_string(bytes.to_string())
  builder.write_string(",\n  \"sha256\": ")
  builder.write_string(json_string(checksum))
  builder.write_string(",\n  \"deterministic\": true")
  builder.write_string(",\n  \"roundtripValid\": ")
  builder.write_string(if valid { "true" } else { "false" })
  builder.write_string(",\n  \"warnings\": [")
  for index, warning in warnings {
    if index > 0 {
      builder.write_string(", ")
    }
    builder.write_string(json_string(warning))
  }
  builder.write_string("]\n}")
  builder.to_string()
}

///|
fn run_package(argv : Array[String], skip : Int32) -> Int32 {
  if skip >= argv.length() {
    println("moonfmi package: missing directory argument\n")
    println(usage())
    return 2
  }
  let mut output : String? = None
  let mut platform : String? = None
  let mut json = false
  let mut index = skip + 1
  while index < argv.length() {
    let arg = argv[index]
    if arg == "--json" {
      json = true
      index += 1
    } else if arg == "--output" || arg == "--platform" {
      if index + 1 >= argv.length() {
        println("moonfmi package: flag '\{arg}' needs a value\n")
        println(usage())
        return 2
      }
      if arg == "--output" {
        output = Some(argv[index + 1])
      } else {
        platform = Some(argv[index + 1])
      }
      index += 2
    } else {
      println("moonfmi package: unknown argument '\{arg}'\n")
      println(usage())
      return 2
    }
  }
  let directory = argv[skip]
  let manifest_path = directory + "/modelDescription.xml"
  let manifest = @fs.read_file_to_bytes(manifest_path) catch {
    error =>
      match error {
        @fs.IOError(message) => {
          println(
            "moonfmi: cannot read '\{manifest_path}': \{message}\nhint: package expects a directory containing modelDescription.xml",
          )
          return 3
        }
      }
  }
  let (_model, report) = @fmi.validate_fmu_bytes(manifest)
  if !report.is_valid() {
    println("moonfmi: the model description failed validation:")
    for line in report_text(report) {
      println(line)
    }
    return 1
  }
  let entries = collect_entries(directory, "") catch {
    error =>
      match error {
        @fs.IOError(message) => {
          println("moonfmi: cannot read '\{directory}': \{message}")
          return 3
        }
      }
  }
  if entries.is_empty() {
    println("moonfmi: the directory '\{directory}' is empty")
    return 1
  }
  let warnings : Array[String] = []
  // A requested platform directory must exist and be referenced.
  match platform {
    Some(requested) => {
      let prefix = "binaries/" + requested + "/"
      let mut found = false
      for entry in entries {
        if entry.0.has_prefix(prefix) {
          found = true
        }
      }
      if !found {
        println(
          "moonfmi: no binary for platform '\{requested}' under binaries/",
        )
        return 4
      }
    }
    None => {
      // Warn when no binary directory at all is present (a pure source FMU
      // is legal, so this stays a warning).
      let mut have_binary = false
      for entry in entries {
        if entry.0.has_prefix("binaries/") {
          have_binary = true
        }
      }
      if !have_binary {
        warnings.push("no binaries/ directory: the FMU will be source-only")
      }
    }
  }
  // Build deterministically and always round-trip through our own reader.
  let archive = @zip.build_deterministic_zip(entries) catch {
    error => {
      println("moonfmi: building the FMU failed: \{error.message()}")
      return 1
    }
  }
  // The roundtrip re-validates the built archive end to end.
  let (_round_model, round_report) = @fmi.validate_fmu_bytes(archive)
  let roundtrip_valid = round_report.is_valid()
  if !roundtrip_valid {
    println("moonfmi: the built FMU failed its round-trip validation:")
    for line in report_text(round_report) {
      println(line)
    }
  }
  let output_path = match output {
    Some(path) => path
    None => {
      // Default: <modelName>.fmu next to the directory.
      let name = match _model {
        Some(model) => model.model_name()
        None => "model"
      }
      name + ".fmu"
    }
  }
  @fs.write_bytes_to_file(output_path, archive) catch {
    error =>
      match error {
        @fs.IOError(message) => {
          println("moonfmi: cannot write '\{output_path}': \{message}")
          return 1
        }
      }
  }
  if json {
    println(
      package_result_json(
        directory,
        output_path,
        entries.length(),
        archive.length(),
        sha256_hex(archive),
        roundtrip_valid,
        warnings,
      ),
    )
  } else {
    println(
      "packaged \{entries.length()} file(s), \{archive.length()} bytes into \{output_path} (deterministic, sha256 \{sha256_hex(archive)})",
    )
    for warning in warnings {
      println("warning: \{warning}")
    }
    if !roundtrip_valid {
      println("error: round-trip validation failed")
      return 1
    }
  }
  if roundtrip_valid {
    0
  } else {
    1
  }
}
