# Postview — engineering record

Why the scheduler, the caches and the budgets are the way they are, what has
actually been measured, and what has not. Source comments cite this file by
section.

Every figure below is labelled. **Measured** means an instrument produced it and
the command that does so is named. **Derived** is arithmetic on measured values.
**Unverified** has not been measured on the machine that matters and must not be
built on without being.

---

## 1. What the program optimises for

A PDF viewer's cost is dominated by one thing: rasterising pages. Everything
here follows from trying not to do that, and from doing it cheaply when it must
happen.

The four levers, in the order they pay:

1. **Not rendering at all** — the motion gate and the dwell test. This is where
   the CPU win came from and it is worth more than the other three together.
2. **Rendering fewer pixels** — previews at 1/3 linear (1/9 the pixels).
3. **Rendering out of the UI's way** — one serial queue at background priority.
4. **Keeping what was expensive to make** — cost-aware eviction. Costs nothing.

There is no user-visible performance mode, and §5.4 is the argument for why not.

---

## 2. The measurement everything else rests on

`make band` (`Tests/pvband.m`), 2026-08-30. Two documents, identical page
geometry, identical bitmap, identical code path, back to back.

| fixture | content | page bitmap | x86_64 (shipping) | arm64 (cross-check) |
|---|---|---|---|---|
| `heavy.pdf` | ~1400 bezier curves/page | 2344 × 3033 = 7.11 Mpx | **657.3 ms** | 490.3 ms |
| `text.pdf` | dense 9 pt body text | 2344 × 3033 = 7.11 Mpx | **11.2 ms** | 11.7 ms |

**Measured. A factor of 59 at constant pixel count.**

The cost of a page is a property of the *document*, not of its size, the display
scale, or the machine — and it varies across documents by far more than across
any hardware in play. Native ARM on a much newer machine renders the text page
*no faster* (0.96×), because that page is bound by content-stream interpretation
inside CoreGraphics, which is native either way. **For text documents, faster
hardware is not an available lever.**

Two mechanisms inside `CGContextDrawPDFPage`, pulling opposite ways:

- **Destination traffic** — a 27 MB bitmap does not fit any last-level cache, so
  the rasteriser streams it to DRAM. Proportional to how much of the destination
  is touched, which is what vector content does.
- **Content-stream interpretation** — proportional to operator count, which is
  what text has, and paid in full however few pixels are drawn.

Band ratios, same run, K bands exactly tiling one page (total pixels identical
by construction, so any change with K is not pixel work):

| K | `heavy.pdf` | `text.pdf` |
|---|---|---|
| 2 (one viewport) | **0.781×** | **1.024×** |
| 4 | 0.686× | 1.177× |
| 8 | 0.699× | 1.67× |

Vector content gets *cheaper* when banded; text gets dearer. Both architectures
agree to within 0.03.

**What transfers and what does not.** The ratios transfer. The absolute
milliseconds do not: no column above is the Mac Pro, whose Xeon E5 v2 is slower
per core than Rosetta-translated code on Apple silicon, so 657 ms is a lower
bound there. *Unverified* — run `make band` on the Mavericks machine; it takes
two minutes.

---

## 3. The cost model

Every gate in the scheduler is trying to ask "will this bitmap finish before its
page leaves the screen?" Before `PVCostModel`, every one asked a proxy — is this
under N megapixels, will the page be visible for a quarter of a second — and §2
shows the proxy wrong by up to 59×. One constant admits a 657 ms render into a
250 ms window and suppresses an 11 ms render that would have fit twenty-two
times over.

`Sources/PVCostModel.{h,m}` keeps an EWMA of **milliseconds per megapixel, per
open document**, fed from the render queue's own timing of
`-createImageForPage:pixelSize:`.

Two earlier attempts at this failed, and the file avoids both by construction:

- **The feedback loop.** Suppressing renders starved the estimate, and the stale
  estimate decided whether to keep suppressing. It cannot happen here because
  the samples come from renders no gate is allowed to withhold: the settle pass
  is unconditional, and `PV_SPEED_FRESH_SECONDS` expires suppression on its own
  even if every timer were lost. Belt and braces: no prediction is offered at
  all below `PV_COST_MIN_SAMPLES`, and the gate is then exactly the old constant.
- **Mixed populations.** A preview is 1/9 the pixels but re-walks the whole
  content stream, so its rate is nothing like a full page's — mixing them moved
  the crossover by a factor of six. Two independent estimates are kept and a
  prediction is only ever made from the matching one.

The absence of a prediction is *exactly* the old policy, not merely similar to
it: `PVShouldRenderWhileMoving` is implemented as the cost-aware function with
no cost, and `pvtest` re-asserts the equivalence across a 180-case sweep.

The model may **raise** the dwell bar and never lower it.
`PV_MIN_VISIBLE_SECONDS` is a claim about eyes — a quarter-second is where a
glimpse becomes a look — and the cost model has no standing to overrule it.

---

## 4. Machine and power: one policy, no modes

`PVRenderPolicyFor(power, tier, pressureReports)` is a pure function returning
every knob that would otherwise have been a mode switch. `pvtest` walks all 36
combinations.

### 4.1 RAM tiers

| tier | RAM | eviction budget | render ceiling | zoom cliff | capacity |
|---|---|---|---|---|---|
| Small | ≤ 2 GB | 32 MB | 2.80 Mpx | — | 3 pages |
| Medium | ≤ 4 GB | 64 MB | 5.59 Mpx | — | 3 pages |
| Large | ≤ 8 GB | 96 MB | 8.39 Mpx | 1.09× | 3 pages |
| Huge | > 8 GB | 256 MB | 16.78 Mpx | 1.54× | 4 pages |

The first three are unchanged from the original derivation `ceiling = budget/3/4`
and are pinned to the byte by `pvtest`, so every Mac with 8 GB or less gets
exactly the budgets it always had.

**The zoom cliff** is where `PVClampPixelSize` begins silently downscaling and
`-drawRect:` stretches the result back up. A US Letter page fit to width on a 2×
display is 7.11 Mpx, so the Large ceiling is crossed at 1.09× zoom — sharpness
degrades from 9% magnification onwards with no diagnostic. The Huge tier doubles
the ceiling, which is √2 on the zoom axis, moving the cliff to 1.54×.

The budget rises as the *cost* of that, not as a benefit: the anti-thrash
inequality is stated in terms of the ceiling. It is a ceiling on occupancy, not
a reservation — at fit-width a page is 7.11 Mpx whatever the ceiling says, the
cache holds the same three, and peak RSS is unchanged. 256 MB is reached only by
a machine both plugged in and zoomed to the ceiling.

### 4.2 Power source

Read through `dlopen` of IOKit rather than by linking it: `make verify`
allow-lists every dylib the shipping binary may carry, and each is a path that
must exist on a 10.9 machine. A lookup failure reports `PVPowerUnknown`, which
behaves exactly as battery.

| | battery / unknown | AC |
|---|---|---|
| full prefetch | `PV_FULL_PREFETCH_PAGES` (1) | 2, clamped to what the tier's cache holds |
| dwell safety factor | 1.50 | 1.25 |
| full renders while moving | no — the blanket motion gate | per-page cost question |

**Battery is byte-for-byte today's behaviour**, asserted per tier by `pvtest`.
Unknown is battery, never AC — asserted, so a later refactor cannot fold them
together on the grounds that most Macs are plugged in.

Memory pressure outranks power in both directions and is applied last, so it can
undo the AC branch: a machine that is swapping is not made better by being
plugged in.

**`Tools/showdown.sh` pins `-PVPowerState battery`.** The arbiter machine is a
Mac Pro, which has no battery and always reports AC, so without the pin every
recorded trial would measure the mains policy while looking comparable against
the battery numbers already on record. `POWERSTATE=ac` measures the other branch
deliberately and says so in the header.

### 4.3 Cost-aware eviction

