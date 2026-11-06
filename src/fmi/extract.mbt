///|
/// Safe extraction of an FMU archive into a private directory (task C-03).
/// The zip package already rejects path traversal, duplicate entries,
/// oversized entries, and compression bombs; this layer adds the private
/// target directory, file writing, and best-effort cleanup on failure.
suberror ExtractionError {
  IoFailed(detail~ : String)
  UnsafeEntry(name~ : String)
}

///|
pub fn ExtractionError::message(self : ExtractionError) -> String {
  match self {
    IoFailed(detail~) => "writing the FMU contents failed: \{detail}"
    UnsafeEntry(name~) => "refusing to extract the suspicious entry '\{name}'"
  }
}

///|
/// True for entries that must never be written as files.
fn is_unsafe_entry_name(name : String) -> Bool {
  if name == "" {
    return true
  }
  if name.contains("..") || name.contains(":") {
    return true
  }
  false
}

///|
/// Extract every entry of the archive into `directory`. The directory is
/// created if needed. Returns the list of written file names. On any
/// failure the already-written files are removed best-effort.
pub fn extract_fmu_to_directory(
  archive : @zip.ZipArchive,
  directory : String,
) -> Array[String] raise ExtractionError {
  @fs.create_dir(directory) catch {
    error =>
      raise IoFailed(detail="cannot create \{directory}: \{io_text(error)}")
  }
  let written : Array[String] = []
  let files = archive.extract_all() catch {
    error => raise IoFailed(detail="cannot unpack the FMU: \{error.message()}")
  }
  for pair in files {
    let (name, bytes) = pair
    if name.has_suffix("/") {
      // Directory markers carry no data; their files create the layout.
      continue
    }
    if is_unsafe_entry_name(name) {
      cleanup_files(directory, written)
      raise UnsafeEntry(name~)
    }
    let target = directory + "/" + name
    // Intermediate directories inside the FMU (e.g. binaries/win64) are
    // created as needed; fzip entry names use forward slashes.
    errdefer cleanup_files(directory, written)
    create_parent_directories(directory, name)
    @fs.write_bytes_to_file(target, bytes) catch {
      error =>
        raise IoFailed(detail="cannot write \{target}: \{io_text(error)}")
    }
    written.push(name)
  }
  written
}

///|
fn io_text(error : @fs.IOError) -> String {
  match error {
    @fs.IOError(message) => message
  }
}

///|
/// Create the parent directories of `name` (relative to `root`).
fn create_parent_directories(
  root : String,
  name : String,
) -> Unit raise ExtractionError {
  let mut position = 0
  while true {
    match name.find_from_slash(position) {
      Some(index) => {
        let segment = name[:index].to_owned()
        if segment != "" {
          let dir = root + "/" + segment
          let exists = @fs.is_dir(dir) catch { _ => false }
          if !exists {
            @fs.create_dir(dir) catch {
              error =>
                raise IoFailed(detail="cannot create \{dir}: \{io_text(error)}")
            }
          }
        }
        position = index + 1
      }
      None => return
    }
  }
}

///|
/// Find the next '/' at or after `position` in the string.
fn String::find_from_slash(self : String, position : Int32) -> Int32? {
  for index = position; index < self.length(); index = index + 1 {
    if self[index] == 47 {
      return Some(index)
    }
  }
  None
}

///|
/// Best-effort removal of the files written into `directory`. Errors are
/// deliberately ignored.
fn cleanup_files(directory : String, names : Array[String]) -> Unit {
  for name in names {
    let target = directory + "/" + name
    @fs.remove_file(target) catch {
      _ => ()
    }
  }
}

///|
/// Remove a private extraction directory after a successful run: every
/// file is removed first, then the directory itself. Failures are ignored
/// - leftover temporary files are preferable to failing a finished
/// simulation.
pub fn remove_directory_best_effort(
  directory : String,
  names : Array[String],
) -> Unit {
  for name in names {
    let target = directory + "/" + name
    @fs.remove_file(target) catch {
      _ => ()
    }
  }
  @fs.remove_dir(directory) catch {
    _ => ()
  }
}
