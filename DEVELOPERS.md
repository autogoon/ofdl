# Developing ofdl-rb

How ofdl works inside: the pipeline, the terminal drawing, and how it gets past
Cloudflare. For installing, running and configuring it, see
[README.md](./README.md).

## Tests

```sh
rake test
```

All offline - Nothing in the suite reaches the network, and no captured request
is committed to this repo.

## Tooling

ofdl has no runtime dependencies; `ofdl.gemspec` declares none. Everything below
is development only.

```sh
bundle install
npm install
```

```sh
bundle exec rubocop -a   # Ruby
npm run format           # markdown and JSON
```

Both are version-pinned. `.rubocop.yml` sets `NewCops: enable`, so an unpinned
rubocop enables cops the config was never written against and a clean checkout
reports offences nobody introduced.

`.prettierrc` sets `proseWrap: always`: prose hard-wraps at 80, so editing one
sentence does not reflow the paragraph into the diff.

`.vscode/settings.json` sets `formatOnSave` per language — ruby through ruby-lsp
with rubocop, markdown and JSON through Prettier — rather than globally, so no
file is handed to a formatter this repo has no config for.

## What this repo must not contain

This repo is public. What it archives is not: no creator username, account or
media ID, subscription count, real `output_dir`, or capture still carrying a
live session belongs in a commit, a test fixture, a commit message or a PR
description. The apps are named throughout this repo; an account never is.

`/personal-check` enforces that. It scans a branch — every revision of every
file it changed, not just the final diff — plus commit messages and any open
PR's title and comments, and for each finding works out whether it is already in
git history and what removing it would take.

The rules it enforces are in
[`.claude/skills/personal-check/SKILL.md`](./.claude/skills/personal-check/SKILL.md);
when to run it is in [CLAUDE.md](./CLAUDE.md).

## One run, two apps

`Session` owns what every app shares: the transport, the library, the scratch
directory, the download pool and the counters. A source adapter owns what one
app does alone — its cookies, its request signing, which feeds it has and how
each is paged. `Session#adapter_for` builds one per app, and `Sources::OnlyFans`
and `Sources::Instagram` are the two.

An adapter answers:

| Method                          | Returns                                           |
| ------------------------------- | ------------------------------------------------- |
| `key`                           | `onlyfans`, `instagram`                           |
| `post_types`                    | the feeds this app has                            |
| `creators`                      | targets to archive with no name given             |
| `resolve(username)`             | one target                                        |
| `each_row(post_types, id, ...)` | yields `[post_type, row]`                         |
| `items_from(row, post_type:)`   | `Item`s                                           |
| `advert_reason(row, creator:)`  | why a post is an advert, or nil                   |
| `status_lines`                  | yields the label/value pairs `ofdl status` prints |

`each_row` takes every post type at once rather than one per call, because one
listing can carry several: an Instagram grid holds reels beside plain posts.
OnlyFans reads one feed per post type and tags each row with the type it asked
for.

`Config::POST_TYPES` is every post type any app has. Which of them one app
actually has is that app's own list, and `Session#stream` walks the two
intersected — so naming a post type only one app carries selects it there and is
absent on the other rather than failing the run.

### Instagram

Most endpoints are the REST ones the web client calls, and they need the cookies
and `x-ig-app-id` and nothing else. The exception is the reels tab, which
Instagram serves only over GraphQL: a `doc_id`, and `fb_dtsg`, which is minted
into every HTML page the site serves. `Sources::Instagram::Tokens` scrapes
`fb_dtsg` once per run, the way `SiteState` reads `x-of-rev` for OnlyFans.

The grid and the reels tab are separate listings, and an account's reels need
not appear in its grid, so `posts` walks one and `reels` the other. A reel in
both is deduplicated by key.

`after` goes beside `data` in that query's variables, not inside it. Inside, the
endpoint ignores it and answers every request with the first page while still
returning a fresh cursor and `has_next_page` true.

The reels listing carries each reel's thumbnail but neither its video nor its
timestamp, so a downloadable reel costs a second request to `/media/<pk>/info/`.
`Library#key?` answers presence from a key alone, `Session` passes that as
`present` into `each_row`, and `walk_reels` asks before it fetches: a rerun over
an archived account spends one request on the listing and none on the reels.

