//  PVCommon.h — shared constants and small value types.
//  Postview: a PDF viewer for OS X 10.9 Mavericks.

#import <Cocoa/Cocoa.h>

#define PV_EDGE_GAP          14.0   // margin around the page column
#define PV_PAGE_GAP          12.0   // vertical gap between pages
#define PV_MIN_ZOOM          0.10
#define PV_MAX_ZOOM          6.00
#define PV_PREVIEW_DIVISOR   3.0    // preview pass renders 1/3 linear size (9x fewer pixels)
#define PV_MAX_PIXELS        (36000000.0)  // hard ceiling on one rendered bitmap

// A page that will be on screen for less time than this, during a scroll, is
// not worth rasterising: the bitmap cannot be finished and delivered before
// the page has gone, so the work is spent on pixels nobody ever sees. A
// quarter of a second is roughly where a glimpse becomes a look, and it is
// well above what any machine needs to blit an image it already has.
//
// A constant, and deliberately not derived from how long renders are currently
// taking. Two attempts at deriving it both failed the same way. Feeding the
// measurement straight in made the decision an input to its own measurement:
// suppressing renders left the estimate stale, and the stale estimate decided
// whether to keep suppressing, so the same scroll settled at either 26% or
// 111% of a core depending on nothing the user could see. Using it only to
// raise a floor fixed the loop but not the wobble -- the estimate mixes two
// populations, because a preview costs about a sixth of a full page and which
// one was rendered last depends on whether you have just stopped scrolling, so
// the crossover moved by a factor of six and the same scroll speed came out at
// 41% or 121% on consecutive runs.
//
// The quantity being thresholded is how long a page is on screen, which is a
// fact about eyes rather than about the machine. A quarter of a second is where
// a glimpse becomes a look on any hardware, so it is written down once.
#define PV_MIN_VISIBLE_SECONDS  0.25

// Below this the document is not moving in any sense worth acting on. A speed
// of zero is the resting state; the small floor keeps a sub-pixel drift from
// being read as travel.
#define PV_MIN_SCROLL_SPEED     1.0

// How long a speed measurement is treated as describing the present.
//
// This is the safety property that makes suppression impossible to get stuck
// in. Speed is only recomputed when the viewport moves, so once movement stops
// the last measurement sits there unchanged and would go on suppressing
// renders forever -- a document left permanently soft with no event coming
// that would fix it. Suppression is therefore not allowed to outlive the
// evidence for it: past this age the measurement is disregarded and pages
// render, whatever it said.
//
// -scheduleSettle is what makes the sharp pass arrive promptly rather than
// merely eventually, but it is an optimisation on top of this rule and not a
// precondition for correctness. If the timer were never delivered at all, the
// worst outcome is that the pages go sharp on the next event instead of
// PV_SETTLE_SECONDS after the last one. Ordering matters and is asserted in
// pvtest: PV_SETTLE_SECONDS < PV_SPEED_FRESH_SECONDS, so in ordinary operation
// the timer always wins and this rule is never the thing that ends a
// suppression.
#define PV_SPEED_FRESH_SECONDS  0.25

// How long after the last movement the exact render pass is asked for.
//
// A gesture scroll has -didEndLiveScroll: to say when it is over. Keyboard
// paging has no such event: holding Page Down produces a stream of discrete
// jumps and releasing the key produces nothing at all, so without a timer the
// settle pass would wait for whatever the user happened to do next. Comfortably
// longer than the fastest key auto-repeat interval the system will produce
// (~15 ms), so the timer is rescheduled by each repeat and fires only once the
// repeats actually stop, and short enough to be imperceptible.
#define PV_SETTLE_SECONDS       0.15

// Faster than any hand: above this, the viewport did not travel, it jumped.
// A page jump, a thumbnail click, the snap back at the end of a rubber-band --
// each of those moves the document thousands of points between one event and
// the next, and folding that into a speed average reports a scroll that never
// happened and stops rendering for as long as it takes to decay. A hard
// trackpad flick peaks near 50,000 pt/s, so a sample past twice that is not a
// measurement of scrolling and is discarded rather than smoothed.
#define PV_MAX_SCROLL_SPEED     100000.0

