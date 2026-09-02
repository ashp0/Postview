# Postview

A PDF viewer built for **OS X 10.9 Mavericks**, for machines where Preview
stutters when you scroll.

It does a few things and tries to do them very well: scroll smoothly, remember
where you were, zoom with the trackpad, jump to a page number, and show
thumbnails only when you ask. It is not a Preview replacement — it cannot edit,
annotate, reorder or export. Keep using Preview for that.

---

## Installing on the Mavericks machine

1. AirDrop **`Postview.zip`** across and unzip it.
2. Drag `Postview.app` to `/Applications`.
3. **Right-click the app and choose "Open"**, then confirm.

Step 3 matters. The app is not signed with an Apple Developer ID, so
double-clicking it the first time gives *"can't be opened because it is from an
unidentified developer."* Right-click → Open gives you an "Open anyway" button.
You only have to do this once.

Step 2 matters too, and it is not just tidiness. OS X reads an application's
code out of its file the whole time the application is running, not only while
it launches. Run Postview straight off the USB stick or the unzipped folder on
a mounted image, and every page of code it has not touched yet still has to
come from that disk later. Eject it, unplug it, or drop a newer build on top of
the copy that is running, and the next piece of code the app needs cannot be
read: the kernel stops the process immediately, and there is nothing any
program can do about that from the inside. That is what produced the one crash
report this project has, and Postview now says so at launch and offers to move
itself if it finds it is running from a disk that can go away.

To make it the default PDF viewer (optional): select a PDF in Finder, press
⌘I, change **Open with** to Postview, then click **Change All**. The app
deliberately registers itself as an *alternate* PDF handler, so installing it
does not quietly take the association away from Preview on its own.

## Using it

| | |
|---|---|
| Scroll | trackpad, wheel, space / shift-space, Page Up / Page Down, arrows |
| Zoom | pinch on the trackpad, **⌘+** / **⌘−**, **⌘0** actual size, **⌘1** fit width, **⌘2** fit page |
| | two-finger double tap toggles fit-width and actual size |
| Go to page number | **⌥⌘G** |
| Next / previous page | **⌘↓** / **⌘↑** |
| First / last page | **⌘Home** / **⌘End** |
| Two pages side by side | **⌘3** |
| Show or hide thumbnails | **⌥⌘2**, or the toolbar button |
| Full screen | **⌃⌘F** |
| Open another PDF | drop it anywhere on the window, or **⌘O** |

Which page you are on is in the window title, the way Preview has it, rather
than in a text field in the toolbar. The toolbar is two buttons: thumbnails,
and zoom.

**Two pages side by side** (**⌘3**) is for wide displays, which is where a
single column of one page wastes most of the glass. Pages pair up the way a
book opens — 1 and 2, then 3 and 4 — aligned at their tops, with the last page
of an odd-length document sitting on its own. Fit-width and fit-page fit the
*pair*, so turning it on zooms out rather than making the window wider, and the
title names both pages: *(pages 4-5 of 100)*. **⌘↓** and **⌘↑** turn the whole
spread. The setting is remembered per document alongside the page and the zoom,
so a document you read as a spread reopens as one.

It costs no more battery per page read. A screenful holds about the same number
of pixels either way — the viewport bounds the pixels, not the page count — so
on graphics-heavy documents the spread is roughly half the work per page, and
on text it is about the same. The reasoning is in ENGINEERING.md §11.3, derived
from the measurement in §2.

Zoom in far enough that the pair no longer fits the window and you can scroll
sideways onto one page of it. Postview then renders only the page you are
actually looking at, and stops asking for the other one until you scroll back
— including when it prefetches the next spread. §11.4.

Opening the app from its icon gives you an empty window that waits: drop a PDF
anywhere on it, pick one of the documents you had open recently, or press ⌘O.
It does not open an Open panel at you, and it does not reopen whatever you were
reading last time — Postview opts out of macOS's window restoration, so a launch
is always a clean one. Reading positions are still remembered per file, and come
back when *you* open that file.

The recent list is macOS's own document history, the same one behind Open
Recent, filtered to the files that are still where they were. (On a current
macOS the system will only keep that history for a code-signed app, so an
unsigned build loses its recent list there; on Mavericks there is no such
condition and the list fills up normally either way.)

A release **should** be signed, and Mavericks is not the obstacle. Mavericks
understands Developer ID perfectly well — Gatekeeper has required it since 10.8
— and dyld does not read code signatures at all. What 10.9.5 introduced is the
*version 2* signature format, which means a SHA-256-only signature (the default
from a modern `codesign`) is what it cannot validate. The compatible form is a
dual SHA-1/SHA-256 signature, which is exactly what `make sign` produces:

