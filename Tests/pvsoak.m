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

#include <sys/sysctl.h>
#include <libproc.h>

static void Pump(double seconds)
{
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

// Physical footprint, or resident size where the kernel cannot report it.
//
// task_vm_info_data_t gained phys_footprint in the REV1 revision, which
// Mavericks' <mach/task_info.h> does not have -- the field simply is not in the
// struct there, so naming it is a compile error rather than a runtime fallback.
// The revision is therefore tested for at compile time, and the count is checked
// at run time as well: an older kernel can answer a TASK_VM_INFO request with a
// short struct, and reading phys_footprint out of it would be reading past what
// was filled in.
static double FootprintMB(void)
{
#if defined(TASK_VM_INFO_REV1_COUNT)
    task_vm_info_data_t info;
    mach_msg_type_number_t vmCount = TASK_VM_INFO_REV1_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO,
                  (task_info_t)&info, &vmCount) == KERN_SUCCESS &&
        vmCount >= TASK_VM_INFO_REV1_COUNT)
        return (double)info.phys_footprint / (1024.0 * 1024.0);
#endif

    mach_task_basic_info_data_t basic;
    mach_msg_type_number_t basicCount = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  (task_info_t)&basic, &basicCount) == KERN_SUCCESS)
        return (double)basic.resident_size / (1024.0 * 1024.0);
    return 0;
}

// Resident bytes in every direct child of this process, summed.
//
// The gate above measures mach_task_self() and nothing else, which was true of
// the whole program right up until rasterisation moved into a helper process.
// After that the largest single consumer in the system was invisible to it:
// measured at 183-242 MB of helper RSS against 34-40 MB in the parent, with the
// soak reporting a clean, flat 40 MB the entire time. A steady state that
// excludes most of the memory is not a steady state.
//
// sysctl(KERN_PROC_ALL) and proc_pidinfo, not task_for_pid: reading another
// task's port needs privileges this test does not have and should not need,
// while both of these work unprivileged on a process of the same user, and both
// have been present since well before 10.9.
static double HelperResidentMB(void)
{
    int mib[3];
    mib[0] = CTL_KERN; mib[1] = KERN_PROC; mib[2] = KERN_PROC_ALL;

    size_t length = 0;
    if (sysctl(mib, 3, NULL, &length, NULL, 0) != 0 || length == 0) return 0;
    // Processes can appear between the sizing call and the fetch, so ask for
    // more room than was quoted rather than failing the whole measurement over
    // a helper that started in between.
    length += length / 8 + 4096;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(length);
    if (!procs) return 0;
    if (sysctl(mib, 3, procs, &length, NULL, 0) != 0) { free(procs); return 0; }

    pid_t self = getpid();
    unsigned long long total = 0;
    size_t i, n = length / sizeof(struct kinfo_proc);
    for (i = 0; i < n; i++) {
        if (procs[i].kp_eproc.e_ppid != self) continue;
        struct proc_taskinfo info;
        int got = proc_pidinfo(procs[i].kp_proc.p_pid, PROC_PIDTASKINFO, 0,
                               &info, sizeof(info));
        // A helper that exited between the listing and this call reports
        // nothing, which is the correct contribution for a process that is gone.
        if (got == (int)sizeof(info)) total += info.pti_resident_size;
    }
    free(procs);
    return (double)total / (1024.0 * 1024.0);
}

