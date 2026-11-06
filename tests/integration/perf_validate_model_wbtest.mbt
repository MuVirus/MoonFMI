///|
/// Generator shared by the 10k-variable performance gates. Variables cycle
/// through input/output/parameter/local roles and every fourth variable
/// becomes an output listed in ModelStructure.
fn generate_large_model(count : Int32) -> String {
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
      builder.write_string("<ScalarVariable name=\"u")
      builder.write_string(suffix)
      builder.write_string("\" valueReference=\"")
      builder.write_string(reference)
      builder.write_string(
        "\" causality=\"input\" variability=\"continuous\" initial=\"exact\"><Real start=\"0\"/></ScalarVariable>\n",
      )
    } else if i % 4 == 1 {
      builder.write_string("<ScalarVariable name=\"y")
      builder.write_string(suffix)
      builder.write_string("\" valueReference=\"")
      builder.write_string(reference)
      builder.write_string(
        "\" causality=\"output\" variability=\"continuous\" initial=\"calculated\"><Real/></ScalarVariable>\n",
      )
    } else if i % 4 == 2 {
      builder.write_string("<ScalarVariable name=\"p")
      builder.write_string(suffix)
      builder.write_string("\" valueReference=\"")
      builder.write_string(reference)
      builder.write_string(
        "\" causality=\"parameter\" variability=\"fixed\" initial=\"exact\"><Real start=\"1\" min=\"0\" max=\"10\" nominal=\"1\"/></ScalarVariable>\n",
      )
    } else {
      builder.write_string("<ScalarVariable name=\"d")
      builder.write_string(suffix)
      builder.write_string("\" valueReference=\"")
      builder.write_string(reference)
      builder.write_string(
        "\" causality=\"local\" variability=\"discrete\" initial=\"calculated\"><Integer min=\"0\" max=\"3\"/></ScalarVariable>\n",
      )
    }
  }
  builder.write_string(
    "  </ModelVariables>\n  <ModelStructure>\n    <Outputs>\n",
  )
  for i = 0; i < count; i = i + 1 {
    if i % 4 == 1 {
      builder.write_string("<Unknown index=\"")
      builder.write_string((i + 1).to_string())
      builder.write_string("\"/>\n")
    }
  }
  builder.write_string(
    "    </Outputs>\n  </ModelStructure>\n</fmiModelDescription>\n",
  )
  builder.to_string()
}
