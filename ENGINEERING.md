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
| `pvtest` (unit) | 319 passed, 0 failed |
| `pvuitest` (drives a real controller) | 140 passed, 0 failed |
| `pvsoak` (175 document cycles) | 20 passed, 0 failed |
| `pvstress` | 14 passed, 0 failed |
| `pvstress` + AddressSanitizer + UBSan | 14 passed, 0 failed |
| `pvstress` + ThreadSanitizer | 14 passed, 0 failed, no data races |
| leak census | no Postview-owned object leaked |
| showdown self-test | 26 instrument checks passed |
| `make verify` (Mach-O 10.9 compatibility) | OK |

**The AddressSanitizer row above was false until 2026-08-31, and `verify-all`
was reporting it as passing.** §9.6. The row is true now, and the harness can no
longer make that particular mistake.

Two gates were also flaky rather than wrong, in the same way and for the same
reason — an asynchronous teardown asserted against a fixed wall-clock budget.
`pvstress`'s deadlines are now scaled for sanitized builds (§9.6), and
`pvuitest` `[8]` waits for the cache and the PDF source instead of sampling them
once the page view has gone. That one lost about one run in three on this host,
and it is the reason the whole class matters: **a flaky gate is worse than a
missing one, because it teaches you to re-run until green** — which is precisely
how the AddressSanitizer failure survived.

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

- ~~**The showdown has not been run on the Mavericks machine.**~~ Run
  2026-08-31; it returned no verdict on two fairness checks, both since fixed.
  **Run it again** — this is still the most valuable outstanding item, because
  no run has yet been allowed to name a winner. See §9.2 and §9.5.
- ~~**`make band` has never run on the Mac Pro.**~~ Run 2026-08-31. §9.3.
- **Banding (stage 2) is not built, and §9.3 is now the argument against
  building it.** Measured on the target: one band at K=2 costs 0.680 of a whole
  page render, so the `read` workload would cost +1.99 s against a surplus over
  Preview of 1.73 s. It pays on vector content and costs on text, §2 said so,
  and the `read` workload is text. Do not build it as a cost reduction. It
  remains arguable as a *latency* change bought with 36% more CPU, which is a
  different case and needs a different measurement.
- **Rendering is single-threaded by construction.** `_queue` is
  `DISPATCH_QUEUE_SERIAL` and `CGContextDrawPDFPage` interprets a sequential
  program with no internal parallelism. During the delay a user notices, one
  core is working. Still the largest untaken Mac Pro win, and still the same
  change as banding — but §9.3 removes the CPU justification that made the pair
  look like one obvious win, so the latency case now has to stand on its own.
- **Peak memory is the only metric Postview loses on everywhere** — all seven
  scenarios, 22–43%. Until §9.4 it was being reasoned about with a column that
  was the difference of two independently-timed maxima. The instrument is fixed;
  the question is untouched.
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

---

## 9. The Mavericks run, 2026-08-31

The first time any of this executed on a 2013 Mac. Raw files are in
`Tests/Mavericks Testing/`. Machine: the Mac Pro, 64 GB, mains power, SIMBL
present as always.

Four things were settled and three instruments were found to be wrong. The
instrument faults matter as much as the results, because two of them had been
reporting confidently for weeks.

### 9.1 The power lookup works on 10.9

`power.source ac`, from the Step 1 session. This was §7's most-likely-broken
item — the one call that could not be tested on a modern OS — and the value
proves the lookup succeeded rather than merely defaulted, because a failed
`dlsym` reports `unknown` and not `ac` (§4.2). The Mac Pro has no battery and
always draws from mains, so `ac` is also the right answer.

**Measured. Closed.** The AC branch of `PVRenderPolicyFor` is live code on the
target, not a code path that has only ever run in a test.

### 9.2 The showdown returned no verdict, and was right to

Seven scenarios, five runs each, and two fairness checks failed. One was the
app and one was the instrument.

**`scroll` — the app.** 200 arrow presses moved Preview 13 pages and Postview
6. Working back through the geometry — the document's page is 3695 px tall at
a backing scale of 2, so 1847.5 pt, and 1859.5 pt with `PV_PAGE_GAP` — Preview
scrolls about 121 pt per press and Postview scrolled a flat 60. **A reader
holding Down in Postview covered half the ground per press**, which is a real
defect in its own right and not merely a staging problem. The 60 was not
derived from anything; `Page Down` and `Space` were already a viewport less a
40 pt overlap, and the arrow key was the one scroll unit in the program with no
argument behind it.

