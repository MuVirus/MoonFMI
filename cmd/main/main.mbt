///|
/// `moonfmi` executable entry point. Reads the file argument itself so the
/// CLI library stays target-neutral; `@cli.run` maps failures to the
/// stable exit codes documented in `src/cli/cli.mbt`.
///
/// `--sandbox` is handled here because it re-executes the command in a
/// child process, which needs the async runtime (`--sandbox` is crash
/// isolation plus a hard watchdog, not a permission sandbox — see
/// `src/cli/sandbox.mbt`).
async fn main {
  let args = drop_program_name(@env.args())
  if @cli.wants_sandbox(args) && !@cli.is_sandbox_child() {
    let code = @cli.run_sandboxed(args) catch {
      error => {
        println("moonfmi: sandboxed child could not be started: \{error}")
        Some(1)
      }
    }
    @env.exit(
      match code {
        Some(code) => code
        None => {
          println(
            "moonfmi: sandboxed child exceeded its --timeout budget and was killed",
          )
          6
        }
      },
    )
  }
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