A reel therefore produces two items from one row, the video and its thumbnail.
Both would key as `<pk>_<pk>`, so the thumbnail's media id carries a `_thumb`
role and `Library::MEDIA_ID` matches it. OnlyFans media ids are all digits, so
its keys and filenames are unchanged.

`--since` cannot end the reels walk early: the listing carries no timestamp to
compare, and the only row that has one is the row a request has already been
spent on. The pages are walked to the end and `Session` drops what is too old.

## Enumeration and downloading run together

Listing is the slow half. It's paced at a couple of requests a second and a
large timeline runs to hundreds of pages, so walking every post type to the end
before fetching anything would waste most of the run. Instead the producer
pushes each item onto a bounded queue and the download pool takes from it, and
the first file lands while the second page is still being listed.

There's one queue and one pool for the whole run, not one per creator. That
means the producer crosses a creator boundary without waiting for that creator's
downloads to finish, so a worker can be fetching for a creator the producer has
already moved past. That's why the username travels on the queue next to its
item, and why every log line and panel row names its creator.

`QUEUE_DEPTH` in `Session` bounds the queue at 256, and the bound is there for
backpressure, not capacity. The producer is paced only by `requests_per_second`
and yields a page at a time, so with an unbounded queue the producer would run
to the end of every post type while the pool was still draining the first pages.
Memory would scale with the size of the library instead of with concurrency, and
`queued` would show the whole timeline rather than what's actually waiting.

The bound also caps the listing a run does that it never uses. Once the queue is
full the producer blocks, so a run stopped with Ctrl-C has listed at most 256
items beyond what it downloaded, rather than every post type to the end. Those
unmade requests are a saving only for a run that doesn't finish — a completed
run lists exactly the same pages either way.

The bound doesn't slow the request rate down. Every API call goes through one
`RateLimiter` on the `Client`, so `requests_per_second` sets the request rate an
app sees. The queue bound sets only how far ahead of the downloads the listing
is allowed to get.

The producer also does the deduplication — the same media often appears in both
a timeline and the paid feed, and the first sighting wins — and the check for
what is already on disk. Both have to happen there: `queued` should only count
work that will actually be done, or a re-run puts the entire library through the
queue.

`Session#verdict_for` applies those tests in one order and returns what became
of the item: `:old`, `:duplicate`, `:present`, `:advert` or `:queued`. The
counters and the panel both read that answer. The advert test is `Advert`, which
reads the post text; `Advert.reason` runs once per row rather than once per
item, and only when `skip_ads` is set.

The panel's `on disk` is not counted by the producer. `Session#count_library`
walks the output tree on its own thread, started before the subscriptions are
resolved. The walk covers the creators named on the command line, or the whole
tree when no names were given. The producer's wait is a position in an ordered
walk, so an unscoped walk makes a run naming one creator wait for every
directory that sorts before that creator's; scoping the walk to that creator
removes the wait.

`Watermark` is what makes running that walk alongside the listing safe.
`Library#tally` walks creators in `<source>/<creator>` order and reports each
one as it finishes; `Session#produce` orders its targets by the same key and
waits for the walk to pass a creator before listing it. So no worker writes into
a directory the walk has still to read, which would count that file twice — once
in the walk and once as `downloaded`. The wait is almost always already
satisfied: the walk is filesystem-bound, and the listing it races is paced at a
couple of requests a second. A creator with no directory yet needs no special
case, because the walk is ordered: a name it has gone past without reporting is
a name it does not hold.

There's no "N items to download" headline, because nothing knows the total until
the last page has been listed.

## output_dir is never created

If `output_dir` does not exist, the run stops:

```text
error: output_dir /tmp/ofdl does not exist and will not be created (nearest existing path: /tmp). If it lives on a network volume, mount it first.
```

If it were created on demand, an unmounted volume would send the whole run to
the boot disk instead. Then the moment the real volume mounts, that directory is
shadowed and the downloads vanish. Naming the nearest existing path is what
tells you it's an unmounted share rather than a typo.

The check runs before every file is written, not once at startup, so a volume
that disappears mid-run fails loudly instead of quietly reappearing on the boot
disk. Directories _below_ a verified root are created normally.

## Downloads land locally first

