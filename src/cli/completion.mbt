///|
/// `moonfmi completion <shell>` (task D-07): static completion scripts.
/// The command set is small, so the scripts are generated verbatim rather
/// than derived from a parser.
fn completion_script(shell : String) -> String {
  match shell {
    "bash" =>
      "# bash completion for moonfmi\n" +
      "_moonfmi_completions() {\n" +
      "  local commands=\"validate info simulate package doctor completion version\"\n" +
      "  local cur=\"\\${COMP_WORDS[COMP_CWORD]}\"\n" +
      "  if [ \"$COMP_CWORD\" -eq 1 ]; then\n" +
      "    COMPREPLY=( $(compgen -W \"$commands\" -- \"$cur\") )\n" +
      "  else\n" +
      "    COMPREPLY=( $(compgen -f -- \"$cur\") )\n" +
      "  fi\n" +
      "}\n" +
      "complete -F _moonfmi_completions moonfmi\n"
    "zsh" =>
      "#compdef moonfmi\n" +
      "# zsh completion for moonfmi\n" +
      "_arguments -C \\\n" +
      "  '1:command:(validate info simulate package doctor completion version)' \\\n" +
      "  '*:file:_files'\n"
    "pwsh" =>
      "# PowerShell completion for moonfmi (source this file or add to $PROFILE)\n" +
      "Register-ArgumentCompleter -Native -CommandName moonfmi -ScriptBlock {\n" +
      "  param($wordToComplete, $commandAst, $cursorPosition)\n" +
      "  $commands = 'validate', 'info', 'simulate', 'package', 'doctor', 'completion', 'version'\n" +
      "  $commands | Where-Object { $_ -like \"$wordToComplete*\" } |\n" +
      "    ForEach-Object { [System.Management.Automation.CompletionResult]::new($_) }\n" +
      "}\n"
    _ =>
      "moonfmi completion: unknown shell '" +
      shell +
      "' (use bash, zsh or pwsh)\n"
  }
}
