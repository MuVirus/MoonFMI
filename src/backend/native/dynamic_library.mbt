///|
/// A dynamically loaded native library.
///
/// The handle is owned by this value. `close` frees it and marks the value
/// closed; later `symbol` calls fail instead of touching a dangling handle.
pub struct DynamicLibrary {
  handle : @c.Pointer[Unit]
  path : String
  mut closed : Bool
}

///|
pub(all) suberror DynamicLibraryError {
  LibraryNotFound(path~ : String)
  MissingDependency(path~ : String, os_message~ : String)
  LoadFailed(path~ : String, os_message~ : String)
  SymbolNotFound(path~ : String, symbol~ : String, os_message~ : String)
  CloseFailed(path~ : String, os_message~ : String)
}

///|
pub fn DynamicLibraryError::message(self : DynamicLibraryError) -> String {
  match self {
    LibraryNotFound(path~) => "dynamic library was not found: " + path
    MissingDependency(path~, os_message~) =>
      "dynamic library could not be loaded because a dependency is missing: " +
      path +
      " (" +
      os_message +
      ")"
    LoadFailed(path~, os_message~) =>
      "dynamic library could not be loaded: " + path + " (" + os_message + ")"
    SymbolNotFound(path~, symbol~, os_message~) =>
      "symbol '" +
      symbol +
      "' was not found in " +
      path +
      " (" +
      os_message +
      ")"
    CloseFailed(path~, os_message~) =>
      "dynamic library could not be unloaded: " + path + " (" + os_message + ")"
  }
}

///|
#borrow(path)
extern "c" fn dl_open(path : Bytes) -> @c.Pointer[Unit] = "moonfmi_dl_open"

///|
#borrow(symbol)
extern "c" fn dl_sym(
  handle : @c.Pointer[Unit],
  symbol : Bytes,
) -> @c.Pointer[Unit] = "moonfmi_dl_sym"

///|
extern "c" fn dl_close(handle : @c.Pointer[Unit]) -> Int32 = "moonfmi_dl_close"

///|
extern "c" fn dl_last_error() -> Bytes = "moonfmi_dl_last_error"

///|
extern "c" fn dl_last_error_code() -> Int32 = "moonfmi_dl_last_error_code"

///|
pub fn DynamicLibrary::open(
  path : String,
) -> DynamicLibrary raise DynamicLibraryError {
  if !@fs.path_exists(path) {
    raise LibraryNotFound(path~)
  }
  let handle = dl_open(@utf8.encode(path))
  if handle.is_null() {
    // Read the platform error code before formatting the message; the
    // formatting call itself may reset the thread's last-error value.
    let code = dl_last_error_code()
    let os_message = last_error()
    if code == 126 || looks_like_missing_dependency(os_message) {
      raise MissingDependency(path~, os_message~)
    }
    raise LoadFailed(path~, os_message~)
  }
  { handle, path, closed: false, }
}

///|
pub fn DynamicLibrary::path(self : DynamicLibrary) -> String {
  self.path
}

///|
pub fn DynamicLibrary::is_closed(self : DynamicLibrary) -> Bool {
  self.closed
}

///|
pub fn DynamicLibrary::symbol(
  self : DynamicLibrary,
  symbol : String,
) -> @c.Pointer[Unit] raise DynamicLibraryError {
  if self.closed {
    raise SymbolNotFound(
      path=self.path,
      symbol~,
      os_message="the library has already been unloaded",
    )
  }
  let pointer = dl_sym(self.handle, @utf8.encode(symbol))
  if pointer.is_null() {
    raise SymbolNotFound(path=self.path, symbol~, os_message=last_error())
  }
  pointer
}

///|
pub fn[T] DynamicLibrary::funcref(
  self : DynamicLibrary,
  symbol : String,
) -> FuncRef[T] raise DynamicLibraryError {
  self.symbol(symbol).unsafe_into()
}

///|
pub fn DynamicLibrary::close(
  self : DynamicLibrary,
) -> Unit raise DynamicLibraryError {
  if self.closed {
    return
  }
  if dl_close(self.handle) != 0 {
    raise CloseFailed(path=self.path, os_message=last_error())
  }
  self.closed = true
}

///|
fn last_error() -> String {
  @utf8.decode_lossy(dl_last_error().exact_view())
}

///|
fn looks_like_missing_dependency(message : String) -> Bool {
  message.contains("126") ||
  message.contains("module could not be found") ||
  message.contains("cannot open shared object file") ||
  message.contains("image not found")
}
