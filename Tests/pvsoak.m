//  pvsoak.m — the multi-day-uptime check, compressed.
//
//  Drives the full document lifecycle over and over: open, lay out, scroll,
//  zoom, show and hide thumbnails, jump pages, close, release. A leak or an
//  accounting drift that would take days to become visible in normal use shows
//  up here in seconds, because the cycle is the same one the app performs every
//  time you open a file.
//
//  It asserts three things:
//    * physical footprint reaches a steady state and stops climbing
//    * the bitmap cache never exceeds its byte budget, and its byte counter
//      agrees with the images it actually holds
//    * every render queue created is eventually deallocated
//
//    make soak

#import "PVCommon.h"
#import "PVPDFSource.h"
#import "PVImageCache.h"
#import "PVRenderQueue.h"
#import "PVWindowController.h"
#import "PVStateStore.h"
#import <mach/mach.h>

static int gPass = 0, gFail = 0;
static void OK(int cond, const char *what)
{
    if (cond) { gPass++; printf("  ok    %s\n", what); }
    else      { gFail++; printf("  FAIL  %s\n", what); }
}

static void Pump(double seconds)
{
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static double FootprintMB(void)
{
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS)
        return (double)info.phys_footprint / (1024.0 * 1024.0);
    struct mach_task_basic_info b;
    count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&b, &count) == KERN_SUCCESS)
        return (double)b.resident_size / (1024.0 * 1024.0);
    return 0;
}

static int CmpDouble(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x < y) ? -1 : (x > y) ? 1 : 0;
}

// Median of samples[lo..hi), computed on a copy so the caller's order survives.
static double Median(const double *v, int lo, int hi)
{
    int n = hi - lo;
    if (n <= 0) return 0;
    double *tmp = (double *)malloc((size_t)n * sizeof(double));
    if (!tmp) return 0;
    memcpy(tmp, v + lo, (size_t)n * sizeof(double));
    qsort(tmp, (size_t)n, sizeof(double), CmpDouble);
    double m = (n % 2) ? tmp[n / 2] : (tmp[n / 2 - 1] + tmp[n / 2]) / 2.0;
    free(tmp);
    return m;
}