Now `PVArrowScrollForViewportHeight`: one eighth of the viewport, bounded to
[40, 160] pt, so eight presses cover a screenful and the step keeps its meaning
at any zoom and window size. At the showdown's 800 pt window that is 96 pt.
*Derived* — 200 presses then travel 10.3 pages against Preview's 13, a ratio of
1.26 where the gate trips at 2.

**Expect the `scroll` CPU margin to shrink, and take that as the fix working.**
The recorded +63% was partly bought by travelling half as far. Per page
travelled the recorded run is Postview 0.54 s against Preview 0.67 s, so a
*projected* honest margin is nearer +20%. That number is arithmetic on a run
made under the old behaviour and is not a measurement; the next run replaces it.

**`wheel` — the instrument.** Postview travelled 0 pages, Preview 1, and the
ratio test read that as an infinite disparity. It is not one. Both apps scroll
the AppKit default of 10 pt per line — Postview because it deliberately does
not override `-scrollWheel:`, which is the precondition for responsive
scrolling — so 60 events of 3 lines is 1800 pt in Postview against a page pitch
of 1859.5. **The two apps were 3% apart and landed on opposite sides of a page
boundary.**

The travel instrument reads a page number out of a window title, so its
resolution is one page and nothing finer, and two apps that travel the *same*
distance still report a page apart whenever that distance straddles a boundary.
A one-page gap is therefore exactly what equal travel looks like, and no ratio
computed from it is evidence. The gate now says so and does not count it; a gap
of two pages or more cannot be manufactured that way and is still the app.

Verified against the recorded TSV: the two failures become one, and `scroll`
— the real one — still fails, which is the property that matters.

### 9.3 Banded rendering does not pay on this document

`pvband`, 528-page Russian-language text document, 8.66 Mpx per page:

| K | ms/render | page-equivalents |
|---|---|---|
| 1 | 156.7 | 1.000 |
| 2 | 106.5 | **1.359** |
| 4 | 81.4 | 2.079 |
| 8 | 69.6 | 3.552 |

One band at K=2 costs 0.680 of a whole-page render against the 0.500 it would
cost if band cost were proportional to pixels. The marginal cost of each extra
split is a steady +0.35 page-equivalents, i.e. the per-render fixed cost is real
and roughly constant. Ink agrees to 0.0005 across every K, so the bands are
drawing the document and not a fraction of it.

