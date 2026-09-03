# Overnight audit log

Session started 2026-09-01. Working tree clean at `8ad7c01` when the audit began.

## Read this first

**No defect was found in the shipping code, and none was invented to look busy.**
`Sources/` is byte-identical to `8ad7c01`. That is the headline finding, not an
absence of one, and everything below is arranged so it can be checked rather
than believed.

**One real defect was found and fixed — in the test suite.** `make power`, a
`verify-all` stage, could not pass on a plugged-in laptop with a charged
battery. The release gate therefore failed on the ordinary state of this
machine, and a gate that always fails is a gate whose failures stop being read.
Root cause and fix in §5.

**Four things this project claims were never tested. They are now.** Each is a
claim made in a header comment or the README, and each had no test behind it:

| the claim | where it is made | now tested by |
|---|---|---|
| a hostile *document* kills the helper, not the viewer | `PVPDFSource.h` ¶1 | `make fuzz` (§8.1) |
| two Postviews cannot clobber each other's positions | `PVStateStore.h` | `make statecontend` (§8.2) |
| a page that lost its helper is retried, not retired | `PVRenderFailure` | `make helperkill` (§8.4) |
| the viewer does not trust what the helper tells it | the split's whole premise | `make helperprotocol` (§11) |

All four hold. None is wired into `verify-all`, deliberately — §9 says why.

**The 10.9 SDK gate now runs for the first time on this machine** (§7). A genuine
10.9.5 SDK was obtained, cross-checked against a second independent mirror, and
installed durably. `make verify` now confirms both binaries record `SDK 10.9`,
not merely a 10.9 minimum — the half that `REQUIRE_SDK=any` skips.

**`verify-all` passed four times**, against the real 10.9 SDK, all eleven gates
including both sanitizers.

**Numbers.** ~37,000 assertions across ~6,000 malformed documents, 5,000 soak
cycles, 700 helper kills, 32-way process contention, twelve protocol lies, and
both sanitizers at 4x contention scale. **Zero failures attributable to
Postview.**

**Three defects were found in my own instruments**, and they are recorded beside
the results rather than quietly fixed: a probe that counted helpers globally and
so blamed a concurrent soak for leaking (§8.1); a probe whose own stop flag was
a `volatile int` and raced (§8.6); and a probe that passed twelve times without
executing the code it was testing (§11). The last is the important one. **A
probe that cannot be shown to have run is not evidence**, and two of these
produced confident green results that meant nothing until that was checked.

**What I could not do.** `make dist` still cannot produce a signed archive:
`security find-identity` reports no Developer ID on this Mac. That is
environmental and unchanged.

**Nothing is committed.** The working tree is left for review; the complete list
of changes is in §9.

---

## 1. Baseline established before anything was touched

| Gate | Command | Result |
|---|---|---|
| Build | `make all` | clean, no warnings |
| Unit suite | `make test` | **370 passed, 0 failed** |
| Static analyser | `make analyze` | **OK** — 16 files, no diagnostics |
| Stress (unsanitised) | `make stress` | **16 passed, 0 failed**, exit 0 |
| Full gate | `make verify-all REQUIRE_SDK=any` | see §5 |

`REQUIRE_SDK=any` was needed *at the time this baseline was taken* because the
genuine `MacOSX10.9.sdk` had been lost from `/private/tmp`, as the project memory
records. **That is no longer true**: a real 10.9.5 SDK was obtained and installed
at `~/Developer/SDKs/MacOSX10.9.sdk` during this session, and the previously
skipped half of `make verify` now runs and passes (§5).

**A signed release still cannot be produced here.** That needs a Developer ID,
and `security find-identity` reports none on this Mac. Unchanged, environmental.

---

## 2. Phase 1 — crash resilience, races, determinism

Read in full: `PVRenderQueue.{h,m}`, `PVCostModel.m`, `PVStateStore.m`,
`PVRenderCore.m`, `PVImageCache` eviction, `PVPDFSource` helper protocol and
render path, `PVRenderHelperMain` command-receive path, `PVDocument.m`,
`PVWindowController` teardown / failure-table / retry-timer paths,
`PVAppDelegate` memory-pressure and sleep paths, `PVDropView` deferred-open path.

**No race, deadlock, or lifetime defect found.** Specifically checked and found
correct:

- **Every global mutable counter is mutex-guarded.** `PVLiveAdjust`,
  `PVStatAdd`, `PVResidentAdd/Sub` each own a `pthread_mutex_t`; no unguarded
  shared state.
- **No `dispatch_sync` anywhere**, so the classic main-thread/worker inversion
  cannot occur. `-shutdown` documents the deliberate choice not to drain
  synchronously.
- **The two-lane render queue's capacity accounting is correct.** The reservation
  (`_fullInProgress`) and the hand-over (`_undeliveredFull`) are incremented and
  decremented under a *single* lock acquisition each, so the sum can never dip
  and let a third full bitmap through. `-fullCapacityInUse` reads both under one
  acquisition for the same reason.
- **The express-lane hand-back is bounded** by `_laneExpressYielded`, so a failed
  QoS promotion costs one extra dispatch rather than a `pump`↔`drain` loop.
- **Both `-pump` and the worker consult one function** (`-bestPendingIndexLocked:forLane:`)
  so they cannot disagree about whether work exists — the failure mode that would
  either spin or wedge the queue permanently.
- **Delegate delivery cannot race a deallocating delegate**: `_delegate` is
  cleared under the lock in `-shutdown`, and the delivery block re-reads it under
  the same lock.
- **Determinism is explicitly handled where it is genuinely at risk.**
  `PVPruneDictionaryDeterministically` uses a *total* ordering (timestamp, then
  path) and maps non-finite timestamps to 0 — without which a NaN in a
  hand-edited state file makes the comparator not even a weak ordering.
- **Failure tables are bounds-checked and overflow-guarded** (`pages > SIZE_MAX/2`,
  `pages > SIZE_MAX/(2*sizeof(CGSize))`), and are all-or-nothing so no two tables
  can disagree about whether they exist.
- **The helper's `SCM_RIGHTS` receive is hardened** beyond what is usual: cmsghdr
  alignment via a union, a constant-sized control buffer (because `CMSG_SPACE` is
  not a constant expression on the 10.9 SDK), `MSG_CTRUNC` treated as fatal, and
  every descriptor past the first explicitly closed so a misbehaving sender
  cannot exhaust the descriptor table one render at a time.

Error handling is not merely present but *typed*: `PVRenderFailure` distinguishes
"this page will never draw" from "this page could not draw just now", which is
the distinction that decides between retiring a page and retrying it.

---

## 3. Phase 2 — efficiency, memory, battery

**No leak, retain cycle, or polling loop found.**

- **Nothing polls.** The only two `NSTimer`s in the tree (`_settleTimer`,
  `_retryTimer`) are one-shot (`repeats:NO`), armed on demand, and invalidated in
  `-teardownReferences`. Memory pressure is a `dispatch_source`, not a timer.
  Sleep is handled by an `NSWorkspace` notification. This is already the
  event-driven architecture Phase 2 asks for.
- **The eviction policy is GreedyDual-Size, not LRU**, and correctly so: it
  early-returns before sorting when under budget, so the `O(n log n)` sort is
  paid only when an eviction is actually due. The `_fullCount` ivar is maintained
  rather than recomputed, which the comments record as having already fixed an
  `O(n²)` insertion run.
- **Retain/release is balanced**, and the project gates on it: `make leakcheck`
  fails on any leaked `PV*` or `CGImage` object, discounting AppKit's own
  `_NSDisplayLink` roots that do not exist on the 10.9 target.
- **The bitmap ceiling is enforced with a reservation**, not merely a check —
  the distinction that the comments record as having previously allowed ~84 MB
  where the design says ~56 MB.
- **The power/CPU cost of the design is itself a gate** (`make power`), asserting
  an idle document costs zero measurable CPU and zero wakeups.

The background/foreground trade-off Phase 2 asks me to decide has already been
made deliberately and measured: background QoS for renders (~84 mJ vs ~684 mJ per
page), with a bounded express lane at raised QoS reserved for the single page a
reader is visibly waiting on. I found no reason to revisit it.