// ---------------------------------------------------------------------------
// Render scheduler budgets.
//
// Grouped here with PV_SETTLE_SECONDS above so the three numbers that decide
// how much expensive work is outstanding at once can be moved during a live
// profiling session without hunting through the controller.
//
// The quantity they are all really about is the size of one full-resolution
// page bitmap, which is not small. In the 1200x706 profiling window a page
// rasterises to ~7.1 Mpx, which is ~28 MB of pixels -- so the 96 MB page-cache
// budget on an 8 GB machine holds three of them, not thirty.

// Neighbouring pages prefetched at FULL resolution once the document has
// settled. Previews are prefetched more widely and separately; they are ~9x
// smaller and are what actually makes scrolling back feel instant.
//
// This was three (the two ahead plus the one behind, from -updateVisibleContent's
// candidate list). Three full-resolution neighbours plus the two pages pinned
// on screen is five ~28 MB bitmaps against a 96 MB budget, so storing the last
// one evicted a page that was still wanted, which was then asked for again.
// The profile shows the result: 51 full renders to display 6 pages of a
// document nobody was scrolling, at one page every 2.5 seconds.
#define PV_FULL_PREFETCH_PAGES   1

// Full-resolution bitmaps allowed to be outstanding at once.
//
// A bitmap that has been rasterised but not yet delivered is live memory that
// the cache's byte budget cannot see: it is not in the cache yet. Several of
// them in flight together is how peak RSS reached 334 MB while the cache
// itself was never allowed past 96 MB.
//
// Enforced in -[PVRenderQueue drainExpressOnly:]: a full request is left in the
// pending set and skipped, rather than the worker being blocked, because the
// queue is serial and previews drain through the same loop -- blocking there
// would stall the responsiveness path to save memory on the quality path. The
// main-queue delivery block re-pumps when the count drops, which is what makes
// the skipped request start again rather than wait for the next scroll event.
//
// Counts bitmaps, not bytes, and deliberately so. Byte accounting is
// instrumentation and can be compiled or configured away; this bound is a
// property of the pipeline that has to hold identically in every build, so it
// is expressed in a quantity the queue knows exactly with no measurement
// involved. Previews (~1/9 the pixels) are never gated: they are the
// responsiveness path and nine of them is one page.
#define PV_MAX_INFLIGHT_FULL     2

// Hard ceiling on how many full-resolution bitmaps the cache will hold,
// independent of their size. The byte budget is the binding constraint at the
// sizes above and this will not normally be reached; it exists so that a small
// page at a small zoom -- where a full bitmap may be only a megabyte or two --
// cannot quietly accumulate dozens of live bitmaps under the same budget.
#define PV_MAX_FULL_IMAGES       8

// Full-resolution neighbours prefetched when the machine is on mains power.
//
// Two rather than one, and not more. PV_FULL_PREFETCH_PAGES documents why three
// was wrong: five ~28 MB bitmaps against a 96 MB budget meant storing the last
// one evicted a page still on screen, which was then asked for again. That
// argument is about the *cache*, not about the battery, so it does not stop
// applying when the charger goes in -- what changes on AC is only that the
// budget is larger on the tier a mains-powered machine is likely to be, not
// that thrashing has become acceptable. PVRenderPolicyFitsCache is what holds
// the line, and pvtest walks every combination through it.
#define PV_AC_FULL_PREFETCH_PAGES  2

// Safety margin on a predicted render time before it is compared against how
// long the page will be on screen.
//
// The prediction covers CGContextDrawPDFPage and nothing else. A bitmap still
// has to cross a main-queue hop, land in the cache and be drawn, and the
// prediction is an average over a document whose pages are not all alike -- so
// a bitmap predicted to take exactly as long as the page has left is a bitmap
// that arrives late. Higher on battery than on AC: being wrong on battery costs
// energy for pixels nobody saw, and being wrong on AC costs nothing anybody is
// paying for.
#define PV_DWELL_SAFETY_BATTERY  1.50
#define PV_DWELL_SAFETY_AC       1.25

extern NSString * const PVMemoryPressureNotification;