curl writes into a scratch directory under `$TMPDIR` (`/var/folders/...` on
macOS), and the finished file is copied into `output_dir` in one go.

When `output_dir` is a mounted share, writing a file incrementally is slow and
watching its progress costs a network round trip every time, because the
attribute cache is invalid the moment the file is written to. Polling four
in-flight downloads ten times a second is enough to drop the dashboard to about
one frame a second. In scratch a `stat()` costs a microsecond.

The copy stages as `<name>.part` **in the destination directory** and renames it
there. A rename within one filesystem is atomic, so a file sitting under its
final name is always complete; see `Scratch#publish`.

Scratch is one directory per run, removed when the run ends and on Ctrl-C.

## How the dashboard is drawn

What the panels show is in [README.md](./README.md#the-dashboard); this is how
they stay on screen.

DECSTBM holds the zones in place — `\e[{top};{bottom}r` tells the terminal that
only those rows scroll. The log keeps its eight rows in any window and the image
zone absorbs the difference.

Every filesystem read happens on a sampler thread, never on the thread that
draws. `test_rendering_touches_no_files` counts the dashboard's filesystem reads
during a render and fails if there are any.

`Stats#active` is keyed by worker slot rather than by download key, so a row
never moves as transfers come and go: row 2 is always worker 2.

Once the bytes have arrived the bar gives way to the phase, `rendering` and then
`moving`. A bar sitting at 100% tells you nothing about the copy still running
behind it, and where `output_dir` is a mounted share that copy is the slow part.

The producer bumps `creators_done` as it finishes listing each creator, rather
than the pool bumping it as downloads finish, which is why the field can reach
its total while transfers are still running. `Stats#throughput` is
`bytes / elapsed` across the whole run, so `rate` is cumulative and not
instantaneous.

A download is retried up to `Downloader::MAX_ATTEMPTS` times, and only when the
error says it's retryable; anything else fails on the first attempt.
`Session#consume` catches every other `StandardError` too, so a bug in a worker
costs one item instead of quietly taking a worker out of the pool.

A transfer that connects and then stops sending raises nothing on its own, so
curl is given a speed floor: under `STALL_BYTES` a second for `STALL_SECONDS`,
it exits 28 and the download becomes a retryable failure. Without that floor a
stalled worker holds its slot until `DOWNLOAD_MAX_TIME`, an hour later, with the
progress bar frozen part-way. Exit 28 is the one curl status treated as
retryable, because it says the bytes stopped rather than that the request was
wrong.

### Image previews

Each worker owns a vertical slice of the image zone and draws into it directly,
from its own download thread, as soon as the bytes arrive and before the copy to
`output_dir` starts. There's no shared "latest image", no queue and no throttle,
so there's no state for two workers to race over.

It's drawn with iTerm2's inline image protocol, read from the local scratch copy
rather than pulled back across the network.

Images go through `sips` first. It's a **cover** rather than a fit: the picture
is scaled until it covers the slice and the overflow is cropped, so the slice is
filled and nothing is letterboxed. Which axis to scale on depends on the
picture. One wider than the slice is scaled to its height and cropped
horizontally, a narrower one the other way round. The result already has the
slice's shape, so it's drawn with aspect correction off and fills the cells
exactly.

The target size comes from the terminal rather than a guess: iTerm2 fills in the
pixel fields of `struct winsize`, so `TIOCGWINSZ` gives the exact cell size and
follows the font size and display as they change. Then it's halved:

```
terminal 200x50, cells 8x16  ->  slice 50 cells x 30 rows
                             ->  200x240 after halving, ~20 KB, ~70ms
```

Drawing blanks the slice and then fills it, and the terminal only paints that as
one frame if the whole sequence arrives inside its synchronized-output window
(DECSET 2026). At full size the payload outruns that window, so the blank gets
painted on its own and the preview flashes black. Half resolution undersamples a
little — you can't see it at this size — and keeps the redraw inside one frame.

If the resize fails, nothing is drawn at all. The original hasn't been cropped
to the slice, so it would letterbox or stretch, and a missing preview costs
nothing.

`sips` rather than an image library because it ships with macOS: no native
build, no ImageMagick. It costs about 70ms, on a worker thread that's about to
spend a lot longer than that copying the original to `output_dir`.

## Signing rules

The signing parameters are cached in `~/.ofdl-config.json` under `rules`,
written there on first fetch:

```json
"rules": {
  "static_param": "STATIC",
  "prefix": "ABC",
  "suffix": "XYZ",
  "checksum_constant": 1000,
  "checksum_indexes": [0, 5, 9],
  "fetched_at": "2026-08-23T00:00:00Z"
}
```

There's no expiry. These values only matter when they stop working, so a
rejected request is what triggers a refetch, not a clock. On the first HTTP
400/401/403 the rules are refetched, written back to the config, and the request
is retried once. If it's rejected again the run stops and says so — at that
point the problem is the session or the algorithm, not the cache.

That refresh happens at most once per run, so an expired session can't turn into
a refetch storm.

## Transport

OnlyFans sits behind Cloudflare, which fingerprints a lot more than headers.
Ruby's `Net::HTTP` fails every check at once: HTTP/1.1 rather than h2,
Title-Cased header names where h2 wants lowercase, an
`Accept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3` that no browser has
ever sent, and an OpenSSL TLS fingerprint that isn't Chrome's.

Signatures verified byte-identical against seven live browser requests still
came back `HTTP 400` with an empty body. That empty body is what puts the
rejection at the edge — a signature OnlyFans itself rejects comes back with
`{"error":{...}}` attached.

So every request, API calls and media downloads alike, goes through
`curl-impersonate`, which reproduces Chrome's BoringSSL stack, h2 settings,
header order and casing.

### Profile and User-Agent are chosen separately

```
impersonation profile : chrome150   <- newest curl-impersonate offers
reported browser      : Chrome 151  <- the installed Chrome's major version
```

The profile supplies the fingerprint, so the newest one is closest to a current
browser. The `User-Agent` reports the Chrome that owns the session cookies.
curl-impersonate trails Chrome's release cadence by a major or two, so these
routinely disagree, and that's fine: Cloudflare fingerprints TLS and header
shape, while OnlyFans — if it checks anything — checks the User-Agent.

Chrome's UA has been _reduced_ for years (platform frozen at `10_15_7` even on
Apple silicon, minor/build/patch always `0.0.0`), so the major version out of
the app bundle rebuilds it exactly. There's no setting for it.

