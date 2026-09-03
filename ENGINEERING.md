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

`make band` (`Tests/pvsuite.m`, subcommand `band`), 2026-08-30. Two documents,
identical page geometry, identical bitmap, identical code path, back to back.

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
no cost, and `pvsuite unit` re-asserts the equivalence across a 180-case sweep.

The model may **raise** the dwell bar and never lower it.
`PV_MIN_VISIBLE_SECONDS` is a claim about eyes — a quarter-second is where a
glimpse becomes a look — and the cost model has no standing to overrule it.

---

## 4. Machine and power: one policy, no modes

`PVRenderPolicyFor(power, tier, pressureReports)` is a pure function returning
every knob that would otherwise have been a mode switch. `pvsuite unit` walks
all 36 combinations.

### 4.1 RAM tiers

| tier | RAM | eviction budget | render ceiling | zoom cliff | capacity |
|---|---|---|---|---|---|
| Small | ≤ 2 GB | 32 MB | 2.80 Mpx | — | 3 pages |
| Medium | ≤ 4 GB | 64 MB | 5.59 Mpx | — | 3 pages |
| Large | ≤ 8 GB | 96 MB | 8.39 Mpx | 1.09× | 3 pages |
| Huge | > 8 GB | 256 MB | 16.78 Mpx | 1.54× | 4 pages |

The first three are unchanged from the original derivation `ceiling = budget/3/4`
and are pinned to the byte by `pvsuite unit`, so every Mac with 8 GB or less gets
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
| arrow key | jumps | animated (§12.2) |

**Battery is byte-for-byte today's behaviour**, asserted per tier by
`pvsuite unit`. Unknown is battery, never AC — asserted, so a later refactor
cannot fold them together on the grounds that most Macs are plugged in.

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
- **The express lane's QoS promotion never runs on 10.9 — but the express lane
  now works there anyway.** `dispatch_block_create_with_qos_class` and
  `QOS_CLASS_UTILITY` are 10.10+, so the `dlsym` returns NULL and the *dispatch*
  promotion is absent on Mavericks. That stopped being the mechanism that
  matters when rasterisation moved into the render helper: promoting the
  dispatch block promotes the thread that waits on a pipe, while the drawing
  happens in another process. The helper puts itself in Darwin's background
  class (`setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG)`, which 10.9 has)
  and leaves it for the duration of one page when the command says the request
  is express. Measured on the development host: 1401 ms backgrounded against
  266 ms at ordinary priority for the same 1200×1550 page — a 5.3× spread, and
  it is the same call on Mavericks.
- **Rasterisation cannot be cancelled.** One CoreGraphics call, no resume. The
  available half is never starting it, and dropping a result for a page the
  viewport has left.
- **Nothing in the viewer process calls `CGPDF*`.** Opening the document,
  walking the page tree and measuring every page are done by the render helper
  and reported over the pipe, for exactly the reason the drawing is: those calls
  fault, hang and abort on malformed input, and none of it is an Objective-C
  exception that `@try` can see. A viewer that opened the document itself could
  be killed by a document before the helper it built was ever asked for a page.

---

## 6. Verification

Every automated check lives in one program, `Tests/pvsuite.m`, with a subcommand
per suite: `unit`, `ui`, `soak`, `stress`, `band` and `power`. It used to be
five executables built from five files, which shared four copies of the same
harness and no way at all to compare a number one of them measured against a
number another one did. `power` is the suite that needed that and could not have
existed without it: it reads the rasterisation counters the `ui` suite asserts
on and the process accounting the `soak` suite uses, and reports them against
the kernel's own.

`make verify-all` runs every gate. Current state, this host, 2026-09-01, after
the sleep hook (§10) and the two-page spread (§11):

| gate | result |
|---|---|
| Clang static analyser | clean |
| `pvsuite unit` | 370 passed, 0 failed |
| `pvsuite ui` (drives a real controller) | 210 passed, 0 failed |
| `pvsuite soak` (175 document cycles) | 26 passed, 0 failed |
| `pvsuite stress` | 16 passed, 0 failed |
| `pvsuite stress` + AddressSanitizer + UBSan | 16 passed, 0 failed |
| `pvsuite stress` + ThreadSanitizer | 16 passed, 0 failed, no data races |
| leak census | no Postview-owned object leaked |
| `pvsuite power` (energy and CPU) | 23 passed, 0 failed |
| showdown self-test | 26 instrument checks passed |
| `make verify` (Mach-O 10.9 compatibility) | **not run — see below** |

Unit is up 25 and UI up 23 on the previous run; every added assertion belongs to
§10 or §11 and no existing one changed. The seven newest are §11.4's, and they
were confirmed to fail with the cull reverted — reinstating the bug fails
exactly the two assertions about the page that is off screen, and nothing
else.

**The Mach-O gate could not run on this host.** `make verify REQUIRE_SDK=any`
passes — `x86_64`, minimum OS 10.9, and the linked dylib allow-list is
unchanged, which is the half of the gate that these changes could have broken
(nothing new is linked; `NSWorkspace` is AppKit, already there). The strict form
also checks that the binary was *built against* the 10.9 SDK, and that needs a
real `MacOSX10.9.sdk`. This machine has only Command Line Tools, and the copy
that was unpacked at `/private/tmp/postview-sdk109` is gone — `/private/tmp`
does not survive a reboot. **A release build must re-run
`make all verify SDK=/path/to/MacOSX10.9.sdk` before it ships.**

### 6.1 The energy suite

Until 2026-09-01 nothing in this tree measured what any of it COST. Every gate
above checked that Postview did the right thing; a build that had doubled its
CPU per page, or started waking the processor a thousand times a second while
displaying a static page, passed all of them. The only energy measurement that
existed was the showdown, which runs on one machine that is not the development
host and whose instruments §9.4 found to be wrong in four separate ways.

`make power` asserts on ratios and on zeroes and reports the seconds, because a
ratio measured back to back on one machine is a property of the code while
seconds are a property of the machine. What it gates:

- **An idle document costs nothing.** Measured at 0.15% of one core and 0.0
  package wakeups a second, against limits of 5% and 60. A reader spends most of
  a session not touching anything, and this is the only check that looks at
  that.