// A toolbar icon from the app bundle, by base name, without extension.
//
// The assets are PDFs, so one file covers every display scale and there is no
// @2x variant to keep in step. They are marked as template images on the way
// out, which is what lets AppKit tint them for the toolbar it finds itself in:
// the artwork is solid black, and without the flag it stays solid black on a
// dark toolbar, where it cannot be seen at all.
//
// Returns nil when the asset is missing, which every caller has to handle:
// -[NSToolbarItem setImage:nil] is not a crash but it is an invisible button,
// so callers fall back to a label rather than shipping a blank toolbar.
NSImage *PVToolbarImageNamed(NSString *name);

// ---------------------------------------------------------------------------
// Machine size, as three tiers.
//
// Installed RAM decides two quantities, and until this split they were one:
// the render ceiling was literally PVPageCacheBudget() / 3 / 4. That made a
// memory decision -- how many bytes of bitmaps the cache may hold -- silently
// into a quality decision -- how sharp a page is allowed to be. Cutting the
// budget to save memory would have dragged the ceiling below the size of an
// ordinary page and rendered every page soft and stretched, permanently, in
// every scenario, with nothing in the build to say it had happened.
//
// They are derived from the tier independently now. What still ties them
// together is one inequality rather than one expression, asserted by pvtest on
// every tier: two full-resolution pages plus PV_CACHE_SLACK_PREVIEWS previews
// must fit inside the eviction budget. That is the anti-thrash property the
// old derivation bought by construction; stating it as an invariant keeps it
// while letting either number move on its own.
//
// The tier is a pure function of a byte count so that every tier can be
// exercised on any machine. A test that can only check the tier it happens to
// be running on is not a test of the invariant.
// The fourth tier is about the render ceiling, not about the cache.
//
// ENGINEERING.md §4.4 establishes that cache hit rate saturates at three
// or four full pages and that no amount of additional memory buys any further
// battery: reuse distance in a document reader is bimodal, so there is no
// population of pages a larger cache could serve. That finding stands, and
// nothing here is an attempt to relitigate it -- the budget below is NOT raised
// to improve hit rate, and it does not.
//
// What the extra tier buys is sharpness. PVMaxRenderPixelsForTier is a quality
// knob, and on the >4 GB tier it sits at 8.39 Mpx against a US Letter page that
// is 7.11 Mpx at fit-width on a 2x display -- so PVClampPixelSize starts
// silently downscaling at 1.09x zoom and every pixel past that is stretched.
// On a 16 GB laptop or a 64 GB desktop that limit is not protecting anything;
// it is the arithmetic of an 8 GB machine applied to a machine eight times
// larger.
//
// Raising the ceiling forces the budget up with it, because the anti-thrash
// inequality is stated in terms of the ceiling: two full-resolution pages plus
// PV_CACHE_SLACK_PREVIEWS must fit what the cache will hold, or storing the
// second visible page evicts the first and the queue rasterises the same two
// pages forever. So the budget moves as the *cost* of the quality change and
// not as a benefit in its own right.
//
// That cost is smaller than it looks, and the distinction matters because peak
// RSS is the one metric this app loses on. The budget is a ceiling on cache
// occupancy, not a reservation: at fit-width a page is 7.11 Mpx whatever the
// ceiling says, the cache holds the same three of them, and peak RSS is
// unchanged to the byte. The larger budget is only ever reached by a user who
// has actually zoomed in -- which is the moment they have asked for the
// sharpness this tier exists to give them.
typedef enum {
    PVRamTierSmall  = 0,   // <= 2 GB
    PVRamTierMedium = 1,   // <= 4 GB
    PVRamTierLarge  = 2,   // <= 8 GB
    PVRamTierHuge   = 3,   //  > 8 GB
    PVRamTierCount  = 4
} PVRamTier;

PVRamTier PVRamTierForBytes(unsigned long long bytes);
PVRamTier PVRamTierOfThisMachine(void);

// Previews the eviction budget must hold beside the two full-resolution pages
// that can be on screen at once.
//
// Five is what -updateVisibleContent can have live at one time: one for each
// visible page (2) and one for each prefetch candidate (3). Previews are
// PV_PREVIEW_DIVISOR^2 smaller than a full page, so this is a small term -- but
// it is the term that stops the invariant from being satisfied by a budget that
// holds exactly two pages and nothing else, which is a cache that evicts a
// preview every time a page is stored.
#define PV_CACHE_SLACK_PREVIEWS  5