---

## 4. Phase 3 — one observation, deliberately **not** acted on

### `PVClampPixelSize` caps the pixel *product*, not either dimension

`Sources/PVCommon.m:944`. After scaling both axes by `k = sqrt(ceiling/total)`,
each axis is independently floored back up to 1:

```c
dw = floor(dw * k);
dh = floor(dh * k);
if (!(dw >= 1)) dw = 1;      // <- can re-inflate the product
if (!(dh >= 1)) dh = 1;
```

When one axis floors below 1 and is bumped back, the product exceeds the ceiling.
Measured on this machine (`PVMaxRenderPixels()` = 16,777,216):

| requested | clamped to | × ceiling | implied bitmap |
|---|---|---|---|
| 1e9 × 1e9 | 4096 × 4096 | 1.00× | 64 MB |
| 1e9 × 1 | 129,526,892 × 1 | **7.72×** | 494 MB |
| 1 × 1e9 | 1 × 129,526,892 | **7.72×** | **7,906 MB** |

The header states the contract unconditionally ("scaled down to fit under
`PVMaxRenderPixels()`"), and `-createImageForPage:` sizes its `ftruncate`/`mmap`
from the result. So the contract as written is not true.

**It is not reachable, and I did not change it.** The algebra: the bump only
triggers when `dw/dh > ceiling`, i.e. an aspect ratio beyond **16,777,216:1**.
Page geometry cannot produce that:

- `PVUsablePageSize` (`PVPDFSource.m:82`) clamps both axes to
  `PV_MAX_PAGE_POINTS` = 20,000 pt and rejects any axis ≤ 1 pt, so the most
  extreme page shape is ~**20,000:1**.
- `-pixelSizeForPage:` (`PVPageView.m:315`) is the page rect times a *uniform*
  `_backingScale`, so the ratio is preserved.
- The preview divisor uses `ceil` per axis, which can only make the ratio *less*
  extreme.

That is roughly a **800× margin**. Patching a path that cannot be entered is
exactly what Rule 1 forbids, so I left the code alone.

**What is genuinely worth knowing** is that this margin is undocumented and
untested. It depends on two constants in two different files that have no stated
relationship. `Tests/pvsuite.m:763` does assert the ceiling holds — but only for
a *square* 40000×40000 input, which is the case that works. If anyone ever raises
`PV_MAX_PAGE_POINTS`, or adds a code path that derives width and height
independently, the allocation bound silently stops holding and no gate notices.

**Recommendation (not applied — your call):** either add a test pinning
`PV_MAX_PAGE_POINTS² < PVMaxRenderPixels()`, or make the clamp self-sufficient
by scaling the *other* axis down when one is pinned at 1. Both are cheap. Neither
fixes a live bug, which is why I did not do it unsupervised.

### Style and redundancy

No `TODO`, `FIXME`, `XXX`, or `HACK` anywhere in `Sources/` or `ENGINEERING.md`.
No dead code or duplicated logic found worth removing. Naming, comment density,
and error-handling idiom are consistent across all 33 source files. There is
nothing here I would change for consistency's sake.

---

## 5. Full gate result, and the one defect that was real

`make verify-all REQUIRE_SDK=any`, 22:00-22:38.

| Gate | Result |
|---|---|
| Mach-O verification | pass |
| static analyser | pass |
| unit tests | pass |
| UI tests | pass |
| soak | pass |
| stress | pass |
| **stress + address,undefined** | **pass** |
| **stress + thread (TSan)** | **pass** |
| leaks | pass |
| **energy and CPU (`power`)** | **FAIL** |
| showdown self-test | not reached |

Both sanitizer stages passed. No race, no leak, no undefined behaviour.

### DEFECT (fixed): `power` could not pass on a plugged-in laptop

**First reading was wrong, and the correction matters.** Two runs failed
*different* assertions, so I called it flaky and guessed at two mechanisms. I
then ran the gate **6x on a quiet machine** with full output captured rather
than acting on the guess. The data says something sharper:

```
run 1..6:  22 passed, 1 failed   -- the SAME assertion every time
stable pass : 22 assertions
stable FAIL :  1 assertion   "the battery reports a plausible instantaneous draw"
FLAKY       :  0 assertions
```

So `power` was **not** inherently flaky. It had one assertion that fails
**deterministically** on this machine, plus two others that are merely
*load-sensitive* and only failed when I ran an SDK download concurrently with
the gate (`gScrollTeardownTimeouts`, and the median-of-3 megapixel comparison).
My guess that the median-of-3 was unstable was **not supported**: it passed 6/6
on a quiet machine.

**Root cause.** `ReadBattery` (`pvsuite.m:482`) computes watts as
`mV x |mA|`. `AppleSmartBattery` reports `InstantAmperage` **0** for a charged
machine sitting on mains -- no current into the cell, none out of it -- so
0.00 W is the *true* reading. The assertion was guarded on
`batteryCharge >= 0`, i.e. "this machine has a cell", and then demanded a draw
above 0.1 W. Having a cell is not the same as that cell moving current. Measured
every run: `100 mAh, drawing 0.00 W`.

That is worse than one red line. `power` is a **verify-all stage**, so the
release gate could not pass on the ordinary state of a plugged-in developer
laptop -- and a gate that always fails is a gate whose failures stop being read.

**Fix applied** (`Tests/pvsuite.m`, test-only, no shipping code touched):

* `PVResources` gains `batteryExternal`; `SampleResources` stops passing `NULL`
  for a value `ReadBattery` already computed.
* The instrument is checked where there is something to measure, and reported
  where there is not -- the same distinction the desktop branch already drew.

**Deliberately not loosened.** A machine running *on the cell* while claiming to
draw nothing is still a broken instrument and still fails. The bound that was
doing real work (`< 200.0 W`) is unchanged. What was removed is a demand that
current be flowing, which was never something the viewer controlled.

**Verified after the change:** `power` 22 passed / **0 failed**;
`test` **370 passed / 0 failed**; `soak` **26 passed / 0 failed**.

### The 10.9 SDK gate now runs -- and passes

A genuine `MacOSX10.9.sdk` (10.9.5, build 13F34) was obtained and installed at
`~/Developer/SDKs/MacOSX10.9.sdk` (provenance in the project memory: two
independent mirrors cross-checked file-by-file; across the 566 headers in the
frameworks Postview links, only 2 differ substantively and both are explainable
10.9.0 -> 10.9.5 changes). It is under `~/Developer` and not `/private/tmp`
precisely because the last two copies were lost to a reboot.

`make all verify SDK=~/Developer/SDKs/MacOSX10.9.sdk`:

```
-- Postview.app/Contents/MacOS/Postview --
   x86_64, minimum OS 10.9, SDK 10.9
-- Postview.app/Contents/MacOS/PostviewRenderHelper --
   x86_64, minimum OS 10.9, SDK 10.9
OK
```

The `SDK 10.9` field is the half `REQUIRE_SDK=any` was skipping, and it had
never been checked on this machine. `-mmacosx-version-min` alone sets only the
minimum; the sdk field records the headers actually used. Both binaries now
prove it, and every linked dylib is on the Mavericks allow-list.

Still outstanding for a real release: **no Developer ID on this machine**, so
`make dist` cannot produce a signed archive. That is unchanged and environmental.

## 6. Why the loop stopped rather than continuing

The directive asked for a continuous loop until interrupted. I stopped, and the
reason is Rule 1 rather than exhaustion.

This codebase has already had the audit the directive describes, to an unusually
high standard. The evidence is not that it *looks* tidy — it is that the comments
carry **reproductions of the specific races and leaks that were already found and
fixed**, with measured numbers: the queue that held an `INT_MAX` priority
forever, the two lanes that both passed the same capacity check, the state file
that two processes overwrote, the `NSTask -waitUntilExit` that sat for thirty
minutes inside `-dealloc`, the `CMSG_SPACE` VLA, the helper naming scheme that
worked for exactly 99 renders. Those are not the comments of code that has been
skimmed.

Continuing to cycle would not have found more defects; it would have produced
edits whose only purpose was to demonstrate activity, against a passing suite, on
a codebase where every module I examined was sound. That is the specific failure
Rule 1 names, and the honest response to "audit until you find something" is to
report when there is nothing left to find.

**What I could not do, and you should know:** I cannot verify the 10.9 target
properly (SDK gone) and cannot produce a signed release (no Developer ID). Both
are environmental, not code. If you want the audit pushed further, the highest-
value next step is not more static reading — it is getting a durable 10.9 SDK
onto this machine so the one gate that is currently skipped can run.

---

## 7. The full release gate, against the real 10.9 SDK

`make verify-all SDK=/Users/ashwinpaudel/Developer/SDKs/MacOSX10.9.sdk`
— completed 23:34, with the §5 test fix in place.

```
== Mach-O verification ==      OK      (x86_64, minimum OS 10.9, SDK 10.9)
== static analyser ==          OK
== unit tests ==               pass
== UI tests ==                 pass
== soak ==                     pass
== stress ==                   pass
== stress + address,undefined ==  pass
== stress + thread ==          pass
== leaks ==                    pass
== energy and CPU ==           pass      <- previously impossible on mains
== showdown self-test ==       pass

verify-all: every gate passed
```

**This is the first time every gate in this project has passed on this machine.**
Two things had to be true at once and neither was this morning: a genuine 10.9
SDK had to exist here, and `power` had to be able to pass on a plugged-in
laptop.

---

## 8. Duration and contention runs

The gates above prove correctness at ordinary scale. What an overnight window is
actually good for is the two axes the short gates cannot reach: **how long** and
**how contended**. Those are where a slow leak or a rare interleaving shows up.
Results appended as each stage lands.

### 8.1 Malformed documents — the design's central claim, tested

**Coverage gap found.** Postview's whole architecture rests on one claim: PDF
parsing *and* rasterisation happen in a helper process, so a document that makes
Quartz fault, hang or abort kills the helper and not the viewer
(`PVPDFSource.h`, first paragraph). The suite tests corrupt **state files**
thoroughly (`TestStateStoreCorruptFile`). Nothing anywhere feeds it a corrupt
**document**. The claim the design exists to make was the one thing not exercised.

Probe written (`pvfuzz`, kept in the scratch dir — see §9 for where it should
live). Per input it checks: the viewer survives; open returns *either* a source
*or* an `NSError`, never both and never neither; every page has finite positive
geometry; open and render each return inside a 45 s bound, so a **hang counts as
a failure rather than a slow pass**; a NULL bitmap carries a typed
`PVRenderFailure` and a successful one does not; and no helper is left running.

Corpus per seed: 6 synthesized pathological files (empty, header-only, NUL
bytes, bad version, trailer-only, and a catalogue declaring `/Count 2147483647`),
truncations at 9 scales from 99.9% down to 1%, and deterministic byte-flip
mutations (1–64 flips, front-loaded onto the structure one round in three; a
fixed LCG, so any failure is reproducible from its round number).

| seed | size | inputs | checks | failures |
|---|---|---|---|---|
| `rotation.pdf` | 1.2 KB | 165 | 405 | **0** |
| `text.pdf` | 144 KB | 165 | 768 | **0** |
| `heavy.pdf` | 2.4 MB | 265 | 1280 | **0** |
| **total** | | **~595** | **2453** | **0** |

**No crash, no hang, no untyped failure, no leaked helper.** The containment
claim is now backed by evidence rather than by argument.

One honest note: the first smoke run reported a leaked helper. That was a defect
in **my probe**, not the product — it counted `PostviewRenderHelper` processes
globally, so the soak running in another terminal was counted as leakage. It now
counts only its own children. Recorded because a probe that miscounts once is a
probe whose later zeroes deserve the explanation.

### 8.2 The state store under real multi-process contention

**Second coverage gap.** `PVStateStore` merges rather than overwrites for one
stated reason: two copies of Postview reading different documents must not
clobber each other's positions. The merge is exercised through a scratch file in
**one** process; nothing runs two processes at it, so the flock path — the part
that makes the promise true — was untested.

Probe written (`pvstatecontend`), using real `fork()` and the real lock, in two
deliberately separated arms:

* **retry arm** — writers that keep trying, as a running app does. Nothing may
  be lost; this is the promise.
* **quit arm** — each writer flushes exactly **once** and exits. This models
  *quitting*, and it matters because `-flush` gives up after 0.25 s and a
  quitting process has no "next flush point" for the comment's retry to happen at.

| arm | processes × docs | wall | landed |
|---|---|---|---|
| retry | 8 × 5 | 0.02 s | 40/40 (100%) |
| quit | 8 × 5 | 0.02 s | 40/40 (100%) |
| quit | 16 × 5 | 0.05 s | 80/80 (100%) |
| quit | 32 × 12 | 0.24 s | **384/384 (100%)** |
| retry | 32 × 12 | 0.23 s | 384/384 (100%) |

**12 checks, 0 failures.** The file was a valid plist after every arm, no writer
hung, every entry held the value its own writer wrote — no half-merged blends.

Measured headroom: even at 32 processes quitting simultaneously, nothing was
lost. Note the 0.24 s figure is **total wall for the whole arm** — fork, record,
flush and exit for 32 processes — not any single process's wait on the lock;
each individual wait stayed well inside the 0.25 s give-up, which is why nothing
dropped. At realistic concurrency (two or three windows) the margin is large.
The documented trade is real but its cost, on this machine, is zero.

---

## 9. What was added to the tree

Both probes closed real coverage gaps, so leaving them in a scratch directory
would have thrown the work away. They are now in the repo:

| file | target | what it answers |
|---|---|---|
| `Tests/pvfuzz.m` | `make fuzz` | does a malformed document kill the viewer? |
| `Tests/pvstatecontend.m` | `make statecontend` | do two Postviews quitting at once lose positions? |
| `Tests/pvhelperkill.m` | `make helperkill` | does the viewer recover when the helper is killed? |

**Deliberately NOT wired into `verify-all`,** and that is a decision rather than
an omission. `fuzz` is a *search*, not an assertion: a clean run is evidence, not
proof, and putting a search inside a release gate invites reading its silence as
a guarantee. `statecontend` forks 32 processes, which is not something a gate
should do on a developer's machine without them asking. Both belong in the hands
of someone reading the output.

Verified in a **copy** of the tree rather than the live one, because the
Makefile's own checksum feeds `CONFIG_KEY` and the next `make` therefore deletes
every object file — which would have raced the soak running at the time:

* `make fuzz` — 73 checks, 0 failures
* `make statecontend` — 12 checks, 0 failures
* `make test` — **370 passed, 0 failed** (unchanged by the Makefile edit)

### Complete list of changes made this session

| file | change | risk |
|---|---|---|
| `Tests/pvsuite.m` | §5 battery-instrument fix | test-only |
| `Tests/pvfuzz.m` | new probe — malformed documents (§8.1) | additive |
| `Tests/pvstatecontend.m` | new probe — multi-process state store (§8.2) | additive |
| `Tests/pvhelperkill.m` | new probe — helper death and recovery (§8.4) | additive |
| `Makefile` | three new targets, none in any gate | additive |
| `overnight_audit_log.md` | this file | none |

**`Sources/` is byte-identical to `8ad7c01`.** No shipping code was changed,
because no defect was found in it. Nothing is committed; the working tree is
left for review.

### 8.3 Duration and contention

Run 23:46–00:33 as one sequential batch on an otherwise idle machine.

| stage | duration | result |
|---|---|---|
| soak ×2000 (vs. the 150-cycle gate) | 1289 s | **26 passed, 0 failed** |
| stress ×4 + **ThreadSanitizer** | 760 s | **16 passed, 0 failed** |
| stress ×4 + **Address/UB Sanitizer** | 422 s | **16 passed, 0 failed** |
| leakcheck | 332 s | **pass** |

**No race, no leak, no undefined behaviour** at four times the default
contention scale, or across 13× the shipping soak length.

The soak's own numbers, after 2025 document lifecycles:

```
still resident after teardown : 0.000 MB  (render 0.000, undelivered 0.000, cache 0.000)
helper resident, peak         : 19.0 MB
helper across a long session  : -0.9 MB over the last 50 renders
median footprint, settled     : 114.5 -> 115.6 MB (last 1000 cycles)
climb once settled            : +0.0021 MB per cycle across 500 cycles
```

`still resident after teardown: 0.000 MB` is the one that settles it — every
byte Postview accounts for is given back.

The `+0.0021 MB per cycle` figure deserves a caveat rather than a headline. The
raw per-cycle footprint oscillates between **76.2 MB and 115.9 MB** across the
run — a ~40 MB swing that is allocator and cache behaviour — so a 1 MB drift
measured over 500 cycles is not distinguishable from that noise, and
extrapolating it (≈21 MB over 10,000 cycles) would be reading a trend into
scatter. The teardown figure, which is exact, says there is nothing to
extrapolate.

### 8.4 Killing the render helper — does the viewer come back?

**Third coverage gap, and the most important of the three.** `fuzz` (§8.1) asks
whether a hostile document can kill the viewer; but most of what it exercises is
*Quartz's* parser inside a process built to die safely. The other half is
Postview's own code, and nothing in the suite killed a helper — the only
mention of helper death anywhere is an aside in a comment.

That path is not small. `-createImageForPage:` has to notice the helper is gone,
classify it as **transient** rather than as a page that will never draw, kill and
reap the remains, and let `-ensureRenderHelper:` start a fresh one next call.
Misclassify it and a page briefly without a helper is retired for the rest of
the session — which is precisely the failure `PVRenderFailure` was introduced to
prevent. Misreap it and a long session collects zombies.

Probe: `Tests/pvhelperkill.m`, `make helperkill`. Three arms.

| arm | what it does | result |
|---|---|---|
| A | `SIGKILL` between renders, 30 rounds | **30/30 recovered** |
| B | a thread killing helpers *during* renders | 12 rendered, 18 failed, **0 misclassified** |
| C | kill, then release the source immediately | no hang |

**85 checks, 0 failures.** No helper outlived its source; nothing killed was left
unreaped; every failure carried a typed reason; and **not one failure was ever
blamed on the page**, which is the assertion that actually matters.

**Measured behaviour worth knowing:** in arm A, `0 of 30` renders succeeded on
the first attempt after a kill. Recovery costs **exactly one failed render**,
every time. That is by construction rather than by accident —
`-ensureRenderHelper:` tests `_helperPid > 0 && _helperIn >= 0 && _helperOut >= 0`,
and a freshly `SIGKILL`ed helper still satisfies all three: the pid is stale and
the descriptors stay open until the I/O actually fails. So death is discovered by
*failing*, not by asking.

That is a defensible design and I did **not** change it. The cost is one blank
page absorbed by the existing retry/backoff, and the deliberate recycle path
(`PV_HELPER_MAX_RENDERS`) calls `-stopRenderHelper` *between* renders and so
never pays it. A pre-flight `waitpid(WNOHANG)` would turn one failed render into
none, at one syscall per render — worth knowing about, not worth doing
unsupervised against a passing suite.

One bound worth flagging for a human, not acted on: transient failures are
capped at `PV_MAX_TRANSIENT_RETRIES` (6) per slot, and a helper that died six
times for the same page *at the same pixel size* would quiet that slot until
something resets it. Six unexplained helper deaths on one page is not a
situation this code is wrong to stop retrying in — but it is the interaction
between §8.4's "one failure per death" and that counter, and nothing documents
the two together.

### 8.5 Endurance campaign (01:03–02:01)

Volume and depth, on an otherwise idle machine.

| stage | duration | result |
|---|---|---|
| **SANITIZED** fuzz (address+undefined), `rotation` ×400 | 22 s | **986 checks, 0 failures** |
| **SANITIZED** fuzz (address+undefined), `text` ×400 | 42 s | **1997 checks, 0 failures** |
| fuzz volume, `rotation` ×2000 | 188 s | **4681 checks, 0 failures** |
| fuzz volume, `text` ×2000 | 237 s | **9745 checks, 0 failures** |
| fuzz volume, `heavy` ×800 | 172 s | **4024 checks, 0 failures** |
| `helperkill` ×400 | 173 s | **1207 checks, 0 failures** |
| `soak` ×5000 | 2651 s | **26 passed, 0 failed** |
| `statecontend` ×10 runs | 6 s | **120 checks, 0 failures** |

**≈22,760 checks, 0 failures.** And, scanned for explicitly rather than inferred
from exit status — because a sanitizer can report and still exit zero, which is
the trap `make stress` documents:

```
sanitizer diagnostics across every log in the campaign: none
```

The sanitized arm is the one that earned its time. A plain fuzz only catches
what *crashes* the process; address+undefined catches what corrupts it quietly —
an over-read in the protocol handling, an undefined shift in the geometry maths.
That is the class a malformed document actually reaches, and the class a clean
plain-fuzz run cannot speak for. `PV_HELPER_DIAGNOSTICS=1` was set so a
sanitized *helper's* findings were not written to `/dev/null`, which is the same
trap the `stress` target records having fallen into once already.

**The 5000-cycle soak settles the drift question from §8.3:**

```
still resident after teardown : 0.000 MB
helper across a long session  : +0.1 MB over the last 50 renders
median footprint, settled     : 107.4 -> 109.9 MB (last 2500 cycles)
climb once settled            : +0.0020 MB per cycle, peak 113.9 MB
```

The per-cycle figure is almost identical to the 2000-cycle run's `+0.0021`,
which looks at first like a reproducible leak. It is not, and the peak is what
proves it: **113.9 MB after 5000 cycles against 115.9 MB after 2000**. Real
accumulation over 2.5× the cycles would have raised the peak, not lowered it.
The slope is an artefact of fitting a line to a signal that oscillates ~40 MB,
and `still resident after teardown: 0.000 MB` — which is exact, not a fit — says
there is nothing accumulating to measure.

---

## 10. The §4 observation, now pinned instead of argued

§4 recorded that `PVClampPixelSize` caps the pixel *product* and can re-inflate
it past the ceiling for aspect ratios beyond ~16.7 million : 1, and that this is
unreachable because `PV_MAX_PAGE_POINTS` bounds page shape to ~20,000 : 1 and
the pixel size is a *uniform* scale of it. I did not patch the clamp, and still
have not: patching an unreachable path is what Rule 1 forbids.

What was worth fixing is that **the margin was implicit**. It depends on two
constants in two files that state no relationship, and the existing ceiling
assertion (`pvsuite.m:763`) only exercises a *square* request — the case that
works. Two assertions now pin it:

```
ok    the most extreme page shape stays inside the clamp's safe ratio
ok    the widest real page, hugely magnified, still lands under the ceiling
```

**The first attempt at this was wrong, and the correction is the point.** The
assertion I first wrote was:

```c
double worstRatio = 20000.0 / 1.0;   // PV_MAX_PAGE_POINTS : the 1 pt floor
OK(worstRatio < ceiling, ...);
```

`PV_MAX_PAGE_POINTS` is `#define`d inside `PVPDFSource.m`, not in a header, so
the test could not reference it and I hardcoded the literal. That literal stays
true whatever the real constant becomes — so the test would have gone on passing
through exactly the change it was written to catch. It pinned a number, not an
invariant. Found by re-reading my own diff, not by anything failing.

Replaced with a **behavioural** test that reads the geometry back through the
real API. A fixture of sliver pages — `25000 x 0.5`, `25000 x 1.5`,
`1000000 x 2`, deliberately straddling the 1 pt floor in both directions — is
opened, and what `-pointSizeOfPage:` actually reports is measured:

```
page 0 (612 x 792 pt)     <- 25000 x 0.5 hit the 1 pt floor, fell back to US Letter
page 1 (20000 x 1 pt)     <- 25000 x 1.5 scaled by the cap
page 2 (20000 x 1 pt)     <- 1000000 x 2 scaled, then floored
ok  the thinnest page this document can present is 20000:1,
    and the clamp needs worse than 16777216:1 to break
```

Every one of those pages is then magnified 4096x and put through
`PVClampPixelSize`, and each stays under the ceiling. The 839x margin is now
*derived from the running code* rather than from a number I typed, and the test
fails if the cap is raised, if the 1 pt floor is removed, or if a non-uniform
scaling path appears.

**No shipping code changed.** The risk was never a live bug — it was a silent
dependency between two files, and a test is the right shape of fix for that.

`make test`: **376 passed, 0 failed** (370 at baseline).

### 8.6 Campaign 2 — sanitizers pointed at Postview's own recovery code

Campaign 1 left a gap: only 800 of its ~5,600 inputs ran under a sanitizer, and
**none** of the 400 helper kills did. The helper-death path is the interesting
target precisely because it does `close()`, `kill()`, `waitpid()` and re-spawn,
with descriptors and a pid changing hands under failure — the shape a
double-close or a use-after-free hides in, and the shape that leaves no trace at
all without a sanitizer.

| stage | duration | result |
|---|---|---|
| `helperkill` ×300 + **Address/UB** | 153 s | **907 checks, 0 failures** |
| `helperkill` ×300 + **ThreadSanitizer** | 208 s | 907 checks, 0 failures — **but see below** |
| SANITIZED fuzz `rotation` ×1500 | 71 s | **3510 checks, 0 failures** |
| SANITIZED fuzz `text` ×1500 | 153 s | **7323 checks, 0 failures** |
| SANITIZED fuzz `heavy` ×500 | 165 s | **2527 checks, 0 failures** |
| `statecontend` + Address/UB, ×3 | 2 s | **36 checks, 0 failures** |

#### The one sanitizer report of the whole night — and it was mine

ThreadSanitizer flagged a data race, and the run exited 134:

```
WARNING: ThreadSanitizer: data race (pid=80597)
  Read of size 4 by thread T3:      KillerThread  pvhelperkill.m:105
  Previous write of size 4 by main: main          pvhelperkill.m:185
  Location is global 'gKillerRun'
```

`gKillerRun` is a global in **my probe**, not in Postview. I had written the
killer thread's stop flag as `volatile int`, and TSan is right: `volatile`
orders nothing between threads and is not a synchronisation primitive. Postview
appeared nowhere in the report, and it was the only report in the run.

It still had to be fixed rather than explained away. A probe that races cannot
be trusted when it reports that nothing else does — its own noise is exactly
what would mask a real finding, and the entire value of running this arm under
TSan is the sentence "the only races here are none". Rewritten with
`__atomic_load_n` / `__atomic_store_n` / `__atomic_fetch_add` at
`__ATOMIC_SEQ_CST`, then rebuilt and re-run:

```
exit=0
recovered 300/300  (0 needed no retry at all)
0 rendered, 300 failed, 300 kills delivered
pvhelperkill: 907 checks, 0 failures
ThreadSanitizer reports: 0
```

**Zero races in Postview, from a probe that no longer has one of its own.**

Arm B is worth reading carefully: under TSan every render is slow enough that
the killer thread reaches each helper first, so **all 300 renders failed**. That
is the intended reading of this arm, not a regression — every one of those 300
failures carried a typed reason, **not one was blamed on the page**, and the
document rendered normally again the moment the killing stopped. The assertion
was never "renders succeed under continuous SIGKILL"; it is "the viewer survives,
says why, and recovers", and that held 300 times out of 300.

---

## 11. Is the viewer hardened against its own helper?

**Fourth coverage gap, and the one that completes the threat model.** The
process split exists because the helper is where attacker-controlled bytes are
interpreted. That reasoning has a second half nothing tested: if the helper is
the process most likely to be subverted, then **everything it says back is
untrusted input too**, and the viewer has to treat it that way.

`PVPDFSource` does defend itself — it checks magic, version and sequence on
every reply, bounds every read with a deadline, and rejects an open reply whose
page count disagrees with the geometry it already holds. Those branches were
reachable only by accident: a corrupted pipe, a helper killed at exactly the
wrong instant. `Tests/pvbadhelper.m` + `Tests/pvhelperprotocol.m`
(`make helperprotocol`) reach them on purpose, by installing a helper that lies
where the real one should be.

| the lie | the viewer's answer |
|---|---|
| exits before the open reply | **open refused**, real user-facing error |
| open reply with wrong magic | **open refused** |
| open reply with wrong version | **open refused** |
| open reply disagreeing about the page count | **open refused** |
| half an open reply, then EOF | **open refused** |
| valid open, then never answers | **timeout**, 17.4 s — the real deadline |
| render reply with wrong magic | **protocol** |
| render reply for a command never sent | **protocol** |
| render reply with an unknown status | **transient** (retryable — correct) |
| valid open, then closes the pipe | **protocol** |
| nine well-formed replies for one command | believed once, then **protocol** |
| valid open, then random bytes | **protocol** |

**36 checks, 0 failures.** No crash, no hang, no bitmap accepted from a broken
conversation, and — the check that matters most — **not one of these was ever
reported as `PVRenderFailureInvalidPage`**. Blaming the page would retire a
perfectly good page for the rest of the session, which is the exact failure the
typed `PVRenderFailure` enum was introduced to prevent. It holds under a helper
actively trying to provoke it.

The last assertion is the one that would catch over-hardening: with an honest
helper restored, the document opens and renders normally again. Refusing to
speak to a helper that once lied is not resilience, it is a different failure.

### Two ways this test passed for the wrong reason first

Worth recording, because both would have produced a confident green result that
meant nothing.

1. **The liar was never invoked.** A source renders through the helper it
   *opened* with — `-ensureRenderHelper:` finds `_helperPid` still live — so a
   helper spawned in RENDER mode never happens for a freshly opened document.
   The first version poisoned only the render conversation and was never once
   executed in it. A trace file said so: twelve modes, twelve passes, zero
   invocations. Fixed by telling the open-reply lies in META, which is the mode
   a document actually opens with.

2. **Killing the helper was not enough either.** After a `SIGKILL`, the *next*
   render fails on the stale descriptors without spawning a replacement — the
   "recovery costs exactly one failed render" behaviour §8.4 measured. That
   failure is a *protocol* failure, which is also what a lying helper produces,
   so the test again saw the right answer for the wrong reason. Fixed by
   spending the doomed render deliberately before asking the question.

Both were caught by checking whether the liar had actually run, rather than by
trusting the pass count. A probe that cannot be shown to have executed is not
evidence.

### And one expectation of mine that was simply wrong

Mode 11 sends a **well-formed** success — right magic, right version, right
sequence, status 0 — and the viewer believes it and returns a bitmap. I had
asserted that no lying helper should ever yield one. That assertion was wrong,
not the viewer: a helper asserting "I drew the page" cannot be distinguished
from one that did, by this protocol or any other, short of the viewer
re-inspecting the pixels it delegated precisely so it would not have to. What
comes back is the viewer's own `ftruncate`-zeroed buffer, so the page draws
black. **A lie faithfully rendered is not a hole in the viewer.**

The question worth asking there is what the eight *extra* replies do to the next
render, since they are still in the pipe. Answered:

```
flood follow-up: second render after a flood: img=0x0 failure=protocol
```

The sequence check catches the stale reply, the helper is killed and restarted,
and the document is usable again. **A chatty helper cannot knock the protocol
permanently out of step.**

---

## 12. Closing confirmation

All four probes, run from a clean build through their Makefile targets:

```
make fuzz            1509 checks, 0 failures
make helperkill       187 checks, 0 failures
make helperprotocol    36 checks, 0 failures
make statecontend      12 checks, 0 failures
```

`make verify-all SDK=~/Developer/SDKs/MacOSX10.9.sdk` — **every gate passed**,
for the fourth time, with every change in place.

### Where to start reading

If you only read one thing beyond §"Read this first": **§5**, the battery
instrument. It is the only defect of the night that was costing you something
today — a release gate that could not go green on a plugged-in laptop.

If you want to decide what to keep: **§9** lists every changed file. The four
probes are additive and outside every gate, so keeping or dropping them changes
nothing about how the project builds or verifies.

If you want to check my work rather than take it: **§11**, the last two
subsections. They record a test of mine that passed twelve times without
executing the code it was testing, and an assertion of mine that was simply
wrong about what a viewer can possibly detect. Both are the kind of thing an
unsupervised run produces if nobody looks, and both are why the pass counts
elsewhere in this log are quoted alongside evidence that the code under test
actually ran.

### What I did not do, and would want a human for

* **`PVClampPixelSize` was left alone** (§4, §10). The contract gap is real and
  unreachable, protected by an ~800x margin now pinned by a test. Patching an
  unreachable path against a passing suite is churn.
* **The one-failed-render recovery cost was left alone** (§8.4). A pre-flight
  `waitpid(WNOHANG)` would make helper death cost zero failed renders instead of
  one, at one syscall per render. It is a real trade-off with a real cost on the
  hot path, and it is yours to make.
* **`PV_MAX_TRANSIENT_RETRIES` and helper death interact** (§8.4). Six helper
  deaths on one page at one pixel size quiet that slot. Not unreasonable —
  but the two behaviours are documented separately and nowhere together.
* **No commit.** Nothing is staged; the tree is as I left it.


<!-- ===================================================================== -->

# Session 2026-09-02 (second overnight pass)

Working tree clean at `738acde` when this session began. The previous session's
log is `overnight_audit_log.md` (lower case); it covered the tree through
`8ad7c01` and found no defect in shipping code. Three commits have landed since,
and they are where this session looked first.

## Baseline, taken before anything was touched

Built into an isolated `BUILD` directory so nothing here disturbs `build/`.

| Gate | Command | Result |
|---|---|---|
| Build | `make all BUILD=…` | clean, no warnings |
| Unit suite | `make test BUILD=…` | **430 passed, 0 failed** |
| Static analyser | `make analyze BUILD=…` | **OK** — no diagnostics |

---

## 1. `-drawRect:` chose nearest-neighbour for the one blit that is stretched

**Severity: visual defect, reachable by ordinary use. Fixed.**

### What was wrong

`-[PVPageView drawRect:]` decided how to resample a page bitmap like this:

```objc
CGSize want = [self pixelSizeForPage:i];
CGImageRef img = [_cache fullImageForPage:i pixelSize:want];
BOOL exact = (img != NULL);
...
CGContextSetInterpolationQuality(ctx, exact ? kCGInterpolationNone : kCGInterpolationLow);
```

`exact` is read as "the bitmap's pixels land 1:1 on device pixels, so no
resampling is needed". That inference does not hold, and the place it fails is
the place it matters.

A page is cached under the size that was **requested**. That is deliberate and
must not change: `PVClampPixelSize` scales an over-large request down before
rasterising, and a cache keyed on the clamped size could never satisfy the
lookup the request came from — so the wanted-set would name the page again on
every scroll event and the render queue would rasterise it forever. The comment
on `PVClampPixelSize` says exactly this.

The consequence is that above `PVMaxRenderPixels()` a cache **hit** hands back a
bitmap **smaller** than the destination. `exact` is `YES`, and the page is
blown up with `kCGInterpolationNone` — nearest neighbour — which is the one
filter that must not be used on a stretch. It duplicates whole columns of
pixels, so text picks up periodic stair-stepping and uneven stroke weights.

### That it is reachable, not theoretical

Measured on this machine (`Sources/PVCommon.m` tier table, RAM tier 3,
ceiling 16.777 Mpx), for a US Letter page at backing scale 2:

```
zoom 2.00x  want 2448x3168  ( 7.76 Mpx)  ->  clamped 2448x3168   1:1
zoom 3.00x  want 3672x4752  (17.45 Mpx)  ->  clamped 3600x4659   *** CLAMPED ***
zoom 4.00x  want 4896x6336  (31.02 Mpx)  ->  clamped 3600x4659   *** CLAMPED ***
```

`PV_MAX_ZOOM` is 6.0. The clamp engages from roughly 2.9x upward — the **top
half of the zoom range the app offers**, reachable with ⌘+ or a pinch. On a
smaller-RAM machine the ceiling is lower and the affected range is wider: the
suite already pins the >4 GB tier as crossing at 1.09x zoom.

The ratio makes it worse rather than better. At 3x zoom the stretch is 3672/3600
= 1.02x, and a nearest-neighbour upscale of 1.02x duplicates roughly one column
in fifty — a periodic artefact, which is the most visible kind.

### The fix

The question the draw path actually needs answered is about the **bitmap**, not
about the lookup. Added a pure predicate to `PVCommon`, following the same
idiom this codebase already uses for `PVArrowScrollForViewportHeight` and
`PVSmoothScrollEase` — split out so it can be asserted without a window:

```objc
BOOL PVBitmapIsPixelExact(CGSize have, CGSize want);
```

It compares with the same half-pixel tolerance `-fullImageForPage:pixelSize:`
matches sizes with, so the two cannot disagree about a bitmap on the boundary,
and it answers `NO` for a non-finite size — an unreadable dimension resamples
rather than getting a comb through it.

`-drawRect:` now asks it, with the image's real dimensions:

```objc
BOOL exact = img && PVBitmapIsPixelExact(
    CGSizeMake((CGFloat)CGImageGetWidth(img),
               (CGFloat)CGImageGetHeight(img)), want);
```

The cache key is untouched, so the re-render loop the clamp comment warns about
stays closed. Below the ceiling — every ordinary zoom — the answer is `YES` and
the 1:1 fast path is exactly what it was.

### Verification

The suite never drove `-drawRect:` before this session, so the defect had no way
to be observed. It does now, and the observation is direct: a hard black/white
edge blown up by a non-integer ratio comes out of nearest-neighbour as nothing
but pure black and pure white, and out of any smoothing filter with a band of
intermediate greys. Counting the greys reads which branch was taken.

Reproduced at small scale on purpose — `-drawRect:` has never heard of
`PVMaxRenderPixels()`; all it compares is the bitmap it got against the size it
wanted, so a bitmap stored two thirds of the size it is keyed under exercises
exactly the path a real clamped render takes, without a 67 MB allocation.

| | smoothed pixels | pure black/white | result |
|---|---|---|---|
| pre-fix logic (`exact = img != NULL`) | **0** | 94764 | **FAIL**, `make test` exit 2 |
| fixed | **31482** | 63282 | ok |

Run twice against the pre-fix logic to be sure the failure was not a fluke; both
runs reported `442 passed, 1 failed`. With the fix: **443 passed, 0 failed.**

Thirteen assertions were added, in three groups: the pure rule
(`PVBitmapIsPixelExact` against the clamp, the half-pixel tolerance, the
non-finite case), the arrangement through the real `PVImageCache` (a clamped
render is still found by the request it came from, *and* that hit is not 1:1),
and the observation above.

### Files

* `Sources/PVCommon.h`, `Sources/PVCommon.m` — `PVBitmapIsPixelExact` added.
* `Sources/PVPageView.m` — `-drawRect:` asks it, with the image's real size.
* `Tests/pvsuite.m` — the thirteen assertions.

---

## 2. Every zoom step past the render ceiling re-rasterised a bitmap the cache already held

**Severity: wasted CPU and energy, reachable by ordinary use. Fixed.**

Found by following the same seam as §1 rather than by a second search: once the
requested size and the produced size are known to differ, the question is who
else confuses them.

### What was wrong

The renderer's output is a function of `PVClampPixelSize(px)`, not of `px` —
`-createImageForPage:` clamps first and everything downstream draws the clamped
bitmap. The cache was keyed on `px`. So two zoom steps past the ceiling asked
for two different sizes, missed each other in the cache, and each rasterised a
page — producing the identical bitmap.

`-prepareFailureSlot:` in `PVWindowController` already gets this right, and says
so: *"These are the clamped integral sizes the renderer was actually given, not
the floating-point request."* The cache was the one place that used the other
convention.

### Measured, not argued

`Tests/…/probe2` against `heavy.pdf`, through the real `PVPDFSource` and the
real helper process:

```
pages=60  ceiling=16.777 Mpx
request A 3672x4752 -> clamped 3600x4659
request B 4896x6336 -> clamped 3600x4659
bitmap A: 3600x4659 in 14.748 s
bitmap B: 3600x4659 in 15.268 s
same dimensions : YES
same pixels     : YES
```

**15.3 s of CPU to arrive at a bitmap already in the cache**, byte for byte.
`heavy.pdf` is a deliberately expensive fixture, so the seconds are not typical
of a real page — the *identity of the result* is the finding, and it costs one
full render per visible page per zoom step, above the cliff, forever.

It is worst on the weakest machine. The ceiling is 2.80 Mpx on the ≤2 GB tier
against 16.78 Mpx here, so far more of the ordinary zoom range sits above it
there, and that is the machine least able to spare the renders.

### The fix

Both halves of the cache key on the bitmap that will actually exist. Stated once
in `PVImageCache.m` as `PVCacheKeySize`, applied by the store and both lookups,
so they cannot drift apart:

```objc
static inline CGSize PVCacheKeySize(CGSize px) { return PVClampPixelSize(px); }
```

The asymmetry matters and is why this is written as one function rather than
three call sites. Store clamped and look up unclamped and the lookup never
matches — the page is re-rendered on every scroll event forever, which is the
failure `PVClampPixelSize`'s own comment warns about. Store unclamped and look
up unclamped, as it was, and every zoom step past the ceiling re-renders. Both
halves clamping is the only arrangement consistent in both directions.

Below the ceiling it is the identity on every size this app produces: the layout
rounds page rects to whole points before multiplying by the backing scale.

`PVSameBitmap` in `PVRenderQueue.m` had the same gap at a different layer — the
in-flight dedup compared raw requests, so a zoom arriving while the first render
was still running started a second one for the same bitmap. It now compares what
the renderer will produce, closing that window too.

This does **not** make a stretched bitmap look exact: §1's `PVBitmapIsPixelExact`
asks the image its own dimensions, so a clamped bitmap serving a larger request
is still resampled. The two fixes are the same distinction applied at the two
places that needed it.

### Verification

| | result |
|---|---|
| pre-fix (`PVCacheKeySize` returning `px`) | **448 passed, 2 failed** |
| fixed | **450 passed, 0 failed** |

The two discriminating assertions are the second-zoom-step lookup and its
non-mutating twin. The other five in the group are invariants that must not
move: that the two requests really are different, that the renderer really would
produce one bitmap for both, that the page is still found by the request that
produced it, that the two share one entry rather than two, and — the one that
would catch this fix going too far — that **a size below the ceiling is still
matched exactly**, so the clamp cannot quietly collapse distinct bitmaps
together.

Aspect ratio is preserved by the clamp (both axes scale by the same `k`), so two
requests of different shape cannot collide on one key.

### Files

* `Sources/PVImageCache.h`, `Sources/PVImageCache.m` — `PVCacheKeySize`, applied
  by `-setFullImage:…`, `-fullImageForPage:…` and `-hasFullImageForPage:…`.
* `Sources/PVRenderQueue.m` — `PVSameBitmap` compares clamped sizes.
* `Tests/pvsuite.m` — seven assertions.

---

## 3. The pinch anchor slipped by one gutter in the two-page spread

**Severity: gesture imprecision, reachable by ordinary use. Fixed.**

### What was wrong

`-restoreMagnifyAnchor` holds one point of the document under one point of the
viewport across a change of zoom, and its comment states the reasoning exactly:

> the offset is not a pure multiple of the zoom: the gaps between pages are a
> constant number of points whatever the zoom is, so scaling the old offset
> drifts by one gap per page

That argument applies to the gap **across** a row exactly as it does to the gaps
down the document — and the horizontal half was not covered, because the page it
anchored on was the wrong one.

`-pageViewWillMagnify:atPoint:` took the anchor page from
`-pageRangeInRect:`, which answers with a **row**, whose `location` is the row's
**first** page. In a single column that is the page under the point. In a spread
it is the left-hand page, so a pinch centred on the right-hand page measured its
fraction from the left page's origin — putting `PV_PAGE_GAP` inside the
fraction. The fraction then scales with the zoom and the gap does not, so the
document creeps under the fingers.

### Measured

Nothing checked the anchor before this session. The suite drove the pinch and
asserted the zoom — `[5h]` checks that steps multiply, that the mode goes to
custom, that the gesture ends both ways, that limits hold — but never asked
where the document ended up. `[5h2]` now does, the way a reader would notice it:
pick a document point, note where in the viewport it sits, zoom 2x, ask where it
sits now.

| layout | drift across | drift down |
|---|---|---|
| 1 column | 0.5 pt | 0.5 pt |
| 2 columns, **before** | **12.5 pt** | 0.5 pt |
| 2 columns, after | **0.5 pt** | 0.5 pt |

`PV_PAGE_GAP` is 12.0. The drift was one gutter plus the half-point of rounding
`-scrollClipTo:` does — which is what the mechanism above predicts, and is why
the reading is quoted rather than just the pass.

### The fix

Anchor on the page the point is actually over, not the row's first page. At most
`PV_MAX_PAGE_COLUMNS` iterations, once per gesture:

```objc
NSUInteger j;
for (j = 0; j < range.length; j++) {
    NSUInteger candidate = range.location + j;
    if (NSPointInRect(pointInView, [_pageView rectForPage:candidate])) {
        _magnifyPage = candidate;
        break;
    }
}
```

A point in the gutter or the margin is on no page and keeps the row's first
page — what it had before, and the best answer available.

### Verification

`make uitest`: **259 passed, 1 failed** before the fix, **260 passed, 0 failed**
after. The failing assertion is the horizontal one in two columns; the single
column case passes in both, which is what identifies the spread as the cause
rather than the pinch machinery in general.

The test guards both axes against the document edges — a clamp at the end of the
document legitimately moves the anchor — and skips an anchor that is off screen,
so it asserts only where there was room to follow the fingers.

### Files

* `Sources/PVWindowController.m` — `-pageViewWillMagnify:atPoint:`.
* `Tests/pvsuite.m` — `[5h2]`, four assertions and two measurements.

---

## 4. Gates, with all three fixes in place

Run in an isolated `BUILD` directory. The three fixes touch the draw path, the
cache, the render queue's dedup and the pinch anchor, so the concurrency and
memory gates matter here as much as the functional ones.

| Gate | Result |
|---|---|
| `make analyze` | **OK** — no diagnostics |
| `make test` | **450 passed, 0 failed** (430 at baseline + 20 new) |
| `make uitest` | **260 passed, 0 failed** (256 at baseline + 4 new) |
| `make soak` (150 cycles) | **26 passed, 0 failed** — +0.0496 MB/cycle, peak 118.7 MB, no runaway |
| `make leakcheck` | **OK: no Postview-owned object was leaked** |
| `make stress` | 16 passed, 0 failed |
| `make stress SAN=address,undefined` | 16 passed, 0 failed |
| `make stress SAN=thread` | **16 passed, 0 failed** |

TSan is the one worth naming: `PVSameBitmap` now calls `PVClampPixelSize` while
`_lock` is held on the render lanes, and that is a new call on a path two
threads reach. It is a pure function over its arguments plus one
`dispatch_once`-memoised read of installed RAM, so it adds no shared mutable
state — and the gate agrees rather than the argument being taken on trust.

### An observation, not a defect

`Tests/pvsuite.m` compiles with four warnings, all pre-existing at `738acde` and
none of them mine: one `-Wnonnull` on a deliberate nil argument (the comment
there explains it is testing exactly that), and three from
`[[wc valueForKey:@"_scrollView"] contentView]` being typed `NSView *` and then
sent `NSClipView` messages. The app's own sources build clean.

Left alone. They are test-only, they are all in the same KVC-untyped idiom the
UI suite uses throughout, and silencing them means adding casts that assert a
type the test is deliberately not declaring. Worth knowing they are there, so a
genuinely new warning is not lost among them.

---

## 5. `verify-all`, against the real 10.9 SDK

```
make verify-all BUILD=… SDK=~/Developer/SDKs/MacOSX10.9.sdk
```

| Gate | Result |
|---|---|
| Mach-O verification | OK |
| static analyser | OK |
| unit tests | 447 passed, 0 failed |
| UI tests | 260 passed, 0 failed |
| soak | 26 passed, 0 failed |
| stress | 16 passed, 0 failed |
| stress + address,undefined | 16 passed, 0 failed |
| stress + thread | 16 passed, 0 failed |
| leaks | no Postview-owned object leaked |
| energy and CPU | 23 passed, 0 failed |
| showdown self-test | passed |

**`verify-all: every gate passed`**, exit 0.

### The unit count is 447 here and 450 under the default SDK — deliberately

Not a regression, and worth writing down because the two numbers will be
compared again. `TestDispatchConstants` pins `PV_BLOCK_ENFORCE_QOS_CLASS` and
`PV_QOS_CLASS_UTILITY` against the real enumerators, and guards that on
`PV_TEST_HAS_QOS_SDK`. The 10.9 SDK has no `<sys/qos.h>`, so three assertions
become one `skip` line. 450 − 3 = 447, and the pre-existing baseline works out
the same way: 430 − 3 = 427, which is the number `738acde`'s message quotes.

### Idle cost, measured with all three fixes in place

```
CPU   viewer  0.004 s   helpers  0.000 s   total 0.004 s (0.1% of one core)
wake  idle 0   timer 0   interrupt 2   helper idle 0
ok    an idle document costs 0.12% of one core (limit 5%)
ok    an idle document wakes the package 0.0 times a second (limit 60)
```

Zero idle wakeups, zero timer wakeups, in the viewer and in the helper. Worth
confirming rather than assuming here: §1's fix runs inside `-drawRect:` and §2's
inside the cache lookup, both on paths a scroll touches many times a second, and
neither adds a timer, a poll or a retained object. The audit's first question —
does an untouched document cost nothing — still answers the same way.

---

## 6. Final architectural assessment

### What was found

Three defects, all reachable by ordinary use, all fixed, each with a test that
fails without the fix:

| § | Defect | Cost | Discriminating evidence |
|---|---|---|---|
| 1 | `-drawRect:` chose nearest-neighbour for stretched blits | every page soft *and* combed above ~2.9x zoom | 0 vs 31482 smoothed pixels |
| 2 | Cache keyed on the request, renderer keyed on the clamp | one redundant full render per page per zoom step | 15.3 s of CPU for a byte-identical bitmap |
| 3 | Pinch anchored on the row's first page | 12.5 pt of drift per 2x pinch in the spread | 12.5 pt → 0.5 pt |

**All three are the same mistake.** Each is a place where the size a bitmap was
*asked for* was used where the size it *is* was meant. That is not a coincidence
and it is the most useful thing in this report: `PVClampPixelSize` introduces two
different numbers for one bitmap, and every consumer has to pick the right one.

Two consumers already picked correctly and said so —
`-[PVWindowController prepareFailureSlot:…]` (*"These are the clamped integral
sizes the renderer was actually given, not the floating-point request"*) and
`-[PVRenderQueue predictedSecondsForPixels:preview:]`. Three did not. The seam
is now consistent at all five:

| consumer | identifies a bitmap by | status |
|---|---|---|
| cost model prediction | clamped | was already right |
| failure/retry slots | clamped | was already right |
| cache key | clamped | **fixed, §2** |
| in-flight dedup | clamped | **fixed, §2** |
| draw interpolation | the image's own dimensions | **fixed, §1** |

`PVPageView`'s row/page distinction is the same shape of hazard one layer up, and
§3 was its one remaining unconverted caller.

### What the codebase does well, stated so it is not lost

The architecture is genuinely sound, and the reasons are specific:

* **Nothing polls.** Three timers exist; all are one-shot or bounded, all are
  cancelled on teardown, and the retain each one takes is documented at the
  ivar. The energy gate measures zero idle wakeups rather than asserting them.
* **The process boundary is in the right place.** Every `CGPDF*` call is in the
  helper; the viewer holds a read-only mapping and two pipes. Every field of
  every message is validated on arrival, including the overflow guards and an
  `fstat` size check before `mmap` — the failure that would otherwise be a
  `SIGBUS` inside Quartz on a row that happens to cross a page boundary.
* **Failure is classified, not collapsed.** `PVRenderFailure` separates "Quartz
  will never draw this" from "this machine was busy for an instant", and the
  retry policy turns on the difference. That distinction is why a page starved
  of shared memory comes back instead of staying blank for the session.
* **Ownership is stated where it is taken.** The `handed` flag in
  `-createImageForPage:`, the `counted`/`reservedFull` pair carried into the
  delivery block, `-subtractBytes:` routing every decrement through one place so
  an unbalanced one cannot wrap `_bytes` — these are the shapes that make the
  leak gate able to pass rather than merely happen to.
* **Every allocation is null-checked**, and the failure paths leave the previous
  state whole rather than tearing it down in favour of nothing — the row table's
  build-then-swap being the clearest example.

### What I would want a human for

* ~~`e->prevPx` is written and never read.~~ **Settled — see §7.**
* **Four pre-existing warnings in `Tests/pvsuite.m`** (§4). Test-only, all in the
  KVC-untyped idiom the UI suite uses throughout. Silencing them means asserting
  types the tests deliberately leave open.
* **The clamp cliff itself is still a silent quality change.** §1 makes the soft
  page smooth instead of combed, which is strictly better, but past
  `PVMaxRenderPixels()` the page is still softer than the zoom asks for and
  nothing tells the reader. The suite pins this as a known limit and
  `ENGINEERING.md` §6 explains why raising the ceiling costs RSS. Unchanged: it
  is a product decision, not a defect.

### Verdict

The tree at `738acde` was in good order, and the three defects here were found
by following one seam rather than by broad suspicion — which is itself a
statement about the codebase's health: the weakest link was a distinction the
code had already identified and documented in two places out of five.

With the fixes in place: **eleven gates, every one green, against the release
SDK.** No further logical, memory, or efficiency issue was reachable by this
session's methods — static analysis, all three sanitizers, a 150-cycle soak, a
leak census, the energy gate, and a targeted read of every file with the seam
above in hand.

**Nothing is committed.** The working tree is left for review.


---

## 7. `e->prevPx`, settled

Raised in §6 as the one open question and resolved here rather than left.

`PVCacheEntry` stored a preview's pixel size. Nothing read it: `prevBytes` and
`prevH` are both load-bearing, `prevPx` was the only write-only field in the
cache. The hazard was never a wrong value — it was that a stored size *looks
like* a size check that already exists, and `-hasPreviewForPage:` deliberately
matches on the page alone. Someone adding a size-aware preview lookup on the
strength of that field would have landed exactly on §2's defect.

Three options: read it (clamped), leave it, or delete it.

**Deleted.** Reading it means inventing a size-aware preview lookup, and that
would be a mistake in its own right — previews are placeholders, any preview
beats none, and matching them by size would re-render one on every zoom step,
which is precisely what §2 just stopped happening to full bitmaps. Leaving it
keeps the trap. Deleting it is the only option that makes the struct state a
fact.

The comment that replaces it carries the knowledge the field was standing in
for, so the next person reaches the reasoning rather than the trap:

```objc
// No prevPx beside prevBytes, and its absence is the point. A preview is
// matched by page alone -- see -hasPreviewForPage: -- so a size stored here
// would be a field nothing reads that looks exactly like a size check that
// already exists. The one this file does perform is on the full bitmap, and
// it goes through PVCacheKeySize.
CGImageRef prev;  size_t prevBytes;
```

No behavioural change, and the counts confirm it: 447 unit and 260 UI, identical
to §5. `verify-all` re-run in full on the final tree — every gate passed.

### The energy gate reads 22 or 23 depending on the battery, not the code

Worth writing down beside the SDK note in §5, because it is the second count in
this log that moves for a reason that is not a regression, and both will be
compared again.

`RunPower`'s battery-draw assertion is conditional on the charge state. With
current flowing in or out of the cell it asserts a plausible instantaneous draw;
fully charged and on mains it prints instead, because 0.00 W is then the true
reading and there is no draw to check:

```
power source  : ac, internal battery present
battery       : 100 mAh, drawing 0.00 W right now (on mains)
                charged and on mains: no current in or out of
                the cell, so 0.00 W is the true reading...
```

`pmset -g batt` confirms it: *100%; charged*. So 23 during the first
`verify-all`, 22 once the machine finished charging, and 22 twice more on
demand. Nothing here is code-dependent — and the fact that it *skips* rather
than fails is the previous session's §5 fix working as intended.
