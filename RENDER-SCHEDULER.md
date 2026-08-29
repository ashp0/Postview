# Render scheduler: what was wrong, what was not, and what it cost

All numbers below come from two recorded runs on the Mavericks machine
(`Postview-Profile-20260828-215944.tsv`, `Postview-vs-Preview-20260828-221206.tsv`)
plus offline replays of the same workloads against the real policy and cache
code. Where a figure is modelled rather than measured on hardware, it says so.

## The bug

Previews were throttled by the speed policy. Full-resolution renders were not.

`-updateVisibleContent` gated previews on `-worthRenderingDuringScroll:`, which
asks `PVShouldRenderWhileMoving()` whether a page will still be on screen by the
time its bitmap arrives. That path is device-independent by design, and a
comment in the file records it being made so.

The full-resolution branch beside it was gated on `_liveScrolling` and
`_liveZooming` instead. AppKit posts those only for trackpad and wheel gestures.
Every keyboard-driven scroll — Page Down held, an arrow key repeating — therefore
took the unthrottled path for the expensive half of the work, while the cheap
half was correctly suppressed one line above.

The profile shows both halves at once:

| workload | previews suppressed | full renders that went through |
|---|---|---|
| `page` (80 Page Downs at 20/s) | 323 | 90 |
| `scroll` (200 arrows at 50/s) | 47 | 126 |

A healthy-looking suppression rate, and underneath it the costly renders walking
straight past.

## What was not wrong

**Zero suppression on the `read` workload is correct.** `read` is 12 Page Downs
2.5 s apart. `-clipBoundsChanged:` treats a gap of half a second or more as the
end of a scroll and returns the speed to zero, so the policy correctly renders
every page. A reader sitting on a page wants it sharp. Raising that number would
make calm reading blurry for no CPU saving, since idle and read CPU at rest were
already ahead of Preview.

`Tests/pvtest.m` now asserts this in those terms so it does not get "fixed".

**The cache was not uncapped.** It was already a byte-budgeted LRU with pinning,
capped at 32/64/96 MB by RAM tier. The 334 MB peak came from prefetch depth, not
from an absent limit — see below. A count cap of 6–8 full bitmaps, as originally
proposed, would have been *looser* than the byte budget already enforced: a full
page bitmap in the profiling window is ~7.1 Mpx ≈ 27 MB, so eight of them is
216 MB and could not have reached a 120–150 MB target.

**Rendering only the visible band is not a win.** A page is about twice the
height of the viewport, so a whole-page bitmap is amortised across roughly two
scroll positions, while a band is valid for exactly one. Modelled against the
real cache and geometry over the `read` workload:

| approach | renders | megapixels |
|---|---|---|
| whole page, 3 full prefetch (baseline) | 39 | 276.1 |
| whole page, 1 full prefetch (now) | 7 | 49.6 |
| viewport bands (hypothetical) | 17 | 57.6 |

Banding increases the call count, which is the opposite of the strategy. It
would pay at high zoom, where a page is many viewports tall; that is a separate,
larger change to the cache key and the draw path.

## The changes

1. **Full renders and full prefetch now answer to the motion state**, not to the
   input device. `-viewportIsMoving` is the explicit `Scrolling` state: a gesture
   flag, or a *fresh* measurement of real speed. `Settled` is its negation, and
   the existing 150 ms settle timer is what makes the sharp pass arrive promptly.

2. **Full-resolution prefetch depth cut from 3 to 1.** `PVMaxRenderPixels()` is a
   third of the cache budget precisely so that two visible pages plus previews
   fit. That derivation leaves no room for full-resolution prefetch; asking for
   three meant storing one evicted a page still on screen, which was then asked
   for again.

3. **Full prefetch waits for real movement.** `_lastDirection` starts at
   "forwards" because prefetch must guess before there is evidence. Free for
   previews, expensive for full bitmaps: at launch it rasterised a whole extra
   page before the user had scrolled at all.

4. **Bitmaps delivered for pages the viewport has left are dropped** rather than
   stored. Rasterisation itself cannot be interrupted — it is one CoreGraphics
   call — so this is the half of cancellation that is available: never start it,
   and do not keep a result that turns out to be for somewhere the user no
   longer is.

5. **A count cap on full bitmaps** (`PV_MAX_FULL_IMAGES`) beside the byte budget,
   for the small-page-small-zoom case where dozens of bitmaps fit inside the same
   bytes.