// The pid of a direct child, or 0. Used only to notice that the helper serving
// renders has CHANGED, which is what recycling looks like from outside.
static pid_t FirstChildPid(void)
{
    int mib[3];
    mib[0] = CTL_KERN; mib[1] = KERN_PROC; mib[2] = KERN_PROC_ALL;
    size_t length = 0;
    if (sysctl(mib, 3, NULL, &length, NULL, 0) != 0 || length == 0) return 0;
    length += length / 8 + 4096;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(length);
    if (!procs) return 0;
    if (sysctl(mib, 3, procs, &length, NULL, 0) != 0) { free(procs); return 0; }
    pid_t self = getpid(), found = 0;
    size_t i, n = length / sizeof(struct kinfo_proc);
    for (i = 0; i < n && !found; i++)
        if (procs[i].kp_eproc.e_ppid == self) found = procs[i].kp_proc.p_pid;
    free(procs);
    return found;
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

        // The memory the old gate could not see.
        //
        // Everything above measures mach_task_self(), which stopped describing
        // this program when rasterisation moved into a child process. The
        // helper holds one CGPDFDocumentRef for its whole life and Quartz never
        // gives back what it caches behind that -- fonts, shadings, decoded
        // images -- so the footprint that matters is the parent's plus every
        // helper's, and it is the helper's that grows.
        //
        // Hundreds of renders of ONE document, which is the shape of a reading
        // session and the shape the old single-pool helper grew under. The
        // large frames are included deliberately: they are the other trigger
        // for retiring a helper, and a zoomed page is where the parse cache is
        // biggest.
        printf("\n[helper process footprint]\n");
        {
            NSError *e = nil;
            PVPDFSource *s = [[PVPDFSource alloc] initWithURL:url error:&e];
            OK(s != nil, "a source for the helper footprint run");

            const int kRenders = 200;
            double helperPeak = 0, aggregatePeak = 0;
            double *helperSamples = (double *)calloc(kRenders, sizeof(double));
            NSMutableSet *pidsSeen = [NSMutableSet set];
            int r, rendered = 0;

            for (r = 0; s && r < kRenders; r++) {
                // Mostly ordinary reading sizes, with every sixteenth render a
                // deliberately enormous one. PVClampPixelSize holds it to the
                // machine's ceiling, which on a large-memory tier is past
                // PV_HELPER_LARGE_FRAME -- so this exercises the size trigger
                // as well as the count trigger.
                CGSize px = (r % 64 == 63) ? CGSizeMake(6000, 7800)
                                           : CGSizeMake(900 + (r % 5) * 60,
                                                        1160 + (r % 5) * 78);
                CGImageRef im = [s createImageForPage:(NSUInteger)(r % [s pageCount])
                                            pixelSize:px];
                if (im) { rendered++; CGImageRelease(im); }

                double h = HelperResidentMB();
                helperSamples[r] = h;
                if (h > helperPeak) helperPeak = h;
                double aggregate = FootprintMB() + h;
                if (aggregate > aggregatePeak) aggregatePeak = aggregate;

                // Which helper served it. A helper that is never retired keeps
                // one pid for the whole run; recycling shows up here as several.
                pid_t child = FirstChildPid();
                if (child > 0)
                    [pidsSeen addObject:[NSNumber numberWithInt:(int)child]];
            }

            char msg[240];
            snprintf(msg, sizeof msg, "%d of %d renders succeeded", rendered, kRenders);
            OK(rendered >= kRenders - 2, msg);

            // The gate can see the helper at all. This is the actual defect:
            // not that the number was too large, but that it was not in the
            // measurement, so no threshold anywhere could have caught it.
            snprintf(msg, sizeof msg,
                     "helper memory is visible to the gate (peak %.1f MB in children)",
                     helperPeak);
            OK(helperPeak > 0.5, msg);

            double h1 = Median(helperSamples, kRenders / 2, kRenders * 3 / 4);
            double h2 = Median(helperSamples, kRenders * 3 / 4, kRenders);
            printf("  helper resident, median    : %.1f -> %.1f MB "
                   "(second half of the run)\n", h1, h2);
            printf("  helper resident, peak      : %.1f MB\n", helperPeak);
            printf("  parent + helpers, peak     : %.1f MB\n", aggregatePeak);
            printf("  distinct helpers over %d renders: %lu\n",
                   kRenders, (unsigned long)[pidsSeen count]);

            // Recycling happened. Without it one process serves all four
            // hundred renders and its parse cache only ever grows.
            snprintf(msg, sizeof msg,
                     "the helper is retired and replaced during a long session "
                     "(%lu distinct helpers)", (unsigned long)[pidsSeen count]);
            OK([pidsSeen count] >= 2, msg);

            // And the footprint is flat across the back half rather than
            // climbing. Generous, because a helper's resident set steps up and
            // down as documents are parsed and processes are replaced; what is
            // being excluded is a monotonic climb, which over four hundred
            // renders would be unmistakable.
            snprintf(msg, sizeof msg,
                     "helper memory does not climb across a long session "
                     "(%+.1f MB over the last %d renders)", h2 - h1, kRenders / 4);
            OK(h2 - h1 < 60.0, msg);

            free(helperSamples);
            [s release];
            // Releasing the source kills and reaps its helper, so nothing is
            // left behind for the cycle trend below to attribute to itself.
            OK(HelperResidentMB() < 0.001,
               "releasing the source leaves no helper process behind");
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
