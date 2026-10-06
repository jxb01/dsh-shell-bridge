<!-- DSH-SHELL-BRIDGE:BEGIN -->
# Route every shell command through the dsh-shell bridge

The stock pwsh tool runs each command as `pwsh -Command <text>` on a machine whose console
code page is a legacy ANSI/OEM page (936 on zh-CN Windows). Measured on this platform, that
produces: mojibake from native tools (ipconfig/python/systeminfo emit cp936 but the harness
decodes UTF-8), mojibake when piping text into native tools, `param()`/`using` parse errors
because the injected encoding preamble is no longer first, `spawn ENAMETOOLONG` past the
~32 KB Windows command-line ceiling, and backslash/quote text that must survive JSON and
PowerShell escaping before the command even starts.

Therefore: **run all PowerShell / cmd work through the bridge; do not hand the pwsh tool
complex commands directly.**

## Two-step workflow

1. Use the `write` tool to save the exact script to `@@TASKS@@/main.ps1`
   (or `main.cmd` for cmd). File content is literal: backslashes, quotes and CJK
   punctuation are preserved without another escaping layer.
2. Run it with the pwsh tool. End the command with `; exit $LASTEXITCODE` so the
   exit code is propagated:

   & '@@BRIDGE@@'; exit $LASTEXITCODE

   This runs tasks/main.ps1. Variants (keep the `; exit $LASTEXITCODE` suffix):
   - another task:  `& '@@BRIDGE@@' -Name build; exit $LASTEXITCODE`
   - a cmd task:    `& '@@BRIDGE@@' -Shell cmd -Name build; exit $LASTEXITCODE`
   - workdir/timeout: `... -WorkDir 'D:/repo' -TimeoutSec 600; exit $LASTEXITCODE`
   - a small inline command: `... -Command 'Get-Date'; exit $LASTEXITCODE`

stdout/stderr and the exit code come back as-is. The bridge runs the child shell under a
hidden console pinned to code page 65001.

## Punctuation rules while writing the script

- Prefer forward slashes for paths: `D:/work/_lab`. PowerShell and most native tools accept
  them, and it avoids JSON backslash escaping entirely.
- Use single-quoted literals; paths containing `[ ] & # % ! ^ , ; = + @ ~` or spaces must use
  `-LiteralPath` (otherwise `[]` is a wildcard and `&` is a background operator).
- Never end an array/hashtable literal with a trailing comma: `@('a',)` is a PowerShell
  syntax error ("missing expression after ','").
- CJK curly quotes `“ ” ‘ ’` act as quote delimiters: `“ ”` truncate a
  double-quoted string and `‘ ’` truncate a single-quoted one. Put them in the other
  quote type or build them with `[char]0x201C`.
- Run cmd builtins (dir, copy, ...) with `-Shell cmd`; do not wrap `cmd /c` inside PowerShell,
  where `^`, `&` and `%` are interpreted first.
- For long-running work, wrap the bridge call above in the pwsh tool's `run_in_background`.
<!-- DSH-SHELL-BRIDGE:END -->