Applied to the `read` workload: today's 7 page renders become 17 renders and
16% more pixels, costing 11.04 page-equivalents against 8.12 today — **+1.99 s
against a recorded surplus over Preview of 1.73 s.** On the run actually
recorded here the surplus is smaller still (`read` was 3.48 s against Preview's
3.96 s, not the 5.18 s the probe's model assumed), so banding looks worse rather
than better once the current numbers are used.

**This retires §7's largest planned item for text documents.** §2 predicted it:
banding pays on vector content (0.686× at K=4) and costs on text (1.177×), and
the `read` workload is text. The measurement now exists on the machine that
decides, and it agrees. Concurrency across bands is a separate argument and is
still open — the Mac Pro's idle cores are still idle — but it can no longer be
justified as a *cost* reduction on documents like this one, only as a latency
one, and it would be paying 36% more CPU to get it.

### 9.4 Three instruments were reporting numbers that were not what they said

Each of these had been in the report for weeks, and each was confidently wrong.

**The cost rate mixed the two populations the model exists to keep apart.**
`cost.ms.per.mpx` divided total render seconds by total megapixels across both
full renders and previews. `PVCostModel.h` calls mixing them "the real defect"
and keeps two independent estimates for exactly this reason; the census then
averaged them back together on the way out. The recorded 432.55 ms/Mpx came
from 96 samples of which **72 were previews**, so the headline figure — the one
`INSTRUCTIONS.md` told the tester to check — largely described previews and was
read as the cost of a page. Now reported as `cost.ms.per.mpx.full` and
`cost.ms.per.mpx.preview`, each dividing its own population's seconds by its own
population's pixels.

That run's figure cannot be recovered by arithmetic and **should not be quoted**.
Nor is it comparable with §9.3's 18.1 ms/Mpx: the Step 1 session averaged
2.03 Mpx per full render against the probe's 8.66, so it was a different window
or a different document, and neither was recorded. `INSTRUCTIONS.md` now asks
for both.

**The "non-bitmap" column was the difference of two clocks.** It was computed as
`max(peak RSS) − max(resident bitmaps)`, two high-water marks taken by different
samplers at different moments. `max(A+B) − max(B)` equals `max(A)` only when the
two maxima coincide and collapses towards zero when they do not, so the column
measured how well two clocks happened to line up. The recorded run shows it:
68.8 MB on `idle` to 177.6 MB on `read`, a 109 MB swing, printed underneath a
note saying the quantity should be roughly constant across scenarios.

The app now samples its own RSS at the instant the bitmap census sets a new
high-water mark and reports it as `resident.peak.rss.mb`, so the pair is
simultaneous by construction. Rows from older TSVs still render, marked `?`,
with the difference stated rather than presented as the same quantity.

**Nothing here says whether peak memory is actually a problem.** It says the
column that was being used to reason about it did not mean what it claimed.
That question is still open and is now measurable.

**A saved verdict did not record which power branch it measured.** §4.2 makes
battery and AC two different scheduling policies, and the `.txt` recorded none
of the run's conditions — the power pin, the document, the window size — because
they were printed to a terminal that had scrolled away by the time anyone read
the file. The battery pin on the 2026-08-31 run had to be inferred from the
script's default. Now written into the verdict itself.

### 9.5 What the next run has to settle

- **Re-run the showdown.** Both fairness checks should now pass and a verdict
  should print for the first time. `scroll`'s CPU margin should fall; if it
  does not fall at all, the arrow change did not reach the binary being measured.
- **Peak memory**, with a `non-bitmap` column that is now a real quantity. This
  is the only metric Postview loses on in all seven scenarios, by 22–43%.
- **`cost.ms.per.mpx.full`**, alongside the window size and document, so it can
  finally be compared with `pvband`'s 18.1 ms/Mpx on the same page.
- **The AC branch**, via `POWERSTATE=ac`. §9.1 makes it live code on this
  machine and it has never been measured there.

### 9.6 `verify-all` was reporting success over a gate that failed

Found while re-running the gates for the changes in §9.2 and §9.4, and the worst
thing in this section, because everything else here rests on the harness.

Each gate was run as

```
@echo "== unit tests ==" && $(MAKE) --no-print-directory test | tail -1
```

and a shell pipeline exits with the status of its **last** command. `tail`
always succeeds, so make never saw a failing sub-make. The evidence was on
screen the whole time:

```
== stress + address,undefined ==
make[1]: *** [stress] Error 1
12 passed, 2 failed
== stress + thread ==
...
verify-all: every gate passed
```

The failure printed, four more gates ran, and the run concluded that every gate
passed. §6 has been carrying `pvstress + AddressSanitizer + UBSan | 14 passed,
0 failed` on the strength of that.

Each gate now runs through a `gate` function that captures the log, echoes the
summary line, and on a non-zero status prints the last 40 lines and stops. Not
`bash -c 'set -o pipefail'`: macOS ships GNU Make 3.81, which has no
`.SHELLFLAGS`, and keeping the whole log of a failing gate is worth more than
its last line anyway.

**What was actually failing was the harness, not the app.** The two failing
assertions were the 60-round teardown unwinds — `abandoned queues all
deallocated` (18 objects still live) and `both render queues deallocated` (10) —
and both are `SettlesToZero` waiting a fixed number of seconds. That deadline is
a claim about how long an unwind takes, which is a property of the code, checked
against wall-clock time, which is a property of the build: a page render under
address+undefined is roughly an order of magnitude slower than the shipping
configuration, and the constant was sized for ThreadSanitizer.

Established rather than assumed, three ways: the plain and ThreadSanitizer
builds pass the same assertions, `leakcheck` reports nothing leaked, and the
address+undefined build passes **14 of 14** at an 8× deadline. The objects were
unwinding; they were not unwinding inside a number chosen for a faster build.

`PVSTRESS_DEADLINE_SCALE` now multiplies every deadline, and the Makefile sets
it to 8 for any sanitized build. Deliberately a multiplier and not a bigger
constant — a real leak still fails, it just takes proportionally longer to say
so, which is exactly the property the original comment claimed and the fixed
constant had quietly stopped providing.

The failure was pre-existing: verified by running the same gate on an unmodified
checkout of the previous commit, which fails the same two assertions.

### 9.7 A fourth instrument: an unmeasured metric was scored as a tie

Found while answering "so did we beat Preview". **Energy Impact reads 0.00 for
both apps in all 70 rows of the recorded run** — the sampler returns zero on a
machine that does not report the figure, and this one does not. The analysis
guarded against a *missing* field (`-`) but a reported `0.00` is not missing, so
it fell through to `ma == 0 && mb == 0` and was scored `TIE +0%`, once per
scenario.

**Seven of the run's nine ties came from a metric nobody measured.** Corrected,
the same TSV reads:

| | before | after |
|---|---|---|
| battery (CPU, energy, wakeups) | 10 / 2 / 9 | **10 / 2 / 2** |
| overall | 11 / 9 / 9 | **11 / 9 / 2** |

The wins and losses were never wrong; the ties were padding, and padding in the
direction of "the two apps are much the same" is the flattering direction for
whichever app is behind. A metric that is identically zero for both apps in
every trial is now printed as `(not reported by this machine -- not scored)`.

Checked against every sample rather than the median, so a metric that genuinely
rests at zero for most of a scenario is still scored on the trials where it
moved. Of the five metrics, only Energy Impact trips it.

### 9.8 What the run supports, and what it does not

The showdown named no winner, and that is the formal position. It is not the
same as having learned nothing, and the distinction is worth stating precisely
because "no verdict" is easy to read as "no evidence".

**Only `scroll` was invalidated.** The arrow-key defect (§9.2) affects one
scenario of seven. In four others the two apps travelled equal distances or
Preview travelled *less*, so their CPU figures compare like with like:

| scenario | travel P / Pv | Postview | Preview | |
|---|---|---|---|---|
| `idle` | 0 / 0 | 0.02 s | 0.33 s | −94% |
| `read` | 4 / 4 | 3.48 s | 3.96 s | −12% |
| `page` | 26 / 23 | 3.27 s | 8.15 s | −60% |
| `swipe` | 6 / 6 | 3.42 s | 6.82 s | −50% |

`page` is the strongest of these in one specific sense: Postview travelled 13%
*further* than Preview and still used 60% less CPU, so the staging error there
runs against Postview rather than for it.

**`swipe` is the control for `scroll`, and it is clean.** The two scenarios were
deliberately sized to the same rate — 240 trackpad events at ~60 Hz is 3125 pt/s
against 200 arrows at 50 Hz — precisely so the keyboard and the trackpad could
be read against each other. `swipe` travelled 6 pages in both apps and Postview
used half the CPU. So the claim `scroll` was making is independently supported
by a scenario the fairness gate passed, which is why §9.2 fixes the arrow key
rather than treating the whole fast-scroll result as suspect.

**The losses are equally real, and one of them is not a staging artifact.**
Peak memory loses in all seven scenarios by 22–43%, including `launch` and
`idle`, where no input is sent and no travel happens at all. At launch
Postview's bitmap cache alone (102.5 MB) is about the size of Preview's entire
process (102 MB). That is the trade the program makes on purpose — §1 ranks
"keeping what was expensive to make" fourth of four levers, and §4.1 sets the
budget by RAM tier — but it is a trade, not a misreading.

Note also that the recorded machine is 64 GB, which is the **Huge** tier and the
most generous budget the program ever grants. *Derived, not measured:* an 8 GB
machine gets 96 MB and a 2 GB machine 32 MB (§4.1), so this is the largest the
memory gap should ever be. Nobody has measured it at a lower tier.

**Idle wakeups are genuinely mixed** — Postview wins `launch`, `idle`, `read`
and `wheel`, loses `scroll` and `swipe`, ties `page`. The `swipe` loss (129
against 67) carries a 4× run-to-run spread and is flagged noisy; the `scroll`
one (26 against 16) is small in absolute terms and sits inside the scenario the
fairness gate rejected.

**What no run has established:** anything about energy directly (§9.7), and
anything about a machine other than a 64 GB Mac Pro on mains power.