`-evictExcept:` orders by GreedyDual-Size — `H = L + cost/bytes`, evict minimum,
raise `L` to what was evicted — instead of by an LRU clock.

Two cached bitmaps of the same size are not interchangeable: rebuilding a
`heavy.pdf` page costs 657 ms and a `text.pdf` page 11.2 ms, and both occupy
27.1 MB. An LRU clock is as likely to discard either — a 59:1 difference in the
value of what is thrown away, invisible to the policy throwing it. Keeping the
expensive one is better on every axis at once: identical bytes, less CPU, less
energy, no budget change. **The only free item on this list.**

With no cost information anywhere the ordering degrades exactly to the stamp LRU
it replaced, which is asserted.

### 4.4 Why there is no "High Performance" mode

A mode control makes sense where there is a continuum to expose. There is not.
Cache hit rate saturates at three or four full pages, because reuse distance in
a document reader is bimodal: a page is either revisited almost immediately or
effectively never, and the middle band a large cache exists to serve does not
exist. So a "High Performance" mode that raises the cache buys nothing
measurable, and a "Lower Memory" mode steps off the knee and pays in re-renders
— costing CPU *and* battery, the opposite of what someone selecting it expects.
A control whose every position is worse than the default moves blame rather than
adding a feature.

What genuinely varies is machine and document state, and the program reads all
of it more reliably than a user can state it: RAM tier, memory pressure, power
source, and measured document cost.

**The one switch worth having is a quality switch**, because sharpness against
memory on a photograph is a preference no measurement resolves. Not built.

---

## 5. Settled — do not relitigate

- **Zero suppression on a slow read is correct.** A gap of half a second ends a
  scroll and returns the speed to zero, so every page renders. A reader sitting
  on a page wants it sharp.
- **The cache was never uncapped.** A byte-budgeted LRU with pinning throughout.
  The 334 MB peak came from prefetch depth and undelivered bitmaps.
- **Background QoS is right on the target, but not for the reason once written
  in the comment.** A 2013 Mac Pro's Xeon E5 v2 cores are homogeneous — there
  are no efficiency cores, and a render is not one joule cheaper for being
  backgrounded. What it buys is lower scheduling priority, timer coalescing and
  throttled I/O. The energy win on the target comes from doing less work.
- **The express lane's QoS promotion never runs on 10.9.**
  `dispatch_block_create_with_qos_class` and `QOS_CLASS_UTILITY` are 10.10+, so
  the `dlsym` returns NULL and an express request gets ordering priority only.
  Both the ~8× energy cost and the latency benefit are absent on Mavericks.
- **Rasterisation cannot be cancelled.** One CoreGraphics call, no resume. The
  available half is never starting it, and dropping a result for a page the
  viewport has left.

---

## 6. Verification

`make verify-all` runs every gate. Current state, this host:

| gate | result |
|---|---|
| Clang static analyser | clean |
| `pvtest` (unit) | 307 passed, 0 failed |
| `pvuitest` (drives a real controller) | 134 passed, 0 failed |
| `pvsoak` (175 document cycles) | 20 passed, 0 failed |
| `pvstress` | 14 passed, 0 failed |
| `pvstress` + AddressSanitizer + UBSan | 14 passed, 0 failed |
| `pvstress` + ThreadSanitizer | 14 passed, 0 failed, no data races |
| leak census | no Postview-owned object leaked |
| showdown self-test | 22 instrument checks passed |
| `make verify` (Mach-O 10.9 compatibility) | OK |

Soak footprint, 175 cycles, measured on this host on 2026-08-30 — the same
command run against the previous commit and against the current tree:

| | settled median | peak | climb per cycle |
|---|---|---|---|
| previous commit | 179.3 MB | 210.2 MB | +0.084 MB |
| current | **169.4 MB** | **198.8 MB** | **+0.002 MB** |

Better on all three. Note that the 65.8 MB settled figure quoted in earlier
documents does not reproduce on this host and should not be cited.

