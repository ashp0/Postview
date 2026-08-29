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
#define PV_MAX_INFLIGHT_FULL     2

// Hard ceiling on how many full-resolution bitmaps the cache will hold,
// independent of their size. The byte budget is the binding constraint at the
// sizes above and this will not normally be reached; it exists so that a small
// page at a small zoom -- where a full bitmap may be only a megabyte or two --
// cannot quietly accumulate dozens of live bitmaps under the same budget.
#define PV_MAX_FULL_IMAGES       8

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

// Cache budgets scale with installed RAM. A Mavericks-era Mac may have only
// 2 GB, where an 80 MB bitmap cache would push the machine towards swapping --
// and swapping on a spinning disk costs far more time and power than simply
// re-rendering a page.
size_t PVPageCacheBudget(void);
size_t PVThumbCacheBudget(void);

// Hard ceiling on the pixel count of one rendered bitmap. PV_MAX_PIXELS is the
// absolute limit; the real one is a third of the page-cache budget, so that
// the pages actually on screen can all be resident at once. A bitmap larger
// than the cache can keep is not merely wasteful: it evicts the other visible
// page, which is then re-requested, which evicts this one, and the render
// queue never reaches a steady state. See PVMaxRenderPixels() in PVCommon.m.
// A Mavericks Mac with 2 GB must also not be pushed into swap by one absurdly
// zoomed page.
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
    PVStatRequestsSuppressed,   // bitmaps not asked for: the throttle working
    PVStatCount
} PVStatKey;

BOOL PVStatsEnabled(void);
void PVStatAdd(PVStatKey key, double delta);
// A human-readable census, or nil when stats are disabled. Written to stderr
// at termination so a benchmark can capture it per run.
NSString *PVStatsReport(void);

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
