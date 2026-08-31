//  pvstress.m — the adversarial concurrency harness.
//
//  pvsoak proves a document cycle leaves nothing behind. It does not prove the
//  cycle is safe while the render queue is actually busy, because it pumps the
//  run loop for a few tens of milliseconds at a time and then moves on. Every
//  interesting window in this app is measured in microseconds and opens only
//  when a background render is in flight:
//
//    * a wanted-set replaced while a page is mid-rasterisation
//    * memory pressure landing between a render finishing and its delivery
//    * an occlusion change suspending the queue while a page is in flight
//    * a display change emptying the cache under a delivery already queued
//    * a window closed with several pages rendered and none yet delivered
//
//  This harness holds the queue busy on a heavy document and then fires those
//  events at it as fast as the run loop will carry them, so ThreadSanitizer has
//  something to see. It asserts the same invariants the rest of the suite does
//  -- census back to zero, cache inside budget, nothing left in flight -- but
//  under contention rather than at rest.
//
//    make stress          (plain)
//    make stress-tsan     (under ThreadSanitizer)

#import "PVCommon.h"
#import "PVPDFSource.h"
#import "PVImageCache.h"
#import "PVRenderQueue.h"
#import "PVWindowController.h"
#import "PVStateStore.h"
#include <stdlib.h>          // getenv, atof -- see DeadlineScale()
#include <math.h>

@interface PVWindowController (PVStressHooks)
- (void)updateVisibleContent;
- (void)memoryPressure:(NSNotification *)note;
- (void)showSidebar;
- (void)hideSidebar;
- (void)clipBoundsChanged:(NSNotification *)note;
- (void)willStartLiveScroll:(NSNotification *)note;
- (void)didEndLiveScroll:(NSNotification *)note;
- (void)windowOcclusionChanged:(NSNotification *)note;
- (void)backingPropertiesChanged:(NSNotification *)note;
- (void)scrollToPage:(NSUInteger)page fraction:(CGFloat)fraction;
@end

static int gPass = 0, gFail = 0;
static void OK(int cond, const char *what)
{
    if (cond) { gPass++; printf("  ok    %s\n", what); }
    else      { gFail++; printf("  FAIL  %s\n", what); }
}
static void Pump(double s)
{
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:s]];
}

// Every teardown here is asynchronous by design: the worker holds its own
// reference until it next looks at the stop flags, and the delivery it may
// already have queued holds one until it runs on the main thread. So the
// assertion is "settles to zero", not "is zero the instant we ask" -- with a
// deadline, because "eventually" is exactly the bug this is looking for.
// Under ThreadSanitizer a page render is an order of magnitude slower, so the
// deadline is generous; a real leak still fails, it just fails at the end.
// Multiplier on every deadline below, from PVSTRESS_DEADLINE_SCALE.
//
// The deadlines are a claim about how long an unwind should take, and that is a
// property of the code. What they were being compared against is wall-clock
// time, which is a property of the build: a page render under a sanitizer is
// an order of magnitude slower than in the shipping configuration, and
// address+undefined is slower again than thread. One constant across all three
// is a constant that means three different things.
//
// Recorded 2026-08-31: the address+undefined build failed the two 60-round
// unwinds on this host -- 18 and 10 objects still live at the deadline -- while
// the plain and thread builds passed the same assertions, and `leakcheck`
// reported nothing leaked. Everything unwound; it did not unwind inside a
// number chosen for a faster build. The failure was invisible for as long as it
// was because `verify-all` piped each gate through `tail` and read the
// pipeline's status instead of the gate's, so it printed "every gate passed"
// two lines after printing the error.
//
// Deliberately a multiplier and not a longer constant: a real leak has to keep
// failing, and it does -- it just takes proportionally longer to say so.
static double DeadlineScale(void)
{
    static double scale = 0;
    if (scale > 0) return scale;
    const char *env = getenv("PVSTRESS_DEADLINE_SCALE");
    double v = env ? atof(env) : 1.0;
    if (!(v >= 1.0) || !isfinite(v)) v = 1.0;
    scale = v;
    return scale;
}

static BOOL SettlesToZero(const char *cls, double deadline)
{
    deadline *= DeadlineScale();
    double waited = 0;
    while (waited < deadline) {
        if (PVLiveCount(cls) == 0) return YES;
        @autoreleasepool { Pump(0.05); }
        waited += 0.05;
    }
    return PVLiveCount(cls) == 0;
}

// Reports the count it actually saw, so a failure says how far off it was
// rather than only that it was not zero.
static void CensusIsZero(const char *cls, const char *what, double deadline)
{
    BOOL ok = SettlesToZero(cls, deadline);
    if (ok) { gPass++; printf("  ok    %s\n", what); }
    else    { gFail++; printf("  FAIL  %s (live=%ld)\n", what, PVLiveCount(cls)); }
}

