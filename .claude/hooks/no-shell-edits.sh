#!/usr/bin/env bash
# PreToolUse/Bash: deny a shell command being used to edit files.
#
# Edits go through Edit and Write, which render a reviewable diff. A script
# rewrite renders nothing, so the change is invisible and has to be taken on
# trust from a summary — and batching six into one script is what makes a bad
# edit hard to catch.
#
# The patterns below only decide what is worth asking about; Claude decides
# whether it is an edit. Nothing is denied on the shape of the text, because
# text cannot tell a command from a commit message quoting one.
#
# It fails open throughout — a missing CLI, a hook the harness kills for being
# slow, or any answer that is not a clean verdict all let the command run.
# Blocking a commit costs more than letting an edit through.
#
# Always exits 0; a denial is carried in the JSON, not the exit code.
set -uo pipefail

cmd=$(jq -r '.tool_input.command // ""')

# Interpreters by name, and the in-place flags of the two stream editors.
# Requiring the flag keeps a plain `sed -n '1,5p' file` off the slow path.
#
# This list is short on purpose, and is not the set of ways a shell can write a
# file: a bare `> file`, `tee` and `git checkout --` all pass it untouched. It
# holds what Claude has actually reached for, which is python and bash, and a
# blocked attempt gets a denial message naming Edit — so the first try is the
# one worth catching. A shape earns a pattern by being used as a workaround,
# never by being imaginable.
grep -qiE 'python|bash' <<<"$cmd" ||
  grep -qE '(^|[^[:alnum:]_])sed[^|;&]*[[:space:]]-[[:alnum:]]*i' <<<"$cmd" ||
  grep -qE '(^|[^[:alnum:]_])perl[^|;&]*[[:space:]]-[[:alnum:].]*i' <<<"$cmd" ||
  exit 0

command -v claude >/dev/null || exit 0

read -r -d '' prompt <<PROMPT
You are a guard on a code repository. Decide whether the shell command below
writes to a file inside the project working tree — a script that opens a file
for writing or appending, an in-place stream edit, or a redirect into a tracked
path.

Answer ALLOW for everything else, including: reading or printing files, running
tests, builds, linters or formatters, git and gh commands, and writes to /tmp or
a scratchpad directory. Text inside a commit message or a string literal is not
a command.

Reply with exactly one word, BLOCK or ALLOW. If you are unsure, reply ALLOW.

Command:
$cmd
PROMPT

# Run from /tmp so the nested CLI does not load this project's hooks and call
# itself. Closing stdin skips a 3-second wait for piped input that never comes.
# No timeout here: the hook's own timeout in .claude/settings.json kills a slow
# call, and a killed hook allows the command.
verdict=$(cd /tmp && claude -p \
  --model claude-opus-5 \
  --disable-slash-commands \
  "$prompt" </dev/null 2>/dev/null |
  grep -oiE '\b(BLOCK|ALLOW)\b' | head -1 | tr '[:lower:]' '[:upper:]')

[[ $verdict == BLOCK ]] && deny=1
if [[ ${deny:-} == 1 ]]; then
  jq -n --arg r "You MUST NOT use shell commands to edit source or documentation files, use the Edit tool instead." '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
fi
exit 0