// The eviction budget: bytes of rendered bitmaps a page cache holds before it
// starts discarding the least recently used. This is the memory knob, and the
// only one of the two below that may be cut to save memory.
//
// Scales with installed RAM. A Mavericks-era Mac may have only 2 GB, where an
// 80 MB bitmap cache would push the machine towards swapping -- and swapping on
// a spinning disk costs far more time and power than re-rendering a page.
size_t PVPageCacheBudgetForTier(PVRamTier tier);
size_t PVThumbCacheBudgetForTier(PVRamTier tier);
size_t PVPageCacheBudget(void);
size_t PVThumbCacheBudget(void);

// The render ceiling: the largest bitmap that will be rasterised for one page,
// in pixels. This is a quality decision. Past it PVClampPixelSize() scales the
// request down and the draw path stretches it back up, so the page is soft --
// which is the correct failure, but it must be a chosen one and not a side
// effect of someone tuning the cache. PV_MAX_PIXELS is the absolute limit above
// these; a 2 GB Mavericks Mac must not be pushed into swap by one absurdly
// zoomed page.
double PVMaxRenderPixelsForTier(PVRamTier tier);
double PVMaxRenderPixels(void);

// The bitmap size that will actually be rendered for a requested one: rounded
// to whole pixels, floored at 1x1, and scaled down to fit under
// PVMaxRenderPixels() if it does not already. Non-finite input yields a zero
// size, which callers treat as "do not render".
//
// Stated once because two places have to agree on it exactly. The renderer
// applies it, and the layer above has to know what it will get: a cache that
// budgets for the size it asked for, while the renderer stores the size it
// clamped to, is a cache whose accounting is wrong in the one case that
// matters. It is also what makes the ceiling testable without a PDF.
CGSize PVClampPixelSize(CGSize px);

// ---------------------------------------------------------------------------
// Power source.
//
// Until now nothing in the program read it, and the whole scheduler was tuned
// for the case where every render costs battery. That is the right default and
// it stays the default -- but it is not true on a desktop, and it is not true
// on a laptop with the charger in. Suppressing a render to save energy that is
// arriving down a wall socket is not a saving, it is just a softer page.
//
// Three states rather than two, and Unknown is not folded into either. A
// machine that declines to answer must get the conservative branch, and that
// has to be a decision written down rather than a default that falls out of an
// enum starting at zero.
typedef enum {
    PVPowerUnknown = 0,   // could not be determined: treated exactly as battery
    PVPowerBattery = 1,
    PVPowerAC      = 2
} PVPowerSource;

// The classification on its own, so it can be tested without unplugging
// anything: the argument is what IOKit reports, or what -PVPowerState was set
// to. Anything unrecognised is PVPowerUnknown, never PVPowerAC -- an unreadable
// answer must not be able to turn the expensive behaviour on.
PVPowerSource PVPowerSourceFromString(NSString *s);

// What the machine says right now.
//
// Resolved through dlopen rather than by linking IOKit. `make verify` allow-lists
// every LC_LOAD_DYLIB the shipping binary may carry -- Cocoa, CoreGraphics and
// libSystem -- because each one is a path that has to exist on a 10.9 machine,
// and IOKit is not on that list. Resolving it at runtime keeps the link map
// exactly as it was, and a machine where the lookup fails reports PVPowerUnknown
// and takes the battery branch, which is the same behaviour the app had before
// this function existed.
//
// Cached with a short TTL. IOPSCopyPowerSourcesInfo allocates a CF dictionary
// and this is consulted from the wanted-set builder, which runs on every scroll
// event: asking the kernel sixty times a second whether the charger is still
// plugged in would cost more than the policy it informs can save. Main thread
// only.
PVPowerSource PVCurrentPowerSource(void);

