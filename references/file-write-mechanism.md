# File-Write Mechanism

"The file-write mechanism" in N1 skill, reference and persona text means the host's file-creation tool, as mapped by the HOST ROUTING line "Write a file with the file-write mechanism". It never means a shell command.

Use it whenever the content is model, reviewer or untrusted text: Codex findings, validator or developer output, PR bodies, fix reports, triage bodies, tracker or comment text. Never write such content with a shell redirect, heredoc, `cp`, `cat`, `printf`, `echo`, `tee` or `sed -i`: the text can break quoting or run as a command.

Shell commands may still move, delete or pass such a file by path (`mv`, a prefix-guarded `rm`, `--body-file <path>`) as long as they never read or rewrite its content.

## Exception (#44657)

`agents/solution-architect.md` writes `analysis.md` and its snapshot with Bash, because the Claude Code harness may refuse file-creation calls for files named `analysis.md` (#44657). The exception covers those files in that persona only.