// One full open/use/close cycle, exactly as the app performs it.
static void Cycle(NSURL *url, int i)
{
    @autoreleasepool {
        NSError *err = nil;
        PVPDFSource *src = [[PVPDFSource alloc] initWithURL:url error:&err];
        if (!src) { fprintf(stderr, "open failed\n"); exit(2); }

        PVWindowController *wc = [[PVWindowController alloc] initWithSource:src url:url];
        [wc showWindow:nil];
        Pump(0.05);

        [wc goToPageNumber:(i % 40) + 1];      // jump somewhere new each time
        Pump(0.03);
        [wc zoomIn:nil];
        [wc zoomIn:nil];
        Pump(0.03);
        [wc toggleSidebar:nil];                // builds the second source+queue+cache
        Pump(0.06);
        [wc toggleSidebar:nil];                // and tears the bitmaps back down
        [wc zoomFitWidth:nil];
        [wc goToPageNumber:1];
        Pump(0.03);

        [[wc window] performClose:nil];        // the real teardown path
        Pump(0.03);
        [wc release];
        [src release];
    }
    // Let any in-flight render finish and release its queue.
    Pump(0.05);
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: pvsoak <pdf> [cycles]\n"); return 2; }
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        int cycles = (argc > 2) ? atoi(argv[2]) : 60;
        if (cycles < 20) cycles = 20;

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        printf("[cache accounting]\n");
        {
            // The byte counter must track what CoreGraphics really allocated,
            // including the row padding CG adds, and must never be driven
            // negative by unbalanced bookkeeping.
            PVImageCache *c = [[PVImageCache alloc] initWithBudget:4 * 1024 * 1024];
            NSError *e = nil;
            PVPDFSource *s = [[PVPDFSource alloc] initWithURL:url error:&e];
            size_t expect = 0;
            int i;
            for (i = 0; i < 12; i++) {
                CGSize px = CGSizeMake(301, 407);   // deliberately not row-aligned
                CGImageRef im = [s createImageForPage:(NSUInteger)i pixelSize:px];
                if (!im) continue;
                [c setFullImage:im pixelSize:px forPage:(NSUInteger)i];
                expect = PVImageBytes(im);
                CGImageRelease(im);
            }
            OK(expect > (size_t)(301 * 407 * 4),
               "byte accounting uses the real row-padded size, not width*height*4");
            OK([c byteCount] <= 4 * 1024 * 1024, "cache stays inside its byte budget");
            [c dropFullImages];
            OK([c byteCount] == 0, "dropping every full image returns the counter to zero");
            OK([c entryCount] == 0, "emptied entries are removed, not left behind");
            [c removeAll];
            OK([c byteCount] == 0, "removeAll leaves a zero byte count");
            [s release];
            [c release];
        }

        printf("\n[render queue lifecycle]\n");
        {
            NSError *e = nil;
            PVPDFSource *s = [[PVPDFSource alloc] initWithURL:url error:&e];
            PVRenderQueue *q = [[PVRenderQueue alloc] initWithSource:s label:"soak"];
            [q setDesiredRequests:[NSArray arrayWithObject:
                [PVRenderRequest page:0 pixels:CGSizeMake(400, 520)
                             priority:PVPriorityVisibleFull preview:NO]]];
            // Shut down while work is very likely still in flight. This must
            // not block the caller and must not deadlock.
            NSDate *t0 = [NSDate date];
            [q shutdown];
            double blocked = -[t0 timeIntervalSinceNow];
            OK(blocked < 0.050, "shutdown does not block the caller on an in-flight page");
            Pump(0.4);
            OK([q isIdle], "queue reports idle once the drain has unwound");
            // The marker that keeps a rendered-but-undelivered page from being
            // rendered again. If it could ever be left behind, that page would
            // be permanently unrequestable for the life of the document -- a
            // page that never goes sharp, which is exactly the class of fault
            // that only shows up after a long session.
            OK([q inFlightCount] == 0, "no work is left marked in flight after a shutdown");
            [q release];
            Pump(0.4);
            OK(PVLiveCount("PVRenderQueue") == 0,
               "a queue released while draining is still deallocated");
            [s release];
        }

        {
            const char * const *tr = PVLiveTrackedClasses();
            int t2, dirty = 0;
            for (t2 = 0; tr[t2]; t2++) if (PVLiveCount(tr[t2]) != 0) dirty = 1;
            OK(!dirty, "census is clean before the soak begins");
        }

        printf("\n[soak: %d open/use/close cycles]\n", cycles);
        // The allocator returns pages to the OS in large irregular steps, so a
        // single before/after reading of the footprint is close to meaningless:
        // across a flat run it swings tens of megabytes either way. The trend
        // is taken from the MEDIAN of each half instead, which is insensitive
        // to that sawtooth while still exposing any genuine monotonic climb.
        int warm = 25;
        int i;
        for (i = 0; i < warm; i++) Cycle(url, i);
        double base = FootprintMB();
        printf("  footprint after %d warm-up cycles: %.1f MB\n", warm, base);

        double *samples = (double *)calloc((size_t)cycles, sizeof(double));
        if (!samples) { fprintf(stderr, "out of memory\n"); return 2; }
        // The warm-up's peaks say nothing about the steady state, and the
        // high-water mark is a maximum: without a reset here it would report
        // whatever the first twenty-five cycles happened to touch, forever.
        PVResidentReset();
        double peak = base;
        for (i = 0; i < cycles; i++) {
            Cycle(url, warm + i);
            samples[i] = FootprintMB();
            if (samples[i] > peak) peak = samples[i];
            if ((i + 1) % 25 == 0)
                printf("  after %3d more cycles: %6.1f MB\n", i + 1, samples[i]);
        }

        // The direct invariant. Process footprint is a noisy proxy dominated by
        // the frameworks' own caches; this is the thing actually under our
        // control, and it must go to exactly zero.
        //
        // AppKit defers the last window's release by an indeterminate number of
        // runloop turns, so the most recently closed document is legitimately
        // still alive for a moment after -performClose: returns. Waiting a
        // fixed interval made this test flaky on a busy machine. Instead, wait
        // for the census to clear with a deadline: a genuine leak never clears
        // and still fails, while normal teardown latency no longer decides the
        // result. How long it took is reported, so a regression that slows
        // teardown down is visible rather than silently absorbed.
        printf("\n[live objects after %d cycles]\n", warm + cycles);
        const char * const *tracked = PVLiveTrackedClasses();
        int t;
        double waited = 0.0;
        // A passing run breaks out the instant the census clears and pays none
        // of this, so the deadline only needs to be past any plausible teardown
        // latency. Rendering runs at background QoS by design, so a queue shut
        // down mid-page can legitimately take a moment to retire; what must
        // never happen is the count sitting still, which is what a genuine leak
        // -- or a starved render queue -- looks like. How long it actually took
        // is printed either way, so a regression that slows teardown is visible
        // rather than absorbed.
        const double kDeadline = 30.0;
        for (;;) {
            int outstanding = 0;
            for (t = 0; tracked[t]; t++)
                if (PVLiveCount(tracked[t]) != 0) outstanding++;
            if (!outstanding || waited >= kDeadline) break;
            @autoreleasepool { Pump(0.05); }
            waited += 0.05;
        }
        printf("  (all documents retired %.2f s after the last close)\n", waited);
        OK(waited < kDeadline, "teardown completes well inside the deadline");
        for (t = 0; tracked[t]; t++) {
            long n = PVLiveCount(tracked[t]);
            char msg[160];
            snprintf(msg, sizeof msg, "%-20s live=%ld (expected 0)", tracked[t], n);
            OK(n == 0, msg);
        }

        // ------------------------------------------------------------------
        // Resident rendered pixels.
        //
        // The footprint trend below is a proxy: it is dominated by AppKit,
        // CoreText and CoreGraphics filling their own caches, and by an
        // allocator that returns pages in irregular steps. This section is the
        // part of the footprint Postview actually decides, measured directly.
        //
        // Two claims, and the second is the one that matters. The high-water
        // marks say how much was resident at the worst instant of the run --
        // the number every memory change in the render pipeline is aimed at.
        // The totals say what is resident now, after every document has been
        // closed and every queue shut down, and that must be exactly zero: a
        // census that does not return to zero is not measuring what it claims
        // to, and any peak it reports is a number about nothing.
        // ------------------------------------------------------------------
        printf("\n[resident rendered pixels]\n");
        const double kMB = 1024.0 * 1024.0;
        printf("  high water, all buckets      : %.1f MB\n",
               (double)PVResidentHighWater() / kMB);
        printf("    of which cache             : %.1f MB\n",
               (double)PVResidentHighWaterForBucket(PVResidentCache) / kMB);
        printf("    of which undelivered       : %.1f MB  (cap %d full bitmaps)\n",
               (double)PVResidentHighWaterForBucket(PVResidentUndelivered) / kMB,
               PV_MAX_INFLIGHT_FULL);
        printf("    of which mid-rasterisation : %.1f MB\n",
               (double)PVResidentHighWaterForBucket(PVResidentRender) / kMB);
        {
            size_t leftRender      = PVResidentBytes(PVResidentRender);
            size_t leftUndelivered = PVResidentBytes(PVResidentUndelivered);
            size_t leftCache       = PVResidentBytes(PVResidentCache);
            size_t leftTotal       = PVResidentTotal();
            char msg[200];
            printf("  still resident after teardown: %.3f MB "
                   "(render %.3f, undelivered %.3f, cache %.3f)\n",
                   (double)leftTotal / kMB, (double)leftRender / kMB,
                   (double)leftUndelivered / kMB, (double)leftCache / kMB);
            snprintf(msg, sizeof msg,
                     "resident bitmap census returns to zero (%lu bytes left)",
                     (unsigned long)leftTotal);
            OK(leftTotal == 0, msg);
        }

        printf("\n[footprint trend]\n");
        // Measured over the LAST half of the run, not the whole of it.
        //
        // The question this has to answer is whether the process is still
        // growing once it has settled, because that is what decides whether a
        // document can be left open for days. Comparing the first half against
        // the second answers a different question -- it includes the frameworks
        // filling their own caches, which is a fixed cost paid once and looks
        // exactly like a slow leak while it is being paid.
        //
        // It is not a small effect. A 400-cycle run climbs 169 -> 180 -> 197 MB
        // and then stops, flat to within a megabyte for the last hundred
        // cycles; measured across the whole run that reads as +0.06 MB/cycle,
        // and measured across only the first 150 it reads as +0.26, purely
        // because the fill is still in progress there. Two quarters at the end
        // of the run see none of it.
        int q = cycles / 4;
        if (q < 2) q = 2;
        double m1 = Median(samples, cycles - 2 * q, cycles - q);
        double m2 = Median(samples, cycles - q, cycles);
        double climb = m2 - m1;
        double perCycle = climb / q;

        // Reported as well, because the difference between the two is the size
        // of the one-off fill and is worth being able to see.
        double whole1 = Median(samples, 0, cycles / 2);
        double whole2 = Median(samples, cycles / 2, cycles);

        printf("\n  median footprint, whole run  : %.1f -> %.1f MB (includes cache warm-up)\n",
               whole1, whole2);
        printf("  median footprint, settled    : %.1f -> %.1f MB (last %d cycles)\n",
               m1, m2, 2 * q);
        printf("  climb once settled %+.2f MB across %d cycles = %+.4f MB per cycle, peak %.1f MB\n",
               climb, q, perCycle, peak);

        // Secondary, and only asserted when there are enough samples to mean
        // anything. Postview's own accounting is pinned exactly by the census
        // above; what is left in this number is AppKit, CoreText and
        // CoreGraphics filling their internal caches, plus an allocator that
        // returns pages to the OS in large irregular steps. Across three
        // identical 50-cycle runs this figure came out at +0.02, +0.20 and
        // +0.98 MB/cycle -- it is simply too noisy to assert on at that sample
        // size, and a test that fails at random is worse than no test. Given
        // enough cycles it settles, so it is asserted there and reported
        // otherwise. A real runaway shows up in the census first regardless:
        // one leaked page bitmap per cycle is ~4 MB, fifty times this limit.
        //
        // The threshold is set well clear of the noise band rather than just
        // above it. What it needs to catch is memory growing outside the
        // census -- a CGImage that never reaches the cache, say -- and that is
        // megabytes per cycle, not kilobytes.
        const int kMinSamplesToAssert = 150;
        if (cycles >= kMinSamplesToAssert) {
            OK(perCycle < 0.250, "footprint shows no runaway growth per cycle");
        } else {
            printf("  note  footprint trend not asserted below %d cycles "
                   "(too noisy); run `make soak SOAKCYCLES=%d`\n",
                   kMinSamplesToAssert, kMinSamplesToAssert);
        }
        OK(peak - m1 < 80.0, "no unbounded peak across the run");
        free(samples);

        printf("\n%d passed, %d failed\n", gPass, gFail);
        return gFail ? 1 : 0;
    }
}
