///|
test "native backend starts unloaded" {
  let backend = NativeBackend::new()
  assert_false(backend.is_loaded())
  assert_eq(backend_tag(@fmi.Fmu::placeholder()), "native:placeholder")
}

///|
/// FMI 3 takes the native directory path of `resources/`, terminated by a
/// file separator — not the `file://` URI that FMI 2 takes (FMI 3.0.2
/// §2.3). Reference FMUs concatenate the resource file name straight onto
/// the path, so the separator has to be there.
test "fmi3 resource path stays native and ends with a separator" {
  if host_platform_name().has_prefix("windows") {
    assert_eq(
      fmi3_resource_location("C:/tmp/fmu/resources"),
      "C:\\tmp\\fmu\\resources\\",
    )
    assert_eq(
      fmi3_resource_location("C:\\tmp\\fmu\\resources"),
      "C:\\tmp\\fmu\\resources\\",
    )
    assert_eq(
      fmi3_resource_location("C:\\tmp\\fmu\\resources\\"),
      "C:\\tmp\\fmu\\resources\\",
    )
  } else {
    assert_eq(
      fmi3_resource_location("/tmp/fmu/resources"),
      "/tmp/fmu/resources/",
    )
    assert_eq(
      fmi3_resource_location("/tmp/fmu/resources/"),
      "/tmp/fmu/resources/",
    )
  }
}