// Test seam: pin the answer and bypass both the cache and IOKit.
//
// -PVPowerState (auto|battery|ac) does this from the command line, which is
// what Tools/showdown.sh needs -- the arbiter machine is a desktop, so every
// trial there would otherwise take the AC branch and stop describing the
// battery case the project exists to optimise. This is the same seam for
// pvtest, which has to walk both branches on whatever machine it runs on.
void PVSetPowerSourceOverride(PVPowerSource source, BOOL enabled);

// ---------------------------------------------------------------------------
// The render policy: every mode-shaped decision, in one pure function.
//
// ENGINEERING.md §4.4 argues against exposing "High Performance" and "Low
// Memory" to the user, and the argument is that both settings are worse than
// the automatic answer -- a larger cache buys nothing because hit rate has
// already saturated, and a smaller one steps off the knee and pays in
// re-renders, costing CPU *and* battery. A control whose every position is
// worse than the default moves blame rather than adding a feature.
//
// This is what replaces it. The three inputs are things the program can read
// more reliably than a user can state them, and the output is the entire set of
// knobs that would otherwise have been a mode switch. One function, no state,
// no clock, so pvtest can walk every combination exhaustively -- which is the
// property that makes an adaptive policy safe to have at all: a policy that can
// only be checked in the configuration it happens to be running in is not a
// policy anyone can reason about.
//
// `pressureReports` keeps its existing meaning and its existing precedence: it
// is the one input that can only ever make the policy cheaper. Memory pressure
// outranks the power source, because a machine that is swapping is not made
// better by being plugged in.
typedef struct {
    // Full-resolution neighbours prefetched once the document has settled.
    // PV_FULL_PREFETCH_PAGES on battery, and never more than the cache can hold
    // two visible pages alongside -- see PVRenderPolicyFitsCache().
    NSUInteger fullPrefetchPages;
    // Multiplier applied to the cost model's predicted render time before it is
    // compared against how long the page will actually be on screen. Above 1 it
    // is a safety margin: the bitmap has to be rasterised, delivered across a
    // main-queue hop and drawn, and a prediction that only covers the first of
    // those admits work that still arrives too late.
    double     dwellSafetyFactor;
    // The floor under any dwell decision, and the answer in full when the cost
    // model has nothing to say. PV_MIN_VISIBLE_SECONDS on battery, which is
    // exactly today's constant and therefore today's behaviour.
    double     minDwellSeconds;
    // May a full-resolution bitmap be asked for while the viewport is moving?
    // NO on battery -- the motion gate, unchanged. On AC the cost model decides
    // per page instead, because a page that costs 11 ms is not worth suppressing
    // for a scroll that will last half a second.
    BOOL       fullRendersWhileMoving;
} PVRenderPolicy;

PVRenderPolicy PVRenderPolicyFor(PVPowerSource power, PVRamTier tier,
                                 NSUInteger pressureReports);

// Does this policy's prefetch depth fit the tier's eviction budget?
//
// The anti-thrash inequality, extended to cover prefetch. pvtest asserts it for
// every (power, tier, pressure) combination, so a policy that would ask for
// more full-resolution bitmaps than the cache can hold cannot be introduced
// without a test failing -- which is the failure mode that produced 51 full
// renders to display 6 pages, and which is invisible from outside the process.
BOOL PVRenderPolicyFitsCache(PVRenderPolicy policy, PVRamTier tier);

// Is a bitmap worth asking for, given how the viewport is moving right now?
//
// The whole of the render-suppression policy, as a pure function of three
// numbers, so it can be tested exhaustively without a window, a clock, a PDF
// or a run loop. The controller supplies the measurements; this decides.
//
//   speed           points per second the document is travelling, 0 at rest
//   ageSeconds      how long ago that speed was measured
//   visibleSeconds  how long this page stays on screen at that speed
//
// Rendering is the safe answer and therefore the default: the function returns
// YES unless there is *fresh* evidence that this page will be gone before its
// bitmap could arrive. Every uncertain case -- no measurement yet, a stale
// measurement, a non-finite input -- renders. The only way to get NO is a
// current measurement of genuine speed and a page that will not survive it.
//
// Deliberately independent of which input device caused the movement. Keying
// this off the live-scroll notifications meant it engaged for a trackpad flick
// and not for a held Page Down key, which is the same motion at the same speed
// and costs the same energy.
BOOL PVShouldRenderWhileMoving(double speed, double ageSeconds, double visibleSeconds);

