///|
test "placeholder FMU has a name and an empty archive" {
  let fmu = Fmu::placeholder()
  assert_eq(fmu.name(), "placeholder")
  assert_eq(fmu.version(), @schema.FmiVersion::V2)
  assert_eq(fmu.entry_count(), 0)
}

///|
/// FMI 2 platform directory mapping (0.7.0): 64-bit ARM hosts use the
/// `aarch64-*` directory names the Reference-FMUs corpus ships, because
/// the plain `linux64` name implies an x86-64 binary that cannot load on
/// an ARM host.
test "fmi2 platform directories are arch-aware for arm64" {
  let linux_arm64 = parse_host_platform("linux-arm64").unwrap()
  assert_eq(fmi2_platform_dir(linux_arm64), "aarch64-linux")
  let darwin_arm64 = parse_host_platform("darwin-arm64").unwrap()
  assert_eq(fmi2_platform_dir(darwin_arm64), "aarch64-darwin")
  // The x86-64 spellings stay as they were.
  let linux_x64 = parse_host_platform("linux-x64").unwrap()
  assert_eq(fmi2_platform_dir(linux_x64), "linux64")
  let windows_x64 = parse_host_platform("windows-x64").unwrap()
  assert_eq(fmi2_platform_dir(windows_x64), "win64")
  let linux_x86 = parse_host_platform("linux-x86").unwrap()
  assert_eq(fmi2_platform_dir(linux_x86), "linux32")
  // FMI 3 already spelled out the CPU family and is unchanged.
  assert_eq(fmi3_platform_dir(linux_arm64), "aarch64-linux")
}