```
make dist SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

Do **not** enable the hardened runtime for this target: that is a 10.14 feature
and Mavericks' Gatekeeper rejects what it cannot parse. `make dist` will not
package without an identity, because an unsigned release should be a decision
someone typed out rather than one reached by omission.

See [Apple TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)
and [Apple Developer ID](https://developer.apple.com/developer-id/).

Close a document and reopen it later and it returns to the same page, the same
position on that page, the same zoom, and the same window size. That is stored
in `~/Library/Application Support/Postview/DocumentState.plist`, keyed by file
path, for the 400 most recently opened documents.

---

## Why scrolling is smooth

Preview rasterises PDF page content while you scroll. On a complicated page
that takes hundreds of milliseconds, and it happens on the main thread, which is
exactly what a stutter is.

Postview never rasterises during drawing. `-drawRect:` only blits bitmaps that
have already been rendered, so exposing a strip of a page costs a memory copy
rather than a page render. Everything else exists to make sure the right bitmap
is already there:

- **Rendering happens on a background-priority serial queue.** The main thread
  never waits for a page.
- **Two-pass rendering.** A page is first rendered at a third of its linear size
  and stretched over the gap, then replaced by the sharp version, so you see
  something immediately instead of a blank page. The saving is smaller than the
  nine-fold pixel ratio suggests: on a content-heavy page the cost is dominated
  by parsing and executing the content stream, not by filling pixels, so a
  preview measures about a sixth of a full render rather than a ninth. It still
  pays for itself — it is what puts ink on screen at ~115 ms instead of ~370 ms —
  but it is a real extra cost on any page you stop and read, which is why the
  full pass is skipped entirely while a scroll is in flight.
- **Cancellation by desire, not by flag.** Every scroll event recomputes the
  full set of bitmaps currently worth having and hands it to the render queue,
  which replaces its pending set wholesale. Pages you have scrolled past simply
  stop being wanted and are never rendered at all.
- **And nothing is asked for that will arrive too late to be seen.**
  Cancellation only covers work that has not started. During a fast scroll the
  queue is never idle, so every page it picks up is genuinely wanted at the
  instant it starts and stale one render later — flat out it manages about nine
  pages a second, and a hard flick moves sixty. So before asking, the app works
  out how long that page will still be on screen at the current speed, and does
  not ask if the answer is under a quarter of a second. Nothing visible changes:
  what stops being rendered is exactly what was arriving after the page had
  gone, and the moment the scroll stops everything is asked for properly.
- **Shallow prefetch.** One or two pages ahead in the direction of travel, so
  the next page is ready as it arrives. Deeper prefetch buys nothing you can see
  and costs battery.
- **Bitmaps land on exact device pixels.** On-screen page size is rounded to
  whole points first and the bitmap size derived from that, so the common case
  is a 1:1 blit with no resampling.
- **Responsive scrolling is enabled**, letting AppKit pre-draw beyond the
  visible rectangle while the main thread is idle.
- **A byte-budgeted cache** holds full-resolution bitmaps — 32, 64 or 96 MB
  depending on installed RAM, because an 80 MB cache on a 2 GB Mavericks machine
  buys page hits by pushing the system towards swap. The cheap one-third-size
  previews are evicted only after all full bitmaps are gone, which is what makes
  scrolling back over pages you have already visited instant. The budget is
  measured against what CoreGraphics actually allocated, row padding included,
  rather than width × height × 4.
- **The cache is never allowed to throw away a page that is on screen.** It is
  told the visible range before anything is asked for, and eviction steps over
  it. Without that the cache and the layer above disagree about what has to be
  resident, and the disagreement does not settle: with two pages visible whose
  bitmaps do not both fit, storing the second evicted the first, the next draw
  found it missing, the wanted-set asked for it again, and storing it evicted
  the second — the same two heavy pages rasterised for as long as the window
  stayed open, flickering between sharp and soft the whole time. One bitmap is
  also capped at a third of the budget, so what has to be kept stays bounded;
  it used to be capped at *twice* the budget, which is a bitmap the cache could
  not hold under any circumstances.

## What was done for battery life

This machine is old and its battery is tired, so this was treated as a real
constraint rather than an afterthought.

- **Rendering runs at background QoS.** The render queue targets
  `DISPATCH_QUEUE_PRIORITY_BACKGROUND`. On Apple silicon that confines the work
  to efficiency cores at a low clock: measured there, one full-resolution page
  costs about **84 mJ** against **684 mJ** at default priority — the same work
  for roughly an eighth of the energy, in exchange for about 3.8x the wall time.
  That is a real trade and not a free win; the page takes visibly longer to
  sharpen, deliberately. The figures are `task_power_info` readings taken on an
  M4 with the render loop driven at each QoS band in turn.

  **On the 2013 Mac Pro this targets, the mechanism is different and the
  eightfold saving does not transfer.** Its Xeon E5 v2 cores are homogeneous —
  there are no efficiency cores to land on, so the same core does the same work
  at the same frequency and a backgrounded render is not cheaper in joules. What
  the setting buys there is lower scheduling priority, timer coalescing and
  throttled I/O: the render thread stays out of the UI's way, which is worth
  having and is measured as a win, but the energy saving on that machine comes
  from **doing less work** — the motion gate below — rather than from cheaper
  work. Both machines want the same setting for different reasons, and it is
  worth being explicit, because a future change reasoning from "renders are 1/8
  price here" would be reasoning from something untrue of the target.

- **One exception, bounded: the page you are actually waiting on.** Opening a
  document, or jumping to a page nothing is cached for, leaves you looking at a
  blank rectangle, and there the delay is not worth the joules. Exactly one
  page — never prefetch, never during a scroll — is promoted to utility QoS for
  that first paint, via `dispatch_block_create_with_qos_class` (resolved through
  `dlsym`, so 10.9 simply keeps the slow path). It costs about **+1.9 J per
  document opened**, which at a hundred documents a day is under a tenth of a
  percent of a laptop battery, and it takes the first sharp page from ~1.4 s to
  ~0.37 s. The promotion disarms itself the moment that page goes sharp, or the
  moment you start scrolling.

  It also has to actually happen. The queue only promotes when it is the one
  starting the work, and it will not start anything while a worker holds the
  running slot — so an express request that arrived while a prefetched page was
  mid-rasterisation used to be picked up by that ordinary block at background
  QoS and the promotion was quietly lost. Jumping to a page within a second of
  stopping a scroll hit it every time: the same action, two different latencies,
  with nothing visible to say why. The ordinary worker now hands its slot back
  when express work appears, at most once per episode, so a promotion that
  cannot be created costs one extra dispatch rather than bouncing.

- **The largest single saving found by measuring rather than reasoning was a
  scroll nobody was reading.** Driven at a real frame rate on a 1200-page
  document, Postview's own code accounts for **4% of main-thread CPU** during a
  scroll — `-drawRect:` is 0.05 ms a frame and the whole scroll-event path is
  0.012 ms — and the other 96% is AppKit's own display machinery. The cost that
  mattered was on the render thread, and only above a certain speed: at reading
  pace it renders about 0.86 pages per page passed, which is close to the
  minimum, but past roughly seven pages a second the queue saturates a core and
  almost every bitmap it produces is delivered for a page that has already gone.
  Declining to ask for those took a hard flick from **121% of a core to 26%**
  and left reading-pace scrolling completely unchanged.

  **It used to apply to the trackpad and not to the keyboard**, which was not a
  decision anyone made. The test was `if (!_liveScrolling) return YES;`, and
  `_liveScrolling` is set from `NSScrollViewWillStartLiveScroll` — a
  notification AppKit posts for gesture scrolls and not for a held Page Down
  key. So the same motion, at a speed limited only by the key repeat rate, took
  the unthrottled path: a full-resolution bitmap plus three full-resolution
  prefetches for every page it flew past. Which device moved the document says
  nothing about whether its pages can be seen, so the policy no longer asks.
  It is now `PVShouldRenderWhileMoving()`, a pure function of speed, the age of
  that measurement, and how long the page will stay on screen — no AppKit, no
  clock, no device.

  Making it device-independent meant giving it a way to *stop*. A gesture
  announces its own end; a key release announces nothing, and speed is only
  recomputed when the viewport moves, so the last measurement would have sat
  there suppressing renders forever and left the document permanently soft.
  Two things prevent that, and only one of them is allowed to matter.
  `PV_SETTLE_SECONDS` schedules the sharp pass 0.15 s after movement stops,
  which is what makes it feel instant. `PV_SPEED_FRESH_SECONDS` is the one that
  makes it *correct*: past 0.25 s a measurement is disregarded no matter what
  it said, so suppression cannot outlive the evidence for it even if the timer
  is never delivered at all. Rendering is the default and suppression is the
  exception that has to be justified, which is the opposite way round from how
  it was written the first time. `pvsuite unit` sweeps the whole input space and
  asserts that no combination of speed, age and dwell suppresses without fresh
  evidence — including NaN, infinity, and a clock that has moved backwards.

  Getting it *stable* took two more attempts, both of which failed by trying to
  be clever about the threshold. Deriving it from how long renders were
  currently taking made the decision an input to its own measurement — with
  rendering suppressed the estimate went stale, and the stale estimate decided
  whether to keep suppressing — and the same scroll settled at either 26% or
  111% depending on nothing the user could see. Using that measurement only to
  raise a floor removed the loop but not the wobble, because the estimate mixes
  a preview with a full page and those differ by a factor of six, so the
  crossover moved with whichever had been rendered last and consecutive runs at
  one speed came out at 41% and 121%. The threshold is now a constant, because
  the thing being thresholded — how long a page is on screen — is a fact about
  eyes and not about the machine. Three runs at each of eight speeds now land
  within a few points of each other, and the crossover falls exactly where the
  constant says it does: a page visible for 272 ms is rendered, one visible for
  180 ms is not.

- **The wanted-set is not recomputed on every scroll event.** During a live
  scroll the set of bitmaps worth having only actually changes when the visible
  page range or the direction of travel changes. On a slow scroll through
  twenty pages that is **36 rebuilds out of 10,000 scroll events** — the other
  99.6% used to allocate a fresh request set and take the render queue's lock
  at 120 Hz to arrive at an identical answer.

- **`NSSupportsAutomaticGraphicsSwitching`** is set. On a dual-GPU MacBook Pro,
  waking the discrete GPU is one of the largest power draws an app can cause.
  Postview draws with Core Graphics only — no OpenGL, no Core Animation layers —
  so it stays on the integrated GPU.
- **Rendering stops completely when the window is not visible.** The window's
  occlusion state is watched, so covering the window or minimising it suspends
  the render queue rather than letting it work on pages nobody can see.
- **No timers. No polling. No animation loops.** The app is entirely
  event-driven; when you stop interacting with it, it does literally nothing.
  This also lets App Nap throttle it in the background, which it is not opted
  out of.
- **Only cheap previews are rendered during a live scroll.** Full-resolution
  rendering waits until scrolling (including momentum) has stopped, so pages you
  fly past are never rendered at full size.
- **Work in flight is never duplicated.** A page counts as in flight from the
  moment the worker picks it up until its bitmap has been handed over on the
  main thread — not merely until rasterising finishes. Those are different
  instants, one main-queue hop apart, and in between the bitmap exists but the
  cache does not have it yet, so a wanted-set rebuilt in that window used to ask
  for a page that had already been rendered. It matters because scroll events
  arrive 60 times a second and the window is widest exactly when the main thread
  is busiest.
- **The reading position is written to disk rarely** — on close, on quit, and
  when the app is deactivated — never on a timer while you read, and not at all
  when nothing has actually moved since the last write. Without that last part,
  switching away from Postview and back a hundred times in a day is a hundred
  identical plist writes, which on a spinning disk is a hundred spin-ups.
- **Thumbnails cost nothing until requested.** The second PDF handle, its render
  queue, its cache and the sidebar view are all created the first time you open
  the sidebar, and the rendered thumbnails are released when you close it.
- **Memory pressure is handled** through a dispatch source: under pressure the
  full-resolution bitmaps are dropped and the previews kept, so the app shrinks
  instead of pushing the system into swap. Prefetch then stays off until you next
  do something — otherwise the pass that follows the drop asks for the very
  bitmaps that were just released, and a machine that stays under pressure spends
  its time rendering megabytes it is about to be told to drop again.

  The pages actually on screen were still re-requested at full resolution, and
  on a machine that stays tight that is its own loop, because re-filling the
  cache is what causes the kernel's next report. A second report with no user
  action in between now stops asking for full-resolution pages at all: the
  previews are a ninth the size and are kept, so the document stays readable and
  the machine is left alone. Any real action — a scroll, a zoom, a page jump,
  the window coming back into view — puts it back at once.

- **Closing a document actually gives its memory back.** AppKit does not release
  a window that has ever been ordered on screen — it holds it for the life of the
  process, closed or not, ordered out or not, `releasedWhenClosed` either way.
  (Checked against a bare `NSWindow` with none of this app's code near it, on
  every style mask, with tabbing disallowed, after forty seconds of run loop:
  shown windows are simply never deallocated.) A window that cannot be got rid of
  goes on owning its content view, and through it the page view, the bitmap cache
  and the `PVPDFSource` behind them — which now means the document's private
  snapshot of the file and its render helper process as well — so every file ever
  opened would stay resident until you quit, tens of megabytes each. Closing a document
  therefore detaches its whole view tree from the window and drops the toolbar,
  leaving the controller holding the only references, and its `-dealloc` hands
  everything back. Where AppKit does hold the window — which it does on every
  system this was measured on — that is worth about three times the steady-state
  footprint: the soak's median went from ~200 MB to ~60 MB. Where it does not,
  the detach costs nothing and the numbers are unchanged.

- **No window animation.** Same rule as the rest of the app — no timers, no
  polling, no animation loops — applied to the one animation AppKit supplies
  whether you asked or not. It is not cosmetic: the default document-window fade
  is an `NSAnimation` in *blocking* mode, a nested run loop held on a Grand
  Central Dispatch worker thread. Close windows in quick succession and those
  threads park in `-[NSAnimation _runBlocking]` and stay there; because they are
  the global concurrent queue's threads, the background render queue then never
  gets scheduled at all and rendering stops permanently, with no error anywhere.
  Sampling the process during that state showed a dozen worker threads inside
  `_runBlocking` and not one inside a page render. Windows now open and close
  instantly, which on this hardware is the better half of the trade anyway.

- **A page CoreGraphics will not rasterise is asked for three times, then left
  alone** until something changes that could plausibly change the answer: a
  different zoom, a different display, the window coming back into view. A failed
  render never reaches the cache, so nothing else would ever stop the wanted-set
  naming that page again on the next scroll event — one bad page in a document
  left open overnight is a background thread rasterising nothing, forever.

---

## Postview versus Preview

Postview exists for one workload — reading a long PDF on a Mavericks-era Mac —
and it is built around one idea: **most of the pixels a PDF viewer rasterises
are never looked at.** Pages that fly past during a scroll, pages prefetched in
a direction the reader turned out not to go, the same page re-rendered because
something else evicted it. Postview's scheduler declines that work. Everything
below follows from it.

The priorities, in order, and they are not equally weighted: **battery life
first, then responsiveness, then memory.** Where those conflict, the earlier one
wins, and the sections below say where they conflicted.

### Where each one wins

| | Postview | Preview |
|---|---|---|
| Work refused during motion | asks for **zero** full-resolution bitmaps while the document moves | renders what is in front of it |
| Rasterisation priority | background QoS, off the UI's path | default priority |
| Memory ceiling | hard byte budget, ~96 MB of bitmaps, invariant asserted per RAM tier | no stated ceiling; in practice **lower than Postview's** |
| Peak memory | **loses in all five scenarios** | wins |
| Reading a PDF | that is all it does | does it too |
| Text selection, search, copy | none | yes |
| Annotation, Markup, signatures, forms | none | yes |
| Editing pages, export, other formats | none | yes |
| Encrypted PDFs | refuses, with a message pointing at Preview | opens them |
| Printing | none | yes |
| Code signature, sandbox, Quick Look | none | yes |
| Reports what it rasterised | full census (`-PVStats YES`) | cannot be asked |

The headline is the first row and the fourth, and they point opposite ways.
Postview refuses work Preview does — that is the reason it exists. Preview does
a dozen things Postview does not do at all, and it does them in less memory.

### What Postview does better, and how

**It does not render what you cannot see.** This is the whole design, and it is
the only one of these that is a genuine architectural difference rather than a
tuning choice. During any motion — trackpad, wheel, held Page Down, arrow
repeat — the scheduler asks for cheap previews (1/9 the pixels) and *no*
full-resolution bitmaps at all. It is two independent layers, either sufficient
on its own: an outer motion gate, and a per-page dwell test that asks whether a
page will still be on screen when its render could finish.

One exception, deliberate and measured: the *first* event of a keyboard scroll.
A gesture announces itself before it begins, so its very first event is already
known to be a scroll; a key press is not announced, and the first one is
indistinguishable from a single deliberate Page Down — which is the case
`read` is made of, and where a sharp page is the entire point. So the first one
renders, at a cost of one wanted-set rebuild per scroll episode (per episode,
not per key). The UI suite pins that at ≤ 2 full requests for the keyboard and
exactly 0 for the trackpad, so the difference cannot drift without a test
failing.

Getting this device-independent was the largest single correction in the
project. The gate used to be `if (!_liveScrolling)`, which is a question about
*which input device* moved the document — AppKit posts that notification for
gestures and not for a held key. So the trackpad was throttled and the keyboard
was not, and a held Page Down took the unthrottled path: a full-resolution
bitmap plus prefetches for every page it flew past. Replaying the recorded
workloads through the scheduler, full-resolution render *requests* model out at
39 → 7 (`read`), 160 → 4 (`page`) and 400 → 4 (`scroll`). Those are
Postview-against-Postview and come from its own census, so they are unaffected
by the harness caveat further down; the zero-during-motion property underneath
them is asserted directly by the UI suite against a real window controller.

**It renders out of the UI's way.** The render queue targets
`DISPATCH_QUEUE_PRIORITY_BACKGROUND`. On Apple silicon that is also a large
energy saving because the work lands on efficiency cores; on the 2013 Mac Pro
this actually targets it is not, because those cores are homogeneous — there it
buys scheduling priority, timer coalescing and throttled I/O, and the energy win
comes from the motion gate doing less work rather than from cheaper work. Worth
stating plainly, because the two machines have different reasons for the same
correct setting.

**It bounds what it holds, and says so in code.** The page cache is byte-budgeted
and evicts to a budget that scales with installed RAM; visible pages are pinned
so a page on screen cannot be evicted by another page the same pass wants;
undelivered bitmaps — rasterised but not yet handed to the main thread, where no
cache budget can see them — are capped at two. The invariant that two
full-resolution pages plus five previews must fit the eviction budget is
asserted by the unit suite on every RAM tier, not left to whoever next edits a
constant.

**It opens straight to a window and does not restore your last session.** Launch
is a window with your document in it; there is no Open panel and no reopening of
whatever you were reading last time. Reading positions are still remembered
per file and come back when you open that file.

**It can be asked what it did.** With `-PVStats YES` it reports full renders,
previews, megapixels, requests suppressed by each gate separately, and the
high-water mark of resident rendered bytes. That is how every claim here was
checked, and it is why the memory loss below is stated as a number rather than
as an impression. Preview has no equivalent, which is a limit of the method
rather than a result.

### Where Postview loses

**Memory, in every scenario, and it is the one metric that has never gone the
right way.** Against Preview's peak RSS the recorded gaps were +33 MB
(`launch`), +26 MB (`idle`), **+120 MB (`read`)**, +77 MB (`page`) and +50 MB
(`scroll`). Mean RSS loses by about the same margin, so this is a sustained
level and not a spike. The unit of the problem is one full-page bitmap: ~7
megapixels, ~28 MB at 4 bytes per pixel, and every gap above is close to a whole
number of them.

Those five figures come from the same run as the CPU figures below, so they
carry the same caveat — but they are much the least sensitive to it. A page
bitmap's size is set by the page geometry and the window, both of which the
harness equalises, and not by how complicated the page is; a 59× more expensive
page is not one byte larger. The gaps are also corroborated from inside the
process, by Postview's own resident-bytes census, which never involves Preview.
The direction is not in doubt. The exact megabytes should be re-taken with the
rest.

Two of the four contributors have been fixed (the undelivered-bitmap cap, and
making the delivery keep-window directional so the page *behind* a moving
viewport no longer keeps a 28 MB bitmap nobody asked for). Together they are
worth roughly half of the `read` gap. The rest is the cache sitting at its
budget, and cutting the budget is not available as a fix without either
rendering every page soft or rendering pages in bands — see
`ENGINEERING.md` §4.1 and §7.

**It is not a PDF application; it is a PDF reader.** No text selection, no copy,
no search, no printing, no annotation, no page editing, no export, no other file
formats, no encrypted PDFs. For a great many people "no search" alone
disqualifies it. Preview is the right tool for all of that and Postview says so
when it declines a file.

**One page is rasterised at a time, on one thread.** `CGContextDrawPDFPage`
interprets a sequential program and cannot be split, resumed or cancelled, and
the render queue is deliberately serial to bound resident bytes. On a
vector-heavy page — measured at **657 ms** against **11 ms** for a text page of
*identical pixel dimensions*, a factor of **59** — you wait, while the Mac Pro's
other 7 to 23 hardware threads do nothing. Preview is not obviously better at
this, but nothing in Postview's design attacks it yet.

(`make band`, on the development host, running the shipping x86_64 binary under
Rosetta. The *ratio* is what transfers and it holds within 0.03 on native arm64
as well; the absolute milliseconds do not — a 2013 Xeon is slower than
Rosetta-translated code on Apple silicon, so 657 ms is a lower bound for the
target and the real figure is likely higher.)

**The latency mechanism does not run on the target machine.** The express lane
promotes exactly one page — the one you are waiting on — to a higher QoS, via
`dispatch_block_create_with_qos_class`. That API is 10.10+. On Mavericks the
`dlsym` returns NULL and an express request gets *ordering* priority only — it
is picked first, but it is not scheduled any faster. The one mechanism the app
has for "get this page in front of the user sooner" is inert on the machine this
targets. It works on 10.10 and later, so it is not dead code; it is simply not
collected where it matters most. The consolation is that its cost is not paid
there either.

**Every render budget is denominated in pixels or bytes, and is being used as a
proxy for time.** `PV_MIN_VISIBLE_SECONDS` suppresses renders a text page could
afford twenty times over, and admits a 657 ms vector render into a 250 ms
window. One constant, two wrong answers, because the quantity it stands in for
varies by 59× across documents. A measured cost model would fix it and has not
been built.

**It is unsigned, unsandboxed and not a system app.** Gatekeeper needs a
right-click → Open the first time. It deliberately registers as an *alternate*
PDF handler so installing it does not take the association away from Preview.

### The state of the head-to-head numbers

**The recorded Postview-vs-Preview measurements should not be quoted, and the
comparison needs re-running.** The harness staged each trial as a hard link to
the PDF so that neither app would recognise the file and restore a saved reading
position. A hard link is the same inode — the same file under a second name.
Postview keys its saved position on the *path*, so it was fooled and started at
page 1. Preview keys on the document's identity and was not fooled: it reopened
at whatever page it had last been left on.

The evidence is in the recorded TSV, in the `launch` scenario, which sends no
input at all: Preview's window title reads *page 1,174 of 1,263* while
Postview's reads *page 1 of 1263*. The two apps were rasterising different parts
of a 1,263-page book — and the cost of a page varies by up to 59× with its
content at identical pixel counts. Whichever way that error pointed, it is
larger than the effect being measured.

A second, independent unfairness sits beside it: in the `scroll` scenario the
same 200 keystrokes moved Preview 48 pages and Postview 7, so those CPU figures
are per-keypress rather than per-page.

Both are fixed, and both are now checked rather than assumed:

- trials are staged as **copies**, which have their own inode and their own
  document identity;
- the harness reads each app's own window title after it opens and records the
  starting page in the TSV, and a trial that did not start on page 1 is
  disqualified;
- travel distance is recorded per trial, and a scenario where one app moved more
  than twice as far as the other is flagged;
- if either check fails, the script prints **NO VERDICT** and refuses to name a
  winner, rather than averaging a contaminated run into a confident-looking
  number;
- the self-test covers all of it, including a case that asserts a hard link and
  a copy differ in exactly the way the bug depended on.

The check matters more than the copy. Inode identity is the mechanism that fits
the evidence, but Preview is a closed application and it is not this project's
place to be certain how it decides that two files are the same document — if it
turns out to key on content, or on Spotlight metadata, a copy will not help
either. What does help, whatever the mechanism, is that the harness no longer
*assumes* the reset worked: it asks each app what page it is on and refuses to
score the run if the answer is wrong. That is the part to keep.

The architectural claims in this README do not rest on that harness. They are
asserted by `make verify-all` — a static-analysis pass, 319 unit checks, 140 UI
checks that drive a real window controller, a 150-cycle soak, a stress suite
under ASan/UBSan and TSan, and a leak census — all of which run on any Mac and
none of which involve Preview.

The *comparative* claims do rest on it. The showdown ran on the Mavericks
machine on 2026-08-31 and **refused to name a winner**: two fairness checks
failed, one a real defect in Postview's arrow-key scrolling and one a limit of
the travel instrument itself. Both are fixed and neither has been re-measured,
so the honest statement remains that the comparative claims are unmeasured.
`ENGINEERING.md` §9 is the full account.

---

## Is it actually faster than Preview?

**Start here: `Postview-Showdown.command`.** One command, both apps, seven
workloads, and a winner named per metric — when the run earns one. It checks
first that both apps were asked the same question, and says so instead of
scoring when they were not:

```
./Postview-Showdown.command ~/Documents/something.pdf
```

Check the instruments first — it takes two seconds and has caught a silently
broken sampler before:

```
./Postview-Showdown.command --selftest ~/Documents/something.pdf
```

It measures the three things that actually drain a battery — exact CPU seconds
from the kernel's own counter, Mavericks' Energy Impact figure, and idle wakeups
as a delta — plus peak memory and launch time, across `launch`, `idle`, `read`,
`page`, `scroll`, `swipe` and `wheel` — the last two synthesised as real
trackpad and mouse-wheel events, because those take a different path through
AppKit than the keyboard does. It equalises both windows to the same size, opens a fresh
**copy** of the document per trial so neither app restores a page position,
waits for a quiet machine, and alternates which app goes first so a
session-long thermal trend is not handed to one side. A metric whose
run-to-run spread is wider than the gap between the apps is flagged as noisy
instead of being allowed to decide anything.

**It also checks that the two apps were asked the same question, and refuses to
declare a winner when they were not.** Both apps' starting and ending page are
read out of their own window titles and recorded per trial. A trial that did not
begin on page 1 is disqualified; a scenario where one app travelled more than
twice as far as the other is flagged; and if either happens the script prints
`NO VERDICT` with the reason instead of a scoreboard. This is not hypothetical
tidiness — it is there because a staging bug let Preview resume at page 1,174 of
a 1,263-page book while Postview started at page 1, and every metric in the run
was silently a comparison of two different workloads. See *The state of the
head-to-head numbers* above.

It also reports what Postview itself rasterised — full renders, previews,
megapixels, suppressed requests — beside the figures from before the render
scheduler work, so you can see not just that a number moved but why.

Quit both apps first and enable Terminal in **System Preferences → Security &
Privacy → Privacy → Accessibility**. `RUNS=5 MIN_IDLE=85 WIN_W=1200 WIN_H=800`
override the defaults. Roughly half an hour at the defaults.

One thing it will tell you that looks wrong and is not: the `read` workload
reports **zero suppressed requests**. That is correct. `read` presses Page Down
every 2.5 seconds, which leaves the document at rest between presses, and a page
someone is sitting and reading should be sharp. Suppression is for pages flying
past, and `page` and `scroll` are where it shows up. See `ENGINEERING.md`.

`scroll` used to report zero as well, and *that* was wrong — not in the app, in
the counter. Suppression happens in two places: a per-page dwell test, and an
outer motion gate. Only the dwell test was counted, and the motion gate is an
outer branch, so when it closed, the arm containing the counter was skipped
entirely. At scroll speeds a page is on screen for about 0.76 s, comfortably
past the dwell threshold, so nothing was dwell-suppressed and the gate doing all
of the actual work got no credit for any of it. The two are now reported as
separate columns plus a total, rather than the older column quietly changing
meaning — runs recorded against `requests_suppressed` go back to the first
profile and it still counts exactly what it always counted.

### The older, narrower tools


`Postview.zip` includes **`Postview-Benchmark.command`**, which measures both
apps on the Mavericks machine rather than asking you to take anyone's word for
it. Copy it next to `Postview.app`, then in Terminal:

```
./Postview-Benchmark.command ~/Documents/something.pdf
```

It alternates runs of Preview and Postview on the same document and reports
launch-to-window time, CPU seconds consumed, and peak memory — each as a median
**and the full range across runs** — writing a TSV alongside so you can check
the numbers yourself. Quit both apps first, enable Terminal in **System
Preferences → Security & Privacy → Privacy → Accessibility** (it drives Page
Down through System Events), and leave the Mac alone while it runs.
`RUNS=7 PAGEDOWNS=120 MIN_IDLE=85 WARMUP=1` overrides the defaults.

**It reports a range, and refuses to call a metric whose ranges overlap.** That
is not hedging; it is what the measurements turned out to require. Five sessions
of the identical workload, minutes apart on one machine, put Postview's mean CPU
anywhere between 39% and 106% and Preview's between 37% and 112% — a spread
several times larger than the gap between the two apps, and large enough that
consecutive sessions disagreed about which app used less CPU. A median of five
runs hid all of that behind one confident-looking number. Three causes, all now
controlled for:

- **Every run started on a different page.** Both apps remember where you were,
  keyed by file path, so run 2 resumed where run 1 stopped and paged through a
  later part of the document. Once a run resumed at the *end* of the document,
  Page Down moved nothing and the app was measured doing nothing at all. Each
  trial now opens its own *copy* of the PDF, at a path neither app has seen, and
  reads back the page each app actually opened on — a trial that did not start
  at page 1 is refused rather than averaged in. (A hard link is not enough: it
  is the same inode, so Preview, which keys on document identity rather than
  path, restores the position it saved last time. See §"the comparison needs
  re-running" above.) None of this reads or writes either app's preferences.
- **Nothing checked whether the machine was busy.** The worst session had *both*
  apps near 105% because something else was running. Each trial now waits for
  the machine to go quiet and records the idle figure it started with, so a
  contaminated trial is visible in the TSV instead of being folded into a median.
- **Sampled `ps %cpu` decided everything.** It is a decaying estimate that needs
  a second or two to catch up, measured over a window that begins at a different
  point in each app's startup — and Postview reaches its window in 0.6 s where
  Preview takes 1.1 s, so the two windows do not open at comparable moments.
  The primary CPU metric is now exact CPU-seconds differenced from the kernel's
  own counter. Sampled mean and peak are still reported, because burstiness is
  worth seeing, but they no longer decide anything.

### Where the battery goes: `Postview-Profile.command`

The benchmark answers *is Postview better than Preview*. It does not answer
*what is Postview spending energy on*, and the two need different measurements.

```
./Postview-Profile.command ~/Documents/something.pdf
```

Five scenarios instead of one — `launch`, `idle`, `read` (a page every 2.5 s),
`page` (the benchmark's 80 Page Downs at ~17/s), `scroll` — because a burst of
frantic paging is not what a reader does, and the case that dominates a PDF
viewer's actual battery draw was never measured at all. **`idle` is the number
to read first:** a document open with nobody touching it is where a reader
spends nearly all of its wall-clock life, and a difference there outweighs
anything the paging scenarios show.

It reports **CPU-seconds, not percent**. Percent is a rate and energy is an
integral, and the distinction is not pedantic here: rendering at background QoS
is slower in wall time and cheaper in joules, so a higher momentary percentage
over a shorter burst can be less total work. A benchmark that reports percent
alone penalises the app's single largest battery optimisation for working.

It also **sets both windows to the same size** before any workload runs, and
records the size each app actually took, because otherwise the two are
rasterising different pixel counts and the comparison quietly measures that
instead of the renderers.

And it **asks the app**. With `-PVStats YES`, Postview reports on termination
how many bitmaps it produced, how many megapixels that was, and how many
requests the throttle declined:

```
defaults write com.postview.Postview PVStats -bool YES
defaults write com.postview.Postview PVStatsPath /tmp/s.txt
open -n -a Postview.app doc.pdf
# ...and afterwards:
defaults delete com.postview.Postview PVStats
defaults delete com.postview.Postview PVStatsPath
```

Not `open --args`: Mavericks' `open` has no such flag and reads what follows it
as further filenames, so the census silently never switches on and every
internal-render column comes out blank. `defaults write` reaches the same
`NSUserDefaults` on every version. Running the executable directly instead
picks up `POSTVIEW_STATS=1` from the environment.

Off in every normal run — the counters cost one guarded add per rendered page
and exist so a profile can attribute work, not so the app carries a profiler.
CPU-seconds say a scenario cost something; these say whether it went on pages
someone looked at, on prefetch nobody reached, or on the same page rendered
five times because the cache could not keep it. Preview cannot be asked, so
those columns are blank for it, which is a limit of the method and not a result.

One thing neither tool equalises: each app picks its own default zoom, so
they may not be rasterising the same pixel count per page. That is a real
difference between the apps as shipped, but it means this is not a like-for-like
rendering benchmark, and the summary says so rather than implying otherwise. It
also says nothing about rendering quality, and a PDF that is unusual for one
engine and ordinary for the other will say so — which is the point of running it
on your own files.

**If you have a TSV from an older `Postview-Profile.command`, its `run` column
is wrong and its `RUNS` setting was ignored.** `sample_process()` read its two
figures into variables called `c` and `r`, and `r` was also the run counter of
the loop driving the whole script — shell functions have no locals, so the first
sample of the first trial overwrote it with a resident-set size in kilobytes.
That is why the `run` column in those files contains numbers like `139704`. The
same overwrite then made `while [ "$r" -le "$RUNS" ]` compare ~150000 against
`RUNS`, so the loop ended after one pass: every one of those profiles is a
single unrepeated trial per scenario, with no spread to check it against. Fixed;
the variables are prefixed now. Re-take any profile you were relying on.

## Building

Requires a Mac with Xcode command line tools. It cross-compiles; you do not
need a Mavericks machine to build it.

```
make            # build Postview.app
make verify     # confirm the binary is Mavericks-loadable
make test       # headless checks of layout, cache, render queue, persistence
make uitest     # drive a real window; toolbar, gestures, drag-and-drop, screenshots
make soak       # repeat the whole document lifecycle and assert nothing accumulates
make stress     # the same objects under contention: every event, queue busy
make power      # what all of it costs: CPU, processor wakeups, battery draw
make leakcheck  # the soak loop under `leaks`
make verify-all # every gate above, in order
make dist       # produce Postview.zip for AirDrop
```

Every one of those runs the same program, `Tests/pvsuite.m`, with a different
subcommand — `pvsuite unit`, `ui`, `soak`, `stress`, `band`, `power` — and the
Makefile target is the fixtures and the environment each needs. `pvsuite all
<pdf> <outdir>` runs the four that gate without needing anything special of
their environment.

Three more are adversarial, and they are deliberately **not** in `verify-all`:

```
make fuzz           # malformed documents: truncated, mutated, synthesised
make helperkill     # SIGKILL the render helper mid-render; does the viewer recover?
make helperprotocol # a helper that LIES; does the viewer believe it?
make statecontend   # 32 Postviews quitting at once onto one state file
```

Each is its own small program (`Tests/pvfuzz.m`, `Tests/pvhelperkill.m`,
`Tests/pvstatecontend.m`) rather than another `pvsuite` subcommand, because each
does something a gate should not: `fuzz` is a *search* rather than an assertion,
and reading a search's silence as a guarantee is exactly the mistake putting it
in a release gate would invite. `helperkill` sends real signals and
`statecontend` forks thirty-two processes; neither belongs in something a
developer runs expecting one clean answer.

They exist because all four test claims this project makes and nothing checked.
`PVPDFSource.h` argues that parsing happens out of process so a hostile document
kills the helper and not the viewer — but the suite only ever fed it *valid*
documents. `PVStateStore` merges rather than overwrites so two copies of
Postview cannot clobber each other's positions — but the merge was only ever
exercised in one process. And the whole `PVRenderFailure` distinction exists so
that a page which lost its helper is retried rather than retired — but nothing
ever killed a helper to find out. And the split is justified by the helper being
where hostile bytes are interpreted — which makes the helper the process most
likely to be subverted, and everything it says back untrusted input — but
nothing ever put a *lying* helper where the real one goes.

What they report, on this host: no crash, no hang, no untyped failure and no
leaked helper across ~6,000 malformed documents; every entry surviving 32
simultaneous quits; recovery from a killed helper costing exactly one failed
render, never a page wrongly blamed; and twelve kinds of protocol lie answered
with a refused open or a typed failure, never with a bitmap the viewer had no
reason to trust.

Between them `make test` and `make uitest` pin the awkward cases directly rather
than by inference: that a page already rendered and waiting to be delivered is
not rendered a second time; that a render CoreGraphics refuses is reported and
then stops being asked for; that memory pressure leaves the cache smaller rather
than immediately refilling it, and that a second report while the machine is
still tight does not start a render loop; that the cache reaches a steady state
instead of evicting one visible page to make room for another; that a page
flying past faster than it can be seen is not rasterised, and that the decision
has one crossover rather than flipping about; that a thumbnail arriving after the
sidebar closed is discarded; that the window title is right from the instant the
window exists, whenever AppKit chooses to build the toolbar; and that a state
file full of the wrong types loads without taking the app down. Each of those was
written by first reverting the fix and watching the test fail. `make uitest` also
pins the window invariant directly: after a document is closed and its controller
released, the page view, its cache and its `PVPDFSource` must all be gone
*while AppKit is still holding the window*, and with the source its render
helper process: `make soak` counts the surviving children directly.

`make soak` is the long-uptime check. It runs the full open / lay out / scroll /
zoom / thumbnails / jump / close cycle over and over, then asserts that every
one of Postview's long-lived classes is back to a live count of **zero**. That
census is the real invariant; process footprint is only reported alongside it,
because the allocator's sawtooth and the frameworks' own caches swing it by tens
of megabytes across a run that is genuinely flat. The trend is measured over the
*last* half of the run rather than across all of it, because the frameworks
filling their own caches is a fixed cost paid once and looks exactly like a slow
leak while it is being paid: a 400-cycle run climbs 169 → 180 → 197 MB and then
holds flat to within a megabyte, which reads as +0.06 MB/cycle measured at the
end and +0.26 measured across the first 150.

`make stress` is the contention check, and the one that answers a question the
soak cannot. The soak proves a document cycle leaves nothing behind; it does not
prove the cycle is safe while the render queue is actually busy, because every
interesting window in this app is microseconds wide and opens only mid-render: a
wanted-set replaced while a page is rasterising, memory pressure landing between
a render finishing and its delivery, an occlusion change suspending the queue
with work in flight, a window closed with several pages rendered and none
delivered. It fires those at a live controller as fast as the run loop will
carry them. It is meant to be run under a sanitizer, which is what it was
written for:

```
make stress SAN="-fsanitize=thread"
make stress SAN="-fsanitize=address,undefined"
```

Both are clean, as are the soak and the UI tests under the same flags. (A
sanitizer build overrides the architecture to the host's own; the shipping
binary is still built by plain `make` with the Mavericks flags.) The static
analyser is clean too, with the core, osx, deadcode and nullability checkers —
helped by `CF_RETURNS_RETAINED` on the one method that hands out a `CGImageRef`,
which turns a comment about ownership into something that gets checked across
the three files that bitmap travels through. It runs over `Sources/` and not
over the test suite, which is a narrower claim than this paragraph used to make:
`make analyze` has only ever walked `Sources/*.m`, and the suite has a
nullability report in it that comes from deliberately handing a controller
arguments no caller would.

`make power` is the newest gate and the one that closes the largest hole: until
it existed, nothing in this tree measured what any of the rest of it COST. Every
other check above asks whether Postview does the right thing. A build that had
doubled its CPU per page, or that woke the processor a thousand times a second
while displaying a page nobody was touching, passed all of them.

It asserts on ratios and on zeroes and reports the seconds, because a ratio
measured back to back on one machine is a property of the code while seconds are
a property of the machine — and the machine that decides is a Mac Pro from 2013,
which is not the one you are building on. So it gates that an idle document
costs approximately no CPU and approximately no processor wakeups; that
rasterisation is charged to the render helper and not to the viewer; that
Postview's own cost census agrees with the kernel's account of the same
renders; that the mains policy asks for full-resolution bitmaps during motion
and the battery policy asks for none; that both policies nevertheless end up
rasterising the same pixels, because the motion gate defers work rather than
dropping it; and that no render helper is left running when it finishes. Where
the machine has a battery it also reads instantaneous amperage and voltage
straight out of the IO registry and reports the real draw in watts.

`make leakcheck` runs the soak loop under `leaks`. **No object Postview
allocates appears in it.** Postview does appear, but only as allocation *stack
frames* — `-[PVWindowController buildInterface]` and friends, as the code that
happened to ask AppKit for something AppKit then never freed.

What is reported is Apple's, and it is all per-window: a handful of
`_NSDisplayLink` and `ViewGraphDisplayLink` objects for each window, plus the
sets and arrays they hang on to, and a few `NSXPCConnection` cycles inside the
AppIntents framework at a little over 6 KB each. About 60 KB across a 25-cycle
run, or a couple of kilobytes per document opened. It is the same fact as the
one below about windows never being released: a window AppKit keeps forever
keeps its display links with it, and nothing this app can do reaches them. At a
hundred documents a day it is well under a megabyte, and it is bounded by how
many documents you open rather than by how long the app has been running.

Two things make targeting 10.9 from a current toolchain safe:

- `-mmacosx-version-min=10.9` makes the linker emit `LC_VERSION_MIN_MACOSX`.
  Mavericks' dyld does not understand the newer `LC_BUILD_VERSION`, and would
  refuse to load a binary that used it. `make verify` asserts this after every
  build, and also rejects chained fixups and any unexpected linked library.
- `-Werror=unguarded-availability` turns the use of *any* API newer than 10.9
  into a compile error. This is the real safety net: it is not possible to
  accidentally call something Mavericks does not have.

The app is written in Objective-C with manual retain/release. That is not
nostalgia — ARC below 10.11 needs `libarclite`, which current Xcode versions no
longer ship.

Built `x86_64` only, with `-march=core2`: Mavericks runs on Macs old enough to
predate SSE4.1, and the default x86_64 baseline would emit instructions those
machines cannot execute.

The toolbar has to survive a large span of AppKit, and the way it now does that
is by having almost nothing in it. It was five items: two controls, a page-number
field, and a pair of flexible spaces with an inert counterweight to balance them,
all of it there to hold the field in the middle of the window across a decade of
AppKit — including `-setCenteredItemIdentifier:`, sent by `-respondsToSelector:`
so the 10.9 deployment target stayed honest, because from Big Sur onwards the
title and toolbar share one row and the leading region is reserved for the title.

The page number is in the window title now, where the system centres it for free
and it does not have to look like a control. That left two buttons, drawn from
the bundled PDF artwork rather than from `−` and `+` text, and nothing to arrange
them with. Where they end up is the system's decision and differs by release:
10.9 packs them from the left with the title on its own row, and macOS 11 and
later lay them out trailing. Both are that release's own convention. Measured
before deciding — a trailing flexible space moves them from x=788 to x=780 in a
900-point window on macOS 26, and the only setting that forces them leading also
takes the document title out of the title bar.

The widths come from `-sizeToFit`, not from constants. The zoom control used to
be pinned to 74 points for two 36-point segments, which left nothing for the
bezel and clipped the outer edge off both magnifiers — visible in the shipped
build on Mavericks. `make uitest` checks, on the live toolbar at 700, 900 and
1900 pt wide, that both controls are wholly inside the window, share a height and
a baseline, and are not clipped by the item holding them.

Pinch-to-zoom needed both of AppKit's gesture eras. Recognising the gesture is
`-magnifyWithEvent:`; knowing when it has *finished* is the part that differs.
10.7 added `-[NSEvent phase]` and current systems report `NSEventPhaseEnded` on
the last event, but Mavericks does not populate phase for gesture events at all
and signals the end with `-endGestureWithEvent:`, which later systems deprecated
and no longer send. Listening for only one of the two leaves the gesture
permanently open on exactly the system this app is built for, so both are
handled and the second end is ignored.

## Deliberately not included

No text selection, no copy, no search, no printing, no annotation, no page
editing, no encrypted PDFs. A password-protected file reports a clear message
telling you to open it in Preview instead. Each of those would have added
surface area to a viewer whose entire point is being fast and frugal.
