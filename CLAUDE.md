# Instructions for Claude Code

## This repo is public and pseudonymous

Never commit identifying details, machine-local paths, anything describing the
archived library under `output_dir`, or live session material. The full list is
in
[`.claude/skills/personal-check/SKILL.md`](./.claude/skills/personal-check/SKILL.md)
→ What must never be committed; that file is the single copy of the rules, and a
category added there is scanned for without this file changing.

## Comments and documentation

A comment carries what the code cannot: the constraint that forced this shape,
the measured value, the API's actual behaviour. If a sentence would still be
true with the code deleted, or is already legible from the lines beneath it, cut
it.

- **Every sentence must add a fact.** Delete a sentence that restates the one
  before it in other words, and phrases that assert importance rather than
  supply it — "this is the point", "deliberately", "it is worth saying", "and
  that is fine", "the whole trick".
- **No archaeology.** Not "an earlier version did X", "this used to be Y", "the
  one it replaced". Git holds that. Where a past bug will be reintroduced
  without the warning, state the constraint that prevents it — once, at the site
  that enforces it — not the story of finding it.
- **Facts must be checkable and current.** A number (70ms, 20 KB, 256) is one
  someone measured; a filename, header or method named in prose must exist. When
  the code moves, the comment is part of the change: `.part` file, `/tmp`,
  `ofdl auth` were all comments describing code that had since moved on.
- **One home per fact.** The definition site owns the reason; the call site
  points at it (`see Thumbnail.build`). A reason written out twice becomes two
  things to keep in step, and they drift.
- **Plain and literal.** No metaphor, no anthropomorphism: "OnlyFans returns a
  reason in the body", not "OnlyFans explains itself"; "the columns hold", not
  "the filenames wander".
- **When revising, cut or correct.** Splitting a long sentence into two shorter
  ones changes nothing and is churn; either the words earn their place or they
  go.

Two documents, and a change belongs in exactly one. [README.md](./README.md) is
for someone running the app: what it does, what it needs, how to drive it, what
the screen means, and every config key. [DEVELOPERS.md](./DEVELOPERS.md) is for
someone changing it: the pipeline, the terminal drawing, the transport, and the
tests. A mechanism explained in the README is in the wrong file; so is a config
key documented only in DEVELOPERS.

README.md additionally: sample output must match what the program prints today,
the config table must match `Config::DEFAULTS`, and any count in it must be
re-derived rather than carried forward. Do not state the number of tests
anywhere -- it changes constantly and carries nothing.

In short : No archeaology, no metaphors, no gloss or flourish, no anthropomorpic
language anywhere. Just precise and technical language.

## Talking to the user

Use the same guidelines when talking to the user.

## Editing files

Change files with **Edit and Write, never a shell rewrite** — a script rewrite
renders no diff, so the change has to be taken on trust from a summary.
[`.claude/hooks/no-shell-edits.sh`](./.claude/hooks/no-shell-edits.sh) enforces
this. Shell commands that only read are unaffected.

## Verifying changes

- `rake test` — the whole suite, offline. Nothing in it contacts OnlyFans.
- `bundle exec rubocop` — Ruby.
- `npm run format:check` — markdown and JSON. `npm run format` writes.

## Git workflow

- Put a change on a branch off `master`. **A docs or comments change _alone_
  doesn't get a branch** — commit it to `master`. Where a branch is already open
  for other work, docs belong on it like anything else; never carve them out of
  an active branch.
- The flow is **branch → do the work → gates → commit → push → open a PR →
  merge**: push with `git push -u origin <branch>`, then open a PR against
  `master` with `gh pr create`.
- **Before opening a PR** (or marking a draft ready), the whole gate set passes:

  - `rake test`, `bundle exec rubocop` and `npm run format:check` all clean;
  - [`/personal-check`](#personal-check), run after every other gate so it reads
    every commit that will be pushed — its misses can't be fixed after a push.

- **Check `master` hasn't moved** before pushing and before merging:
  `git fetch origin && git log --oneline HEAD..origin/master` should be empty.
  If it isn't, merge `origin/master` into the branch and **verify nothing was
  lost** — don't trust a clean auto-merge. For mechanical changes (formatting,
  renames), take the file wholesale from `origin/master`, re-apply the change,
  and diff to confirm.
- Merge with a **merge commit**, not squash or rebase, and **delete the branch,
  local and remote**: `gh pr merge <n> --merge --delete-branch`.
- Committing, pushing and merging are separate actions. Only do each when asked.

## `/personal-check`

`/personal-check` scans for that material and checks whether any finding is
already in git history. Run it:

- **Before pushing.** Its misses can't be fixed after a push — they become a
  history rewrite and a force-push, and GitHub keeps the objects even then.
- **Before opening a PR** (or marking a draft ready), after every other gate, so
  it reads every commit that will be pushed.
- **Before merging**, again, to catch new commits, the PR title, and comments.
  Treat `gh pr merge` as blocked until it has run against the final diff.
- **After writing docs**, including edits to [README.md](./README.md) and
  [DEVELOPERS.md](./DEVELOPERS.md).

Run it on every branch. It reports "nothing found" cheaply when a branch didn't
touch its subject.

`/personal-check all` scans the whole tree rather than the branch. Expensive;
not the per-PR mode.

### How its report behaves

- **It ends without a push.** The check reports and stops. An instruction to
  push given before it ran is not permission to push what it has just read — the
  question gets asked again, with the findings in front of you.
- **One finding at a time.** Propose, wait, fix, ask to commit, commit. Only
  then is the next finding named. Never a blanket "shall I do these?".
- **Never discard a valid finding for being outside the check's remit.** A line
  that turns out not to matter costs nothing; a finding dropped because it
  looked like someone else's is lost.
