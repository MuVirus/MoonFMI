///|
/// Platform selection (task C-02). FMI platform directory names must match
/// the standard exactly — no fuzzy matching between FMI 2 (`win64`) and
/// FMI 3 (`x86_64-windows`) conventions.
/// The operating system part of a host platform description.
#derive(Eq, Debug)
pub(all) enum HostOs {
  Windows
  Linux
  Darwin
}

///|
pub extend HostOs with Eq::{not_equal, equal}

///|
pub extend HostOs with @debug.Debug::{to_repr}

///|
/// A host platform: operating system plus CPU description as written in
/// the host name (`x64`, `arm64`, `x86`, `arm32`).
#derive(Eq, Debug)
pub struct HostPlatform {
  os : HostOs
  cpu : String
  bits : Int32
}

///|
pub extend HostPlatform with Eq::{not_equal, equal}

///|
pub extend HostPlatform with @debug.Debug::{to_repr}

///|
/// Parse a host description of the form `windows-x64`, `linux-arm64`, or
/// `darwin-x64` (as produced by the native stub). Returns `None` for
/// unknown names.
pub fn parse_host_platform(name : String) -> HostPlatform? {
  let parts : Array[String] = name
    .split("-")
    .collect()
    .map(fn(v) { v.to_owned() })
  if parts.length() != 2 {
    return None
  }
  let os = match parts[0] {
    "windows" => Windows
    "linux" => Linux
    "darwin" => Darwin
    _ => return None
  }
  let cpu = parts[1]
  let bits = match cpu {
    "x64" | "arm64" => 64
    "x86" | "arm32" => 32
    _ => return None
  }
  Some({ os, cpu, bits, })
}

///|
/// The FMI 2 `binaries/` directory name for a host platform.
pub fn fmi2_platform_dir(host : HostPlatform) -> String {
  let suffix = if host.bits == 64 { "64" } else { "32" }
  match host.os {
    Windows => "win" + suffix
    Linux => "linux" + suffix
    Darwin => "darwin" + suffix
  }
}

///|
/// The FMI 3 `binaries/` directory name for a host platform. The FMI 3
/// naming spells out the CPU family.
pub fn fmi3_platform_dir(host : HostPlatform) -> String {
  match (host.os, host.cpu) {
    (Windows, "x64") => "x86_64-windows"
    (Windows, "arm64") => "aarch64-windows"
    (Windows, "x86") => "x86-windows"
    (Linux, "x64") => "x86_64-linux"
    (Linux, "arm64") => "aarch64-linux"
    (Linux, "x86") => "x86-linux"
    (Darwin, "x64") => "x86_64-darwin"
    (Darwin, "arm64") => "aarch64-darwin"
    _ =>
      // FMI 3 does not define 32-bit ARM directories; fall back to the
      // closest spelling so the error message stays useful.
      match (host.os, host.bits) {
        (Windows, _) => "x86-windows"
        (Linux, _) => "x86-linux"
        (Darwin, _) => "x86-darwin"
      }
  }
}

///|
/// The shared-library file extension for the host operating system.
pub fn library_extension(host : HostPlatform) -> String {
  match host.os {
    Windows => ".dll"
    Linux => ".so"
    Darwin => ".dylib"
  }
}

///|
/// The `binaries/` directory name for the given model version and host.
pub fn platform_dir(
  version : @schema.FmiVersion,
  host : HostPlatform,
) -> String {
  match version {
    @schema.V2 => fmi2_platform_dir(host)
    @schema.V3 => fmi3_platform_dir(host)
  }
}

///|
suberror PlatformSelectionError {
  /// The requested override directory does not exist in the archive.
  OverrideMissing(dir~ : String, available~ : Array[String])
  /// The host platform directory is not in the archive.
  HostMissing(dir~ : String, available~ : Array[String])
  /// The directory exists but does not contain the model binary.
  BinaryMissing(dir~ : String, binary~ : String, available~ : Array[String])
  /// No platform binary exists at all, but the FMU ships sources.
  NeedsCompilation(available~ : Array[String])
  /// The archive carries no binaries and no sources.
  NoBinaries(available~ : Array[String])
}

///|
pub fn PlatformSelectionError::message(self : PlatformSelectionError) -> String {
  match self {
    OverrideMissing(dir~, available~) =>
      "platform override '\{dir}' is not present in the FMU (available: \{available.join(", ")})"
    HostMissing(dir~, available~) =>
      "this FMU has no binary for the host platform '\{dir}' (available: \{available.join(", ")})"
    BinaryMissing(dir~, binary~, available~) =>
      "the FMU directory '\{dir}' does not contain '\{binary}'" +
      (if available.is_empty() {
        ""
      } else {
        " (available: \{available.join(", ")})"
      })
    NeedsCompilation(available~) =>
      "this FMU ships sources instead of binaries and must be compiled first (binaries present: \{available.join(", ")})"
    NoBinaries(available~) =>
      "this FMU contains no platform binaries (directories: \{available.join(", ")})"
  }
}

///|
/// List the platform directories under `binaries/` from the archive entry
/// names. Returns directory names without the `binaries/` prefix (e.g.
/// `win64`, `linux64`).
pub fn list_platform_dirs(entries : Array[String]) -> Array[String] {
  let dirs : Array[String] = []
  let seen : Map[String, Unit] = Map([])
  for entry in entries {
    let prefix = "binaries/"
    if entry.has_prefix(prefix) && entry.length() > prefix.length() {
      let rest = entry[prefix.length():].to_owned()
      let dir = match rest.find("/") {
        Some(position) => rest[:position].to_owned()
        None => rest
      }
      if dir != "" && !seen.contains(dir) {
        seen.set(dir, ())
        dirs.push(dir)
      }
    }
  }
  dirs
}

///|
/// Choose the platform directory and the binary name inside it.
/// Returns `(directory, binary_file_name)`.
pub fn select_platform(
  entries : Array[String],
  version : @schema.FmiVersion,
  model_identifier~ : String,
  host~ : HostPlatform,
  requested~ : String?,
) -> (String, String) raise PlatformSelectionError {
  let available = list_platform_dirs(entries)
  let binary = model_identifier + library_extension(host)
  match requested {
    Some(requested) => {
      // An override only accepts exact matches.
      let prefix = "binaries/" + requested + "/" + binary
      for entry in entries {
        if entry == prefix {
          return (requested, binary)
        }
      }
      if !available.contains(requested) {
        raise OverrideMissing(dir=requested, available~)
      }
      raise BinaryMissing(dir=requested, binary~, available~)
    }
    None => {
      if available.is_empty() {
        // Sources FMU: tell the user this FMU needs compiling.
        for entry in entries {
          if entry.has_prefix("sources/") {
            raise NeedsCompilation(available~)
          }
        }
        raise NoBinaries(available~)
      }
      let dir = platform_dir(version, host)
      if !available.contains(dir) {
        raise HostMissing(dir~, available~)
      }
      let prefix = "binaries/" + dir + "/" + binary
      for entry in entries {
        if entry == prefix {
          return (dir, binary)
        }
      }
      raise BinaryMissing(dir~, binary~, available~)
    }
  }
}