// A deterministic PRNG, so a failure found here is a failure that can be
// reproduced. rand() is seeded per-process and would make every run a
// different test.
static unsigned int gSeed = 0x5eed1234u;
static unsigned int Rnd(void)
{
    gSeed = gSeed * 1103515245u + 12345u;
    return (gSeed >> 16) & 0x7fffu;
}

#pragma mark - Queue-level contention

// Hammer -setDesiredRequests: from the main thread while the worker is picking
// requests off the other end. This is the app's hottest lock by a wide margin:
// during a live scroll it is taken on every bounds notification, and the worker
// takes it once per page and once per delivery.
static void StressQueueChurn(NSURL *url, int rounds)
{
    printf("\n[queue churn: %d rounds of wanted-set replacement under load]\n", rounds);
    NSError *err = nil;
    PVPDFSource *src = [[PVPDFSource alloc] initWithURL:url error:&err];
    if (!src) { printf("  FAIL  could not open fixture\n"); gFail++; return; }

    NSUInteger pages = [src pageCount];
    @autoreleasepool {
    PVRenderQueue *q = [[PVRenderQueue alloc] initWithSource:src label:"com.postview.stress"];
    int i;
    for (i = 0; i < rounds; i++) {
        NSMutableArray *reqs = [NSMutableArray array];
        NSUInteger base = (NSUInteger)(Rnd() % (unsigned)pages);
        int k;
        for (k = 0; k < 6; k++) {
            NSUInteger p = (base + (NSUInteger)k) % pages;
            // Vary the size so some requests match work already in flight and
            // some deliberately do not.
            CGFloat scale = 1.0 + (CGFloat)(i % 3) * 0.25;
            [reqs addObject:[PVRenderRequest page:p
                                           pixels:CGSizeMake(220 * scale, 300 * scale)
                                         priority:(k & 1) ? PVPriorityNearFull
                                                          : PVPriorityVisiblePreview
                                          preview:(k & 1) ? NO : YES
                                          express:(i % 17 == 0 && k == 0)]];
        }
        [q setDesiredRequests:reqs];
        // Interleave the two state flips that can race the worker's own
        // check-and-clear of the running slot.
        if (i % 5 == 0)  [q setSuspended:YES];
        if (i % 5 == 1)  [q setSuspended:NO];
        if (i % 23 == 0) Pump(0.002);
    }
    [q setSuspended:NO];
    Pump(0.30);

    [q shutdown];
    // The worker sees _shutdown on its next iteration; give it that iteration.
    Pump(0.40);
    OK([q isIdle], "queue is idle after churn and shutdown");
    OK([q inFlightCount] == 0, "nothing is left marked in flight after churn");
    [q release];
    }
    [src release];
    CensusIsZero("PVRenderQueue", "every churned queue was deallocated", 20.0);
}

// Release the queue while it is mid-render and never call -shutdown first. The
// worker block holds its own reference, so this must still unwind cleanly.
static void StressAbandonMidRender(NSURL *url, int rounds)
{
    printf("\n[abandon: %d queues released while rasterising]\n", rounds);
    NSError *err = nil;
    PVPDFSource *src = [[PVPDFSource alloc] initWithURL:url error:&err];
    if (!src) { printf("  FAIL  could not open fixture\n"); gFail++; return; }
    int i;
    for (i = 0; i < rounds; i++) {
        @autoreleasepool {
            PVRenderQueue *q = [[PVRenderQueue alloc] initWithSource:src
                                                               label:"com.postview.stress.abandon"];
            NSMutableArray *reqs = [NSMutableArray array];
            int k;
            for (k = 0; k < 4; k++)
                [reqs addObject:[PVRenderRequest page:(NSUInteger)k
                                               pixels:CGSizeMake(700, 950)
                                             priority:PVPriorityVisibleFull preview:NO]];
            [q setDesiredRequests:reqs];
            Pump(0.001);              // let the worker get its teeth into a page
            [q release];              // no -shutdown: the abandoned-object path
        }
    }
    // Every abandoned queue's worker has to unwind and drop its own reference.
    // An abandoned queue is not cancelled -- nobody called -shutdown -- so it
    // finishes the whole set it was given before its last reference goes. That
    // is the point of the check: the unwinding has to complete, not be quick.
    // Under ThreadSanitizer a full-resolution page is an order of magnitude
    // slower, so the deadline is sized for that; a queue that never unwinds
    // still fails.
    CensusIsZero("PVRenderQueue", "abandoned queues all deallocated", 120.0);
    [src release];
}

#pragma mark - Controller-level contention

