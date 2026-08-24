# ofdl-rb

A local archiver for OnlyFans subscriptions, with a live terminal dashboard.
Ruby, no gems, no database, no server component.

If you want to know how it works inside, that's in
[DEVELOPERS.md](./DEVELOPERS.md).

## What it does and does not do

**Does:** photos, GIFs, audio, and unprotected video, from timelines, DMs,
stories, highlights, archived posts and purchased posts. Resumable,
deduplicated, rate limited, and previewed as it goes.

**Does not:** DRM-protected video. Those items are detected, reported and
skipped. No setting changes that — see [Protected video](#protected-video).

## Requirements

macOS only. Cookie decryption goes through the login Keychain, and Chrome's jar
layout differs per platform. Feel free to get this working in Windows/WSL/Linux
and submit a PR!

| Dependency         | Why                                          | Install                         |
| ------------------ | -------------------------------------------- | ------------------------------- |
| Ruby 4.0+          | runs it                                      | `rbenv` (macOS ships Ruby 2.6)  |
| Google Chrome      | your session cookies, and its version string | signed in to OnlyFans           |
| `curl-impersonate` | every HTTP request ofdl makes                | `brew install curl-impersonate` |
| `sips`             | resizes images for the terminal preview      | ships with macOS                |
| `ffmpeg`           | joins the few videos served in segments      | `brew install ffmpeg`           |
| `sqlite3`          | reads Chrome's cookie jar                    | ships with macOS                |

Those binaries should be on `PATH`; the `curl_impersonate` and `ffmpeg` config
keys can point elsewhere.

Plain `curl` cannot stand in for `curl-impersonate`: OnlyFans refuses requests
that don't look like Chrome, down to the TLS handshake.

## Install

There is no published gem yet. Either run it from a clone:

```sh
git clone https://github.com/autogoon/ofdl.git
cd ofdl
./bin/ofdl status
```

or build the gem and install it, which puts `ofdl` on `PATH`:

```sh
gem build ofdl.gemspec
gem install ./ofdl-*.gem
```

Under `rbenv`, run `rbenv rehash` afterwards if the command is not found.

Every command below is written `ofdl`. Running from a clone, read that as
`/path/to/ofdl/bin/ofdl`.

## Setup

```sh
ofdl init                    # writes ~/.ofdl-config.json
$EDITOR ~/.ofdl-config.json  # set output_dir (it must already exist)
ofdl status                  # check the tools, the library, and the session
```

`output_dir` is the one key you must set; everything else has a default. See
[Configuration](#configuration).

Run `status` first. It reports the tools it found, some info about the terminal,
and what is already in `output_dir` -- then reads your cookies, loads the
signing rules.

It makes one real request to `/users/me`. If there is a problem with
authentication, that request will fail and is reported.

The first command that reads your cookies makes macOS ask for your login
password, to unlock the `Chrome Safe Storage` keychain entry Chrome encrypts
them under. That prompt is macOS's, not ofdl's; choose Always Allow and it does
not come back. Cancel it and the run stops with
`could not read "Chrome Safe Storage" from the Keychain`.

## Use

```sh
ofdl status                                # setup, library, and session check
ofdl subs                                  # who you are subscribed to
ofdl fetch                                 # every subscription, configured sources
ofdl fetch someone                         # one creator
ofdl fetch someone other                   # several creators
ofdl fetch someone --since 2026-01-01      # only recent posts
ofdl fetch --sources posts,messages        # everything, narrowed
ofdl --help                                # every command and option
```

A name may be given with or without a leading `@`, and case is ignored; it is
matched against `ofdl subs`, and an unknown name is an error rather than a
silent skip.

Ctrl-C stops immediately. The stats panel is printed once more, the scratch
directory is removed, and nothing partially downloaded is kept. Rerun and
nothing is downloaded twice: the listing starts again, and every item already in
`output_dir` is passed over.

## Where the files go

Under `output_dir`, a directory per creator and one per source inside it:

```text
/tmp/onlyfans/someone/posts/2026-01-14_111_222.jpg
              │       │     │          │   └ media id
              │       │     │          └ post id
              │       │     └ the date it was posted
              │       └ posts, messages, stories, highlights, paid, archived
              └ the creator's username
```

The date and the two ids are the whole name: no title, no caption, and the same
item always lands at the same path. Those ids are also how a rerun recognises
what it already has. Delete a file and the next run fetches it again; rename one
so the ids no longer lead, and the next run fetches a second copy.

## Configuration

One JSON file at `~/.ofdl-config.json`, written by `ofdl init`. The path is
fixed. It's per user rather than per directory, so you can't change which
account gets archived by running from somewhere else.

That file is the only state ofdl keeps — no database, no dotfile directory. The
only environment it reads is `PATH`, to find the binaries above, and `$TMPDIR`,
where downloads are staged before being copied to `output_dir`.

`init` writes a single key, with a placeholder path that does not exist, so an
unedited config stops at `ofdl status` rather than archiving somewhere invented.
Point it at your library and the config is complete:

```json
{
  "output_dir": "/tmp/onlyfans"
}
```

Everything else is optional. Leave a key out and ofdl uses its own default, so
if that default improves in a later version you get the improvement for free.
Put a key in and you're pinned to that value until you edit the file again. So
set what you actually want to control, and leave the rest out:

```json
{
  "output_dir": "/tmp/onlyfans",
  "concurrency": 2,
  "sources": ["posts", "messages"],
  "images": false
}
```

If the file is unreadable, or isn't a JSON object, ofdl says so and stops.
`rules` is the one key ofdl writes back for itself; the rest is yours.

| Key                   | Default                                                | Meaning                                                |
| --------------------- | ------------------------------------------------------ | ------------------------------------------------------ |
| `output_dir`          | **required**                                           | download root; **must already exist**                  |
| `chrome_profile`      | `Default`                                              | Chrome profile directory name                          |
| `concurrency`         | `4`                                                    | parallel downloads                                     |
| `requests_per_second` | `2.0`                                                  | API pacing                                             |
| `rules_url`           | `https://r2.hlsdownloader.com/win32/dynamicRules.json` | where to refetch signing parameters                    |
| `rules_file`          | unset                                                  | pinned local rules; disables `rules_url`               |
| `rules`               | written automatically                                  | cached signing parameters                              |
| `sources`             | all six                                                | `posts, messages, stories, highlights, paid, archived` |
| `skip_protected`      | `true`                                                 | skip Widevine video                                    |
| `mark_protected`      | `true`                                                 | leave `.drm` markers                                   |
| `images`              | `true`                                                 | preview downloads in the terminal                      |
| `refresh`             | `0.05`                                                 | seconds between dashboard repaints                     |
| `ffmpeg`              | `ffmpeg`                                               | path to ffmpeg                                         |
| `curl_impersonate`    | `curl-impersonate`                                     | path to curl-impersonate                               |

`chrome_profile` is the profile's directory name, not the name Chrome shows:
`Default` for the first profile, `Profile 1` for the next. It is the last
component of "Profile Path" on `chrome://version`.

How the `rules` cache is refreshed is in
[DEVELOPERS.md](./DEVELOPERS.md#signing-rules).

## The dashboard

Four zones, top to bottom: a stats panel, an image slice per download worker,
eight rows of scrolling log, and one row per worker showing what it is doing.

Photos are previewed as they are downloaded. This requires iTerm2 — it uses that
terminal's inline image protocol, and no other terminal renders it.
`--no-images` disables previews for one run, `"images": false` can be added to
the config file to disable them permanently. Sizing and cropping are in
[DEVELOPERS.md](./DEVELOPERS.md#image-previews).

```text
┌─ ofdl ─────────────────────────────────────────────────────────────────────────────────── 16 fps · io 1ms · 4m12s ─┐
│ creators    2/10 someone              queued      250                       on disk     1,000 / 20.0 GB            │
│ scanning    messages                  successful  400                       fetched     400 / 2.0 GB               │
│ requests    90                        skipped     75                        rate        9.8 MB/s                   │
│ discovered  1,000 images / 200 videos failed      2                                                                │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘



                                                    [ images ]



  ✓ someone/posts/2026-01-14_111_222.jpg  842.0 KB
  → /users/12345/posts?limit=50&order=publish_date_desc&...&beforePublishTime=...
┌─ downloading ──────────────────────────────────────────────────────────────────────────────────────────────── 2/4 ─┐
│ [=====             ]   26%    11.8 MB / 45.8 MB    someone/posts/2026-01-14_111_224.mp4                            │
│ rendering                    781.0 KB / 781.0 KB   other/messages/2026-01-11_98_402.jpg                            │
│ idle                                                                                                               │
│ idle                                                                                                               │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

Three columns, each read downward.

**The crawl** — position, and totals found.

- `creators` — creators finished scanning, over the total, then the one being
  listed.
- `scanning` — the step running: `subscriptions`, then the source being listed.
  Reads `waiting for listing` while listing is held up by the count of
  `output_dir`, and `done` when there's nothing left to list.
- `requests` — API calls made.
- `discovered` — media found, as images / videos.

**Download Progress** — `queued` is what waits; the three beneath it are what
has left the queue.

- `queued` — items waiting, capped at 256. Listing pauses at the cap and resumes
  as the workers take items off it. The cap is to help avoiding OnlyFans
  classifying ofdl's traffic as unusual, since API request frequency is much
  reduced.
- `successful` — downloads that completed.
- `skipped` — DRM items, never attempted. Yellow above zero.
- `failed` — downloads that didn't complete. Red above zero.

**Storage** — how much has landed.

- `on disk` — everything in `output_dir`, plus what this run has downloaded. The
  whole library, not only the creators named on the command line, so it is the
  same figure whoever you fetch. It fills in over the first seconds of a run,
  while the directories are read.
- `fetched` — files and bytes this run downloaded. The count is `successful`.
- `rate` — `fetched` bytes divided by how long the run has been going. It's an
  average over the whole run, not what's happening right now.

**The download rows.** By default, there are four concurrent workers. You can
configure this in the configuration file. You get a progress bar and percentage
while the bytes arrive, then `rendering` while the preview is drawn, then
`moving` while the file is copied to `output_dir`.

**The title bar.** Frames per second, how long the last filesystem scan took,
and how long the run has been going.

## Protected video

OnlyFans serves much of its video under Widevine.

You can download the encrypted bytes, but you can't play them. Widevine decrypts
inside the browser's CDM and never hands the keys to anything else, so a local
tool can't decrypt them. Getting at those keys means extracting a CDM device,
which is circumventing a technical protection measure, and that's out of scope
here.

So rather than write out broken files, each protected item leaves an empty
marker:

```text
2026-01-14_111_333.mpd.drm
```

The marker uses the item's key, so one directory scan finds real files and
skipped ones together.

It's bookkeeping, not a speed-up — a protected item costs no request either way.
Set `"mark_protected": false` and you won't get the markers, but then every run
counts those items as `skipped` again instead of knowing it has already seen
them.

## Rate limiting

`requests_per_second` defaults to `2.0`. Users are signed out of OnlyFans after
heavy sessions, which is consistent with volume-based session invalidation.
Raising it is your call. If you are signed out, sign in again in Chrome and
rerun -- what is already in `output_dir` is not fetched a second time.

## Privacy

These are the network calls ofdl makes:

| Destination              | Carries                                 | Why                               |
| ------------------------ | --------------------------------------- | --------------------------------- |
| `onlyfans.com/api2/v2`   | your session cookies                    | listing posts, messages, stories  |
| `onlyfans.com/`          | nothing — no cookies                    | the build revision for `x-of-rev` |
| `cdn2.onlyfans.com/hash` | your `auth_id` in the query, no cookies | the value of `x-hash`             |
| media URLs               | nothing — no cookies, no headers        | the actual files                  |
| `rules_url`              | nothing — plain GET                     | current API signing parameters    |

Your cookies are read from the local Chrome profile, kept in memory, and sent
only to onlyfans.com. ofdl never writes them to disk.

`rules_url` defaults to the CDN of the Onlyfans-Downloader browser extension,
because that's where current values can be found. The extension has been removed
from the Chrome Web Store, so there is no link for it here. It's fetched with no
cookies and no identifying headers, so it gives away nothing beyond "somebody
requested this file". If you'd rather not touch it at all, pin a local copy:

```json
{ "rules_file": "./dynamic-rules.json" }
```

and ofdl never goes to the network for rules again.

## Legal

Downloading content you subscribe to, for personal use, is between you and
OnlyFans' terms of service. Redistributing a creator's work is not covered by
your subscription and is not what this is for.
