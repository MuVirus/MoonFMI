///|
/// `moonfmi` executable entry point. Reads the file argument itself so the
/// CLI library stays target-neutral; `@cli.run` maps failures to the
/// stable exit codes documented in `src/cli/cli.mbt`.
fn main {
  let args = drop_program_name(@env.args())
  let code = @cli.run(args, path => {
    @fs.read_file_to_bytes(path) catch {
      error =>
        match error {
          IOError(message) => raise @cli.ReadError::Failed(message)
        }
    }
  })
  @env.exit(code)
}

///|
/// Some runtimes pass the program path as argv[0]; drop it when the first
/// argument is not a known subcommand but looks like a path.
fn drop_program_name(args : Array[String]) -> Array[String] {
  if args.is_empty() {
    return args
  }
  let first = args[0]
  if first.contains("/") || first.contains("\\") {
    let rest : Array[String] = []
    for index = 1; index < args.length(); index = index + 1 {
      rest.push(args[index])
    }
    return rest
  }
  args
}
