---
name: personal-check
description:
  Use before pushing to the public repo, before opening a PR and again before
  merging it, or after writing docs/content — scans for personal information,
  identifying details, or account/library references that shouldn't be public,
  and checks whether any finding is already committed to git history.
---

# Personal check

This repo is **public and pseudonymous**. Scan for personal information and make
it generic. Anything ever committed lives in **history**, not just HEAD: a
finding is not fixed until the history that contains it is rewritten.

## What must never be committed

Each of these is a check.

- **Identity** — real names, personal email addresses, personal URLs, social
  handles, session links, AI attribution trailers.
- **Machine-local paths** — `/Users/<name>/…`, a real `output_dir`, a volume or
  folder name from the author's own disk. Genericize to `~/OnlyFans` or `/tmp/x`
  (always use `/tmp` for an absolute path that isn't a home directory.)
- **The archived library** — creator usernames or display names, account IDs,
  post or media IDs, subscription counts, file counts, byte totals, directory
  listings. The library is what the app produces; it is not the app. Write about
  the feature, never about its contents.
- **Live session material** — cookies, `auth_id`, `sess`, bearer tokens, `x-bc`,
  User-Agent strings carrying a real build, and any capture taken from a
  logged-in browser that still holds the account it was taken from. A signing
  vector is a fixture only once its identifiers are synthetic.
- **Analysis of the author's own legal exposure.** The README's Legal section is
  the project's position; a paragraph reasoning about the author's personal risk
  is not.

`/personal-check` is the backstop, not the defence. History rewrites are the
only fix once pushed.

## Where those leaks hide

The rules above tell you what; this tells you where.

- **A personal fact stated as a project fact** — the author's own library size,
  folder layout, hardware, subscription list or workflow, stated as though
  describing the app. Reframe as a generic worked example ("say 40k items", "a
  64GB machine") or delete.
- **A sentence about the real library that reads as a sentence about the
  feature** — a rate-limit figure justified by "which is what a run of mine
  does", a dashboard example that needs a real creator count, a cost or timing
  estimate that only holds for one account. Both have slipped from the feature
  to the library. **Do not quote the offending sentence when reporting it** —
  restating it is the same leak.
- **Sourcing implied rather than stated.** OnlyFans is the declared subject of
  this project and naming it is not a finding. _Which account_ is: a creator
  handle in an example path, a real username in test data, a screenshot or
  sample log with a subscription in it.
- **Test fixtures and captures.** The suite is verified against real requests. A
  vector that still carries a live `auth_id`, a real media ID, or a real path is
  a leak wearing a test's clothes — and it is committed by definition.
- **Leaky meta-files** — a `.gitignore` entry or a script name can reveal what
  it hides; weigh the wording, not just the file it points at.
- **Commit messages** — a surface of their own: session links and attribution
  trailers (`Claude-Session:`, tool-generated URLs), personal emails or URLs in
  message bodies. `-S` only searches content — messages need
  `git log --all --grep='<pattern>'` — and a message finding has no working-tree
  fix: remediation is always a history rewrite (a message-only
  `filter-branch --msg-filter` keeps every tree identical).
- **PR titles, descriptions and comments** — public the moment they're posted,
  and not in git at all. No `git` search will ever find them. Read the body you
  wrote (`gh pr view <n> --json title,body,comments`) with the same eye as a
  doc. **Where an edit takes personal information out**, editing is not removal:
  GitHub keeps a revision history behind the body's _edited_ marker, readable by
  anyone who can see the PR. Deleting a revision is UI-only and author-only.
  That edit has to be followed by "open the edited dropdown and delete the
  revision" — say so rather than calling it fixed. An edit that only adds or
  reworks text leaves nothing in the old revision that wasn't already public. It
  needs no follow-up and isn't worth mentioning.

## Scope

Default: the branch — **every revision of every file it changed**, plus
`git log <base>..HEAD` for messages and the PR's title/body/comments if one is
open. `<base>` is the last published commit: `origin/main`, or the branch point
if the branch itself is unpushed.

**A repo with no remote has published nothing yet, so it has no base.** There
the default scope is the whole history, every commit — and every finding is
still fixable with an ordinary rewrite, because nothing has left the machine.
That is the cheapest this check will ever be.

`/personal-check all`: the whole tree — every committed file, plus filenames of
untracked files (they may get committed later). Fan out one read-only subagent
per directory and collect their reports. Expensive; this is not the per-PR mode.

### Every revision, not the final diff

`git diff <base>...HEAD` shows where the branch **landed**, not what it
published. Text added in one commit and removed in a later one never appears in
it, and on a branch that is pushed as it goes, every one of those commits was
public the moment it landed. A long branch with doc churn can rewrite the same
paragraph five times; the final diff reads one of them.

So the content pass is over the union of every added line in every commit.
Subtract the lines the final tree already holds, and what remains is exactly the
material no final-diff pass reads — where a deleted-but-published leak hides.

Two things make that remainder small enough to read rather than skim:

- **Reconstruct each revision whole; don't read the diff.** For each changed
  `*.md`, walk `git log <base>..HEAD --format=%h -- <file>`,
  `git show <c>:<file>` each one, and **strip fenced code blocks** before
  collecting. A README this size is largely fenced examples, and a diff-based
  filter cannot tell a `+` prose line from a `+` line of a code sample.
- **Read comments and prose; pattern-scan the rest.** In `.rb` files, personal
  information reaches the reader through comments and string literals. Read
  every comment the branch ever added; run the identifier patterns (**What must
  never be committed**) over everything else.

Deduplicate before reading — a rename or wording pass repeats one sentence
across many revisions.

This is content only. Messages, PR text and history exposure are their own
passes.

### Do not let the findings so far shape the search

Once a finding exists, the cheap next move is to grep the rest of history for
its wording. That finds more of what is already known and nothing else. The
identifier patterns come from **What must never be committed** and run in full
regardless. For the categories no regex covers — a library's size, a folder
layout, hardware, whose account an example is from — reading is the only pass
that works. That remainder gets read, not searched.

## History

For **every** finding, determine exposure before calling it fixed:

1. `git log --all -S'<the string>' --oneline` (and `-- <file>` for whole files):
   which commits contain it?
2. Pick the remediation the exposure requires:
   - **Never committed** → fix the working tree; done.
   - **Committed, not pushed** → fix, then rewrite so no commit ever contains it
     — fixup into the introducing commit, or squash the introducing and removing
     commits together. Editing HEAD alone leaves the data in history.
   - **Pushed** → rewrite and **force-push**, and say plainly: GitHub retains
     once-pushed objects server-side even after a force-push — truly purging
     them needs GitHub support, and anything that sat public may have been seen
     or archived.
3. **Verify**: the `git log --all -S` search returns nothing; then check the
   places rewrites miss — backup branches, remote-tracking refs, stashes, other
   clones. A backup branch that still reaches the old commit _is_ the leak.

Do the content fix and the history cleanup in the same piece of work — get
explicit approval for the rewrite/force-push, then finish it. Report what
remains exposed (retained server-side objects, other clones) rather than
claiming complete removal.

## The check ends without a push

**Report, then stop.** Never push, force-push or open a PR as the last step of
this check — hand the report over and ask, naming the push you would run.

Put those questions **one at a time**, in four parts and in this order: the
problem; the current situation with the evidence for it; the proposed change, or
the options with what each costs; the resulting text, where it is short enough
to read. Quote verbatim in the reply itself — a description of a change cannot
be judged against the change. This governs the question that closes the check,
not only standalone proposals: a long findings list does not earn a compressed
one-line ask at the end.

**An instruction to push given _before_ the check does not carry through it.**
"Run the checks and push", or a push asked for earlier in the session, is
permission that predates every finding: it was given by someone who did not yet
know what the check would turn up, or how it was performed. So it is not
permission to push what the check has just read. Ask again afterwards, with the
findings in front of them. Pushing is its own action and is only done when
asked; this says which asking counts.

Every other check can be re-run and its findings fixed with an ordinary commit.
This one's miss becomes a history rewrite and a force-push the moment the branch
goes up, and GitHub keeps the objects even then — so the minute before the push
is the last cheap minute there is.

State what the check actually did, in the words of **Scope** — a cumulative
`git diff <base>...HEAD` is not "every revision", and reporting it as one gets
the push approved on a pass that was never run.

## Red flags

| Thought                                  | Reality                                                                             |
| ---------------------------------------- | ----------------------------------------------------------------------------------- |
| "It's only in an old commit"             | History is one click away on a public repo.                                         |
| "It's just my hardware/folder names"     | Identifying details compound across files.                                          |
| "I'll clean history later"               | Later is when someone else finds it. Same piece of work.                            |
| "Force-pushed, so it's gone"             | GitHub keeps once-pushed objects. Say so.                                           |
| "It's only the PR description"           | Public, unsearchable by git, and edits leave a revision.                            |
| "The library isn't committed"            | Describing it publishes it anyway.                                                  |
| "It's a test fixture, not documentation" | A committed fixture is published verbatim. Check whose account it came from.        |
| "The repo already names the platform"    | The platform is the subject. The account is not.                                    |
| "It's not in the final diff"             | A pushed branch published every commit on the way.                                  |
| "I grepped for it and it's clean"        | Grepping the findings finds the findings. Read.                                     |
| "They already told me to push"           | That was before the findings existed. Ask again.                                    |
| "Close enough to every revision"         | Say which pass ran. A wrong scope reported as the right one is worse than no check. |