- **Rasterisation is charged to the helper.** 99.7% of the CPU a render costs is
  spent in the child process, which is the whole point of the process boundary
  and was never verified from outside.
- **Postview's own cost census agrees with the kernel's.** 821 ms of CPU per
  megapixel against the census's 884, measured over the same six renders. This
  is the check §9.4 did not have: the number `PVCostModel` predicts from had
  never been compared with anything outside the program.
- **The mains policy asks for full-resolution bitmaps during motion and the
  battery policy asks for none** — 6 against 0 over three repetitions each.
- **Both policies end up rasterising the same pixels.** 7.86 Mpx either way. The
  motion gate defers work; it does not drop it, and a page the reader settles on
  goes sharp under either policy.
- **No render helper is left running when the measurement ends.**

Two instrument faults were found by writing it, and both are the kind that
report a plausible number rather than an error:

- **Helper CPU was under-reported by 41.67x.** `proc_pid_rusage` returns times
  in the kernel's absolute-time unit, and this binary is x86_64, so on an Apple
  silicon host it runs under Rosetta — which reports the timebase it *emulates*,
  1/1, while the kernel's numbers stay in the host's real units. The obvious fix
  (ask `mach_timebase_info`) gives the answer 1 on precisely the machine where
  the answer is 41.67. `RusageSeconds()` now measures the ratio against
  `getrusage`, which is microseconds by definition, and `[E1]` asserts the
  result. Before the fix, eight page renders reported 0.121 s of helper CPU
  while `ps` showed that same helper had accumulated 7.5 s.
- **The harness was keeping seven documents alive.** `-valueForKey:` returns an
  autoreleased reference, and the pool it landed in did not drain until the
  whole suite had finished — so every repetition left a render helper resident,
  and every reading after the first included other people's rasterisers. The UI
  suite's `[8]` documents the same trap; there it costs a failed assertion,
  here it cost a quietly wrong number and 237 seconds of run time.

**The AddressSanitizer row above was false until 2026-08-31, and `verify-all`
was reporting it as passing.** §9.6. The row is true now, and the harness can no
longer make that particular mistake.

Two gates were also flaky rather than wrong, in the same way and for the same
reason — an asynchronous teardown asserted against a fixed wall-clock budget.
The stress suite's deadlines are now scaled for sanitized builds (§9.6), and the
UI suite's `[8]` waits for the cache and the PDF source instead of sampling them
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

The UI suite pins the power source to battery for its whole length, because
otherwise its verdict would depend on whether the machine was plugged in when it
ran. `[5g6]` turns the AC branch on explicitly and asserts what it changes, and
`power` `[E4]` measures what that branch costs.

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
  ~~**Run it again**~~ — run again 2026-09-02, and it returned no verdict on
  **nine**. See §9.2, §9.5 and §13. Three things now block a verdict, and none
  of them is the app:
  - **The showdown measures the viewer process only**, so it counts about 3% of
    Postview's CPU and none of the helper's memory or wakeups. §13.2. Fix this
    first; it is the one that makes every column mean something different from
    what it says.
  - **Preview starts every trial on page 2**, which disqualifies all of them.
    §13.2. Needs the Mavericks machine to diagnose.
  - **Energy Impact is not reported by a Mac Pro**, and a Mac Pro has no
    battery. Every battery claim in this project is unmeasured, and measuring
    one needs a portable. §13.2.
- **Keyboard scrolling costs 1.8× Preview's CPU per page travelled.** §13.1.
  The one workload where this program is measurably behind, and §13.3 has the
  only lead: the preview arm has no motion branch, only the dwell test, which
  at scrolling speeds admits every request. Whether that is cheap depends on
  which of §2's two regimes the document is in, and nobody has measured it.
  Measure before changing anything.
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
  a full render. *Unverified* — the band probe varies band count, not scale.
- **A speed-dependent preview divisor.** At 3000 pt/s nothing at 1/3 linear is
  resolvable; 1/6 linear is 1/36 the pixels. Risk is a visible transition when
  the scroll stops, which this host cannot judge.
- **The keyboard's unannounced first event** costs one wanted-set rebuild per
  scroll episode. Closing it means treating `[event isARepeat]` as the
  keyboard's announcement, which moves CPU and belongs after a showdown run.
- **Zoom past the tier's cliff renders soft.** Pinned by `pvsuite unit`, not fixed.
- **What made the crashing window a layer tree is unverified** (§10.2). Full
  screen and injected SIMBL code can both produce an
  `_NSUnbufferedLayerTreeWindow`, and the report does not say which was in
  force. Worth settling only because it is the one input to that crash the
  program has any say over — and settling it means reproducing a wake, not
  reading the report again.
- **The spread's cost is derived, not measured** (§11.3). The arithmetic on
  §2's ratios says a two-page spread is a win on vector content and neutral on
  text per page read. `make power` is the instrument that would confirm it and
  has not been pointed at this.
- **A sideways flick across a zoomed spread is not throttled.** The motion gate
  measures vertical travel only, for the reason in §11.5. The horizontal cull
  bounds the waste to at most one page render per flick, which is why this is a
  note rather than a fix: the machinery to do better is a horizontal dwell
  model, and nothing has measured that it would pay.

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

The first time any of this executed on a 2013 Mac. Machine: the Mac Pro,
64 GB, mains power, SIMBL present as always.

The raw TSV and console output used to be committed under
`Tests/Mavericks Testing/`. They are no longer in the tree, and that is a
consequence of §9.4 and §9.7 rather than tidying: four of the instruments that
produced those files were reporting quantities that were not what their column
headings said, so the files invited exactly the quoting this section spends most
of its length warning against. What survives is below, each figure stated with
what it does and does not support. The figures that are still safe to use are
reproducible by re-running the harness that produced them; the ones that are not
are marked unrecoverable, and no file in the tree now makes them look
otherwise.

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

> **The next run replaced it, and it was wrong — §13.1.** The 2026-09-02 run
> travels 12 pages against Preview's 13, so the fix worked; the margin did not
> merely shrink, it inverted. Per page travelled, Postview 0.116 s against
> Preview 0.065 s. **Do not cite the +20%.**

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

