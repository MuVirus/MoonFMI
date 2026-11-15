///|
/// P5 integration: the `package` command and deterministic archives
/// (tasks B-05 / D-06).

///|
fn package_dir() -> String {
  let directory = "tests/data/.cache/pkg-demo-\{@env.now()}"
  ensure_dir(directory)
  let manifest = @fs.read_file_to_bytes(
    "tests/data/model-description/valid/fmi2-minimal.xml",
  ) catch {
    error => abort("reading fixture failed: " + io_message(error))
  }
  @fs.write_bytes_to_file(directory + "/modelDescription.xml", manifest) catch {
    error => abort("writing fixture failed: " + io_message(error))
  }
  ensure_dir(directory + "/binaries")
  ensure_dir(directory + "/binaries/win64")
  @fs.write_string_to_file(
    directory + "/binaries/win64/Demo.dll",
    "placeholder binary",
  ) catch {
    error => abort("writing binary failed: " + io_message(error))
  }
  directory
}

///|
test "package builds a valid deterministic fmu" {
  let directory = package_dir()
  // Package twice; both archives must be byte-identical and valid. The
  // outputs go outside the packaged directory, or run two would archive
  // run one's result.
  let out_dir = "tests/data/.cache/pkg-out-\{@env.now()}"
  ensure_dir(out_dir)
  let outputs : Array[String] = []
  for run_index in 0..<2 {
    let output = out_dir + "/out-\{run_index}.fmu"
    let code = @cli.run(
      ["package", directory, "--output", output, "--platform", "win64"],
      fn(path) { @fs.read_file_to_bytes(path) catch { _ => b"" } },
    )
    assert_eq(code, 0)
    outputs.push(output)
  }
  let first = @fs.read_file_to_bytes(outputs[0]) catch {
    error => abort("reading package output failed: " + io_message(error))
  }
  let second = @fs.read_file_to_bytes(outputs[1]) catch {
    error => abort("reading package output failed: " + io_message(error))
  }
  // Task B-05 acceptance: two runs produce the same bytes.
  assert_eq(first.length(), second.length())
  for index, byte in first {
    assert_true(byte == second[index], msg="nondeterministic byte at \{index}")
  }
  // The archive must open and validate with our own reader (the FMPy
  // acceptance is the same ZIP layout).
  let archive = @zip.ZipArchive::open(first) catch {
    error => abort("opening the built FMU failed: " + error.message())
  }
  assert_true(archive.contains("modelDescription.xml"))
  assert_true(archive.contains("binaries/win64/Demo.dll"))
  let (model, report) = @fmi.validate_fmu_bytes(first)
  assert_true(model is Some(_))
  assert_true(report.is_valid())
}

///|
test "package rejects a missing platform with exit code 4" {
  let directory = package_dir()
  let code = @cli.run(["package", directory, "--platform", "x86_64-linux"], fn(
    path,
  ) {
    @fs.read_file_to_bytes(path) catch {
      _ => b""
    }
  })
  assert_eq(code, 4)
}

///|
test "package rejects an invalid model description" {
  let directory = "tests/data/.cache/pkg-bad-\{@env.now()}"
  ensure_dir(directory)
  let manifest = @fs.read_file_to_bytes(
    "tests/data/model-description/semantic-invalid/fmi2-md012-illegal-combination.xml",
  ) catch {
    error => abort("reading fixture failed: " + io_message(error))
  }
  @fs.write_bytes_to_file(directory + "/modelDescription.xml", manifest) catch {
    error => abort("writing fixture failed: " + io_message(error))
  }
  let code = @cli.run(["package", directory], fn(path) {
    @fs.read_file_to_bytes(path) catch {
      _ => b""
    }
  })
  assert_eq(code, 1)
}

///|
test "zip writer is deterministic and readable" {
  let entries = [("b.txt", b"second"), ("a.txt", b"first")]
  let options = @zip.ZipWriteOptions::default()
  let first = @zip.build_deterministic_zip(entries, options~) catch {
    error => abort("zip build failed: " + error.message())
  }
  let second = @zip.build_deterministic_zip(entries, options~) catch {
    error => abort("zip build failed: " + error.message())
  }
  assert_eq(first.length(), second.length())
  for index, byte in first {
    assert_true(byte == second[index], msg="nondeterministic at \{index}")
  }
  // Entry order is sorted, not insertion order.
  let archive = @zip.ZipArchive::open(first) catch {
    error => abort("zip open failed: " + error.message())
  }
  let names : Array[String] = []
  for entry in archive.entries() {
    names.push(entry.name())
  }
  assert_eq(names[0], "a.txt")
  assert_eq(names[1], "b.txt")
}

///|
test "simulate timeout exits with code 6" {
  // A deadline in the past fires immediately: the master raises Timeout
  // at the first loop iteration and the CLI maps it to exit 6.
  let code = @cli.run(
    [
      "simulate", "tests/data/.cache/fmi2/BouncingBall.fmu", "--timeout", "0.0000001",
      "--stop-time", "3",
    ],
    fn(path) { @fs.read_file_to_bytes(path) catch { _ => b"" } },
  )
  assert_eq(code, 6)
}
