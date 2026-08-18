# Terrastep — Issues Log

Every blocker hit during development, what caused it, and how it was fixed.
Written so the project can be picked up on a different machine, weeks later,
without rediscovering the same problems.

**Format:** each entry has Symptom → Cause → Fix → Prevention.
`#` numbers are stable — reference them in commits. Newest in each section last.

**Legend:** 🔴 blocked work · 🟡 slowed work · 🟢 caught before it bit us

**How to read this:** if you are resuming, read *Recurring Patterns* at the
bottom first, then *Open Items*. The numbered entries are the paper trail.

---

## Index

| # | Title | Sev |
|---|---|---|
| [1](#1--node---check-fails-on-a-process-substitution) | `node --check` fails on a process substitution | 🟡 |
| [2](#2--apt-get-install-fails-without-sudo-silently) | `apt-get install` fails without sudo | 🟡 |
| [3](#3--installed-packages-dont-survive-between-sessions) | Installed packages don't survive sessions | 🔴 |
| [4](#4--git-identity-lost-between-sessions) | Git identity lost between sessions | 🟡 |
| [5](#5--supabase-only-extensions-unavailable-locally) | Supabase extensions unavailable locally | 🔴 |
| [6](#6--authuid-and-realtimesend-dont-exist-outside-supabase) | `auth.uid()` / `realtime.send()` missing | 🔴 |
| [7](#7--postgis-geography-type-unavailable) | PostGIS `geography` unavailable | 🟡 |
| [8](#8--test-expectation-wrong-validation-rules-are-order-dependent) | Test expected the wrong rejection | 🟢 |
| [9](#9--test-fixture-violated-its-own-time-window) | Fixture violated its own time window | 🟢 |
| [10](#10--run_testssh-unusable-after-clone) | `run_tests.sh` lost its exec bit | 🔴 |
| [11](#11--postgres-binary-discovery-too-narrow) | Postgres binary discovery too narrow | 🟡 |
| [16](#16--run_testssh-not-re-runnable--orphaned-postmaster-holds-the-port) | Orphaned postmaster holds the port | 🔴 |
| [12](#12--ci-secret-scanner-would-have-failed-on-its-own-documentation) | Secret scanner matched its own docs | 🟢 |
| [13](#13--a-credential-was-pasted-into-chat) | A credential was pasted into chat | 🔴 |
| [14](#14--fine-grained-tokens-cannot-create-repositories) | Fine-grained tokens cannot create repos | 🟡 |
| [15](#15--workflow-files-need-a-separate-permission) | Workflow files need a separate permission | 🟡 |
| [17](#17--stationary-gps-jitter-accumulated-11-km-of-phantom-distance) | Stationary GPS jitter claimed a cell | 🔴 |
| [18](#18--a-too-aggressive-fix-broke-the-golden-path) | Anti-drift filter erased real walks | 🟡 |
| [19](#19--rate-limiting-backed-off-one-batch-instead-of-the-queue) | Rate-limit backoff was per-batch | 🔴 |
| [20](#20--adding-flutter-would-have-made-the-logic-tests-need-an-emulator) | Flutter would have killed `dart test` | 🟢 |
| [21](#21--maplibre-would-have-complicated-the-ci-apk-build) | MapLibre would have complicated CI | 🟢 |
| [22](#22--first-apk-build-failed-open-carets-pulled-in-too-new-plugins) | Open carets pulled too-new plugins | 🔴 |
| [23](#23--h3_flutter-07x-cannot-resolve-on-flutter-3245) | `h3_flutter` 0.7.x vs Flutter 3.24.5 | 🔴 |
| [24](#24--colorwithvalues-does-not-exist-on-flutter-324) | `Color.withValues` is 3.27+ | 🟢 |
| [25](#25--pedometer-would-have-been-silently-empty-on-android-10) | Pedometer silent without runtime grant | 🟡 |
| [26](#26--local-apk-build-on-a-2-gb-box) | Local APK build on a 2 GB box | 🟡 |
| [27](#27--the-apk-was-built-but-not-in-the-repo) | APK was built but gitignored | 🟡 |
| [28](#28--first-device-walk-got-no-gps-and-no-permission-dialog) | First walk: no GPS, no permission dialog | 🔴 |

---

## Environment & Tooling

### #1 🟡 `node --check` fails on a process substitution
**Symptom**
```
Error: ENOENT: no such file or directory, open '/proc/1459/fd/pipe:[14935]'
```
when validating the prototype's inline JS via `node --check <(sed ... file.html)`.

**Cause** `node --check` reads the path twice (stat, then open). A process
substitution is a one-shot pipe — it's already drained by the second read.

**Fix** Write to a real temp file first.
```bash
sed -n '/^<script>/,/^<\/script>/p' prototype/index.html | sed '1d;$d' > /tmp/proto.js
node --check /tmp/proto.js
```

**Prevention** Any tool that seeks or re-opens its input (`node --check`,
`python -m py_compile`, most linters) needs a real file, not a pipe.

---

### #2 🟡 `apt-get install` fails without sudo, silently
**Symptom** Package install appeared to fail with no useful output; `psql` still
not found afterwards.

**Cause** The sandbox user isn't root, and the failure message was being
swallowed by output redirection.

**Fix** Fall through to `sudo`, and always surface the log tail on failure:
```bash
apt-get install -y postgresql >/tmp/apt.log 2>&1 \
  || sudo apt-get install -y postgresql >/tmp/apt.log 2>&1 \
  || tail -3 /tmp/apt.log
```

**Prevention** Never redirect an install to `/dev/null`. Log it and print the
tail on failure.

---

### #3 🔴 Installed packages don't survive between sessions
**Symptom** `./tests/run_tests.sh` worked, then later the same command gave
`initdb: command not found` with no changes made.

**Cause** The workspace snapshot persists files under `/home/user` but **not**
installed system packages, running processes, or shell state. Postgres was
simply gone.

**Fix** Reinstall (~10 s), then re-run. Nothing in the repo was wrong.

**Prevention** Treat the toolchain as ephemeral. `run_tests.sh` is written to be
run from scratch and now fails with an explicit install hint (see #10). If you
resume this project and tests won't run, **install Postgres first** before
debugging anything else.

---

### #4 🟡 Git identity lost between sessions
**Symptom**
```
Author identity unknown
fatal: empty ident name (for <user@e2b.local>) not allowed
```
mid-commit, despite having committed successfully earlier.

**Cause** Same as #3 — `git config` values written to `.git/config` were reset,
and `.git/config` is deliberately excluded from workspace snapshots (it can hold
credentials).

**Fix**
```bash
git config user.email "nematullah9812@users.noreply.github.com"
git config user.name  "NematUllah9812"
```

**Prevention** Expect to re-set identity and re-add the remote each session.
Cheap, but do it *before* a long commit message, not after.

---

## Database & Test Harness

### #5 🔴 Supabase-only extensions unavailable locally
**Symptom** `01_DATA_MODEL.sql` aborts on
`create extension postgis / pg_cron / h3` against vanilla Postgres.

**Cause** These ship with Supabase's managed image, not stock Postgres.

**Fix** `tests/run_tests.sh` strips those lines at load time with `sed`, and
`tests/00_shim.sql` supplies minimal stand-ins. **The committed SQL files are
never modified** — the shim exists only for local testing.
```bash
sed -e 's/^create extension if not exists postgis.*/-- shimmed/' \
    -e 's/^create extension if not exists pg_cron.*/-- shimmed/' \
    -e 's/^create extension if not exists h3.*/-- shimmed/' \
    01_DATA_MODEL.sql | psql -d terrastep -f -
```

**Prevention** Keep production SQL authoritative; adapt in the harness. If the
harness and production diverge, production wins.

⚠️ **Still to verify on real Supabase:** whether the `h3` extension is available
in your region (`select * from pg_available_extensions where name like 'h3%'`).
If yes, uncomment the `[H3-PG]` blocks in `02_CLAIM_ENGINE.sql` — they close the
telemetry-replay hole.

---

### #6 🔴 `auth.uid()` and `realtime.send()` don't exist outside Supabase
**Symptom** `claim_cells()` fails to create — unknown schema `auth` / `realtime`.

**Cause** Supabase-provided. `auth.uid()` reads the caller's JWT.

**Fix** `tests/00_shim.sql` defines both. `auth.uid()` reads a session GUC so
tests can switch users:
```sql
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('test.uid', true), '')::uuid;
$$;
```
```sql
-- in a test, become Alice:
select set_config('test.uid','1111...1111', false);
```
`realtime.send()` becomes a `raise notice`, which doubles as a useful trace of
what *would* have been broadcast.

**Prevention** Good side effect: the engine is now testable without any network
or Supabase account. Keep it that way.

⚠️ **Untested in reality:** whether `realtime.send()` behaves the same inside a
`SECURITY DEFINER` function on real Supabase. Verify at threshold 3.2.

---

### #7 🟡 PostGIS `geography` type unavailable
**Symptom** `territories.center geography(Point, 4326)` — type does not exist.

**Cause** No PostGIS locally.

**Fix** Shim `create domain geography as text;` plus a fake `st_point()`, and the
harness rewrites the column type and strips `::geography` casts. The column is
only a centroid for optional clustering — no query in the engine depends on real
spatial operations, which is why this substitution is safe.

**Prevention** Deliberate design choice: **distance maths uses `haversine_m()`,
not PostGIS.** Keeps the engine portable and avoids a hard dependency for one
convenience column.

---

### #8 🟢 Test expectation wrong: validation rules are order-dependent
**Symptom**
```
FAIL A2 shake attack (2000 steps, 5m)
  got=below_min_distance  want=steps_without_distance
```

**Cause** **The engine was right; the test was wrong.** `validate_cell_claim()`
checks the minimum-distance floor (R2) *before* the step/distance ratio rule
(R6). A 5 m "walk" trips the floor first and never reaches the ratio check.

**Fix** Split into two tests that reflect real attacker behaviour:
- **A2a** crude shake (2000 steps, 5 m) → `below_min_distance`
- **A2b** *smart* shake — walks 90 m to clear the floor, then shakes for steps
  (2000 steps, 90 m) → `steps_without_distance`

A2b is the more valuable test: it proves R6 catches an attacker who has already
defeated the simple floors.

**Prevention** When a rejection test fails with a *different* rejection reason,
suspect the test before the code. Assert the specific reason, never just
"was rejected" — otherwise a rule can silently stop working while tests stay
green because an earlier rule masks it.

---

### #9 🟢 Test fixture violated its own time window
**Symptom** A2b returned `dwell_exceeds_window` instead of the expected reason.

**Cause** The fixture claimed 600 s of dwell inside a default 9-minute (540 s)
window. Rule R5 correctly rejected it — a genuine catch of a bad fixture.

**Fix** Lowered fixture dwell to 500 s.

**Prevention** Test fixtures must themselves be internally coherent. R5 exists
precisely to catch dwell > wall-clock, and it caught it here — in a test.

---

### #10 🔴 `run_tests.sh` unusable after clone
**Symptom** `./tests/run_tests.sh` → `Permission denied`.

**Cause** `chmod +x` in the working tree does **not** stage a mode change. The
first commit stored the file as `100644`.

**Fix**
```bash
chmod +x tests/run_tests.sh
git update-index --chmod=+x tests/run_tests.sh
```
Index now shows `100755`.

**Prevention** After adding any script, check `git ls-files -s path` shows
`100755` before pushing. Or invoke as `bash tests/run_tests.sh` to sidestep it.

---

### #11 🟡 Postgres binary discovery too narrow
**Symptom** After reinstall, `initdb: command not found` — the script's own
`PATH` setup wasn't finding it.

**Cause** Detection only looked at `/usr/lib/postgresql/*/bin` (Debian layout)
and failed silently, then hit a bare not-found error with no guidance.

**Fix** Search Debian, Homebrew (Intel + Apple Silicon) and Postgres.app, honour
an explicit `PGBIN` override, and exit with install instructions:
```
ERROR: Postgres client tools not found (initdb).
  Debian/Ubuntu : sudo apt-get install -y postgresql
  macOS         : brew install postgresql@17
  Or set PGBIN=/path/to/postgres/bin
```

**Prevention** Any script depending on an external binary should fail with the
fix, not just the symptom.

---

### #16 🔴 `run_tests.sh` not re-runnable — orphaned postmaster holds the port
**Symptom** Second invocation fails:
```
pg_ctl: could not start server
FATAL: could not create any TCP/IP sockets
LOG: could not bind IPv4 address "127.0.0.1": Address already in use
```

**Cause** Three compounding bugs, found by *testing the documented resume
procedure* rather than assuming it worked:
1. The script never stopped the server it started, so a postmaster from the
   previous run kept holding port 5433.
2. Deleting `PGDATA` orphaned that process — no pid file, so `pg_ctl status`
   reported "not running" while the port stayed bound.
3. The port was hardcoded, so there was no fallback.

Also masked by `pg_ctl ... >/dev/null` swallowing the real error.

**Fix** Four changes:
- Stop any prior server before starting (`pg_ctl -m immediate stop || true`)
- `trap cleanup EXIT` so the server always shuts down
- Probe 5433–5460 for a free port instead of assuming one
- On failure, print the Postgres log tail instead of a bare error
- Validate `PGDATA` with `PG_VERSION`, not just directory existence

**Verified** Three consecutive runs — with an orphan running, immediately again,
and after deleting `PGDATA` — all 48 passing.

**Prevention** **A "run this to get started" command must be idempotent.** Test
it twice in a row, and once after deleting its state. This bug only surfaced
because the documented resume steps were actually executed.

---

## Security & Git

### #12 🟢 CI secret scanner would have failed on its own documentation
**Symptom** Pre-commit scan flagged 6 hits in `SECURITY.md` and
`CURRENT_PROGRESS.md` — all prose *describing* key formats, no real secrets.

**Cause** The regex matched `sb_secret_` as a bare prefix with only `{20,}`
trailing characters, so documentation naming the prefix matched.

**Fix** Anchor patterns to a full-length run of key characters and exclude the
docs file:
```
ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{50,}|sb_secret_[A-Za-z0-9_-]{28,}|eyJhbGciOi[A-Za-z0-9_-]{30,}
```
Verified both directions: 3 real-shaped secrets caught, 0 false positives on
prose. Docs also use a Unicode ellipsis (`sb_secret_…`) after prefixes, which
cannot match an ASCII character class.

**Prevention** **Always test a scanner against both true and false positives.**
A scanner that cries wolf gets disabled within a week, which is worse than no
scanner. Caught before the first CI run.

---

### #13 🔴 A credential was pasted into chat
**Symptom** A classic GitHub PAT with full `repo` scope was shared in
conversation to enable a push.

**Cause** Convenience — no laptop access, and a repo needed creating.

**Impact** `repo` scope grants read/write to **every** repository on the account,
not just the intended one. The token also passed through chat transport,
provider logs and conversation history.

**Fix**
1. Token used without ever writing it to a file; every commit was
   secret-scanned first.
2. Pushed via `http.extraheader` so it never entered `.git/config`:
   ```bash
   AUTH=$(printf 'x-access-token:%s' "$TOKEN" | base64 -w0)
   git -c http.extraheader="Authorization: Basic $AUTH" push origin main
   ```
   Stored remote stays clean: `https://github.com/NematUllah9812/terrastep.git`
3. Token deleted immediately after.
4. Replaced with a fine-grained PAT: **1 repo, Contents + Metadata + Workflows,
   7-day expiry.**

**Prevention** See `SECURITY.md`. Short version: prefer `gh auth login` so no
secret is ever transmitted; if delegation is unavoidable, use a fine-grained
token scoped to one repo and delete it the moment the push lands.

⚠️ **Deleting a token stops future use — it does not undo past use.** After any
exposure, audit for unexpected commits, deploy keys, altered workflows and newly
minted tokens.

---

### #14 🟡 Fine-grained tokens cannot create repositories
**Symptom** Not hit — anticipated while planning the switch away from the
classic PAT.

**Cause** A fine-grained token's repository picker only lists repos that
**already exist**. Creation is an account-level action a repo-scoped token
deliberately can't perform. The original repo was created with the classic
token's `repo` scope.

**Fix** Reorder the workflow:
1. Create the empty private repo in the **GitHub mobile app**
2. *Then* generate a fine-grained token scoped to it
3. Delegate the push, delete the token

**Prevention** Better anyway — repo creation stays under your control, and the
token can never create anything new.

---

### #15 🟡 Workflow files need a separate permission
**Symptom** Anticipated. A push containing `.github/workflows/*.yml` with a
Contents-only token fails:
```
refusing to allow a Personal Access Token to create or update workflow
`.github/workflows/tests.yml` without `workflow` scope
```

**Cause** Contents: write does **not** cover workflow files. Writing a workflow
means executing arbitrary code in CI, so GitHub gates it separately.

**Fix** Enable **Workflows: Read and write** on the token for that commit only,
then revert to Contents-only for routine pushes.

**Prevention** Confusing error — it looks like a file-write problem, but it's a
scope problem. Noted in `SECURITY.md §3`.

---

## Client (Flutter / Dart)

### #17 🔴 Stationary GPS jitter accumulated 1.1 km of phantom distance
**Symptom** Threshold 1.6 test T5 failed on first run:
```
FAIL T5 GPS jitter while stationary
  Expected: < 900    Actual: 1144.14
```
A phone standing still with 28 m GPS accuracy accrued **1,144 m over five
minutes** — enough to claim a cell without leaving the room. Threshold 4.2
specifies *"stand still indoors 10 min → distance < 20 m"*.

**Cause** The accumulator summed the raw distance between consecutive fixes,
gated only on `d > 1.0 m`. A stationary phone produces a **random walk**: each
fix lands tens of metres from the last. Summing those hops integrates noise into
kilometres.

**Failed first attempt.** An accuracy-aware deadband (subtract a noise floor
from each hop) does *not* work. Measured across noise factors:

| factor | real walk | jitter |
|---|---|---|
| 0.00 | 456 m | 1267 m |
| 0.25 | 376 m | 816 m |
| 0.50 | 105 m | 397 m |
| 0.75 | **0 m** | 138 m |

At 28 m accuracy the individual jitter hops are genuinely large, so any deadband
big enough to suppress them also erases real walking. There is no good value.

**Fix — displacement anchor.** The distinguishing property isn't hop size, it's
**net displacement**: jitter oscillates around a point, walking moves away from
it. So hold an anchor fix and only credit distance once the current fix is
`2 × accuracy` away, then move the anchor there.

```dart
final threshold = math.max(8.0, math.max(anchor.accuracy, fix.accuracy) * 2.0);
if (d < threshold) return 0;      // never escaped the noise envelope
_anchor = fix;
return d;
```

`2.0` was chosen by measurement (`app/tool/tune.dart`), being the smallest factor
that zeroes jitter while leaving a walk fully credited.

**Verified** (`app/tool/verify.dart`):

| Scenario | Credited | Claimable |
|---|---|---|
| Genuine 10-min walk (810 m actual) | **789 m (97%)** | 4 cells ✅ |
| Standing still, 28 m accuracy, 10 min | **0.0 m** | 0 ✅ |
| Shaking phone, 3025 fake steps | **0.0 m** | 0 ✅ |

**Prevention** Two lessons. First, **write the adversarial test before the
implementation** — T5 existed because the plan demanded it, and it caught a
cell-claiming exploit on the very first run. Second, when a filter can't
separate two signals, **look for a different discriminating property** rather
than tuning the parameter; hop magnitude was the wrong axis, net displacement
was the right one.

---

### #18 🟡 A too-aggressive fix broke the golden path
**Symptom** After the first anti-drift attempt, T5 passed but the golden-path
test failed: a genuine 8-minute walk became unclaimable (`readyToSubmit()` empty).

**Cause** The 0.75 noise factor suppressed jitter by erasing *all* movement.
Tests only caught it because a "real walk must still work" test existed
alongside the adversarial ones.

**Fix** Replaced with the anchor filter (#17), which passes both.

**Prevention** **Every anti-cheat test needs a paired golden-path test.** A
filter that rejects everything scores 100% against attackers and ships a broken
product. This is the client-side mirror of the SQL suite's `A1 valid walk
accepted`.

---

### #19 🔴 Rate limiting backed off one batch instead of the queue
**Symptom** Sync test failure:
```
FAIL rate limiting backs off the whole queue
  Expected: <1>   Actual: <2>
```
The worker made a second network call immediately after the server had said
`rate_limited`.

**Cause** On a rate-limit response the worker called
`outbox.recordFailure(entry.batchUuid, ...)`, which delays **only that batch**.
`break` stopped the current round, but the next flush (90 s later) found the
*next* batch due and sent it — still inside the server's cooldown.

Real-world consequence, from `02_CLAIM_ENGINE.sql`: every rate-limited call adds
**+5 suspicion**. A user who walked a lot and tripped the 50-cells/hour limit
would keep hammering, and could shadow-ban themselves for walking too much.

**Fix** Added `Outbox.backoffAll(error, notBefore)` and used it for
**account-wide** conditions (rate limiting, expired auth, offline) as opposed to
batch-specific ones. Two deliberate details:

- **`attempts` is not incremented.** The batch didn't fail — the account was
  throttled. Counting it would push healthy batches toward the poison
  threshold and silently discard walked data.
- **Auth failures use it too.** An expired JWT invalidates every batch, so
  retrying the rest is pointless.

**Prevention** **Classify a failure before reacting to it.** Ask "is this the
batch's fault, or the account's?" Batch-specific → back off that batch and count
the attempt. Account-wide → hold everything and count nothing. Two regression
tests now pin this: one asserts all four queued batches are held, the other that
`attempts` stays 0.

---

### #20 🟢 Adding Flutter would have made the logic tests need an emulator
**Symptom** Anticipated, not hit. Before writing the Android app, everything
lived in one package (`app/`) whose `pubspec.yaml` had the Flutter dependencies
commented out with a note saying *"uncomment at threshold 1.1"*.

**Cause** Following that note would have broken the test suite. The moment
`flutter: sdk: flutter` is added to a package:

- `dart test` no longer works — it becomes `flutter test`
- Running it needs the full Flutter SDK, not just Dart
- CI needs `subosito/flutter-action` instead of `setup-dart`, and a much
  heavier runner

The 43 logic tests — including the one that caught the GPS-drift exploit
(#17) — would have gone from *"runs anywhere in 2 seconds"* to *"needs a
1.5 GB SDK"*. That is exactly the kind of friction that leads to tests being
skipped.

**Fix** Split into two packages before adding Flutter:

```
packages/terrastep_core/   pure Dart. claim/contest/decay logic. 43 tests.
app/                       Flutter. sensors, map, UI. depends on core by path.
```

`app/pubspec.yaml` references it as a path dependency:
```yaml
terrastep_core:
  path: ../packages/terrastep_core
```

**Why this works structurally, not just tidily.** `SessionAccumulator` already
depended on the `CellIndexer` *interface* rather than on H3 (that seam existed
from the start). The real `H3Indexer` now lives in `app/lib/services/` and
implements it. So the native FFI plugin is on the Flutter side of the boundary
while all the logic that needs testing stays on the pure side.

**Prevention** The rule is written in `packages/terrastep_core/pubspec.yaml`,
`app/README.md` and the core README: **never import `package:flutter` into
`terrastep_core`.** Previously this was discipline; now the package boundary
enforces it, and CI would fail loudly since the `client` job runs `dart test`,
not `flutter test`.

---

### #21 🟢 MapLibre would have complicated the CI APK build
**Symptom** Anticipated. `03_CLIENT_ARCHITECTURE.md` specifies `maplibre_gl`.

**Cause** `maplibre_gl` wraps the native MapLibre SDK via platform views. That
means an NDK build step, larger APK, longer CI times, and a class of
Gradle/AGP version conflicts that are painful to debug remotely — with no
device here to reproduce them on.

**Fix** Used `flutter_map` for the first build instead: pure-Dart rendering over
OSM raster tiles. No native build step, so the CI APK build stays simple and
fast. It draws the H3 polygons via `PolygonLayer` perfectly well at the scale
we need (2 rings = 19 hexes).

**Trade-off, honestly stated.** `flutter_map` with raster tiles is slower than
vector rendering at high zoom and with hundreds of polygons. If Phase 3 shows
frame drops with a dense claimed map, revisit MapLibre then — on a machine that
can build and test it. For answering *"does a hex fill when I walk?"* and
*"what does this cost in battery?"*, raster tiles are fine.

**Prevention** Prefer the dependency that keeps the feedback loop working.
A technically superior library that cannot be built or tested in the current
environment is worth less than an adequate one that ships today.

---

### #22 🔴 First APK build failed: open carets pulled in too-new plugins
**Symptom** `Build Android APK` failed after 1m37s — too fast to be a Gradle
compile failure, which pointed at dependency resolution.

**Cause** The plugin versions in `app/pubspec.yaml` were written from memory
rather than checked, and used open carets. Checking pub.dev showed what `^`
actually resolves to today:

| Declared | Resolves to | Requires |
|---|---|---|
| `flutter_foreground_task: ^8.10.4` | **10.0.0** | Flutter >=3.38 |
| `shared_preferences: ^2.3.2` | **2.5.5** | Flutter >=3.35 |
| `pedometer: ^4.0.2` | **4.2.0** | Dart >=3.8 |
| `flutter_map: ^7.0.2` | 7.0.2 | ok |
| `geolocator: ^13.0.1` | **14.0.3** | newer AGP |

A caret is a promise that every future minor release stays compatible. Flutter
plugins routinely raise their minimum SDK in minor versions, so that promise
does not hold, and the build broke without a single commit changing.

Compounded by `channel: stable` in the workflow, which is a *moving* toolchain.
Moving deps against a moving SDK means a green build can turn red overnight.

**Fix** Four changes:

1. **Explicit upper bounds**, every version verified against pub.dev's API:
   ```yaml
   flutter_map: ">=7.0.2 <8.0.0"        # 8.x needs Flutter >=3.27
   shared_preferences: ">=2.3.5 <2.4.0" # 2.5.x needs Flutter >=3.35
   pedometer: ">=4.0.2 <4.1.0"          # 4.2.0 needs Dart 3.8
   geolocator: ">=13.0.4 <14.0.0"
   latlong2: ">=0.9.1 <0.10.0"          # flutter_map 7.x requires ^0.9.1
   ```
2. **Pinned the toolchain**: `flutter-version: '3.24.5'` instead of `stable`.
3. **Dropped unused plugins.** `flutter_foreground_task` and
   `permission_handler` were declared but never imported — the former caused
   the failure. geolocator handles its own permission requests.
4. **Made `terrastep_core` zero-dependency.** It declared `meta: ^1.15.0`
   without using it; Flutter pins `meta` via the SDK, so that was a latent
   resolution conflict for no benefit.

Also verified the transitive graph by hand: `flutter_map 7.0.2` requires
`latlong2 ^0.9.1`, which is why latlong2 needed the `<0.10.0` cap.

**Also fixed: the failure was hard to diagnose.** The workflow now
- writes `pub get` and build output to files, uploaded as a `build-logs`
  artifact,
- prints the error to `$GITHUB_STEP_SUMMARY`, so the actual message is visible
  on the run's summary page without opening raw logs,
- runs `flutter pub deps` to record what actually resolved,
- makes `flutter analyze` non-blocking, so a lint warning can't hide whether
  the APK compiles.

**Prevention** **Never guess a version number.** pub.dev has a JSON API; one
curl per package confirms the version exists and what SDK it needs:
```bash
curl -s https://pub.dev/api/packages/<pkg> | jq '.latest.version, .latest.pubspec.environment'
```
And for an app that must keep building unattended, prefer explicit bounds and a
pinned toolchain over carets and `stable`.

---

### #23 🔴 `h3_flutter` 0.7.x cannot resolve on Flutter 3.24.5
**Symptom** After pinning plugins (#22), `flutter pub get` on the pinned
toolchain failed with:
```
Because h3_flutter >=0.7.0 depends on h3_web >=0.7.0 which requires SDK
version >=3.6.0 <4.0.0, h3_flutter >=0.7.0 is forbidden.
```
Bumping to Flutter 3.27.4 (Dart 3.6.2) then failed one step further:
```
h3_web ^0.7.0 depends on js ^0.7.2, and js >=0.7.2 requires SDK ^3.7.0
```

**Cause** There is no `h3_flutter` that sits on Dart 3.5. 0.6.x is locked
to Dart 2 (`sdk: <3.0.0`). 0.7.x is the first Dart 3 line, but its own
`environment.sdk` says `>=3.5.0` while a transitive dep (`h3_web` →
`js` 0.7.2) needs 3.7. The declared range is a lie.

**Fix** Two things, both required:
1. Pin the toolchain to **Flutter 3.27.4 / Dart 3.6.2** — the oldest
   Flutter that can even see `h3_flutter` 0.7.x.
2. `dependency_overrides: js: 0.7.1` so pub can finish resolving. We
   never import the web backend on Android; the override exists only to
   satisfy the solver. `js` 0.7.1 accepts Dart `^3.1.0`.

**Verified** `flutter pub get` succeeds, `flutter analyze` is clean, and
the debug APK contains `lib/arm64-v8a/libh3.so` (141 KB).

**Prevention** When a plugin's `environment.sdk` looks compatible, still
walk the *transitive* graph. The hole was two layers down and would have
burned another CI round-trip. A package's declared SDK range is not a
promise about its dependencies.

---

### #24 🟢 `Color.withValues` does not exist on Flutter 3.24
**Symptom** Anticipated while reading the first app sources against the
then-pinned 3.24.5 toolchain. `Color.withValues(alpha: …)` landed in
3.27; on 3.24 it is a compile error.

**Cause** Widget code was written against current Flutter muscle memory,
then the toolchain was pinned *older* to keep plugin versions stable
(#22). The two decisions fought.

**Fix** Became moot when #23 forced the toolchain to 3.27.4, which has
`withValues`. Left the call as `withValues` so analyze stays clean.

**Prevention** API surface is a function of the *pinned* SDK, not of
"what Flutter can do today". After a pin, grep the tree for APIs newer
than that pin before pushing.

---

### #25 🟡 Pedometer would have been silently empty on Android 10+
**Symptom** Anticipated. `StepService` listens to
`Pedometer.stepCountStream` and swallows errors. The claim floors
require 120 steps. Android 10+ makes `ACTIVITY_RECOGNITION` a runtime
permission, and neither `pedometer` 4.0.2 nor `geolocator` requests it.
First walk on a real phone would have shown `NO SENSOR` and no hex
would ever fill — looking exactly like a logic bug.

**Cause** #22 dropped `permission_handler` because it was unused *for
location*. That was correct for location and wrong for steps.

**Fix** Brought `permission_handler` 11.3.1 back, requested
`Permission.activityRecognition` after location (denial is non-fatal),
and added a stride estimator (0.78 m/step) that kicks in after 8 s
with no hardware reading. The overlay labels this `EST. from dist`.

**Prevention** A permission in the manifest is not a grant. Every sensor
behind a runtime permission needs an explicit request, and every
request needs a defined failure mode that does not look like a logic
bug.

---

### #26 🟡 Local APK build on a 2 GB box
**Symptom** The plan said "the sandbox has 2 GB RAM and Gradle wants more,
so build on GitHub Actions." The Actions token on this session had
Contents + Workflows but **not** Actions:read, so we could neither
watch a CI run nor download its artifact. The APK had to be produced
here or not at all.

**Cause** Three compounding environment facts, none of them in the repo:
1. **1.9 GB RAM, 0 swap.** Gradle's default heap will OOM.
2. **Debian 13 (Trixie) has no `openjdk-17-jdk`.** Only 21 and 25.
   Flutter 3.27 / AGP 8 still want 17.
3. `swapon` is in `/usr/sbin`, which is not on the default `PATH`, so
   a `set -e` setup script died after creating the swapfile.

**Fix**
- 4 GB swapfile (`fallocate` + `mkswap` + `/usr/sbin/swapon`)
- Temurin 17 from Adoptium into `/opt/jdk17` (not apt)
- Flutter **3.27.4** into `/opt/flutter` (see #23)
- Android SDK 34 + NDK 25 (Flutter pulled NDK 25.1 and platforms 31/35
  itself during the build)
- `org.gradle.jvmargs=-Xmx1024m`, daemon off, workers=1
- `flutter build apk --debug --target-platform android-arm64`

**Verified** AssembleDebug 360.7 s. 45 MB APK. Contains
`lib/arm64-v8a/libh3.so` (141 KB) and `libflutter.so`.

**Prevention** Document the local-build recipe next to the "we build on
CI" claim, because CI is only useful if you can read the artifact. And
never assume `openjdk-17-jdk` exists — check `apt-cache search openjdk`
first.

---

### #27 🟡 The APK was built but not in the repo
**Symptom** After the green build, the only copy lived at
`/home/user/Terrastep-debug.apk` and `dist/terrastep-debug.apk`.
`dist/` is gitignored (CI output). The phone-install instructions
pointed at "this workspace" and at Actions artifacts — neither of
which is the git repo the user actually opens.

**Cause** `.gitignore` treats every APK as a build product. That is
correct for `app/build/` and `dist/`. It is wrong for the *deliverable*
the next person (or the same person, on a phone) needs to download.

**Fix** Commit the tested artifact to `releases/terrastep-debug.apk`
and point README / CURRENT_PROGRESS / app/README at that path.
`dist/` stays ignored. 45 MB is under GitHub's 100 MB file limit and
under the 50 MB warning threshold.

**Prevention** If the deliverable is a file a human has to tap, it
belongs in the repo (or a Release), not in a gitignored build folder
and not only in an Actions artifact that needs a different token
permission to read.

---

### #28 🔴 First device walk got no GPS and no permission dialog
**Symptom** On a real phone the first APK:
1. Never showed the location permission sheet. The tester had to open
   **App info → Permissions** by hand, then turn GPS on by hand.
2. After that, a walk changed **only** battery % and elapsed time.
   Cell, steps, distance, dwell, gps acc, accepted fixes all stayed
   at zero / `—`.

**Cause** Two stacked bugs, both in `LocationService`:

1. **GPS-off short-circuits the permission request.**
   `requestForeground()` returned `denied` if
   `isLocationServiceEnabled()` was false — *without* asking for the
   runtime permission and *without* opening location settings. On a
   phone that ships with Location off (common), the boot screen said
   "enable GPS and tap retry" but offered no button that actually
   opened the GPS toggle. The tester went to App Info instead.

2. **25 m distance filter from the first millisecond.**
   The service started in `MotionState.stationary` with
   `LocationSettings(distanceFilter: 25)`. On many Android phones
   (Fused Location) a stream with `distanceFilter > 0` **never emits
   an initial fix**. The tester walked "some distance" — less than
   25 m of *GPS-detected* displacement, or GPS never locked — and
   the overlay's own 20 s battery timer was the only thing that
   rebuilt the widget. Hence only time and battery moved.

   A third, quieter issue: if `H3Indexer.geoToCell` had thrown on
   the first fix, the listen callback would have died and every
   later fix would have been dropped with no UI. Not confirmed on
   this device, but the stream had no `onError` and no try/catch.

**Fix** (APK **v0.1.1+2**)
- Ask for location via `permission_handler` (`locationWhenInUse`,
  then `location` as OEM fallback). Open **Turn on GPS** and **App
  settings** as real buttons. Re-run the gate when the app resumes
  from Settings.
- Seed with `getLastKnownPosition` + `getCurrentPosition`.
- Stream at 1 Hz, `distanceFilter: 0`, `LocationAccuracy.best`.
  Do **not** retune the filter until we have five raw fixes.
- If Fused Location is silent for 8 s, restart with
  `forceLocationManager: true`.
- Overlay ticks at 1 Hz and shows `raw gps`, `waiting for GPS…`,
  and the last error string.
- H3 load is lazy; a native-lib failure cannot kill the GPS
  listener.

**Prevention** A sensor test APK must show *why* a sensor is silent
(permission / GPS off / 0 raw fixes / last error), not just the
derived game stats. And never put a movement threshold on the first
lock — you cannot filter a stream that has not started.

---

## Open Items

Known problems not yet solved. Carry these forward.

| # | Item | Where | Status |
|---|---|---|---|
| O1 | `h3` extension availability on Supabase unverified | #5 | Check at threshold 2.1 |
| O2 | `realtime.send()` inside `SECURITY DEFINER` untested on real Supabase | #6 | Verify at threshold 3.2 |
| O3 | Rate limiting written but untested | 4.6 | Needs a 60-cell fixture |
| O4 | `score_suspicion()` written, never deployed or run | 4.7 | Needs a synthetic bot profile |
| O5 | `admin_rollback_user()` untested | 4.8 | Needs a reassignment fixture |
| O6 | RLS hostile test not written | 2.4 | Needs a real JWT — can't be shimmed |
| O7 | Background battery drain unmeasured | 0.3 | **Highest project risk — awaiting device test** |
| O8 | APK still not compiled | 1.1 | **Resolved.** v0.1.1+2 in `releases/`. First walk (#28) showed GPS was silent. |
| O9 | `H3Indexer` unverified against `h3-js` | 1.3 | Cell ids must match the server's. Compare a known coordinate before trusting claims. |
| O10 | Anti-drift filter untuned against real GPS | 4.2 | Tuned on synthetic jitter. Real GPS may need a different `_anchorFactor`. |
| O11 | Foreground service not implemented | 1.8 | Tracking currently stops when the app is backgrounded. Needed for the real battery test. |

---

## Recurring Patterns

Lessons that keep resurfacing. Read these first if you're resuming.

### On the environment
1. **The sandbox is ephemeral; the repo is not.** Packages, processes, git
   identity and remotes all reset (#3, #4, and #10 recurred twice). Anything
   that must survive goes in a committed file. On resuming: install Postgres,
   install Dart, set git identity, re-add the remote.

### On testing
2. **When a test fails, suspect the test first.** Three "failures" (#8, #9,
   #18) were wrong expectations or bad fixtures. The implementation was right
   each time.
3. **Assert the specific reason, not just failure.** #8 only surfaced because
   tests assert exact rejection strings. `assert rejected` would have hidden a
   rule being masked by an earlier one.
4. **Every anti-cheat test needs a paired golden-path test.** A filter that
   rejects everything scores 100% against attackers and ships a broken product
   (#18). The SQL suite's `A1 valid walk accepted` is the same idea.
5. **Test the safety net itself, in both directions.** The secret scanner (#12)
   would have failed every CI run by matching its own documentation. Tools that
   protect you need their own tests.
6. **A "run this to get started" command must be idempotent.** Run it twice,
   and once after deleting its state (#16). That bug only appeared because the
   documented resume steps were actually executed rather than assumed.

### On implementation
7. **When a filter can't separate two signals, change the axis.** Hop magnitude
   could not distinguish GPS jitter from walking at any threshold; net
   displacement separated them perfectly (#17). Tuning a parameter harder is
   not always the answer.
8. **Classify a failure before reacting to it.** "Is this the batch's fault or
   the account's?" Batch-specific → back off that batch. Account-wide → hold
   everything (#19). Getting this wrong could have shadow-banned real users.
9. **Never guess a version number.** #22 cost a failed build purely because
   plugin versions were written from memory. One curl to the pub.dev API
   confirms both existence and SDK requirements.
10. **Prefer the dependency that keeps the feedback loop working.** A better
    library you cannot build or test in the current environment is worth less
    than an adequate one that ships today (#21).

### On structure
11. **Enforce boundaries structurally, not by discipline.** A comment saying
    "don't add Flutter here" is weaker than a separate package where adding it
    breaks the build visibly (#20).
12. **Design for unattended failure.** The first APK build failed with an error
    nobody could read from a phone. Diagnostics that surface on the summary
    page cost ten minutes and save every future round-trip (#22).
13. **A package's declared SDK range is not a promise about its dependencies.**
    `h3_flutter` 0.7.1 said `>=3.5.0`; two layers down, `js` 0.7.2 needed
    3.7 (#23). Walk the transitive graph, not just the top-level pubspec.
14. **A permission in the manifest is not a grant.** Dropping
    `permission_handler` was right for location and wrong for the
    pedometer (#25). Every runtime permission needs an explicit request
    *and* a failure mode that cannot be mistaken for a logic bug.