`pvsuite band`, 528-page Russian-language text document, 8.66 Mpx per page:

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
the tester was told to read off the screen — largely described previews and was
read as the cost of a page. Now reported as `cost.ms.per.mpx.full` and
`cost.ms.per.mpx.preview`, each dividing its own population's seconds by its own
population's pixels.

That run's figure cannot be recovered by arithmetic and **should not be quoted**.
Nor is it comparable with §9.3's 18.1 ms/Mpx: the Step 1 session averaged
2.03 Mpx per full render against the probe's 8.66, so it was a different window
or a different document, and neither was recorded. Any future run has to record
the window size and the document alongside the rate, or the rate is not
comparable with anything.

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
  finally be compared with the band probe's 18.1 ms/Mpx on the same page.
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
passed. §6 has been carrying `stress + AddressSanitizer + UBSan | 14 passed,
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

---

## 10. The wake-from-sleep crash, 2026-09-01

A crash report from the Mac Pro, taken 19:26 the same day, after the machine
woke from sleep. `EXC_CRASH (SIGABRT)`, `abort() called`, and one line that
names the mechanism outright:

```
Application Specific Signatures:
Graphics kernel error: 0xfffffffe
```

**The crash is not in this program, and there is no line of Postview to fix.**
That is a claim, so here is the evidence for it.

### 10.1 What the stack says

Read from the bottom, the crashing thread is:

```
22  -[NSApplication run]
21  -[NSApplication sendEvent:]
20  -[NSApplication _reactToDisplayChanged:resetScreens:]
19  -[NSApplication makeWindowsPerform:inOrder:]
16  -[NSWindow _displayChanged]
14  -[NSWindow _screenChanged:]
13  -[NSWindow _updateSettingsSendingScreenChangeNotificationIfNeeded:]
10  -[_NSUnbufferedLayerTreeWindow display]
 9  -[NSView(NSLayerKitGlue) _drawRectAsLayerTree:]
 8  CAViewDraw
 7  view_draw(_CAView*, double, CVTimeStamp const*, bool)
 6  CGLFlushDrawable
 5  com.apple.AMDRadeonX4000GLDriver
 4  gpusSubmitDataBuffers
 3  gpusKillClient
 2  abort
