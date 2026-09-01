//  PVPDFSource.h — page geometry and rasterisation, both out of process.
//
//  Threading contract: -initWithURL: copies the complete input into one local,
//  immutable snapshot and caches every page size. Opening the document and
//  rendering from it are both performed by a private helper process; this class
//  holds no CGPDFDocumentRef and calls no CGPDF* function. Each source is still
//  confined to one render queue because its helper protocol is deliberately
//  serial.
//
//  That the PARSE is out of process, and not merely the drawing, is the point
//  of the design rather than a detail of it. CGPDFDocumentCreateWithURL and the
//  page-tree walk are Quartz interpreting attacker-controlled bytes exactly as
//  CGContextDrawPDFPage is, and they fault, hang and abort in exactly the same
//  ways -- none of which is an Objective-C exception, so none of which @catch
//  can see. A viewer that opened the document itself could be killed by a
//  document before the helper it built was ever asked for a page.

#import "PVCommon.h"
#include <sys/types.h>   // pid_t, for the render helper below

// Why a bitmap could not be produced.
//
// The single NULL return this replaces conflated two entirely different things:
// a page CoreGraphics will never draw, and a page it could not draw just now.
// The layer above retires a page after three failures, which is right for the
// first and catastrophic for the second -- a machine briefly out of shared
// memory, or a helper killed mid-render, permanently blanked valid pages for
// the rest of the session and nothing anywhere said why.
typedef NS_ENUM(NSInteger, PVRenderFailure) {
    PVRenderFailureNone = 0,
    // The document will not draw this page, and asking again will not change
    // that. The only failure that may consume a permanent-failure attempt.
    PVRenderFailureInvalidPage,
    // Shared memory, address space or an allocation, none of them available at
    // this instant. Retry, with a bound.
    PVRenderFailureTransientResource,
    // The helper did not answer within its deadline. It has been killed; the
    // next attempt gets a fresh one.
    PVRenderFailureTimeout,
    // No helper could be started, or it did not survive being spoken to. This
    // is an installation fault, not a page fault: every page will fail the same
    // way, so it belongs in one document-level error rather than in the
    // per-page counters.
    PVRenderFailureHelperUnavailable,
    // The helper answered, but not with something this protocol allows.
    PVRenderFailureProtocol
};

// Test seam: run the abandoned-snapshot sweep on demand.
//
// The sweep normally runs once per process, the first time a document is
// opened, which makes it unobservable from a test that has already opened one.
// Exposed because the operation is `unlink` on files this process did not
// create, and the property that matters -- that a snapshot in USE is never
// swept, however old it is -- is worth asserting rather than reasoning about.
void PVSweepAbandonedSnapshotsNow(void);

@interface PVPDFSource : NSObject {
    NSUInteger        _pageCount;
    CGSize           *_sizes;      // rotation-corrected point sizes
    CGSize            _maxSize;
    NSURL            *_url;
    id                _snapshot;   // private PVPDFSnapshot
    // The render helper, owned as a raw process rather than through NSTask.
    //
    // NSTask's -waitUntilExit spins the CALLING THREAD'S RUN LOOP until the
    // child is reaped. Both places this teardown happens are places a run loop
    // must not be spun: -dealloc, where it re-enters arbitrary application code
    // from inside an object's destruction, and the render queue's worker
    // thread, whose run loop has no sources to service and which simply hangs.
    // Observed directly -- a soak run sat for thirty minutes in
    // -[NSConcreteTask waitUntilExit] inside -[PVPDFSource dealloc], having
    // used 27 seconds of CPU.
    //
    // posix_spawn and waitpid have neither problem: they are two syscalls, they
    // work identically from any thread, and the reaping is this object's rather
    // than shared with NSTask's process-wide SIGCHLD machinery.
    pid_t              _helperPid;       // 0 when no helper is running
    int                _helperIn;        // -1, or the pipe commands are written to
    int                _helperOut;       // -1, or the pipe replies are read from
    unsigned long long _helperSequence;
    // Renders this helper has served. See PV_HELPER_MAX_RENDERS: a helper is
    // retired on a boundary the viewer chooses, between renders, so recycling
    // never costs a visible failure.
    unsigned long      _helperRenders;
    // Set once the helper has failed in a way that says the installation is
    // broken rather than the page. Stops every later page paying the same
    // spawn-and-fail cost to reach the same conclusion.
    BOOL               _helperUnavailable;
}
- (id)initWithURL:(NSURL *)url error:(NSError **)outError;
// Same, but copies page geometry from an already-open source instead of asking
// the helper to walk the page tree again. The helper process is still separate,
// so the two sources can safely render on two different queues.
- (id)initWithURL:(NSURL *)url geometryFrom:(PVPDFSource *)other error:(NSError **)outError;
// A second source over the SAME snapshot bytes, +1 retained, or nil.
//
// For a second render lane. A helper process is not shared between lanes; what
// IS shared is the immutable snapshot underneath, so the two lanes cannot
// disagree about the document and the file is copied once. Geometry is copied
// rather than re-measured, so this costs one helper start and no page-tree
// traversal.
- (PVPDFSource *)newLaneSource;

- (NSUInteger)pageCount;
- (CGSize)pointSizeOfPage:(NSUInteger)index;   // 0-based
- (CGSize)maxPointSize;
// Returns a +1 retained CGImageRef, or NULL. Owning queue only.
//
// CF_RETURNS_RETAINED is what makes that sentence checkable. The bitmap
// travels from the render queue's worker, through a block, onto the main
// thread and into the cache, and the balancing release is three files away
// from the create; stating the ownership in the type lets the static analyser
// follow it instead of taking the comment's word for it.
//
// `failure` receives why NULL came back, and is the difference between a page
// that should be retried and one that should be given up on. May be NULL.
// THE DESIGNATED OVERRIDE POINT. Every other spelling below funnels through
// this one, and PVRenderQueue calls this one directly.
//
// Said in capitals because it has now gone wrong twice, both times silently: a
// test subclass instrumenting renders overrode a convenience spelling, the
// queue kept calling the primitive, and the instrumentation recorded nothing
// while the suite went on reporting a pass. A subclass that wants to see
// renders must override THIS method.
//
// `interactive` asks the helper to draw this one page at ordinary priority
// instead of the background class it otherwise stays in. Reserved for the
// express lane -- the page a reader is waiting on with nothing cached to show --
// because it is the difference between ~266 ms and ~1401 ms for a full page, and
// because paying it for prefetch would be paying it for everything.
- (CGImageRef)createImageForPage:(NSUInteger)index
                       pixelSize:(CGSize)px
                     interactive:(BOOL)interactive
                         failure:(PVRenderFailure *)failure CF_RETURNS_RETAINED;
// As above at background priority, which is what all but one render should be.
- (CGImageRef)createImageForPage:(NSUInteger)index
                       pixelSize:(CGSize)px
                         failure:(PVRenderFailure *)failure CF_RETURNS_RETAINED;
// As above, discarding the reason. Kept for callers that genuinely cannot act
// on one -- the band probe and the scale-independence checks -- so they do not
// each have to declare a variable to ignore.
- (CGImageRef)createImageForPage:(NSUInteger)index
                       pixelSize:(CGSize)px CF_RETURNS_RETAINED;
@end