`pvuitest` pins the power source to battery for the whole suite, because
otherwise its verdict would depend on whether the machine was plugged in when it
ran. `[5g6]` turns the AC branch on explicitly and asserts what it changes.

### Tests written to fail against the old behaviour

Checked by reverting the change and re-running:

- budget assertions fail if `PV_FULL_PREFETCH_PAGES` returns to 3;
- the cache count cap fails if the cap is removed;
- `[5g2]` fails against the original full-render gate;
- the in-flight cap test records 6 undelivered bitmaps / 14.50 MB instead of
  2 / 4.83 MB if `PV_MAX_INFLIGHT_FULL` stops being enforced;
- `[5g3]` fails on three of eight assertions against the old symmetric delivery
  keep-window;
- the cost-model equivalence sweep fails if the no-prediction path stops
  reducing to `PVShouldRenderWhileMoving`;
- the eviction tests fail if GreedyDual ordering is replaced by the stamp.

---

## 7. Still open

- **The showdown has not been run on the Mavericks machine since any of this.**
  Every comparative CPU, energy and peak-RSS claim against Preview is stale. Run
  `./Postview-Showdown.command <document.pdf>` there. This is the single most
  valuable outstanding item.
- **`make band` has never run on the Mac Pro.** Two minutes, and it converts
  every absolute millisecond in §2 from proxy to fact. Do it in the same session.
- **Banding (stage 2) is not built.** §2 shows it pays on vector content (0.39 of
  a page render per band) and costs on text (1.024× at K=2, worse with K), and
  the `read` workload is text. It is now gateable on measured cost, which is the
  precondition that was missing — but it changes the cache key, the wanted-set
  builder, delivery pruning and `-drawRect:`, and building that on an unmeasured
  baseline would make the result unattributable. Concurrency should land with it:
  bands are independent, and the Mac Pro has 8–24 hardware threads idle during
  every render.
- **Rendering is single-threaded by construction.** `_queue` is
  `DISPATCH_QUEUE_SERIAL` and `CGContextDrawPDFPage` interprets a sequential
  program with no internal parallelism. During the delay a user notices, one
  core is working. This is the largest remaining Mac Pro win and it is the same
  change as banding.
- **A middle preview rung** at 1/2 linear (1/4 pixels) would land far sooner than
  a full render. *Unverified* — `pvband` varies band count, not scale.
- **A speed-dependent preview divisor.** At 3000 pt/s nothing at 1/3 linear is
  resolvable; 1/6 linear is 1/36 the pixels. Risk is a visible transition when
  the scroll stops, which this host cannot judge.
- **The keyboard's unannounced first event** costs one wanted-set rebuild per
  scroll episode. Closing it means treating `[event isARepeat]` as the
  keyboard's announcement, which moves CPU and belongs after a showdown run.
- **Zoom past the tier's cliff renders soft.** Pinned by `pvtest`, not fixed.

---

## 8. Constraints

- **Target is OS X 10.9**, built with a current toolchain,
  `-mmacosx-version-min=10.9`, `-Werror=unguarded-availability`. Anything newer
  is a hard compile error unless resolved dynamically — see
  `PVBlockCreateWithQoS()` and `PVPowerSymbols()` for the pattern.
- **Manual retain/release** (`-fno-objc-arc`). Every `CGImageRef` is +1 and
  hand-balanced.
- **`-arch x86_64 -march=core2`** — Mavericks runs on Macs as old as 2007, some
  of which predate SSE4.1. Sanitizer builds override the arch; the shipping
  binary does not.
- **`make verify` allow-lists every linked dylib.** Adding a framework to that
  list means asserting the path exists on 10.9.
- **This development host cannot verify the UI.** The 10.9 binary runs under
  Rosetta here but never shows windows. Verify by the headless harnesses.
- **The Mavericks test machine has SIMBL**, so every process there has
  third-party code injected. Read crash reports accordingly.
- **`Postview-Showdown.command` is the arbiter**, and it must run on the
  Mavericks machine, not here.
