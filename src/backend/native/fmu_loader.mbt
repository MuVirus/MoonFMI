///|
/// Loading an FMU end to end (tasks C-01/C-03/C-04): container check, model
/// description parse + validation, platform selection, safe extraction,
/// dynamic loading, and instantiation. Everything is released through
/// `LoadedFmu2::dispose`.
/// A successfully loaded FMI 2 co-simulation FMU. `files` lists the names
/// written under `directory` so cleanup can remove exactly those.
pub(all) struct LoadedFmu2 {
  model : @schema.Fmi2ModelDescription
  directory : String
  files : Array[String]
  library : Fmi2Library
  instance : Fmi2Instance
}

///|
pub fn LoadedFmu2::model(self : LoadedFmu2) -> @schema.Fmi2ModelDescription {
  self.model
}

///|
pub fn LoadedFmu2::instance(self : LoadedFmu2) -> Fmi2Instance {
  self.instance
}

///|
/// Release the instance, unload the library, and remove the private
/// extraction directory. Failures are ignored: dispose runs during error
/// paths as well.
pub fn LoadedFmu2::dispose(self : LoadedFmu2) -> Unit {
  self.instance.free()
  Fmi2Library::close(self.library) catch {
    _ => ()
  }
  @fmi.remove_directory_best_effort(self.directory, self.files)
}

///|
/// Loader failures. Container/schema problems carry the validation
/// report; loading problems carry the underlying message.
pub(all) suberror LoaderError {
  Rejected(detail~ : String)
  LoadFailed(detail~ : String)
}

///|

///|
fn render_report(report : @schema.ValidationReport) -> String {
  report.diagnostics().map(fn(d) { d.render() }).join("; ")
}

///|

///|
/// Resolve a possibly-relative directory against the current working
/// directory; FMU resource locations need absolute file:/// URIs.
fn absolute_directory(path : String) -> String {
  if path.has_prefix("/") || path.has_prefix("\\") {
    return path
  }
  if path.length() >= 2 && path[1] == ':' {
    // Windows drive letter.
    return path
  }
  match @env.current_dir() {
    Some(directory) => directory + "/" + path
    None => path
  }
}

///|
pub fn LoaderError::message(self : LoaderError) -> String {
  match self {
    Rejected(detail~) => detail
    LoadFailed(detail~) => detail
  }
}

///|
/// Load an FMI 2 co-simulation FMU from raw bytes.
///
/// - `host` describes the running platform (see `host_platform_name`).
/// - `temp_directory` must be a fresh, empty path owned by the caller;
///   the FMU contents are unpacked there.
/// - `platform_override` restricts the `binaries/` directory to an exact
///   match instead of the host default.
pub fn load_fmi2_fmu(
  data : Bytes,
  host~ : @fmi.HostPlatform,
  temp_directory~ : String,
  platform_override? : String,
  logging_on? : Bool,
  on_log~ : (Fmi2LogMessage) -> Unit = fn(_) {  },
) -> LoadedFmu2 raise LoaderError {
  // FMU internals reference the extraction directory by absolute path
  // (the resource location must be a file:/// URI), so resolve it here.
  let directory = absolute_directory(temp_directory)
  let temp_directory = directory
  if !@fmi.is_zip_archive(data) {
    raise Rejected(
      detail="simulation needs a full FMU archive, not a bare modelDescription.xml",
    )
  }
  let archive = @zip.ZipArchive::open(data) catch {
    error => raise Rejected(detail="cannot open the FMU: \{error.message()}")
  }
  let xml_bytes = archive.read("modelDescription.xml") catch {
    error =>
      raise Rejected(
        detail="the FMU does not contain a readable modelDescription.xml: \{error.message()}",
      )
  }
  let (model, report) = @schema.parse_and_validate(xml_bytes)
  let parsed = match model {
    Some(@schema.V2(m)) => m
    Some(@schema.V3(_)) =>
      raise Rejected(
        detail="this FMU is FMI 3; only FMI 2 co-simulation is supported for now",
      )
    None => {
      let detail = "the model description is invalid: " + render_report(report)
      raise Rejected(detail~)
    }
  }
  if !report.is_valid() {
    let detail = "the model description failed validation: " +
      render_report(report)
    raise Rejected(detail~)
  }
  let co_simulation = match parsed.co_simulation {
    Some(interface) => interface
    None =>
      raise Rejected(
        detail="this FMU does not declare a CoSimulation interface",
      )
  }
  let (platform_dir, binary_name) = @fmi.select_platform(
    archive.entries().map(fn(e) { e.name() }),
    @schema.V2,
    model_identifier=co_simulation.model_identifier,
    host~,
    requested=platform_override,
  ) catch {
    error => raise Rejected(detail=error.message())
  }
  let files = @fmi.extract_fmu_to_directory(archive, temp_directory) catch {
    error => raise LoadFailed(detail=error.message())
  }
  let library_path = temp_directory +
    "/binaries/" +
    platform_dir +
    "/" +
    binary_name
  let library = Fmi2Library::open(library_path) catch {
    error => {
      @fmi.remove_directory_best_effort(temp_directory, files)
      raise LoadFailed(
        detail="loading '\{library_path}' failed: \{error.message()}",
      )
    }
  }
  let version = Fmi2Library::version(library)
  if !version.has_prefix("2.0") {
    Fmi2Library::close(library) catch {
      _ => ()
    }
    @fmi.remove_directory_best_effort(temp_directory, files)
    raise LoadFailed(
      detail="the FMU binary reports fmi2GetVersion='\{version}', expected 2.0",
    )
  }
  let resource_directory = temp_directory + "/resources"
  let instance = Fmi2Library::instantiate(
    library,
    instance_name=parsed.model_name,
    guid=parsed.guid,
    resource_path=resource_directory,
    logging_on=logging_on.unwrap_or(true),
    on_log~,
  ) catch {
    error => {
      Fmi2Library::close(library) catch {
        _ => ()
      }
      @fmi.remove_directory_best_effort(temp_directory, files)
      raise LoadFailed(detail=error.message())
    }
  }
  { model: parsed, directory: temp_directory, files, library, instance, }
}

