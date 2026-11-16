///|
/// Benchmark scaffold for MoonFMI (roadmap A-08 / G-03).
///
/// Run with:
///
///     moon test --target native --release -p MuVirus/MoonFMI/tests/integration -f "bench scaffold"
///
/// (Debug builds skip this file via the moon.pkg target filter; release
/// timing is the only comparable number.) Each benchmark runs one warmup
/// pass plus seven measured runs; the table prints min / median / max
/// wall-clock milliseconds so runs on the same machine compare directly.
/// The G-03 regression gate compares medians between runs.
test "bench scaffold prints comparable medians" {
  println("| benchmark | min ms | median ms | max ms |")
  println("| --- | --- | --- | --- |")
  bench_row(name="parse-validate-10k", f=bench_parse_validate)
  bench_row(name="zip-open-extract-dahlquist", f=bench_zip_dahlquist)
  bench_row(name="export-codegen-dahlquist", f=bench_export_codegen)
}

///|
let bench_runs : Int32 = 7

///|
fn bench_median(values : Array[UInt64]) -> UInt64 {
  let sorted = values.copy()
  sorted.sort()
  sorted[sorted.length() / 2]
}

///|
fn bench_row(name~ : String, f~ : () -> UInt64) -> Unit {
  ignore(f()) // warmup
  let samples : Array[UInt64] = []
  for _ in 0..<bench_runs {
    samples.push(f())
  }
  let mut min = samples[0]
  let mut max = samples[0]
  for value in samples {
    if value < min {
      min = value
    }
    if value > max {
      max = value
    }
  }
  let med = bench_median(samples)
  println("| \{name} | \{min} | \{med} | \{max} |")
}

///|
/// 10k-variable FMI 2 model description, generated the same way the perf
/// budget gates build theirs.
fn bench_large_model() -> Bytes {
  let count = 10000
  let builder = StringBuilder(size_hint=count * 120)
  builder.write_string("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
  builder.write_string(
    "<fmiModelDescription fmiVersion=\"2.0\" modelName=\"Large\" guid=\"{large}\">\n",
  )
  builder.write_string(
    "  <CoSimulation modelIdentifier=\"Large\"/>\n  <UnitDefinitions><Unit name=\"m\"><BaseUnit m=\"1\"/></Unit></UnitDefinitions>\n",
  )
  builder.write_string("  <ModelVariables>\n")
  for i = 0; i < count; i = i + 1 {
    let suffix = i.to_string()
    let reference = i.to_string()
    if i % 4 == 0 {
      builder.write_string(
        "<ScalarVariable name=\"u\{suffix}\" valueReference=\"\{reference}\" causality=\"input\" variability=\"continuous\" initial=\"exact\"><Real start=\"0\"/></ScalarVariable>\n",
      )
    } else if i % 4 == 1 {
      builder.write_string(
        "<ScalarVariable name=\"y\{suffix}\" valueReference=\"\{reference}\" causality=\"output\" variability=\"continuous\" initial=\"calculated\"><Real/></ScalarVariable>\n",
      )
    } else if i % 4 == 2 {
      builder.write_string(
        "<ScalarVariable name=\"p\{suffix}\" valueReference=\"\{reference}\" causality=\"parameter\" variability=\"fixed\" initial=\"exact\"><Real start=\"1\" min=\"0\" max=\"10\" nominal=\"1\"/></ScalarVariable>\n",
      )
    } else {
      builder.write_string(
        "<ScalarVariable name=\"d\{suffix}\" valueReference=\"\{reference}\" causality=\"local\" variability=\"discrete\" initial=\"calculated\"><Integer min=\"0\" max=\"3\"/></ScalarVariable>\n",
      )
    }
  }
  builder.write_string("  </ModelVariables>\n")
  builder.write_string("  <ModelStructure>\n    <Outputs>\n")
  for i = 0; i < count; i = i + 4 {
    builder.write_string("      <Unknown index=\"\{i + 2}\"/>\n")
  }
  builder.write_string("    </Outputs>\n  </ModelStructure>\n")
  builder.write_string("</fmiModelDescription>\n")
  @utf8.encode(builder.to_string())
}

///|
let bench_large_model_bytes : Bytes = bench_large_model()

///|
fn bench_parse_validate() -> UInt64 {
  let start = @env.now()
  let (model, report) = @schema.parse_and_validate(bench_large_model_bytes)
  ignore(model)
  if report.error_count() != 0 {
    abort("bench model must validate")
  }
  @env.now() - start
}

///|
fn bench_zip_dahlquist() -> UInt64 {
  let data = @fs.read_file_to_bytes("tests/data/.cache/fmi2/Dahlquist.fmu") catch {
    _ => abort("fetch the corpus first: node tests/data/fetch-fmus.mjs")
  }
  let start = @env.now()
  let archive = @zip.ZipArchive::open(data) catch {
    error => abort("zip open failed: " + error.message())
  }
  let entries = archive.extract_all() catch {
    error => abort("zip extract failed: " + error.message())
  }
  ignore(entries.length())
  @env.now() - start
}

///|
fn bench_export_codegen() -> UInt64 {
  let ir = @export.dahlquist_example_ir()
  let start = @env.now()
  ignore(
    @export.model_description_xml(ir, @schema.FmiVersion::V2) catch {
      error => abort("xml2 failed: " + error.message())
    },
  )
  ignore(
    @export.model_description_xml(ir, @schema.FmiVersion::V3) catch {
      error => abort("xml3 failed: " + error.message())
    },
  )
  ignore(@export.generate_model_header(ir))
  ignore(@export.generate_model_c(ir))
  ignore(@export.generate_fmi2_entry(ir))
  ignore(@export.generate_fmi3_entry(ir))
  @env.now() - start
}