// The real thing: a live controller with a busy queue, taking the whole set of
// asynchronous events the app can receive, in an order no user would produce
// but the system can.
static void StressControllerEvents(NSURL *url, int rounds)
{
    printf("\n[controller: %d rounds of interleaved events under render load]\n", rounds);
    NSError *err = nil;
    PVPDFSource *src = [[PVPDFSource alloc] initWithURL:url error:&err];
    if (!src) { printf("  FAIL  could not open fixture\n"); gFail++; return; }

    NSUInteger pages = [src pageCount];

    // The controller's entire life is inside a pool. AppKit retains and
    // autoreleases a delegate around its own callbacks, so a controller left
    // in the enclosing pool's scope is still referenced when the census runs,
    // and the census reads it as a leak that is not one.
    @autoreleasepool {
    PVWindowController *wc = [[PVWindowController alloc] initWithSource:src url:url];
    [wc showWindow:nil];
    Pump(0.05);

    int i;
    for (i = 0; i < rounds; i++) {
        @autoreleasepool {
            switch (Rnd() % 10) {
                case 0: [wc goToPageNumber:(NSInteger)(Rnd() % (unsigned)pages) + 1]; break;
                case 1: [wc zoomIn:nil];  break;
                case 2: [wc zoomOut:nil]; break;
                case 3: [wc zoomFitWidth:nil]; break;
                // Memory pressure while pages are mid-flight: the delivery
                // that lands afterwards writes into a cache that was emptied
                // between its render starting and its bitmap arriving.
                case 4: [wc memoryPressure:nil]; break;
                // Occlusion suspends the queue mid-page.
                case 5: [wc windowOcclusionChanged:nil]; break;
                // A display change empties the cache under queued deliveries.
                case 6: [wc backingPropertiesChanged:nil]; break;
                case 7: [wc willStartLiveScroll:nil];
                        [wc scrollToPage:(NSUInteger)(Rnd() % (unsigned)pages) fraction:0.5];
                        [wc clipBoundsChanged:nil];
                        [wc didEndLiveScroll:nil]; break;
                case 8: [wc showSidebar]; break;
                case 9: [wc hideSidebar]; break;
            }
            // Most rounds do not pump at all, so events pile onto a queue that
            // is still working through the previous round's set.
            if ((Rnd() % 8) == 0) Pump(0.004);
        }
    }
    Pump(0.40);

    [[wc window] performClose:nil];
    Pump(0.05);
    [wc release];
    }
    [src release];

    CensusIsZero("PVWindowController", "controller deallocated after event storm", 20.0);
    CensusIsZero("PVRenderQueue",      "both render queues deallocated",           20.0);
    CensusIsZero("PVImageCache",       "both caches deallocated",                  20.0);
    CensusIsZero("PVPDFSource",        "both PDF sources deallocated",             20.0);
    CensusIsZero("PVPageView",         "page view deallocated",                    20.0);
    CensusIsZero("PVThumbStripView",   "thumb strip deallocated",                  20.0);
}

// Close the document while the queue is at its busiest and nothing has been
// delivered yet. Repeated, because the window that matters is one main-queue
// hop wide.
static void StressCloseUnderLoad(NSURL *url, int rounds)
{
    printf("\n[close-under-load: %d documents closed mid-render]\n", rounds);
    int i;
    for (i = 0; i < rounds; i++) {
        @autoreleasepool {
            NSError *err = nil;
            PVPDFSource *src = [[PVPDFSource alloc] initWithURL:url error:&err];
            if (!src) continue;
            PVWindowController *wc = [[PVWindowController alloc] initWithSource:src url:url];
            [wc showWindow:nil];
            [wc goToPageNumber:(i % 30) + 1];
            [wc showSidebar];
            // Deliberately short: the renders are still in flight.
            Pump(0.002 + 0.001 * (double)(i % 5));
            [[wc window] performClose:nil];
            [wc release];
            [src release];
        }
    }
    CensusIsZero("PVWindowController", "no controller survives a mid-render close", 30.0);
    CensusIsZero("PVRenderQueue",      "no render queue survives a mid-render close", 30.0);
    CensusIsZero("PVPDFSource",        "no PDF source survives a mid-render close",   30.0);
    CensusIsZero("PVImageCache",       "no cache survives a mid-render close",        30.0);
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: pvstress <pdf> [scale]\n"); return 2; }
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        int scale = (argc > 2) ? atoi(argv[2]) : 1;
        if (scale < 1) scale = 1;

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        // Reading positions are written through the shared store, so this is
        // run with HOME pointed at a scratch directory (see the makefile
        // target) rather than over the user's real DocumentState.plist.

        StressQueueChurn(url, 400 * scale);
        StressAbandonMidRender(url, 60 * scale);
        StressControllerEvents(url, 600 * scale);
        StressCloseUnderLoad(url, 40 * scale);

        printf("\n%d passed, %d failed\n", gPass, gFail);
        return gFail ? 1 : 0;
    }
}
