///|
/// The host platform description used for FMI platform-directory
/// selection, produced by the C stub at load time (task C-02).
pub fn host_platform_name() -> String {
  @utf8.decode_lossy(dl_host_platform().exact_view())
}

///|
extern "C" fn dl_host_platform() -> Bytes = "moonfmi_dl_host_platform"
