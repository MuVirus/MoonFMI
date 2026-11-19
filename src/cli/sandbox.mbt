///|
/// `--sandbox`: re-execute the same command in a child process (R11
/// mitigation). This is crash isolation plus a hard wall-clock watchdog —
/// an FMU segfault or hang kills the child instead of the parent — not a
/// permission sandbox: the child FMU still runs with the host user's
/// permissions (docs/design/security-review.md R1).

///|
/// Environment guard marking a sandboxed child, so a child never
/// re-sandboxes itself.
let sandbox_guard_env : String = "MOONFMI_SANDBOX_CHILD"

///|
/// Whether this process is already a sandboxed child.
pub fn is_sandbox_child() -> Bool {
  match @env.get_env_var(sandbox_guard_env) {
    Some(_) => true
    None => false
  }
}

///|
/// Whether the command line carries `--sandbox`.
pub fn wants_sandbox(args : Array[String]) -> Bool {
  for arg in args {
    if arg == "--sandbox" {
      return true
    }
  }
  false
}

///|
/// The parent-side watchdog budget in milliseconds, derived from the first
/// `--timeout SEC` on the command line plus 1 s of slack for process
/// startup and teardown. The child's own `--timeout` fires earlier (it has
/// no slack), so the watchdog only catches FMUs hung in native code where
/// the cooperative deadline check never runs. `None` = no watchdog.
fn sandbox_watchdog_ms(args : Array[String]) -> UInt64? {
  let mut index = 0
  while index < args.length() {
    if args[index] == "--timeout" && index + 1 < args.length() {
      match parse_simulation_double(args[index + 1]) {
        Some(seconds) =>
          if seconds > 0.0 {
            return Some(seconds.to_uint64() * 1_000UL + 1_000UL)
          }
        None => ()
      }
    }
    index += 1
  }
  None
}

///|
/// Execute `args` in a sandboxed child, forwarding stdout/stderr. Returns
/// `None` when the watchdog killed the child; otherwise the child's exit
/// code. Raises when the child could not be started at all.
pub async fn run_sandboxed(args : Array[String]) -> Int32? {
  let self_path = @env.args()[0]
  let child_args : Array[String] = []
  for arg in args {
    if arg != "--sandbox" {
      child_args.push(arg)
    }
  }
  let extra_env : Map[String, String] = Map([])
  extra_env[sandbox_guard_env] = "1"
  let run = () => {
    @process.run(
      self_path,
      child_args,
      extra_env~,
      inherit_env=true,
      stdout=@stdio.stdout,
      stderr=@stdio.stderr,
      cancel_handler=@process.hard_cancel(),
    )
  }
  match sandbox_watchdog_ms(args) {
    Some(ms) => @async.with_timeout_opt(ms.to_int(), run)
    None => Some(run())
  }
}