// The same decision, told what this particular bitmap is predicted to cost.
//
// PV_MIN_VISIBLE_SECONDS is 0.25 because a quarter of a second is where a
// glimpse becomes a look. That is a fact about eyes and it is the right floor.
// What it was also being made to stand in for is a fact about the machine --
// "will this render finish before the page leaves" -- and that quantity is not
// 0.25 s. It is 11 ms on a page of body text and 657 ms on a page of vector
// artwork, measured back to back at identical pixel counts (ENGINEERING.md
// §1). One constant, asked to cover a 59x range, is wrong at both ends: it
// suppresses text renders the machine could afford twenty-two times over, and
// it admits a 657 ms render into a 250 ms window.
//
// `predictedSeconds` is what the cost model expects this bitmap to take. When
// it is not finite or not positive -- no model yet, first render of a document,
// the census disabled -- this function reduces *exactly* to
// PVShouldRenderWhileMoving above, and pvtest asserts that equivalence across a
// full sweep rather than trusting the reading. That is what makes the cost model
// safe to add: its absence is not a different policy, it is the old policy.
//
// The floor is never removed, only raised. A prediction of 2 ms does not license
// rendering a page that will be on screen for 3 ms; `minDwell` still applies,
// so the model can admit work the old constant refused but can never admit work
// that arrives after the page has gone.
//
// On the feedback loop that sank two earlier attempts at this, see the note on
// PV_MIN_VISIBLE_SECONDS above and PVCostModel.h. The short version: the samples
// this is fed come from the settle pass, which is unconditional, so suppression
// cannot starve its own measurement.
BOOL PVShouldRenderWhileMovingCost(double speed, double ageSeconds, double visibleSeconds,
                                   double predictedSeconds, double safetyFactor,
                                   double minDwell);

// Bytes a CGImage actually occupies, taken from the image itself rather than
// recomputed from a nominal size: CoreGraphics pads every row out to an
// alignment boundary, so width*height*4 consistently understates the truth and
// lets a byte-budgeted cache drift over its budget. Returns 0 for NULL.
size_t PVImageBytes(CGImageRef img);

// Where the application is running from.
//
// A 10.9 crash report showed the process taking SIGBUS -- EXC_BAD_ACCESS with
// KERN_MEMORY_ERROR -- on an address inside its own __TEXT, in the ObjC class
// name strings the runtime dereferences on every objc_lookUpClass. That is not
// a pointer bug and nothing in this program was on the stack: OS X pages an
// application's code in from its executable file on demand for as long as the
// process lives, and the copy in question was at /Volumes/... When the file
// stops being readable -- the disk is ejected or unplugged, or a new build
// overwrites the copy that is running -- the next page that has to be faulted
// in cannot be, and the kernel stops the process on the spot. The same report
// listed the executable as "0 - 0xffffffffffffffff +Postview (???)", meaning
// the crash reporter could not read the file either.
//
// No code inside a process can survive its own text going away; there is no
// instruction left to run. So the fix is not a check in some code path, it is
// not being in that situation: warn at launch, and offer to move the app to a
// disk that cannot be removed.
typedef enum {
    PVVolumeFixed     = 0,  // an internal disk: the file cannot vanish underneath us
    PVVolumeRemovable = 1,  // USB stick, external drive, or mounted disk image
    PVVolumeNetwork   = 2   // a file server or other network mount
} PVVolumeKind;

// The classification on its own, so it can be tested without a USB stick: the
// three arguments are exactly what NSURL reports about a volume.
PVVolumeKind PVVolumeKindFromFlags(BOOL removable, BOOL ejectable, BOOL local);

// The same classification for the volume a file actually sits on. Answers
// PVVolumeFixed when the volume's properties cannot be read, so a question the
// system declines to answer never turns into a warning.
PVVolumeKind PVVolumeKindForURL(NSURL *url);