Available profiles are read from the wrappers beside the binary and then
confirmed against curl itself with a `file://` URL, so checking a target makes
no network request and sends nothing to an app.

### Fetch metadata is corrected

curl-impersonate's Chrome profile is a _document navigation_:
`sec-fetch-mode: navigate`, `sec-fetch-dest: document`,
`upgrade-insecure-requests: 1`, and an `Accept:` of `text/html,...`. API calls
are XHR, so `accept` becomes `application/json, text/plain, */*`,
`sec-fetch-mode`/`-dest`/`-site` become `cors`/`empty`/`same-origin`,
`priority: u=1, i` and `referer: https://onlyfans.com/` are added, and
`upgrade-insecure-requests` is passed an empty value — how curl is told to drop
a header it would otherwise set itself.

Media downloads are left alone. They're unauthenticated CloudFront URLs, and a
plain browser file GET is exactly what curl's defaults already produce.

## x-of-rev and x-hash

Two headers the web client sends on every `/api2/v2` call that aren't part of
the signature. From its bundle:

```js
t["x-of-rev"] = "202608211829-e25f858429";
const { hash: r } = G.A.state.hash;
r && (t["x-hash"] = r);
```

**`x-of-rev`** is the front-end build revision. It's a literal in each build and
appears in every asset URL on the page, so ofdl reads it back out of
`https://onlyfans.com/` once per run instead of pinning it here. A pinned value
would go stale on the next OnlyFans deploy.

**`x-hash`** comes from a CDN endpoint the client calls with
`withCredentials: false`, cached for ten seconds — the same window the browser
uses:

```text
GET https://cdn2.onlyfans.com/hash/?u=<auth_id>
-> HASHVALUE...    (text/plain)
```

Neither request carries cookies. If the hash fetch fails the header is omitted
and the run continues, matching the client, which only sets it when the value is
truthy.

One header still differs from the local browser: `accept-language` is whatever
curl-impersonate compiles in (`en-US,en;q=0.9`), not what the installed Chrome
is configured to send.
