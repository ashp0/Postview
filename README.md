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
| Show or hide thumbnails | **⌥⌘2**, or the toolbar button |
| Full screen | **⌃⌘F** |
| Open another PDF | drop it anywhere on the window, or **⌘O** |

Which page you are on is in the window title, the way Preview has it, rather
than in a text field in the toolbar. The toolbar is two buttons: thumbnails,
and zoom.

Opening the app from its icon gives you an empty window that waits: drop a PDF
anywhere on it, pick one of the documents you had open recently, or press ⌘O.
It does not open an Open panel at you, and it does not reopen whatever you were
reading last time — Postview opts out of macOS's window restoration, so a launch
is always a clean one. Reading positions are still remembered per file, and come
back when *you* open that file.

The recent list is macOS's own document history, the same one behind Open
Recent, filtered to the files that are still where they were. (On a current
macOS the system will only keep that history for a code-signed app, and this one
deliberately is not signed — a modern signature is one of the things Mavericks'
dyld cannot read. On Mavericks itself there is no such condition and the list
fills up normally.)

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

- **Rendering runs at background QoS, and that is the single biggest saving
  here.** The render queue targets `DISPATCH_QUEUE_PRIORITY_BACKGROUND`, which
  confines the work to efficiency cores at a low clock. Measured on this
  hardware, one full-resolution page costs about **84 mJ** there against
  **684 mJ** at default priority — the same work for roughly an eighth of the
  energy, in exchange for about 3.8x the wall time. It is worth knowing that
  this is a real trade and not a free win: the page takes visibly longer to
  sharpen, and that is deliberate. The figures are `task_power_info` readings
  taken on an M4 with the render loop driven at each QoS band in turn; they will
  differ in magnitude on the Mavericks-era hardware this targets, but the
  direction is a property of how the scheduler places the work, not of the chip.

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
  it was written the first time. `pvtest` sweeps the whole input space and
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
  and the parsed `CGPDFDocument` behind them — so every file ever opened would
  stay resident until you quit, tens of megabytes each. Closing a document
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

## Is it actually faster than Preview?

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
  trial now opens its own hardlink to the PDF, at a path neither app has seen,
  so every run starts at page 1 in the default view — without the benchmark
  reading or writing either app's preferences.
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
POSTVIEW_STATS=1 open -n -a Postview.app doc.pdf --args -PVStatsPath /tmp/s.txt
```

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
make leakcheck  # the soak loop under `leaks`
make dist       # produce Postview.zip for AirDrop
```

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
released, the page view, its cache and its `CGPDFDocument` must all be gone
*while AppKit is still holding the window*.

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
analyser is clean too, over sources and tests, with the core, osx, deadcode and
nullability checkers — helped by `CF_RETURNS_RETAINED` on the one method that
hands out a `CGImageRef`, which turns a comment about ownership into something
that gets checked across the three files that bitmap travels through.

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