// Live-instance census.
//
// The point of the soak test is to prove that a document cycle leaves nothing
// behind. Inferring that from the process footprint does not work: the
// allocator's sawtooth and the frameworks' own caches swamp the signal. These
// counters answer the question directly instead -- after N open/close cycles,
// every one of Postview's long-lived objects must be back to where it started.
//
// Cost is one mutex-guarded increment per object for a handful of classes that
// are created a few times per document, which is not measurable.
void PVLiveAdjust(const char *cls, int delta);
long PVLiveCount(const char *cls);
// Every class that participates, NULL-terminated, for tests to iterate.
const char * const *PVLiveTrackedClasses(void);

// Opt-in rasterisation census: where the energy went.
//
// CPU seconds say a document cost something; they do not say whether it was
// spent on pages the user saw, on prefetch they never reached, or on the same
// page rendered five times because the cache could not keep it. Answering that
// from outside the process is guesswork, so the process keeps the count.
//
// Off unless POSTVIEW_STATS is set in the environment, and off is the shipping
// default -- these exist so a benchmark can attribute work, not so the app
// carries a profiler. Enabled, the cost is one mutex-guarded add per rendered
// page, against a rasterisation that takes milliseconds.
//
// Keys are an enum rather than strings so nothing is allocated, hashed or
// compared on the render thread, and so the set is fixed and bounded at
// compile time.
typedef enum {
    PVStatRendersFull = 0,      // full-resolution bitmaps produced
    PVStatRendersPreview,       // 1/3-linear preview bitmaps produced
    PVStatRendersFailed,        // CoreGraphics declined
    PVStatPixelsFull,           // megapixels rasterised at full resolution
    PVStatPixelsPreview,        // megapixels rasterised as previews
    PVStatRequestsSuppressed,   // bitmaps not asked for: the dwell throttle working
    // Full-resolution bitmaps not asked for because the document was moving.
    //
    // Separate from PVStatRequestsSuppressed, which counts only the per-page
    // dwell test. The motion gate is an outer branch -- `if (!moving && ...)`
    // in -updateVisibleContent -- and when it is closed the whole
    // full-resolution arm is skipped without any counter running. That is why
    // `scroll` reported `0 requests suppressed` while the gate was doing all of
    // the work: at 3000 pt/s a page is visible for ~0.76 s, comfortably above
    // PV_MIN_VISIBLE_SECONDS, so nothing was dwell-suppressed and the gate got
    // no credit. Anyone tuning the scheduler from that one column was reading a
    // number that omitted the mechanism doing most of the suppressing.
    //
    // A new key rather than an addition to the old one: `requests_suppressed`
    // has recorded runs going back to the first profile and its meaning must
    // not change underneath them. The report prints both and their total.
    PVStatMotionSuppressed,
    // The cost model's two directions, counted separately because they are two
    // different claims and averaging them would hide both.
    //
    // A cost model that only ever suppressed would be indistinguishable in the
    // totals from a tighter constant, and one that only ever admitted would be
    // indistinguishable from a looser one. The whole argument for measuring
    // instead of choosing a number is that the right answer goes in opposite
    // directions on different documents, so the evidence for it has to be able
    // to show both happening in one session.
    PVStatCostSuppressed,       // full renders refused: predicted cost > dwell
    PVStatCostAdmitted,         // full renders allowed that PV_MIN_VISIBLE_SECONDS
                                // alone would have refused
    // Wall-clock seconds actually spent inside the rasteriser, and the sample
    // count behind it. The cost model's input, recorded so a run can be checked
    // against the model's own predictions after the fact rather than only from
    // inside the process.
    PVStatRenderSeconds,
    PVStatRenderSamples,
    // High-water marks, in bytes, of resident rendered pixels. Fed by the
    // resident census below rather than accumulated here, so they are maxima
    // and not sums: see PVStatMax().
    PVStatPeakResidentBytes,    // cache + in-flight + undelivered, summed
    PVStatPeakUndeliveredBytes, // rasterised, dispatched, not yet handed over
    PVStatPeakCacheBytes,       // held by the image caches
    PVStatCount
} PVStatKey;