```

Every frame is Apple's. Frame 23 is `main`, and that is the only Postview
frame in it. The sequence is: the display configuration changed, AppKit told
every window to redraw, the redraw went through CoreAnimation to OpenGL, the
kernel rejected the command buffer, and `gpusKillClient` — which is exactly
what its name says — called `abort()` on its own client.

`0xfffffffe` is `-2` from the kernel GPU driver. `gpusKillClient` is not a
crash in the ordinary sense; it is libGPUSupport deciding a context is
unusable and destroying the process holding it.

### 10.2 Why it cannot be Postview's OpenGL

Postview has none.

| claim | check |
|---|---|
| Links only Cocoa and CoreGraphics | `LDFLAGS` in the Makefile; `make verify` allow-lists the linked dylibs |
| Never sets `wantsLayer` | `grep -rn 'wantsLayer\|CALayer\|setLayer' Sources/` → nothing |
| Never uses OpenGL | `grep -rn 'NSOpenGL' Sources/` → nothing |
| Never creates a `CVDisplayLink` | `grep -rn 'CVDisplayLink' Sources/` → nothing |
| Draws by blitting `CGImage`s in `-drawRect:` | `PVPageView.m` |

The report also shows OpenCL, QuartzComposer, ImageKit, QTKit, PDFKit and two
dozen `cl_kernels` images loaded into a process that links none of them, and
`org.w0lf.SIMBL` with four injected bundles. §8 already says to read crash
reports from that machine accordingly, and there is precedent in this tree:
`Resources/crash report.txt`, 2026-08-28, is a `SIGBUS` inside
`Wowfunhappy.greenFullscreen` — a SIMBL bundle — while it swizzled
`-[NSWindow update]`.

The window in the stack is an `_NSUnbufferedLayerTreeWindow`, drawn as a layer
tree. Postview does not ask for that. What can produce it is full-screen mode
(the app sets `NSWindowCollectionBehaviorFullScreenPrimary`) or injected code.
Which of the two it was on this run is **unverified** and the report does not
say.

*Confidence:* that the aborting GL context is not one Postview created is
**certain** — the program creates none. That a MacPro6,1 with two FirePro D500s
on 10.9.5 is a configuration where waking invalidates GPU contexts is
**consistent with the report and with the hardware**, and is not something this
tree has instrumented.

### 10.3 What was deliberately not done

- **No `SIGABRT` handler.** The abort happens after the driver has decided the
  context is dead, on the main thread, inside a framework, with the process in
  a state nothing here defined. Catching it would replace a clean crash with
  undefined behaviour and a viewer that stays open showing whatever it can
  still draw. For a program that claims mission-critical stability that is
  strictly worse: an honest crash is a better failure than a live process
  making things up.
- **No change to the display-change path.** `-backingPropertiesChanged:` does
  the most expensive thing in the app — drops both caches and re-renders — and
  it does it at the exact moment of a wake. That is correct: at a new backing
  scale every cached bitmap really is the wrong size. Deferring it would only
  make the window blank for longer, and it is not what aborted.
- **No removal of full-screen support** to avoid the layer-tree window. The
  connection is unverified, and trading a feature for a guess is not a fix.

### 10.4 What was done

The crash cannot be prevented from inside the process. What it *cost* can be.

State is flushed when a document closes, when the app is deactivated, and at
quit. A reader who is looking at a page when the lid closes hits none of the
three: the app is frontmost, so it never resigns active, and it never
terminates — it is killed. Every position change from that whole session is
lost.

`PVAppDelegate` now observes `NSWorkspaceWillSleepNotification` and commits the
reading position there. Sleep is the one warning this process reliably gets
before this class of death.

- One notification, one write, a handful of times a day. **Nothing polls and no
  timer is armed**, so `PVStateStore`'s own rule is kept exactly.
- The census stays on the termination path. `-saveOpenDocumentState` was split
  out of `-saveAllOpenDocuments` so that sleeping does not emit the
  rasterisation counters: those describe a whole run, and writing them per
  sleep would interleave several runs in one log and rewrite `PVStatsPath` with
  a partial total — a measurement changed by taking it.
- `NSWorkspace` posts on **its own** notification centre. Registering on the
  default centre compiles, links, runs, raises nothing, and is never called.
  `pvsuite unit` asserts the notification arrives on the workspace centre and
  does *not* arrive on the default one, because those two cases are otherwise
  indistinguishable from outside.
- Unregistration now names both centres. `-removeObserver:` on the default
  centre does not touch the workspace's, and the workspace holds observers
  unsafely — the previous teardown would have left a freed delegate to be
  messaged at the next sleep.

### 10.5 What the clocks already got right

A wake is where interval arithmetic usually breaks, so it was audited rather
than assumed. Nothing needed changing:

- Every interval in the program comes from `PVMonotonicSeconds()`
  (`mach_absolute_time`), which does not step and does not advance across
  sleep on 10.9. A render deadline set before the machine slept still has its
  full budget on wake, so a long sleep cannot spuriously time out a helper and
  kill it. This is the safe direction and it is the one in force.
- The single wall-clock read, `PVCurrentPowerSource`'s cache stamp, is a
  staleness test with an explicit backwards-clock guard. On wake the stamp is
  old, the cache expires, and the power source is read again — which is correct
  behaviour, since the machine may well have been unplugged while it slept.

---

## 11. Two pages side by side

Added 2026-09-01. `View ▸ Two Pages`, ⌘3, remembered per document.

### 11.1 It is not a second layout

`PVPageView` lays pages out in **rows**. A row holds one page or two, and the
column count is the only thing that differs. There is no second layout path and
no second drawing path, and nothing downstream — the visible range, the wanted
set, the prefetch, the cache, the cost model — knows which one is in force,
because all of them are written in pages and a row hands back pages.

Two things had to be got right for that to be true rather than merely claimed:

**The binary search needed a monotonic index.** `-pageRangeInRect:` finds the
first page whose bottom edge reaches the rect. That is a binary search, and a
binary search requires its predicate to be monotonic in the index it searches.
Page frames stop being monotonic the moment a row holds two of them: facing
pages are aligned at their tops, so a tall page beside a short one gives the
*lower* index the *greater* maximum y, and the search can step past the row it
is standing in — dropping a page that is on screen out of the visible range, so
it is never pinned and never rendered. Rows are monotonic by construction, each
beginning below the last, so the search runs over rows and converts to pages at
the end. At one column it is the identical search over the identical numbers.

**A reading position is a fraction into the row, not into the page.** Both
facing pages occupy the same band, so a fraction measured against one of them
does not survive being handed back to `-scrollToPage:fraction:`. Reopening a
document in the spread would land the reader somewhere they had never been.

### 11.2 The requested count is not the laid-out count

`-setColumns:` records an intent; the row table is rebuilt by the next layout
pass. Between those two moments the two counts disagree, and every query that
indexes the row table answers from `_laidOutColumns` — never from `_columns`.

The failure if it does not is not a stale answer but an out-of-range one: at
two columns over a table still built one row per page, `row * columns` runs
past the end of the document, and `NSMakeRange(first, last - first + 1)`
underflows to a length of billions — which then goes to `-setPinnedPages:` and
to the draw loop.

Nothing in the app can currently reach that window, because the controller
relayouts in the same turn of the run loop that it sets the count. That is a
property of one call site, not of the class, and it is the kind of guarantee
that holds until someone adds a call between the two. `pvsuite unit` sets the
count without a relayout on purpose and asserts every range stays inside the
document.

### 11.3 What it costs

*Derived from §2, not separately measured.* §2 is the measurement that decides
this, and it says a page's cost has two components pulling opposite ways:
destination traffic, proportional to pixels touched, and content-stream
interpretation, proportional to operator count and paid in full however few
pixels are drawn.

In the spread, fit-width halves the zoom, so each page is about a quarter of
the area it had — and a screenful still holds about the same number of pixels,
because **the viewport bounds the pixels, not the page count**.

| document kind | cost per screenful | pages per screenful | cost per page read |
|---|---|---|---|
| vector (`heavy.pdf`) | ~unchanged — pixel-bound, viewport-bounded | ×2 | **~halved** |
| text (`text.pdf`) | ~doubled — two content streams walked | ×2 | **~unchanged** |

So the spread is a win on vector content and neutral on text, per page
actually read. It is not a battery regression in either direction, which is why
it needed no new gate, no new budget and no change to the scheduler. *This is
arithmetic on §2's ratios and has not been measured on the target;* the
instrument to do it with is `make power`.

The cache is unaffected in the way that matters. `PVRenderPolicyFitsCache`
budgets for two visible full-resolution pages plus prefetch, evaluated at the
tier's render ceiling; in the spread at any fit zoom each page is far under
that ceiling, so the pinned set costs less than the invariant already reserves.
At actual size on a large display the spread can pin four pages where the
column pinned two — and that is the case `-setPinnedPages:` was written for: the
cache goes over budget by a bounded amount and comes straight back, rather than
evicting a page that is still wanted and re-rendering it forever.

### 11.4 The page you cannot see is not rendered

The spread introduced a way for a page to be on screen vertically and not on
screen at all, and the scheduler did not notice.

`-pageRangeInRect:` asks a purely vertical question, because until the spread
there was no other kind. A single column is centred in a document exactly as
wide as its widest page, so whatever the horizontal scroll position, the one
page in a row always overlaps the window — the horizontal question has the
answer YES by construction and nobody had to ask it.

A row of two pages plus a gutter breaks that. Zoom past the point where a row
fits the window and the reader can scroll sideways until one of the pair is
entirely off the glass. Both pages stay in the visible page *range* — they
share the row — so the scheduler went on asking for a preview **and** a
full-resolution bitmap for a page with no pixels on screen. That is the most
expensive thing this program does, spent against §1's first and largest lever:
not rendering at all.

`-drawRect:` never had the bug — it has always culled with `NSIntersectsRect`
against the dirty rect. The fix is that same test, moved to the decision that
costs something: `PVPageOverlapsColumn()` now gates the visible pages and both
prefetch loops. Prefetch is gated too, and deliberately: a reader who has
scrolled a zoomed spread over to the left-hand page will still be on the
left-hand page one spread further down, so the right-hand column is as
invisible there as it is here.

**The cull alone would have been a bug.** The wanted set is rebuilt only when
the visible page range, the direction of travel, or the motion state changes —
and none of those move when you scroll across a spread. Culling without saying
so would have dropped the far page correctly on the way out and never asked for
it again on the way back in. `-clipBoundsChanged:` therefore also compares the
horizontal position, guarded by `laidOutColumns > 1 &&` the document being wider
than the window, so the single-page column's early-out is bit for bit the one
that was measured.

`pvsuite ui` `[5j]` pins all of it: zoom until a row is wider than the window,
scroll hard left and assert the right-hand page is never named, scroll hard
right and assert the mirror image, scroll across and assert the page that came
into view *is* named. Verified to fail without the cull — reinstating the bug
fails exactly the two assertions about the invisible page and nothing else.

*Not measured in joules.* What is measured is the request count, which is the
thing the energy would be spent on: at the zooms where this fires, half of every
full-resolution render was being thrown away.

### 11.5 Details that are decisions

- **Pairing is (0,1), (2,3), …** — the plain "Two Pages" of the platform's own
  viewer. ~~No cover-page-alone variant: it doubles the state space to serve a
  convention this program has no way to detect.~~ **Reversed, 2026-09-02; see
  §11.6, which answers both halves of that sentence.**
- **Facing pages are aligned at their tops**, and the row is as tall as the
  taller of the two. Centring them instead would be prettier on mixed page
  sizes and would cost the monotonicity §11.1 is built on.
- **Rows are centred as a unit**, so the gutter sits in the middle of the
  window. At one column this is the page centred on its own, which is what it
  always was.
- **Next and Previous turn a whole spread.** Stepping one page would leave the
  viewport where it was for every second press — the page asked for is already
  on screen — which reads as a menu item that half works.
- **The title names both pages**: "(pages 4-5 of 100)". It is the only page
  indicator the app has, and naming just the left one makes the number stop
  changing on every second turn.
- **The last row of an odd-length document holds one page** and is titled as
  one.
- **No toolbar button.** There is no artwork for one, and inventing an icon is
  a different job from this one.
- **Horizontal travel does not feed the motion gate.** `_scrollSpeed` is
  vertical, and `-secondsPageStaysVisible:` derives dwell from vertical
  geometry; mixing a sideways speed into either would corrupt a dwell model
  that is about pages leaving the top of the window. So a fast sideways flick
  across a zoomed spread is not throttled the way a vertical flick is. The cull
  in §11.4 bounds what that can cost — there are only ever two pages to choose
  between, and only the visible one is asked for — so what remains is at most
  one page render per flick. A horizontal dwell model would be new machinery
  for a case nobody has measured, and §7 is where it belongs until someone
  does.

### 11.6 The cover page

**⌘4 lays the document out as a book: page one alone, then 2-3, 4-5.** §11.5
said this would not be built. The objection had two halves and both are
answered, which is why it is built rather than relitigated.

**"It doubles the state space."** It would have, against the code as it stood.
The pairing rule was arithmetic — row `r` holds pages from `r*k` — and it was
written out at each of the three places that needed it: the layout pass, the
row query, and the window title. A rule that lives in three places cannot be
changed in one, and a fourth caller would have made four.

It is now one rule, in `PVCommon`, as six pure functions: `PVPagesInFirstRow`,
`PVRowCountForPages`, `PVFirstPageOfRow`, `PVRowContainingPage`,
`PVFirstPageOfRowContainingPage` and `PVPagesInRow`. Everything that needs it
asks — the layout pass, the row queries, the window title, and the row stepping
behind ⌘↓ and ⌘↑, which was the fourth copy waiting to happen and is where the
arithmetic had already gone wrong (see below). The cover is an argument to them,
not a branch inside them, and the row table, the binary search over it, the
visible range, the prefetch, the pins and the failure tables are byte for byte
the code that already served the spread — §11.1's "it is not a second layout"
now covers three layouts instead of two.

What the state space actually grew by is one boolean, and it is bounded at both
ends by normalisation rather than by callers remembering: a cover in a single
column is not a shape the program can hold. `-setColumns:1` publishes
`laidOutCover == NO` whatever was asked for, the state store refuses to hand one
back, and `applyColumns:cover:` clears it. Asserted, because "normalised
everywhere" is the kind of claim that is true of three of the four places.

**"A convention this program has no way to detect."** That objection was against
*detecting* a cover page, and it is still correct — nothing in a PDF says which
of its pages is a title page, and a heuristic over page sizes would be wrong on
the documents that matter most. This does not detect anything. **The reader says
so**, with a menu item and a check mark, and it is remembered per document
beside the page, the zoom and the column count. The program never guesses.

**The gutter is the centre line, and the cover page is the page to the right of
it.** A title page is a recto. Centring it instead would put page one over the
gutter and every page after it half a page to one side, so the document would
appear to slide sideways as the reader turned off the first row. The cover's
left edge is `totalWidth/2 + PV_PAGE_GAP/2` — for an evenly matched pair that is
*exactly* where the centring in §11.5 already puts the right-hand page, with the
page width cancelling out of the algebra. Pages of unequal width are centred as
a unit and so carry their gutter off the centre line by half the difference; the
cover does not follow it there, because the whole document is the thing being
aligned and the centre line is the only part of that which does not depend on
page two.

Fit-width therefore fits the *pair* on the cover row as on every other row, so
the cover page is drawn at half the window's width. That is the same page scale
as the rest of the document, which is the point of a book layout — and the same
pixel argument as §11.3: the viewport bounds the pixels, not the page count.

**A trailing short row is still centred, not put in its verso slot.** In a book
the last page of an even-length cover layout is a left-hand page, and this draws
it in the middle instead. That is not an oversight peculiar to the cover: the
plain spread has centred the lone last page of an odd-length document since it
was written (§11.5, "rows are centred as a unit"), and the cover row is the
deliberate exception because it is *first* — every row after it shifts relative
to where it sits, and a trailing row has nothing after it to be consistent with.
One rule with one exception, rather than two rules.

**The row step was the fourth copy of the rule, and it was already wrong.**
`goToNextPage:` computed the next row as "this row's first page, plus a row's
worth of pages", which is the layout's own answer only while every row is the
same size. In the cover layout it skipped over the left half of the 2-3 spread,
and — worse, because it is silent — the Go menu disabled **Next** on the cover
of a two-page document, since `0 + 2` is not less than `2` while the row it was
refusing to turn to was sitting right there. It steps by row through
`PVFirstPageOfRow` now, and `TestRowPairing` walks every document length from 1
to 20 pages in both layouts asserting that a row step reaches the next row and
stops at the last one.

**The three short rows.** A spread had one short row and it was always the last.
There are three now — the cover, the last row, and a two-page document where
they are the same row — so `PVPagesInRow` is asked for the count rather than
deriving it from the page index. The version that subtracted the first page of a
row from the page count was a correct reading of "how many pages are left" only
while every row before it was full; in the cover layout it said two for a row
holding one, and the range built from it named a page that is not on screen at
every scroll position that shows the cover. That is a full-resolution
rasterisation of an invisible page, per rebuild, which is the exact cost §11.4
exists to avoid.

**What the tests hold.** `TestRowPairing` walks both spreads over every document
length from 1 to 100 pages and asserts three properties over every page of each:
the row a page is in begins at a page in that row (the round trip every restored
reading position depends on), the rows partition the document with no page
skipped or counted twice (what the drawing loop walks), and rows begin at
strictly increasing pages (what makes the binary search over them legitimate —
§11.1). `[5i2]` drives the real controller: the title names one page on the
cover and two after it, Next turns onto the 2-3 spread by one page and thereafter
by two, and the two menu items behave as one choice rather than two independent
switches.

---

## 12. Scrolling with the hand, and with the arrow key

Two additions on 2026-09-02, and they are the same kind of thing from opposite
directions: one gives the reader a way to move the document that did not exist,
and one changes how the document arrives when they use the key that did.

### 12.1 Click and drag pans the document

There is no text selection in this program, so a press on the page means nothing
and there is no tool palette to choose what it should mean. The whole document
area is therefore the hand, with no mode: a press that does not move is still a
press, and one that does is a pan.

**The content follows the hand.** Drag upwards and the page rises with the
pointer, uncovering what is below it — the same direction of travel as pushing
the wheel away or swiping up on the trackpad, and the same as every other hand
tool. Both axes, because a spread zoomed past the width of the window has
somewhere to go sideways and the horizontal scroll should not be the one thing
that has to be found with the scroller.

**The anchor is in window coordinates, and that is the whole of the difficulty.**
A clip view's bounds origin *is* the scroll offset, so a window point converted
into the clip view moves as the document scrolls. Measured there, the delta
contains the travel that has already been applied, the subtraction feeds its own
output back in, and the document runs away from the pointer at compounding
speed. The window does not move during a drag, so the difference between two
points in it is the distance the hand has actually travelled and nothing else.
`[5g11]` pins this the way it shows up: drag out and back to the anchor, and the
document has to be where it started.

Each frame is computed from the anchor rather than accumulated from the last
one, so a clamp at the end of the document is undone simply by dragging back
instead of being lost. A 3 pt deadband keeps a click a click — a hand resting on
a mouse moves a point or two while pressing the button.

`-acceptsFirstMouse:` returns NO. The first click on a background window is how
a reader chooses which document they are reading, and panning it as well would
move the page under someone who was only activating the window.

**The closed hand is a push onto a global stack, and the pair has to balance
however the gesture ends.** `-endPan` is the one place it is popped, for
released, cancelled, and window-taken-away alike — but the audit of 2026-09-02
found the one path that reset the flags without going through it. A second
`-mouseDown:` arriving with no mouse-up in between cleared `_panMoved` directly,
orphaning the push: the closed hand stayed up over a document nobody was
dragging, for the rest of the session, one deeper every time it happened. Not a
hypothetical sequence — a modal panel put up mid-drag, a sheet opened from a
notification, and a process stopped and resumed under a debugger each swallow
the release, and the next press is then the second `-mouseDown:` in a row.
`-mouseDown:` ends any pan still open before starting another; `[5g12]` measures
the stack the only way the API allows, by popping until the closed hand is no
longer on top, and asserts the count is zero.

It costs nothing this program was not already paying: a drag is a scroll, the
motion gate and the dwell model read it exactly as they read a trackpad swipe,
and `-scrollWheel:` is still not overridden — which is the precondition for
responsive scrolling (§ PVPageView) and would have been the tempting place to
put this.

### 12.2 The arrow key is animated on mains power, and jumps on battery

`PVArrowScrollForViewportHeight` is untouched. **An animated press lands on
exactly the offset a jumped one would**, so the showdown's travel fairness check
— measured in pages moved per keystroke — reads the same number under both
policies. That is the invariant, and it is not free: it is what the retarget in
`-scrollByPoints:animated:` exists for. A second press arriving mid-animation
adds its step to the *destination*, not to wherever the document has got to.
Adding it to the latter silently discards the unfinished part of every press, so
a held key would cover a distance that depends on the machine's frame rate — and
the same keystrokes would then move a reader a different distance on mains than
on battery while the showdown reported one number for both. `[5g10]` sends ten
presses with no run loop in between and requires ten steps of travel.

**Why it is off on battery.** One press used to be one `-scrollToPoint:` and one
bounds notification. An animated press is a timer at 60 Hz for 140 ms — about
eight frames, each a redraw and another trip through `-clipBoundsChanged:` — so
roughly eight times the wakeups and eight times the blitting for one keystroke.
Idle wakeups are a metric this project measures precisely because they are what
a processor cannot sleep through, and §1 ranks not doing work above doing it
cheaply. This is work that buys nothing but smoothness, so it is bought only
where smoothness is free. `PVSmoothScrollForPower` is the policy, stated as a
function of the power source alone so it can be walked without unplugging
anything; Unknown takes the battery branch, asserted, for §4.2's reason.

It is **not** a saving in renders, and should not be described as one. The
motion gate reads an animated scroll as motion either way — a 96 pt step over
140 ms is ~690 pt/s, and the same step arriving as one event at the key repeat
rate is ~2900 pt/s — so both are well above `PV_MIN_SCROLL_SPEED` and both
suppress full-resolution rendering while the document moves. What the animation
adds is the frames in between, and those are pure cost.

**Only the arrow keys.** Space, Page Up and Page Down are a screenful on
purpose; 140 ms of a whole viewport sliding past is a longer wait for the page
you asked for, not a smoother one. Home and End are jumps by definition.

**Anything else that moves the document wins.** Each frame compares the clip
view's offset against the offset the animation last *wrote*; if they differ,
something else has scrolled and the animation abandons itself rather than
dragging the view back. That covers the wheel, the trackpad, the scroller and
the controller's own restores in one test, without this class having to know
about any of them — which matters, because the first of those reaches the clip
view without passing through `PVPageView` at all and must go on doing so.

**But that test is evidence, not a signal, and on its own it was not enough.**
It answers "has the document moved since I last moved it", which is a different
question from "is this animation still the right thing to be doing", and the
audit of 2026-09-02 found two ways the two answers come apart:

- *A jump that lands where the animation already is.* Go to Page and a
  thumbnail click place the document without changing its geometry, so the only
  thing that could stop an animation there is the frame comparison — and a jump
  landing within `PV_SMOOTH_SCROLL_EPSILON` of where the animation had got to
  passes it. The animation then finishes, carrying the reader off the page they
  chose. `-scrollClipTo:` is the controller's one write of the offset and both
  those paths go through it, so it now cancels outright: a chosen position is
  not something an earlier keystroke gets to finish overriding.
- *A relayout under a live animation.* `_scrollTo` is an absolute offset in the
  geometry the press was made in. A resize replaces that geometry and
  `-relayoutKeepingPage:fraction:` restores the reading position — and a purely
  vertical resize does not move the offset, so the frame comparison sees
  nothing and the animation goes on to a destination that no longer means
  anything. Reproduced: resizing the window while the Down arrow was held moved
  the reader off the position the relayout had just preserved. The cancel is
  stated in `-setZoom:backingScale:containerWidth:`, past its early-out — the
  one place the geometry actually changes, so no caller has to know that one of
  these invalidates the other.

Both are asserted in `[5g13]`. The frame comparison stays: it is still the only
thing that can see the wheel and the trackpad, which reach the clip view
without passing through this class at all.

**And the comparison had a third failure, in the other direction: a keystroke
it swallowed.** The sixtieth of a second between two frames is a real window,
and a press landing inside it finds an animation that is still running but no
longer driving the document. The press correctly re-bases on where the document
now is — but `_scrollLastSet`, the offset the next frame checks against, was
only written when a timer was *created*. So the next frame compared the
document's position against a number from before the wheel, concluded that
somebody else was scrolling, and cancelled: the press moved nothing at all.
Measured at 0 pt against a 92.6 pt step. Taking charge of the document again
and recording where from are the same act, so they now happen together —
`if (!stillOurs) _scrollLastSet = now`, where `stillOurs` is the same test the
frame makes. `[5g14]`.

Three defects in one mechanism is the argument against the mechanism, and it is
worth stating what would replace it: the destination is an absolute offset, and
the rest of this program deliberately speaks in page-and-fraction *because*
that survives a relayout. Holding `_scrollTo` that way would make two of the
three impossible rather than handled. It is not done here because the property
that matters most is exact — 40 held presses travel 3505.0 pt under both
policies, the same number to the point — and a round trip through page and
fraction is the one thing that would put a rounding error into it.

**The timer retains the view**, and through it the cache and the parsed document
behind it, so a live one is not merely a wakeup left running. It is invalidated
when the animation lands, when the view leaves its window, and by
`-cancelScrollAnimation`, which `-teardownReferences` calls for the same reason
it cancels the controller's own two timers there.

`accessibilityDisplayShouldReduceMotion` is honoured where it exists. It is
10.12 and later, so it is asked for by selector and its absence on Mavericks
means the same as it being off.

**It is an `NSTimer` and nothing else — §10.2 still holds.** "Animation" is
exactly the word that ought to make anyone who has read §10 nervous, so it is
worth saying plainly: this adds no `CVDisplayLink`, no `CALayer`, no
`wantsLayer`, and no OpenGL. Every one of that section's greps still returns
nothing, which is the evidence the wake-from-sleep argument rests on. The frames
are `-[NSClipView scrollToPoint:]` calls from a run-loop timer, which is the
same call the arrow key already made — once instead of eight times.

---

## 13. The Mavericks run, 2026-09-02

`build/Showdown Mavericks/Postview-Showdown-20260902-082544.{txt,tsv}`. Seven
scenarios, five runs each, `Computer Graphics.pdf`, 1200×800, Postview pinned to
`-PVPowerState battery`, Darwin 13.4.0.

**It named no winner, and this time nine fairness checks failed rather than
two.** The formal position is §9.8's: no verdict. What follows is what the
recorded rows do and do not support.

### 13.1 The arrow-key fix worked, and it cost the `scroll` win

§9.2 replaced a flat 60 pt arrow step with one eighth of the viewport, because
200 presses had moved Postview 6 pages against Preview's 13. **That is fixed:
12 against 13, and the gate now records `scroll` as "travel not checkable"
rather than as a disparity.**

§9.2 also predicted the CPU margin would shrink to about +20% in Postview's
favour and said to take that as the fix working. It did not shrink. It
inverted:

| | Postview | Preview | margin |
|---|---|---|---|
| `scroll` CPU | 1.39 s | 0.84 s | −40% |
| pages travelled | 12 | 13 | |
| **CPU per page** | **0.116 s** | **0.065 s** | **−44%** |

*Margins in this file's convention: the gap over the larger of the two, which is
what the report prints. As a ratio, Postview uses 1.8× Preview's CPU per page.*

The +20% was arithmetic on a run made under the old behaviour, and it is now
*falsified*, not merely superseded. Keyboard scrolling is the one workload where
this program is measurably worse than Preview per page read, and §13.3 is the
only lead the recorded data offers.

**Read it against §13.2 before acting on it.** Those are viewer-process CPU
figures, so Postview's real cost per page is larger again by whatever its helper
spent — which makes this the one loss in the file that the accounting error
understates rather than flatters.

`swipe` and `wheel` lose on CPU by similar margins at equal travel (−54%,
−57%), which is consistent: all three are the fast-scroll path.

### 13.2 What the run measured, and the three reasons it cannot be read

**Energy was not measured at all.** `energy_mean` is `0.00` and `energy_peak` is
`0` in all 70 rows. §9.7 taught the analysis to print
`(not reported by this machine -- not scored)` instead of scoring it as a tie,
and it does — correctly. **So this run says nothing about battery**, and nor can
any run on that machine: a Mac Pro has no battery to drain and does not report
Energy Impact. Every battery claim this project makes has to be measured on a
portable, and none has been.

**Every trial was disqualified by the start-page check, in all seven scenarios.**
Preview started on page 2 in 35 of 35 trials; Postview on page 1 in 35 of 35.
`assert_fresh_start` reports this as "It restored a saved reading position" —
and the data contradicts that reading. The file is freshly copied for every
trial, and a restored position would land on a *different* page each time, not
on exactly 2 in every scenario and every run. Whatever Preview's title means by
page 2 at the top of a freshly opened document, the harness's assumption about
it is wrong, and **until that is diagnosed no showdown can produce a verdict.**
*Not diagnosable from the development host:* it needs Preview on the Mavericks
machine and the exact window title it puts up.

**A fifth instrument fault: the showdown does not measure the render helper.**
`cpu_seconds_for`, `sample_process` and `power_sample_for` each read a single
pid — the viewer. Rasterisation has been in a child process since the helper
landed, and `ps -o time` reports a process's own `utime + stime`, never a
child's, reaped or not (checked directly: a parent that spawned and reaped a
child which burned two seconds of CPU reports `0:00.01`).

The size of the hole is measured, on the development host, by `make power`
[E6] over one whole run:

| | CPU |
|---|---|
| viewer | 3.520 s |
| helpers | 108.069 s |
| **share the showdown counts** | **3.2%** |

which agrees with §6.1's "99.7% of the CPU a render costs is spent in the child
process". So **every `Postview` CPU figure in the report is a few per cent of
what Postview cost**, while Preview's figure is that instrument's whole answer
for Preview. The wins are overstated and the losses understated by an unknown
factor, and the same applies to the memory and idle-wakeup columns — the report
already says the bitmaps' physical pages are charged to the helper, and peak
memory is where the biggest losses already are.

This is not an argument that Postview is worse than the run says. It is that the
CPU columns are not a comparison, and should not be read as one until the
accounting covers both apps' whole process trees. Preview has helper processes
of its own; fixing one side alone would replace a known bias with a new one.

### 13.3 Where the scheduler could still pay, and what is not yet evidence

The one lead the recorded rows offer for §13.1. Over `scroll`'s 12 pages:

| | count | withheld |
|---|---|---|
| full renders | 7 | 51 requests, all by the motion gate |
| preview renders | 15 | **none** |
| dwell throttle | | **0 requests, of either kind** |

**Everything withheld on `scroll` was withheld by the blanket motion gate, and
that gate covers only full-resolution bitmaps.** The preview arm has no motion
branch: it is asked the per-page dwell question and nothing else, and at these
speeds that question always answers yes — `PVStatMotionSuppressed`'s own comment
says why, and it is correct arithmetic. At ~3000 pt/s a page is visible for
about 0.76 s, comfortably above `PV_MIN_VISIBLE_SECONDS`, so a preview that
takes a few tens of milliseconds is genuinely worth rendering. The reader gets
something on every page they scroll past, which is the whole job of the preview
path.

So the question is not whether the gate is working — it is whether **15 previews
is cheap**, and that is a question §2 has already split in two:

- **Pixel-bound content (vector).** A preview really is ~1/9 of a page, and 15
  of them are under two page-equivalents against 7 full renders. Nothing to
  find here.
- **Content-stream-bound content (text).** A preview re-walks the *entire*
  content stream for 1/9 the pixels. §3 kept a separate cost estimate for
  previews precisely because their rate "is nothing like a full page's" —
  mixing the two moved a crossover by a factor of six. On such a document 15
  previews could plausibly cost more than the 7 full renders beside them.

`Computer Graphics.pdf` is presumably the first kind, and the arbiter's own
`read` workload is the second. **Nobody has measured which regime `scroll` is
in, and the showdown could not have shown it either way** — that work is in the
helper (§13.2).

**Candidate, not a change:** put the preview arm behind a speed test of its own,
using the preview cost estimate `PVCostModel` already keeps. It is §1's first
lever applied to the one arm that currently has no motion branch. It is also
directly against responsiveness — a suppressed preview is a page with nothing on
it, which is the failure the preview path exists to prevent — so it needs
`make power` and `make band` on the target to decide, and a per-document answer
rather than a constant. **Nothing here is measured yet, and none of it may be
cited as a saving.**

What is *not* a lead, so that nobody spends a week on it: banding (§9.3 retired
it for text), a performance mode (§4.4), and reducing the cache — the Huge
tier's budget is why peak memory loses, and stepping off the knee costs CPU and
energy to save bytes nobody is short of (§4.1, §4.4).

### 13.4 What the run supports

`launch` (+58% on CPU, +54% on the time to a usable window) and `idle` (+97% on
CPU) at zero travel in both apps, and `page` (+82%) at 35 pages against
Preview's 80 — where Postview used 0.019 s of viewer CPU per page against
Preview's 0.045 s. Those hold to the extent §13.2's accounting allows, which is:
for the viewer process only. `launch` and `idle` are the two where that is least
of a caveat, because a document that is open and not moving is asking its helper
for nothing.

The rasterisation counters, which are Postview's own and unaffected by §13.2,
are the clearest result in the file. Against the reference run made before the
scheduler work, on the same machine:

| scenario | renders then | renders now | Mpx then | Mpx now |
|---|---|---|---|---|
| `read` | 51 | **10** | 380.7 | **64.4** |
| `page` | 90 | **8** | 666.7 | **49.3** |
| `scroll` | 126 | **7** | 962.2 | **46.9** |

That is the motion gate and the dwell throttle doing exactly what §1 ranks
first. It is a measurement of Postview against its own past, not against
Preview, and it is the one number in this run that needs no caveat.