///|
/// A successfully loaded FMI 2 model-exchange FMU. The state and event
/// indicator counts come from the model description (`Derivatives` length
/// and `numberOfEventIndicators`) and size the master algorithm's buffers.
pub(all) struct LoadedFmu2Me {
  model : @schema.Fmi2ModelDescription
  directory : String
  files : Array[String]
  library : Fmi2Library
  instance : Fmi2Instance
  state_count : Int32
  event_indicator_count : Int32
}

///|
pub fn LoadedFmu2Me::model(self : LoadedFmu2Me) -> @schema.Fmi2ModelDescription {
  self.model
}

///|
pub fn LoadedFmu2Me::instance(self : LoadedFmu2Me) -> Fmi2Instance {
  self.instance
}

///|
/// Release the instance, unload the library, and remove the private
/// extraction directory. Failures are ignored: dispose runs during error
/// paths as well.
pub fn LoadedFmu2Me::dispose(self : LoadedFmu2Me) -> Unit {
  self.instance.free()
  Fmi2Library::close(self.library) catch {
    _ => ()
  }
  @fmi.remove_directory_best_effort(self.directory, self.files)
}

///|
/// Load an FMI 2 model-exchange FMU from raw bytes. The arguments mirror
/// `load_fmi2_fmu`; the FMU must declare a `ModelExchange` interface.
pub fn load_fmi2_me_fmu(
  data : Bytes,
  host~ : @fmi.HostPlatform,
  temp_directory~ : String,
  platform_override? : String,
  logging_on? : Bool,
  on_log~ : (Fmi2LogMessage) -> Unit = fn(_) {  },
) -> LoadedFmu2Me raise LoaderError {
  // FMU internals reference the extraction directory by absolute path
  // (the resource location must be a file:/// URI), so resolve it here.
  let directory = absolute_directory(temp_directory)
  let temp_directory = directory
  if !@fmi.is_zip_archive(data) {
    raise Rejected(
      detail="simulation needs a full FMU archive, not a bare modelDescription.xml",
    )
  }
  let archive = @zip.ZipArchive::open(data) catch {
    error => raise Rejected(detail="cannot open the FMU: \{error.message()}")
  }
  let xml_bytes = archive.read("modelDescription.xml") catch {
    error =>
      raise Rejected(
        detail="the FMU does not contain a readable modelDescription.xml: \{error.message()}",
      )
  }
  let (model, report) = @schema.parse_and_validate(xml_bytes)
  let parsed = match model {
    Some(@schema.V2(m)) => m
    Some(@schema.V3(_)) =>
      raise Rejected(
        detail="this FMU is FMI 3; only FMI 2 model exchange is supported for now",
      )
    None => {
      let detail = "the model description is invalid: " + render_report(report)
      raise Rejected(detail~)
    }
  }
  if !report.is_valid() {
    let detail = "the model description failed validation: " +
      render_report(report)
    raise Rejected(detail~)
  }
  let model_exchange = match parsed.model_exchange {
    Some(interface) => interface
    None =>
      raise Rejected(
        detail="this FMU does not declare a ModelExchange interface",
      )
  }
  let state_count = parsed.model_structure.derivatives.length()
  if state_count == 0 {
    raise Rejected(
      detail="the model declares no Derivatives in its ModelStructure; there is nothing to integrate",
    )
  }
  let (platform_dir, binary_name) = @fmi.select_platform(
    archive.entries().map(fn(e) { e.name() }),
    @schema.V2,
    model_identifier=model_exchange.model_identifier,
    host~,
    requested=platform_override,
  ) catch {
    error => raise Rejected(detail=error.message())
  }
  let files = @fmi.extract_fmu_to_directory(archive, temp_directory) catch {
    error => raise LoadFailed(detail=error.message())
  }
  let library_path = temp_directory +
    "/binaries/" +
    platform_dir +
    "/" +
    binary_name
  let library = Fmi2Library::open(library_path) catch {
    error => {
      @fmi.remove_directory_best_effort(temp_directory, files)
      raise LoadFailed(
        detail="loading '\{library_path}' failed: \{error.message()}",
      )
    }
  }
  let version = Fmi2Library::version(library)
  if !version.has_prefix("2.0") {
    Fmi2Library::close(library) catch {
      _ => ()
    }
    @fmi.remove_directory_best_effort(temp_directory, files)
    raise LoadFailed(
      detail="the FMU binary reports fmi2GetVersion='\{version}', expected 2.0",
    )
  }
  let resource_directory = temp_directory + "/resources"
  let instance = Fmi2Library::instantiate_me(
    library,
    instance_name=parsed.model_name,
    guid=parsed.guid,
    resource_path=resource_directory,
    logging_on=logging_on.unwrap_or(true),
    on_log~,
  ) catch {
    error => {
      Fmi2Library::close(library) catch {
        _ => ()
      }
      @fmi.remove_directory_best_effort(temp_directory, files)
      raise LoadFailed(detail=error.message())
    }
  }
  {
    model: parsed,
    directory: temp_directory,
    files,
    library,
    instance,
    state_count,
    event_indicator_count: parsed.number_of_event_indicators
    .unwrap_or(0U)
    .reinterpret_as_int(),
  }
}