BOOL PVStatsEnabled(void);
void PVStatAdd(PVStatKey key, double delta);
// Record a maximum rather than a sum. The peak keys above are the only ones
// that use it; adding a high-water mark with PVStatAdd would report the sum of
// every peak ever reached, which is a number about nothing.
void PVStatMax(PVStatKey key, double value);
// One counter's current value, or 0 when the census is disabled or the key is
// out of range. For tests: a counter nothing can read is a counter nothing can
// prove counts, and the suppression keys exist precisely to be read.
double PVStatValue(PVStatKey key);
// A human-readable census, or nil when stats are disabled. Written to stderr
// at termination so a benchmark can capture it per run.
NSString *PVStatsReport(void);

// ---------------------------------------------------------------------------
// Resident rendered-pixel census: what is alive right now, not what was made.
//
// The rasterisation census above counts work performed. It says nothing about
// what is *resident*, which is the quantity peak RSS is made of -- so before
// this existed, no memory change to the render pipeline could be falsified from
// inside the process. Three buckets, disjoint by construction, covering every
// rendered bitmap Postview owns between the moment its pixels are allocated and
// the moment the last owning reference goes away:
//
//   PVResidentRender        a bitmap context mid-rasterisation, on the render
//                           queue. Balanced inside one function, so it cannot
//                           leak however that function exits.
//   PVResidentUndelivered   rasterised, owned by the render queue, on its way
//                           to the main thread. Invisible to the cache's byte
//                           budget, which is exactly why it is counted.
//   PVResidentCache         held by a PVImageCache.
//
// Disjoint means every byte is in at most one bucket at a time, so the sum is a
// figure that can be compared against RSS rather than an upper bound on it.
// Ownership is handed over at one point per boundary: the queue drops its
// undelivered claim immediately before the delegate is called, and the delegate
// either stores the image -- where the cache's own accounting picks it up
// inside that call -- or lets it go. The one uncounted instant is the tail of a
// delivery block for an image the delegate declined, which is released a few
// microseconds later and can never be more than one bitmap.
//
// Unconditionally on, unlike the census above. Two reasons. It is consulted by
// the soak and unit suites, which do not set POSTVIEW_STATS and should not have
// to. And an accounting that is present in some builds and absent in others is
// an accounting whose own overhead has to be reasoned about twice; at a handful
// of mutex-guarded adds per rasterisation, against a rasterisation measured in
// milliseconds, there is nothing here worth switching off.
typedef enum {
    PVResidentRender = 0,
    PVResidentUndelivered,
    PVResidentCache,
    PVResidentBucketCount
} PVResidentBucket;

void   PVResidentAdd(PVResidentBucket bucket, size_t bytes);
void   PVResidentSub(PVResidentBucket bucket, size_t bytes);
size_t PVResidentBytes(PVResidentBucket bucket);
size_t PVResidentTotal(void);
// The largest value PVResidentTotal() has ever returned, and the same for the
// two buckets a memory change is aimed at. Read at termination for the stats
// report and by the soak's footprint section.
size_t PVResidentHighWater(void);
size_t PVResidentHighWaterForBucket(PVResidentBucket bucket);
// Zero the totals and the high-water marks. For tests that need a clean
// measurement window; nothing in the application calls it.
void   PVResidentReset(void);

typedef enum {
    PVZoomModeCustom   = 0,
    PVZoomModeFitWidth = 1,
    PVZoomModeFitPage  = 2,
    PVZoomModeActual   = 3
} PVZoomMode;

// Priorities: lower number is rendered sooner.
enum {
    PVPriorityVisiblePreview = 0,
    PVPriorityVisibleFull    = 1,
    PVPriorityNearPreview    = 2,
    PVPriorityNearFull       = 3
};

@interface PVRenderRequest : NSObject {
@public
    NSUInteger  page;
    CGSize      px;        // exact target bitmap size in pixels
    int         priority;
    BOOL        preview;   // YES => store in the cheap preview slot
    BOOL        express;   // YES => run at raised QoS for a first paint
}
+ (PVRenderRequest *)page:(NSUInteger)p pixels:(CGSize)s priority:(int)pri preview:(BOOL)pv;
+ (PVRenderRequest *)page:(NSUInteger)p pixels:(CGSize)s priority:(int)pri preview:(BOOL)pv
                  express:(BOOL)ex;
@end