## Where the changes are

The first git commit conflates the tree as received with the first round of
scheduler changes, and the pre-change copies were not preserved, so there is no
commit that diffs the original against them. Every change is listed here
instead; commits after the first are separable in the usual way.

| change | location |
|---|---|
| motion state (`Scrolling` / `Settled`) | `Sources/PVWindowController.m:549` `-viewportIsMoving` |
| policy split from accounting | `Sources/PVWindowController.m:511` `-scrollSpeedAge`, `:525` `-pageSurvivesMotion:` |
| full renders gated on motion | `Sources/PVWindowController.m:639` and the loop below it |
| full prefetch gated and capped | `Sources/PVWindowController.m:748` |
| deliveries pruned to the wanted window | `Sources/PVWindowController.m:850` |
| full-bitmap count cap in the LRU | `Sources/PVImageCache.m:193`, `:212` |
| scheduler tunables | `Sources/PVCommon.h:103` onward |
| prefetch waits for movement | `Sources/PVWindowController.h` `_hasMovedViewport` |

## What it cost

Soak test (`make soak`), settled median footprint over 175 document cycles:

| | settled | peak | climb/cycle | result |
|---|---|---|---|---|
| baseline | 344.7 MB | 413.6 MB | +0.90 MB | FAIL |
| after motion gate | 170.6 MB | 200.1 MB | +0.00 MB | pass |
| after prefetch gate | **65.8 MB** | **80.9 MB** | +0.005 MB | pass |

Modelled render reduction on the recorded workloads:

| workload | full-render asks before | after |
|---|---|---|
| `read` | 39 renders / 276 Mpx | 7 renders / 50 Mpx |
| `page` | 160 | 4 |
| `scroll` | 400 | 4 |

Launch rasterisation drops from 5 full + 3 preview bitmaps (22.91 Mpx, recorded)
to 2 full + 3 preview (~10.0 Mpx modelled).

Test suites: pvtest 159, pvuitest 102, soak 19, stress 14, analyzer clean, no
Postview-owned leaks. The baseline had one failing UI test and one failing soak
assertion; both now pass.

## Measuring it on the Mavericks machine

```
./Postview-Showdown.command /path/to/document.pdf
```

One script, both apps, five scenarios, a winner per metric and an overall
verdict. It measures exact CPU seconds from the kernel counter, Energy Impact,
idle wakeups as a delta, peak memory and launch time; it equalises window size,
opens a fresh hardlink per trial so both apps start at page 1, waits for a quiet
machine, and alternates which app goes first so a session-long thermal trend is
not handed to one side. A metric whose run-to-run spread exceeds the gap between
the apps is flagged as noisy rather than being allowed to decide the verdict.

Energy Impact is not reported by every machine. The script probes for it at
startup and says so; the verdict drops a metric neither app reported rather than
scoring it as a zero.

## Tunables

All in `Sources/PVCommon.h`, grouped:

| constant | value | what it controls |
|---|---|---|
| `PV_SETTLE_SECONDS` | 0.15 | debounce before the sharp pass |
| `PV_SPEED_FRESH_SECONDS` | 0.25 | how long a speed measurement counts as "now" |
| `PV_MIN_VISIBLE_SECONDS` | 0.25 | dwell below which a page is not worth rendering |
| `PV_FULL_PREFETCH_PAGES` | 1 | full-resolution neighbours prefetched |
| `PV_MAX_FULL_IMAGES` | 8 | count cap beside the byte budget |
| `PV_PREVIEW_DIVISOR` | 3 | preview is 1/3 linear, 1/9 the pixels |

`make test` fails if `PV_FULL_PREFETCH_PAGES` is raised past what the cache
budget can hold.

## Still open

- **The `read` workload is the one to watch.** It was 6.03 CPU s against
  Preview's 0.84. The modelled reduction is 276 → 50 Mpx, which should bring it
  close, but it is the metric most likely to still be behind. Run the showdown
  before assuming otherwise.
- **Banding at high zoom**, as above.
- **`_expressPage` promotion** raises one render to UTILITY QoS, roughly eight
  times the energy of the same render in the background. It is bounded to one
  page and armed only by a cold event, which is defensible, but it is the one
  place the app deliberately spends energy for latency.
