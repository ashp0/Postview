//  pvtest.m — headless checks for the parts of Postview that have no visible
//  surface: layout maths, cache eviction, the render queue, and persistence.
//  Built for the same x86_64 / 10.9 target as the app so it exercises the exact
//  shipping code paths.   make test

#import "PVCommon.h"
#include <dispatch/block.h>
#include <dlfcn.h>
#include <sys/qos.h>
#include <unistd.h>
#import "PVPDFSource.h"
#import "PVImageCache.h"
#import "PVRenderQueue.h"
#import "PVPageView.h"
#import "PVStateStore.h"

static int gFail = 0, gPass = 0;

static void OK(BOOL cond, const char *what)
{
    if (cond) { gPass++; printf("  ok    %s\n", what); }
    else      { gFail++; printf("  FAIL  %s\n", what); }
}

static double NowMs(void) { return [NSDate timeIntervalSinceReferenceDate] * 1000.0; }

#pragma mark - Render queue collector

@interface Collector : NSObject <PVRenderQueueDelegate> {
@public
    NSMutableArray *pages;
    NSMutableArray *failed;
    BOOL onMainThread;
    BOOL quiet;            // suppress the per-image assertion in bulk tests
}
@end
@implementation Collector
- (id)init
{
    self = [super init];
    if (self) {
        pages  = [[NSMutableArray alloc] init];
        failed = [[NSMutableArray alloc] init];
        onMainThread = YES;
    }
    return self;
}
- (void)dealloc { [pages release]; [failed release]; [super dealloc]; }
- (void)renderQueue:(PVRenderQueue *)q didRenderPage:(NSUInteger)page image:(CGImageRef)img
          pixelSize:(CGSize)px preview:(BOOL)preview
{
    if (![NSThread isMainThread]) onMainThread = NO;
    if (!quiet) OK(img != NULL, "render queue delivered a non-NULL image");
    [pages addObject:[NSNumber numberWithUnsignedLongLong:page]];
}
- (void)renderQueue:(PVRenderQueue *)q didFailPage:(NSUInteger)page
          pixelSize:(CGSize)px preview:(BOOL)preview
{
    if (![NSThread isMainThread]) onMainThread = NO;
    [failed addObject:[NSNumber numberWithUnsignedLongLong:page]];
}
@end

static void PumpRunLoop(double seconds)
{
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

#pragma mark - Tests

// Returns the fraction of the bitmap's width and height actually covered by
// non-white pixels. Catches a page that renders correct-sized but with the
// content shrunk into the middle -- which is exactly what
// CGPDFPageGetDrawingTransform does if you let it scale a page up.
static void InkCoverage(CGImageRef img, double *outW, double *outH)
{
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    size_t stride = w * 4;
    unsigned char *buf = (unsigned char *)calloc(h, stride);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(buf, w, h, 8, stride, cs,
        (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(cs);
    CGContextDrawImage(c, CGRectMake(0, 0, w, h), img);

    size_t minX = w, maxX = 0, minY = h, maxY = 0;
    BOOL any = NO;
    for (size_t y = 0; y < h; y++) {
        for (size_t x = 0; x < w; x++) {
            unsigned char *p = buf + y * stride + x * 4;
            // bytes are B,G,R,<skipped alpha>; index 3 is padding, not colour
            if (p[0] < 235 || p[1] < 235 || p[2] < 235) {
                any = YES;
                if (x < minX) minX = x;  if (x > maxX) maxX = x;
                if (y < minY) minY = y;  if (y > maxY) maxY = y;
            }
        }
    }
    *outW = any ? (double)(maxX - minX + 1) / (double)w : 0.0;
    *outH = any ? (double)(maxY - minY + 1) / (double)h : 0.0;
    CGContextRelease(c);
    free(buf);
}

static void TestSource(PVPDFSource *src)
{
    printf("\n[PVPDFSource]\n");
    OK([src pageCount] == 60, "page count is 60");
    CGSize s = [src pointSizeOfPage:0];
    OK(fabs(s.width - 612) < 1 && fabs(s.height - 792) < 1, "page 0 is US Letter");
    OK(fabs([src maxPointSize].width - 612) < 1, "max page width is 612");
    CGSize oob = [src pointSizeOfPage:9999];
    OK(oob.width > 0 && oob.height > 0, "out-of-range page returns a safe fallback size");

    CGImageRef img = [src createImageForPage:0 pixelSize:CGSizeMake(612, 792)];
    OK(img != NULL, "rendered page 0");
    OK(img && CGImageGetWidth(img) == 612 && CGImageGetHeight(img) == 792, "bitmap has exact requested size");
    if (img) CGImageRelease(img);

    // Content must FILL the bitmap at every scale, including well above the
    // page's natural size (the fit-width / Retina case).
    double cw = 0, ch = 0;
    struct { const char *name; CGSize px; } scales[] = {
        { "natural size 612x792",   { 612,  792  } },
        { "2x upscale 1224x1584",   { 1224, 1584 } },
        { "fit-width-ish 1600x2071",{ 1600, 2071 } },
        { "preview 204x264",        { 204,  264  } },
    };
    for (unsigned i = 0; i < sizeof(scales)/sizeof(scales[0]); i++) {
        CGImageRef im = [src createImageForPage:0 pixelSize:scales[i].px];
        if (!im) { OK(NO, scales[i].name); continue; }
        InkCoverage(im, &cw, &ch);
        char msg[160];
        snprintf(msg, sizeof msg, "content fills the bitmap at %s (ink %.0f%% x %.0f%%)",
                 scales[i].name, cw * 100, ch * 100);
        OK(cw > 0.85 && ch > 0.85, msg);
        CGImageRelease(im);
    }

    OK([src createImageForPage:9999 pixelSize:CGSizeMake(10, 10)] == NULL, "out-of-range page renders NULL");

    // 40000x40000 would be 6.4 GB. The guard used to return NULL, which kept
    // the allocation safe but left the page permanently blank AND had the
    // render queue re-request it on every scroll event, since nothing ever
    // reached the cache to stop asking. It now scales the request down to the
    // ceiling instead: still bounded, but it produces a usable page.
    CGImageRef huge = [src createImageForPage:0 pixelSize:CGSizeMake(40000, 40000)];
    OK(huge != NULL, "absurd pixel size is scaled down, not refused");
    if (huge) {
        double px = (double)CGImageGetWidth(huge) * (double)CGImageGetHeight(huge);
        OK(px <= PVMaxRenderPixels() + 1, "scaled-down bitmap respects the pixel ceiling");
        OK(CGImageGetWidth(huge) == CGImageGetHeight(huge),
           "scaling down preserves the requested aspect ratio");
        CGImageRelease(huge);
    }

    // Non-finite geometry cannot be clamped meaningfully and is still refused.
    OK([src createImageForPage:0 pixelSize:CGSizeMake(NAN, 100)] == NULL, "NaN pixel size is refused");
    OK([src createImageForPage:0 pixelSize:CGSizeMake(INFINITY, 100)] == NULL, "infinite pixel size is refused");

    CGImageRef tiny = [src createImageForPage:0 pixelSize:CGSizeMake(0, 0)];
    OK(tiny != NULL, "zero pixel size is clamped, not crashed");
    if (tiny) CGImageRelease(tiny);
}

// The render queue hardcodes two libdispatch constants so it can compile
// against 10.9 headers while still using a 10.10+ entry point through dlsym.
// Getting one wrong is silent -- the express lane simply stops promoting and
// the only symptom is that opening a document feels slower -- so pin them here
// against the real SDK values.
static void TestDispatchConstants(void)
{
    printf("\n[dispatch constants used by the express lane]\n");
    // Reading these enumerators is what the availability guard objects to, but
    // they are compile-time integers: no symbol is bound and nothing executes
    // on 10.9. Suppressed for this comparison only -- the guard stays armed
    // everywhere else, which is exactly what caught the mistake this test now
    // pins down.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
    uintptr_t sdkEnforce  = (uintptr_t)DISPATCH_BLOCK_ENFORCE_QOS_CLASS;
    uintptr_t sdkDetached = (uintptr_t)DISPATCH_BLOCK_DETACHED;
    unsigned  sdkUtility  = (unsigned)QOS_CLASS_UTILITY;
#pragma clang diagnostic pop

    OK(PV_BLOCK_ENFORCE_QOS_CLASS == sdkEnforce,
       "PV_BLOCK_ENFORCE_QOS_CLASS matches DISPATCH_BLOCK_ENFORCE_QOS_CLASS");
    OK(PV_QOS_CLASS_UTILITY == sdkUtility,
       "PV_QOS_CLASS_UTILITY matches QOS_CLASS_UTILITY");
    OK(PV_BLOCK_ENFORCE_QOS_CLASS != sdkDetached,
       "the enforce flag is not confused with DISPATCH_BLOCK_DETACHED");

    // And the entry point itself must still be resolvable, or the express lane
    // silently degrades to the slow path on every machine.
    OK(dlsym(RTLD_DEFAULT, "dispatch_block_create_with_qos_class") != NULL,
       "dispatch_block_create_with_qos_class resolves at runtime");
}

static void TestRenderSpeed(PVPDFSource *src)
{
    printf("\n[render cost — heavy vector pages, 1400 curves + 40 text lines each]\n");
    double t0 = NowMs();
    int n = 8;
    for (int i = 0; i < n; i++) {
        CGImageRef im = [src createImageForPage:i pixelSize:CGSizeMake(850, 1100)];
        if (im) CGImageRelease(im);
    }
    double full = (NowMs() - t0) / n;

    t0 = NowMs();
    for (int i = 0; i < n; i++) {
        CGImageRef im = [src createImageForPage:i pixelSize:CGSizeMake(284, 367)];
        if (im) CGImageRelease(im);
    }
    double prev = (NowMs() - t0) / n;

    printf("  full page @850x1100 : %6.1f ms/page\n", full);
    printf("  preview   @284x367  : %6.1f ms/page  (%.1fx cheaper)\n", prev, full / prev);
    OK(prev < full, "preview pass is cheaper than the full pass");
}

static void TestCache(void)
{
    printf("\n[PVImageCache]\n");
    // 4 MB budget; each 512x512 bitmap is 1 MB.
    PVImageCache *cache = [[PVImageCache alloc] initWithBudget:4 * 1024 * 1024];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();

    CGImageRef imgs[10];
    for (int i = 0; i < 10; i++) {
        CGContextRef c = CGBitmapContextCreate(NULL, 512, 512, 8, 0, cs,
            (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host);
        imgs[i] = CGBitmapContextCreateImage(c);
        CGContextRelease(c);
    }

    for (int i = 0; i < 10; i++)
        [cache setFullImage:imgs[i] pixelSize:CGSizeMake(512, 512) forPage:i];

    OK([cache fullImageForPage:9 pixelSize:CGSizeMake(512, 512)] != NULL,
       "most recently inserted page survives eviction");
    OK([cache fullImageForPage:0 pixelSize:CGSizeMake(512, 512)] == NULL,
       "oldest page was evicted under budget pressure");

    // Wrong-size lookup must miss, but still be usable as a placeholder.
    OK([cache fullImageForPage:9 pixelSize:CGSizeMake(256, 256)] == NULL,
       "exact-size lookup rejects a bitmap rendered at another zoom");
    OK([cache placeholderImageForPage:9] != NULL,
       "wrong-size bitmap is still offered as a placeholder");

    // Previews must outlive full bitmaps.
    PVImageCache *c2 = [[PVImageCache alloc] initWithBudget:3 * 1024 * 1024];
    for (int i = 0; i < 3; i++)
        [c2 setPreviewImage:imgs[i] pixelSize:CGSizeMake(512, 512) forPage:i];
    for (int i = 5; i < 8; i++)
        [c2 setFullImage:imgs[i] pixelSize:CGSizeMake(512, 512) forPage:i];
    int previewsLeft = 0;
    for (int i = 0; i < 3; i++) if ([c2 hasPreviewForPage:i]) previewsLeft++;
    OK(previewsLeft > 0, "previews survive while full bitmaps are evicted first");

    // Record exactly which previews exist, then assert the drop keeps all of
    // them. (Checking one fixed page would be wrong: some previews may already
    // have been evicted by budget pressure above.)
    BOOL before[3];
    for (int i = 0; i < 3; i++) before[i] = [c2 hasPreviewForPage:i];
    [c2 dropFullImages];
    OK([c2 fullImageForPage:7 pixelSize:CGSizeMake(512, 512)] == NULL,
       "memory-pressure drop releases full bitmaps");
    BOOL keptAll = YES;
    for (int i = 0; i < 3; i++) if (before[i] && ![c2 hasPreviewForPage:i]) keptAll = NO;
    OK(keptAll && previewsLeft > 0,
       "memory-pressure drop keeps every preview it had");

    [cache removeAll];
    OK([cache placeholderImageForPage:5] == NULL, "removeAll empties the cache");

    for (int i = 0; i < 10; i++) CGImageRelease(imgs[i]);
    CGColorSpaceRelease(cs);
    [c2 release];
    [cache release];
}

// The cache and the wanted-set have to agree about what must be resident, and
// the only proof that they do is that the loop between them stops.
//
// It did not. With two pages on screen whose full bitmaps did not both fit,
// storing the second evicted the first; the next draw found the first missing;
// the wanted-set asked for it again; storing it evicted the second. Nothing
// ever landed in the cache to break the cycle, so the render queue rasterised
// the same two heavy pages for as long as the window stayed open -- a
// background thread at full tilt on a document nobody is touching, and pages
// visibly flickering between sharp and soft. It began at 200% zoom on a Retina
// 2 GB machine.
//
// This drives the real loop -- ask what is missing, render it, store it -- and
// asserts it reaches a pass that renders nothing. Reverting either half of the
// fix (the pin, or the per-bitmap ceiling) fails it.
static void TestCacheConverges(void)
{
    printf("\n[cache reaches a steady state: no render/evict loop]\n");

    struct { const char *name; size_t budget; size_t w, h; int visible; } cases[] = {
        { "fit width, 2 pages on screen",      32u<<20,  830, 1075, 2 },
        { "retina fit width, 2 pages",         32u<<20, 1660, 2150, 2 },
        { "200% retina, 2 pages",              32u<<20, 2400, 3100, 2 },
        { "400% retina, 2 pages",              32u<<20, 3400, 4400, 2 },
        { "600% retina, 2 pages",              96u<<20, 5000, 6500, 2 },
        { "low zoom, 6 small pages on screen", 32u<<20,  420,  545, 6 },
        { "one enormous page alone",           32u<<20, 6000, 7800, 1 },
    };
    const int nc = (int)(sizeof(cases) / sizeof(cases[0]));
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();

    for (int ci = 0; ci < nc; ci++) {
        PVImageCache *c = [[PVImageCache alloc] initWithBudget:cases[ci].budget];
        // Exactly what -updateVisibleContent does before it asks for anything.
        [c setPinnedPages:NSMakeRange(0, (NSUInteger)cases[ci].visible)];

        // The renderer clamps every request, so the test has to ask for what it
        // would actually be given -- otherwise it measures a bitmap the app can
        // never produce.
        CGSize want = PVClampPixelSize(CGSizeMake((CGFloat)cases[ci].w, (CGFloat)cases[ci].h));
        size_t pw = (size_t)want.width, ph = (size_t)want.height;

        int rendersInLastPass = 0;
        for (int pass = 0; pass < 8; pass++) {
            rendersInLastPass = 0;
            for (int p = 0; p < cases[ci].visible; p++) {
                if ([c fullImageForPage:(NSUInteger)p pixelSize:want]) continue;
                CGContextRef bc = CGBitmapContextCreate(NULL, pw, ph, 8, 0, cs,
                    (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host);
                if (!bc) continue;
                CGImageRef im = CGBitmapContextCreateImage(bc);
                CGContextRelease(bc);
                if (!im) continue;
                [c setFullImage:im pixelSize:want forPage:(NSUInteger)p];
                CGImageRelease(im);
                rendersInLastPass++;
            }
        }
        char msg[160];
        snprintf(msg, sizeof msg, "%s: settles, no page re-rendered forever", cases[ci].name);
        OK(rendersInLastPass == 0, msg);
        [c release];
    }

    // The bound that makes the pin safe to hold: one bitmap can never be more
    // than a third of the budget, so the visible set cannot run away with the
    // cache however far the user zooms in.
    OK(PVMaxRenderPixels() * 4.0 <= (double)PVPageCacheBudget() / 3.0 + 1.0,
       "one bitmap can never exceed a third of the cache budget");
    OK(PVClampPixelSize(CGSizeMake(1e9, 1e9)).width * PVClampPixelSize(CGSizeMake(1e9, 1e9)).height
       <= PVMaxRenderPixels() + 1.0,
       "an absurd request is scaled down to the ceiling, not refused");
    OK(PVClampPixelSize(CGSizeMake(NAN, 100)).width == 0,
       "a non-finite request yields a zero size, which the renderer refuses");
    OK(PVClampPixelSize(CGSizeMake(0.2, 0.2)).width >= 1,
       "a degenerate request is floored at one pixel, not refused");

    CGColorSpaceRelease(cs);
}

static void TestLayout(PVPDFSource *src)
{
    printf("\n[PVPageView layout]\n");
    PVImageCache *cache = [[PVImageCache alloc] initWithBudget:PVPageCacheBudget()];
    PVPageView *v = [[PVPageView alloc] initWithSource:src cache:cache];
    [v setZoom:1.0 backingScale:1.0 containerWidth:900];

    NSUInteger n = [src pageCount];
    BOOL monotonic = YES, noOverlap = YES;
    for (NSUInteger i = 1; i < n; i++) {
        NSRect a = [v rectForPage:i - 1], b = [v rectForPage:i];
        if (NSMinY(b) <= NSMinY(a)) monotonic = NO;
        if (NSMinY(b) < NSMaxY(a))  noOverlap = NO;
    }
    OK(monotonic, "page rects increase down the document");
    OK(noOverlap, "page rects never overlap");
    OK(NSHeight([v frame]) > NSMaxY([v rectForPage:n - 1]), "document view is tall enough for the last page");

    // Exhaustive binary-search check: the search must agree with a linear scan
    // for every page, including the page-0 boundary where an unsigned underflow
    // would be easy to write.
    BOOL searchOK = YES;
    for (NSUInteger i = 0; i < n; i++) {
        NSRect r = [v rectForPage:i];
        NSRange got = [v pageRangeInRect:NSMakeRect(0, NSMinY(r) + 1, 900, 10)];
        if (got.location != i || got.length < 1) searchOK = NO;
    }
    OK(searchOK, "pageRangeInRect finds the right page for all 60 pages");

    NSRange top = [v pageRangeInRect:NSMakeRect(0, 0, 900, 5)];
    OK(top.location == 0, "rect above page 1 resolves to page 0 (no unsigned underflow)");
    NSRange all = [v pageRangeInRect:[v frame]];
    OK(all.location == 0 && all.length == n, "whole-document rect covers every page");
    NSRange past = [v pageRangeInRect:NSMakeRect(0, NSHeight([v frame]) + 500, 900, 50)];
    OK(past.location < n, "rect past the end stays in range");

    // Position round-trip: page + fraction -> scroll offset -> page + fraction.
    BOOL roundTrip = YES;
    for (NSUInteger i = 0; i < n; i += 7) {
        CGFloat frac = 0.37;
        NSRect r = [v rectForPage:i];
        CGFloat y = NSMinY(r) + frac * NSHeight(r);
        CGFloat outFrac = 0;
        NSUInteger back = [v pageAtTopOfRect:NSMakeRect(0, y, 900, 600) fraction:&outFrac];
        if (back != i || fabs(outFrac - frac) > 0.02) roundTrip = NO;
    }
    OK(roundTrip, "page+fraction survives a round trip through scroll coordinates");

    // Pixel alignment: this is what makes the common case a 1:1 blit.
    BOOL aligned = YES;
    [v setZoom:1.37 backingScale:2.0 containerWidth:900];
    for (NSUInteger i = 0; i < n; i += 5) {
        NSRect r = [v rectForPage:i];
        CGSize px = [v pixelSizeForPage:i];
        if (fabs(px.width - r.size.width * 2.0) > 0.001) aligned = NO;
        if (r.size.width != floor(r.size.width))  aligned = NO;
    }
    OK(aligned, "bitmap pixels map exactly onto device pixels at fractional zoom");

    [v setZoom:0.0001 backingScale:1.0 containerWidth:900];
    OK([v zoom] >= PV_MIN_ZOOM, "zoom is clamped at the low end");
    [v setZoom:999 backingScale:1.0 containerWidth:900];
    OK([v zoom] <= PV_MAX_ZOOM, "zoom is clamped at the high end");

    [v release];
    [cache release];
}

// A page is "in flight" from the moment the worker picks it up until its bitmap
// has been handed over on the main thread -- not merely until rasterisation
// finishes. Those two instants are one main-queue hop apart, and in between the
// bitmap exists but the cache does not have it, so a wanted-set rebuilt in that
// window used to name a page that had already been rendered. Under main-thread
// load that is a heavy page rasterised two or three times over.
//
// The window is reproduced exactly: render, let the worker finish WITHOUT
// running the run loop (so the delivery cannot be dequeued), then ask again.
static void TestRenderQueueDeduplication(NSURL *url, PVPDFSource *geom)
{
    PVPDFSource *own = [[PVPDFSource alloc] initWithURL:url geometryFrom:geom error:NULL];
    Collector *col = [[Collector alloc] init];
    col->quiet = YES;
    PVRenderQueue *q = [[PVRenderQueue alloc] initWithSource:own label:"test.dedup"];
    [q setDelegate:col];

    CGSize px = CGSizeMake(240, 310);
    [q setDesiredRequests:[NSArray arrayWithObject:
        [PVRenderRequest page:3 pixels:px priority:PVPriorityVisibleFull preview:NO]]];

    // Deliberately not PumpRunLoop: the main queue must stay unserviced so the
    // delivery is queued and nothing has reached the delegate yet. Background
    // QoS makes this slow, so the wait is generous.
    usleep(1200 * 1000);
    OK([col->pages count] == 0, "delivery really is still queued (test premise holds)");
    OK([q inFlightCount] == 1, "a rendered-but-undelivered page is still counted in flight");

    // The layer above has no way to know the bitmap exists yet, so it asks for
    // the same page again -- exactly what -updateVisibleContent would do.
    [q setDesiredRequests:[NSArray arrayWithObject:
        [PVRenderRequest page:3 pixels:px priority:PVPriorityVisibleFull preview:NO]]];
    PumpRunLoop(2.0);

    OK([col->pages count] == 1, "a page already rendered and awaiting delivery is not rendered twice");
    OK([q inFlightCount] == 0, "the in-flight count returns to zero after delivery");
    OK([q isIdle], "the queue is idle once everything has been delivered");

    // A different pixel size for the same page is genuinely different work and
    // must NOT be suppressed, or a zoom during a render would never resolve.
    [col->pages removeAllObjects];
    [q setDesiredRequests:[NSArray arrayWithObject:
        [PVRenderRequest page:3 pixels:CGSizeMake(300, 388)
                     priority:PVPriorityVisibleFull preview:NO]]];
    PumpRunLoop(2.0);
    OK([col->pages count] == 1, "the same page at a different size is still rendered");

    [q shutdown];
    [q release];
    [col release];
    [own release];
}

// A request CoreGraphics cannot satisfy must be reported, not silently dropped.
// Silently dropping it is what let the layer above ask for the same impossible
// page on every scroll event for the rest of the session.
static void TestRenderQueueFailureReporting(NSURL *url, PVPDFSource *geom)
{
    PVPDFSource *own = [[PVPDFSource alloc] initWithURL:url geometryFrom:geom error:NULL];
    Collector *col = [[Collector alloc] init];
    col->quiet = YES;
    PVRenderQueue *q = [[PVRenderQueue alloc] initWithSource:own label:"test.fail"];
    [q setDelegate:col];

    // A page index past the end of the document is the one failure that can be
    // provoked deterministically; -createImageForPage: returns NULL for it by
    // exactly the same route as a page object the document cannot hand back.
    NSUInteger bogus = [own pageCount] + 5;
    [q setDesiredRequests:[NSArray arrayWithObject:
        [PVRenderRequest page:bogus pixels:CGSizeMake(200, 260)
                     priority:PVPriorityVisibleFull preview:NO]]];
    PumpRunLoop(2.0);

    OK([col->failed count] == 1, "a render that produced no bitmap is reported as a failure");
    OK([col->pages count] == 0, "a failed render is not reported as a success");
    OK([q inFlightCount] == 0, "a failed render still retires its in-flight marker");
    OK([q isIdle], "a failed render leaves the queue idle, not wedged");

    [q shutdown];
    [q release];
    [col release];
    [own release];
}

// The express lane exists so that the one page the user is visibly waiting on
// arrives in ~0.37 s instead of ~1.4 s. It is worth about eight times the
// energy of a background render, which is why it is spent on exactly one page.
//
// It has to be spent reliably, though, or the same action has two different
// latencies depending on nothing the user can see. -pump gives up when the
// worker is already running, so an express request arriving while a prefetched
// page was mid-rasterisation used to be drained by that ordinary block at
// background QoS and the promotion was simply lost. Jumping to a page within a
// second of stopping a scroll -- when prefetch is still working -- hit it every
// time.
//
// A PVPDFSource subclass records the QoS each render actually ran at, which is
// the only way to observe the promotion from outside.
@interface PVQoSRecordingSource : PVPDFSource {
@public
    NSMutableArray *qos;      // qos_class_t per render, in order
    NSLock         *lock;
}
@end

@implementation PVQoSRecordingSource
- (id)initWithURL:(NSURL *)u geometryFrom:(PVPDFSource *)g error:(NSError **)e
{
    self = [super initWithURL:u geometryFrom:g error:e];
    if (self) { qos = [[NSMutableArray alloc] init]; lock = [[NSLock alloc] init]; }
    return self;
}
- (void)dealloc { [qos release]; [lock release]; [super dealloc]; }
- (CGImageRef)createImageForPage:(NSUInteger)index pixelSize:(CGSize)px
{
    // qos_class_self() is 10.10+, and this file is compiled at the app's own
    // 10.9 deployment target with -Werror=unguarded-availability. Resolved the
    // same way the express lane resolves its own entry point, so the guard
    // stays armed and a 10.9 run simply records nothing.
    static unsigned int (*qsel)(void);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        qsel = (unsigned int (*)(void))dlsym(RTLD_DEFAULT, "qos_class_self");
    });
    unsigned int q = qsel ? qsel() : 0;
    [lock lock];
    [qos addObject:[NSNumber numberWithUnsignedInt:q]];
    [lock unlock];
    return [super createImageForPage:index pixelSize:px];
}
- (BOOL)sawQoSAtLeast:(unsigned int)want
{
    BOOL found = NO;
    [lock lock];
    NSUInteger i, n = [qos count];
    for (i = 0; i < n; i++)
        if ([[qos objectAtIndex:i] unsignedIntValue] >= want) { found = YES; break; }
    [lock unlock];
    return found;
}
- (void)resetQoS { [lock lock]; [qos removeAllObjects]; [lock unlock]; }
@end

static void TestExpressLanePromotion(NSURL *url, PVPDFSource *geom)
{
    printf("\n[express lane: the promotion is not lost to a busy queue]\n");

    PVQoSRecordingSource *own =
        [[PVQoSRecordingSource alloc] initWithURL:url geometryFrom:geom error:NULL];
    Collector *col = [[Collector alloc] init];
    col->quiet = YES;
    PVRenderQueue *q = [[PVRenderQueue alloc] initWithSource:own label:"test.express"];
    [q setDelegate:col];

    // Baseline: an express request handed to an idle queue must be promoted.
    [q setDesiredRequests:[NSArray arrayWithObject:
        [PVRenderRequest page:0 pixels:CGSizeMake(700, 900)
                     priority:PVPriorityVisibleFull preview:NO express:YES]]];
    PumpRunLoop(3.0);
    OK([own sawQoSAtLeast:PV_QOS_CLASS_UTILITY],
       "an express request on an idle queue runs at raised QoS");

    // The real case. Fill the queue with ordinary background work, let the
    // worker get into a page, and only then ask for the express one -- which
    // is what a page jump during prefetch does.
    [own resetQoS];
    [col->pages removeAllObjects];
    NSMutableArray *bulk = [NSMutableArray array];
    NSUInteger i;
    for (i = 1; i < 7; i++)
        [bulk addObject:[PVRenderRequest page:i pixels:CGSizeMake(700, 900)
                                     priority:PVPriorityNearFull preview:NO]];
    [q setDesiredRequests:bulk];
    PumpRunLoop(0.05);                      // the worker is now inside a page

    NSMutableArray *withExpress = [NSMutableArray arrayWithArray:bulk];
    [withExpress insertObject:[PVRenderRequest page:9 pixels:CGSizeMake(700, 900)
                                           priority:PVPriorityVisibleFull preview:NO
                                            express:YES]
                      atIndex:0];
    [q setDesiredRequests:withExpress];
    PumpRunLoop(4.0);

    OK([own sawQoSAtLeast:PV_QOS_CLASS_UTILITY],
       "an express request arriving while the queue is busy is still promoted");

    [q shutdown];
    PumpRunLoop(0.5);
    [q release];
    [col release];
    [own release];
}

static void TestRenderQueue(PVPDFSource *src, NSURL *url)
{
    printf("\n[PVRenderQueue]\n");
    PVPDFSource *own = [[PVPDFSource alloc] initWithURL:url geometryFrom:src error:NULL];
    OK(own != nil, "second source shares geometry from the first");
    OK(own && [own pageCount] == [src pageCount], "shared-geometry source has the same page count");

    Collector *col = [[Collector alloc] init];
    PVRenderQueue *q = [[PVRenderQueue alloc] initWithSource:own label:"test.render"];
    [q setDelegate:col];

    NSMutableArray *reqs = [NSMutableArray array];
    for (int i = 0; i < 3; i++)
        [reqs addObject:[PVRenderRequest page:i pixels:CGSizeMake(200, 260)
                                     priority:PVPriorityVisibleFull preview:NO]];
    [q setDesiredRequests:reqs];
    PumpRunLoop(4.0);

    OK([col->pages count] == 3, "all three requested pages were delivered");
    OK(col->onMainThread, "results are delivered on the main thread");

    // Replacing the desired set must drop work that is no longer wanted.
    [col->pages removeAllObjects];
    NSMutableArray *many = [NSMutableArray array];
    for (int i = 10; i < 40; i++)
        [many addObject:[PVRenderRequest page:i pixels:CGSizeMake(700, 900)
                                     priority:PVPriorityNearFull preview:NO]];
    [q setDesiredRequests:many];
    [q setDesiredRequests:[NSArray array]];      // user scrolled away
    PumpRunLoop(1.5);
    OK([col->pages count] <= 1,
       "replacing the wanted set cancels queued work (at most the in-flight page lands)");

    [q shutdown];
    OK(YES, "shutdown drained without deadlocking");
    [q release];
    [col release];
    [own release];

    TestRenderQueueDeduplication(url, src);
    TestRenderQueueFailureReporting(url, src);
    TestExpressLanePromotion(url, src);
}

// The file on disk is untrusted input: it can be hand-edited, restored from a
// backup written by another version, or left half-sane by a filesystem that
// lost a write. Every value used to be read with its type simply assumed, so a
// string where a number belonged reached -unsignedLongLongValue and took the
// app down -- at document-open time, on every open, until the user found and
// deleted the file. Run against a scratch file, never the user's own.
static void TestStateStoreCorruptFile(void)
{
    printf("\n[PVStateStore: hostile plist]\n");
    NSString *path = @"/tmp/postview-selftest-corrupt.plist";
    NSURL *good = [NSURL fileURLWithPath:@"/tmp/postview-corrupt-a.pdf"];
    NSURL *junk = [NSURL fileURLWithPath:@"/tmp/postview-corrupt-b.pdf"];

    NSDictionary *hostile = [NSDictionary dictionaryWithObjectsAndKeys:
        // Every field the wrong type, which is the shape that used to crash.
        [NSDictionary dictionaryWithObjectsAndKeys:
            @"not a number",              @"page",
            @"neither is this",           @"fraction",
            [NSArray array],              @"zoom",
            [NSDictionary dictionary],    @"zoomMode",
            @"yes please",                @"sidebar",
            [NSNumber numberWithInt:7],   @"windowFrame",
            nil],                                         [junk path],
        // An entry that is not a dictionary at all.
        @"I am not a state dictionary",                   @"/tmp/postview-corrupt-c.pdf",
        // A well-formed entry alongside them, which must survive intact.
        [NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithInt:11],   @"page",
            [NSNumber numberWithDouble:0.5], @"fraction",
            [NSNumber numberWithDouble:1.25], @"zoom",
            [NSNumber numberWithInt:2],    @"zoomMode",
            [NSNumber numberWithBool:YES], @"sidebar",
            @"10 10 700 500 0 0 1440 900", @"windowFrame",
            nil],                                         [good path],
        nil];
    OK([hostile writeToFile:path atomically:YES], "hostile fixture written");

    PVStateStore *s = [[PVStateStore alloc] initWithPath:path];
    OK(s != nil, "a store loads from a plist full of wrong types without crashing");

    NSUInteger page = 999; CGFloat frac = -5, zoom = -5;
    PVZoomMode mode = (PVZoomMode)99; BOOL sidebar = YES; NSString *frame = (NSString *)@"x";
    BOOL found = [s stateForURL:junk page:&page fraction:&frac zoomMode:&mode
                           zoom:&zoom sidebar:&sidebar windowFrame:&frame];
    OK(found, "the wrong-typed entry is still found, not discarded wholesale");
    OK(page == 0,                      "a non-numeric page reads back as 0");
    OK(frac >= 0 && frac <= 1,         "a non-numeric fraction is clamped into range");
    OK(zoom == 1.0,                    "a non-numeric zoom falls back to 1.0");
    OK(mode == PVZoomModeFitWidth,     "a non-numeric zoom mode falls back to fit width");
    OK(sidebar == NO,                  "a non-numeric sidebar flag reads back as NO");
    OK(frame == nil,                   "a non-string window frame reads back as nil");

    // A value that is not a dictionary must not be reachable at all: -prune
    // reaches into every value it holds and would have gone down with it.
    OK(![s stateForURL:[NSURL fileURLWithPath:@"/tmp/postview-corrupt-c.pdf"]
                  page:NULL fraction:NULL zoomMode:NULL zoom:NULL sidebar:NULL windowFrame:NULL],
       "an entry that is not a dictionary is dropped on load");

    // The good entry must be untouched by any of that.
    page = 0; frac = 0; zoom = 0; mode = PVZoomModeCustom; sidebar = NO; frame = nil;
    OK([s stateForURL:good page:&page fraction:&frac zoomMode:&mode
                 zoom:&zoom sidebar:&sidebar windowFrame:&frame], "the sound entry survives");
    OK(page == 11 && fabs(zoom - 1.25) < 0.0001 && mode == PVZoomModeFitPage &&
       sidebar == YES && [frame length] > 0, "the sound entry round-trips unchanged");

    // Writing after loading a hostile file must not carry the junk back out,
    // and -prune must be able to walk what is left.
    [s recordForURL:good page:3 fraction:0.1 zoomMode:PVZoomModeActual
               zoom:1.0 sidebar:NO windowFrame:@"0 0 10 10 0 0 100 100"];
    [s flush];
    OK(YES, "flush after loading a hostile file completes");
    [s release];

    // Truncated / not-a-plist-at-all.
    [@"this is not a plist" writeToFile:path atomically:YES
                              encoding:NSUTF8StringEncoding error:NULL];
    PVStateStore *s2 = [[PVStateStore alloc] initWithPath:path];
    OK(s2 != nil, "a store loads from a file that is not a plist at all");
    OK(![s2 stateForURL:good page:NULL fraction:NULL zoomMode:NULL
                   zoom:NULL sidebar:NULL windowFrame:NULL],
       "an unreadable file yields an empty store rather than a crash");
    [s2 release];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static void TestStateStore(void)
{
    printf("\n[PVStateStore]\n");
    NSURL *url = [NSURL fileURLWithPath:@"/tmp/postview-selftest-doc.pdf"];
    PVStateStore *s = [PVStateStore sharedStore];
    [s recordForURL:url page:42 fraction:0.25 zoomMode:PVZoomModeFitPage
               zoom:1.75 sidebar:YES windowFrame:@"100 100 800 600 0 0 1440 900"];
    [s flush];

    NSUInteger page = 0; CGFloat frac = 0, zoom = 0;
    PVZoomMode mode = PVZoomModeCustom; BOOL sidebar = NO; NSString *frame = nil;
    BOOL found = [s stateForURL:url page:&page fraction:&frac zoomMode:&mode
                           zoom:&zoom sidebar:&sidebar windowFrame:&frame];
    OK(found, "state was recorded");
    OK(page == 42, "page number round-trips");
    OK(fabs(frac - 0.25) < 0.0001, "scroll fraction round-trips");
    OK(mode == PVZoomModeFitPage, "zoom mode round-trips");
    OK(fabs(zoom - 1.75) < 0.0001, "zoom round-trips");
    OK(sidebar == YES, "sidebar visibility round-trips");
    OK([frame length] > 0, "window frame round-trips");

    // Survives a full reload from disk, which is the case that actually matters:
    // quit the app, relaunch, reopen the document.
    NSString *path = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
        NSUserDomainMask, YES) objectAtIndex:0]
        stringByAppendingPathComponent:@"Postview/DocumentState.plist"];
    NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:path];
    NSDictionary *entry = [onDisk objectForKey:[url path]];
    OK(entry != nil, "state is readable straight from the plist on disk");
    OK([[entry objectForKey:@"page"] intValue] == 42, "page survives a real disk round trip");

    NSUInteger p2 = 7;
    BOOL missing = [s stateForURL:[NSURL fileURLWithPath:@"/tmp/never-opened-xyz.pdf"]
                             page:&p2 fraction:NULL zoomMode:NULL zoom:NULL
                          sidebar:NULL windowFrame:NULL];
    OK(!missing, "unknown document reports no saved state");
}

// Locates the black square and reports which quadrant of the rendered image it
// landed in. /Rotate is applied clockwise on display, so the square drawn at the
// PDF-space bottom-left corner must move predictably as rotation increases.
static const char *DarkQuadrant(CGImageRef img)
{
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    size_t stride = w * 4;
    unsigned char *buf = (unsigned char *)calloc(h, stride);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(buf, w, h, 8, stride, cs,
        (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(cs);
    CGContextDrawImage(c, CGRectMake(0, 0, w, h), img);

    double sx = 0, sy = 0; long n = 0;
    for (size_t y = 0; y < h; y++)
        for (size_t x = 0; x < w; x++) {
            unsigned char *p = buf + y * stride + x * 4;
            if (p[0] < 60 && p[1] < 60 && p[2] < 60) { sx += x; sy += y; n++; }
        }
    CGContextRelease(c);
    free(buf);
    if (n == 0) return "none";
    double cx = sx / n / w, cy = sy / n / h;   // cy: 0 = top of the image
    if (cy < 0.5) return (cx < 0.5) ? "top-left" : "top-right";
    return (cx < 0.5) ? "bottom-left" : "bottom-right";
}

static void TestRotation(NSString *path)
{
    printf("\n[page rotation — /Rotate 0, 90, 180, 270]\n");
    NSError *err = nil;
    PVPDFSource *src = [[PVPDFSource alloc] initWithURL:[NSURL fileURLWithPath:path]
                                                  error:&err];
    if (!src) { OK(NO, "rotation fixture opened"); return; }
    OK([src pageCount] == 4, "rotation fixture has 4 pages");

    // Media box is 400x200 landscape; 90 and 270 must report it swapped.
    struct { int rot; CGSize size; const char *quadrant; } expect[] = {
        {   0, { 400, 200 }, "bottom-left"  },
        {  90, { 200, 400 }, "top-left"     },
        { 180, { 400, 200 }, "top-right"    },
        { 270, { 200, 400 }, "bottom-right" },
    };

    for (int i = 0; i < 4; i++) {
        CGSize got = [src pointSizeOfPage:i];
        char msg[160];
        snprintf(msg, sizeof msg, "/Rotate %d reports %.0fx%.0f", expect[i].rot,
                 got.width, got.height);
        OK(fabs(got.width - expect[i].size.width) < 1 &&
           fabs(got.height - expect[i].size.height) < 1, msg);

        // Render at 2x the reported size: exercises rotation and upscaling together.
        CGImageRef im = [src createImageForPage:i
                                      pixelSize:CGSizeMake(got.width * 2, got.height * 2)];
        if (!im) { OK(NO, "rotated page rendered"); continue; }

        double cw = 0, ch = 0;
        InkCoverage(im, &cw, &ch);
        snprintf(msg, sizeof msg, "/Rotate %d fills the bitmap (ink %.0f%% x %.0f%%)",
                 expect[i].rot, cw * 100, ch * 100);
        OK(cw > 0.9 && ch > 0.9, msg);

        const char *q = DarkQuadrant(im);
        snprintf(msg, sizeof msg, "/Rotate %d puts the corner mark %s (expected %s)",
                 expect[i].rot, q, expect[i].quadrant);
        OK(strcmp(q, expect[i].quadrant) == 0, msg);
        CGImageRelease(im);
    }
    [src release];
}

static void TestArbitrary(NSString *path)
{
    printf("\n[arbitrary real-world document: %s]\n",
           [[path lastPathComponent] UTF8String]);
    NSError *err = nil;
    PVPDFSource *src = [[PVPDFSource alloc] initWithURL:[NSURL fileURLWithPath:path]
                                                  error:&err];
    if (!src) { OK(NO, "document opened"); return; }
    OK([src pageCount] > 0, "document reports at least one page");

    CGSize nat = [src pointSizeOfPage:0];
    OK(nat.width > 1 && nat.height > 1, "page 0 has a sensible size");

    // The invariant that holds for ANY document: whatever fraction of the page
    // is inked, it must be the same fraction at every rendering scale. If the
    // content were being centred at 1:1 instead of scaled up, coverage would
    // shrink as the bitmap grew.
    double baseW = 0, baseH = 0, cw = 0, ch = 0;
    BOOL consistent = YES;
    double factors[] = { 0.5, 1.0, 2.0, 3.0 };
    for (int i = 0; i < 4; i++) {
        CGImageRef im = [src createImageForPage:0
            pixelSize:CGSizeMake(nat.width * factors[i], nat.height * factors[i])];
        if (!im) { consistent = NO; break; }
        InkCoverage(im, &cw, &ch);
        if (i == 0) { baseW = cw; baseH = ch; }
        else if (fabs(cw - baseW) > 0.06 || fabs(ch - baseH) > 0.06) consistent = NO;
        CGImageRelease(im);
    }
    char msg[160];
    snprintf(msg, sizeof msg,
             "ink coverage is scale independent (%.0f%% x %.0f%% at 0.5x through 3x)",
             baseW * 100, baseH * 100);
    OK(consistent && baseW > 0.05, msg);
    OK(baseW <= 1.0 && baseH <= 1.0, "ink stays inside the page");
    [src release];
}

#pragma mark - Where the app is running from

// The crash this guards against cannot be reproduced in a test: it needs the
// executable's own file to stop being readable while the process runs, and a
// process cannot survive that by construction. What is testable is the
// decision that keeps the app out of that situation, so that is what is
// pinned here -- the whole truth table, and the one volume every machine has.
static void TestRunningLocation(void)
{
    printf("\n[where the app is running from]\n");

    // removable, ejectable, local
    OK(PVVolumeKindFromFlags(NO,  NO,  YES) == PVVolumeFixed,
       "an internal disk is somewhere safe to run from");
    OK(PVVolumeKindFromFlags(YES, NO,  YES) == PVVolumeRemovable,
       "removable media is not");
    OK(PVVolumeKindFromFlags(NO,  YES, YES) == PVVolumeRemovable,
       "an ejectable device or mounted disk image is not");
    OK(PVVolumeKindFromFlags(YES, YES, YES) == PVVolumeRemovable,
       "removable and ejectable together is still one risk");

    // Not local outranks the other two: a share can be exported from a disk
    // that is itself removable, and the network is the part that will drop.
    OK(PVVolumeKindFromFlags(NO,  NO,  NO)  == PVVolumeNetwork,
       "a network mount is reported as a network mount");
    OK(PVVolumeKindFromFlags(YES, NO,  NO)  == PVVolumeNetwork,
       "and stays one when the far end is removable");
    OK(PVVolumeKindFromFlags(NO,  YES, NO)  == PVVolumeNetwork,
       "and when it is ejectable");
    OK(PVVolumeKindFromFlags(YES, YES, NO)  == PVVolumeNetwork,
       "and when it is both");

    // The boot volume is the case that must never produce a dialog, because
    // every correctly installed copy is on it.
    OK(PVVolumeKindForURL([NSURL fileURLWithPath:@"/"]) == PVVolumeFixed,
       "the boot volume never raises the warning");
    OK(PVVolumeKindForURL([NSURL fileURLWithPath:@"/Applications"]) == PVVolumeFixed,
       "nor does /Applications");

    // Anything unanswerable is answered "fixed": a question the file system
    // declines is not evidence of danger, and must not put a dialog in front
    // of someone who has done nothing wrong.
    OK(PVVolumeKindForURL(nil) == PVVolumeFixed,
       "no URL raises nothing");
    OK(PVVolumeKindForURL([NSURL URLWithString:@"http://example.com/"]) == PVVolumeFixed,
       "a non-file URL raises nothing");
    OK(PVVolumeKindForURL([NSURL fileURLWithPath:@"/no/such/path/at/all"]) == PVVolumeFixed,
       "an unreadable path raises nothing");
}

#pragma mark - Scheduler budget arithmetic

// The render scheduler's memory arithmetic, pinned so that changing one of the
// three numbers without the others cannot pass.
//
// PVMaxRenderPixels() is a third of the page-cache budget, chosen so that the
// two pages on screen come to two thirds and the previews fit in what is left.
// That derivation leaves NO room for a full-resolution prefetch, which is
// exactly the bug this guards: the wanted-set used to ask for three of them.
// Five full bitmaps against a budget sized for three meant that storing one
// evicted a page still on screen, which was then asked for again -- 51 full
// renders to display six pages of a document nobody was scrolling.
static void TestSchedulerBudgetArithmetic(void)
{
    printf("\nScheduler budget arithmetic\n");

    double maxPx    = PVMaxRenderPixels();
    double maxBytes = maxPx * 4.0;
    double budget   = (double)PVPageCacheBudget();

    OK(maxBytes > 0 && budget > 0, "budget and per-bitmap ceiling are positive");
    OK(fabs(maxBytes - budget / 3.0) < 1.0,
       "one full bitmap is capped at a third of the page-cache budget");

    // Two pages are on screen at any ordinary zoom. Everything the wanted-set
    // may ask for at full resolution has to fit what the cache can hold, or
    // the last one stored evicts one that is still wanted.
    double fullsRequested = 2.0 + (double)PV_FULL_PREFETCH_PAGES;
    OK(fullsRequested * maxBytes <= budget + 1.0,
       "visible pages plus full prefetch fit the cache budget");

    // Stated separately so the failure message says which number moved.
    OK(PV_FULL_PREFETCH_PAGES <= 1,
       "full-resolution prefetch depth stays within what the budget allows");
    OK(PV_MAX_FULL_IMAGES >= 3,
       "the count cap is looser than the byte budget, not a second ceiling");

    // Previews are what make scrolling back instant, so the budget has to hold
    // several of them alongside the visible pages.
    double previewBytes = maxBytes / (PV_PREVIEW_DIVISOR * PV_PREVIEW_DIVISOR);
    OK(previewBytes * 4.0 < budget,
       "four previews still fit beside the full bitmaps");
}

#pragma mark - Scenario replay

// The profiler's three workloads, replayed through the same speed model the
// controller uses, so the throttle's behaviour on each is pinned without a
// window, a clock or a PDF.
//
// This exists because the profile is easy to misread. `read` reports zero
// suppressed requests, which looks like a broken throttle and is in fact the
// correct answer: a reader sitting on a page for two and a half seconds wants
// it sharp. Only `page` and `scroll` move fast enough for suppression to be
// right, and the test says so in those terms.
static double ReplaySpeed(int presses, double delay, double travel)
{
    double speed = 0, lastT = 0, now = 0;
    int i;
    for (i = 0; i < presses; i++) {
        now += delay;
        double dt = now - lastT;
        // Mirrors -[PVWindowController boundsDidChange:].
        if (lastT > 0 && dt >= 0.002 && dt < 0.5) {
            double v = travel / dt;
            if (v <= PV_MAX_SCROLL_SPEED)
                speed = (speed > 0) ? (speed * 0.7 + v * 0.3) : v;
        } else if (lastT > 0 && dt >= 0.5) {
            speed = 0;                      // half a second of stillness ends a scroll
        }
        lastT = now;
    }
    return speed;
}

static void TestScenarioReplay(void)
{
    printf("\nScenario replay (profiler workloads)\n");

    const double kPageTravel = 760.0;   // roughly one viewport per Page Down
    const double kLineTravel = 24.0;    // one line per arrow key

    // read: 12 Page Downs, 2.5 s apart. Every gap exceeds half a second, so
    // each one ends the previous scroll and the speed returns to rest.
    double readSpeed = ReplaySpeed(12, 2.5, kPageTravel);
    OK(readSpeed == 0.0, "read: 2.5 s gaps leave the document at rest");
    OK(PVShouldRenderWhileMoving(readSpeed, 0.0, 0.1),
       "read: a page being read is rendered, however short its dwell looks");

    // page: 80 Page Downs at 20/s. This is a flick.
    double pageSpeed = ReplaySpeed(80, 0.05, kPageTravel);
    OK(pageSpeed > PV_MIN_SCROLL_SPEED, "page: 20 presses/s registers as motion");
    OK(!PVShouldRenderWhileMoving(pageSpeed, 0.0, kPageTravel / pageSpeed),
       "page: pages flying past are skipped");

    // scroll: 200 arrow keys at 50/s. Slower travel, but still real motion.
    double scrollSpeed = ReplaySpeed(200, 0.02, kLineTravel);
    OK(scrollSpeed > PV_MIN_SCROLL_SPEED, "scroll: 50 presses/s registers as motion");
    OK(!PVShouldRenderWhileMoving(scrollSpeed, 0.0, kLineTravel / scrollSpeed),
       "scroll: continuous motion suppresses too");

    // The ordering that makes the throttle device-independent. A keyboard
    // scroll posts no live-scroll notification, so anything keyed off those
    // flags alone would treat these two as different -- which is precisely the
    // bug that let full-resolution renders past the throttle while previews
    // beside them were correctly suppressed.
    OK(pageSpeed > scrollSpeed,
       "paging travels faster than line scrolling, as the geometry says");
    OK(!PVShouldRenderWhileMoving(pageSpeed, 0.0, 0.1) ==
       !PVShouldRenderWhileMoving(scrollSpeed, 0.0, 0.1),
       "both keyboard motions reach the same decision for the same dwell");

    // The safety property, restated at the scenario level: whatever the speed,
    // a measurement that has gone stale renders. A document that stops moving
    // cannot stay soft.
    OK(PVShouldRenderWhileMoving(pageSpeed, PV_SPEED_FRESH_SECONDS * 1.01, 0.0),
       "a flick that ended leaves nothing suppressed behind it");
}

#pragma mark - Render-suppression policy

// PVShouldRenderWhileMoving is the whole of the throttle. It is a pure
// function precisely so it can be pinned here: no window, no run loop, no PDF,
// and no dependence on how fast this machine happens to be.
//
// The property that matters most is the last group. Suppression must be
// impossible to get stuck in, because the only thing that recomputes speed is
// movement -- so if a stale measurement could still suppress, a document that
// stopped moving would stay soft with no event coming that would fix it.
static void TestRenderSuppressionPolicy(void)
{
    printf("\nRender-suppression policy\n");

    const double kFresh = 0.0;                     // measured just now
    const double kSlow  = 0.5 * PV_MIN_VISIBLE_SECONDS;   // page gone too soon
    const double kLong  = 2.0 * PV_MIN_VISIBLE_SECONDS;   // page stays put

    // Ordering the design depends on: the settle timer must normally fire
    // before staleness would have ended the suppression on its own, or the
    // backstop becomes the mechanism and the sharp pass gets slower.
    OK(PV_SETTLE_SECONDS < PV_SPEED_FRESH_SECONDS,
       "settle fires before a measurement goes stale");
    OK(PV_SETTLE_SECONDS > 0.0 && PV_SPEED_FRESH_SECONDS > 0.0,
       "settle and freshness windows are positive");

    // At rest: always render, however briefly the geometry says a page lasts.
    OK(PVShouldRenderWhileMoving(0.0, kFresh, kSlow),
       "at rest, renders");
    OK(PVShouldRenderWhileMoving(PV_MIN_SCROLL_SPEED, kFresh, kSlow),
       "at the speed floor, renders");
    OK(PVShouldRenderWhileMoving(PV_MIN_SCROLL_SPEED * 0.99, kFresh, 0.0),
       "below the speed floor, renders even for a page with no dwell");

    // Moving fast, fresh measurement: this is the only case that suppresses.
    OK(!PVShouldRenderWhileMoving(20000.0, kFresh, kSlow),
       "fast and fresh, a page that will be gone is skipped");
    OK(PVShouldRenderWhileMoving(20000.0, kFresh, kLong),
       "fast and fresh, a page that stays is still rendered");
    OK(!PVShouldRenderWhileMoving(20000.0, PV_SPEED_FRESH_SECONDS * 0.99, kSlow),
       "just inside the freshness window, still suppressing");

    // The stuck-suppression guard. Past the freshness window the measurement
    // is disregarded no matter how fast it said the document was going.
    OK(PVShouldRenderWhileMoving(20000.0, PV_SPEED_FRESH_SECONDS, kSlow),
       "exactly at the freshness limit, renders");
    OK(PVShouldRenderWhileMoving(20000.0, PV_SPEED_FRESH_SECONDS * 1.01, kSlow),
       "a stale measurement cannot suppress");
    OK(PVShouldRenderWhileMoving(1.0e9, 3600.0, 0.0),
       "an hour-old measurement of any speed cannot suppress");
    OK(PVShouldRenderWhileMoving(20000.0, HUGE_VAL, kSlow),
       "no measurement yet cannot suppress");
    OK(PVShouldRenderWhileMoving(20000.0, -1.0, kSlow),
       "a clock that moved backwards cannot suppress");

    // Non-finite inputs render rather than falling through comparisons that
    // are all false for a NaN.
    OK(PVShouldRenderWhileMoving(NAN, kFresh, kSlow),
       "NaN speed renders");
    OK(PVShouldRenderWhileMoving(20000.0, kFresh, NAN),
       "NaN dwell renders");
    OK(PVShouldRenderWhileMoving(HUGE_VAL, kFresh, kSlow),
       "infinite speed renders");
    OK(PVShouldRenderWhileMoving(20000.0, NAN, kSlow),
       "NaN age renders");

    // Exhaustive sweep: the ONLY combination that may return NO is fresh
    // evidence of real speed with a page that will not survive it. Anything
    // else returning NO is a document that could be left permanently soft.
    int violations = 0, suppressions = 0;
    double speeds[] = { 0.0, 1.0, 1.5, 100.0, 20000.0, 99999.0, 1.0e9 };
    double ages[]   = { 0.0, 0.01, 0.1, 0.24, 0.25, 0.26, 1.0, 60.0 };
    double dwells[] = { 0.0, 0.01, 0.24, 0.25, 0.26, 1.0, 1.0e6 };
    size_t si, ai, di;
    for (si = 0; si < sizeof(speeds) / sizeof(speeds[0]); si++)
    for (ai = 0; ai < sizeof(ages)   / sizeof(ages[0]);   ai++)
    for (di = 0; di < sizeof(dwells) / sizeof(dwells[0]); di++) {
        BOOL render = PVShouldRenderWhileMoving(speeds[si], ages[ai], dwells[di]);
        if (render) continue;
        suppressions++;
        BOOL legitimate = (speeds[si] > PV_MIN_SCROLL_SPEED) &&
                          (ages[ai]   < PV_SPEED_FRESH_SECONDS) &&
                          (dwells[di] <= PV_MIN_VISIBLE_SECONDS);
        if (!legitimate) {
            violations++;
            printf("        speed=%g age=%g dwell=%g suppressed without cause\n",
                   speeds[si], ages[ai], dwells[di]);
        }
    }
    OK(violations == 0, "no combination suppresses without fresh evidence");
    OK(suppressions > 0, "the sweep actually exercised suppression");

    // Determinism: identical inputs, identical answer, every time. The policy
    // reads no clock and holds no state of its own, and this says so.
    int i, stable = 1;
    BOOL first = PVShouldRenderWhileMoving(20000.0, 0.05, kSlow);
    for (i = 0; i < 10000; i++)
        if (PVShouldRenderWhileMoving(20000.0, 0.05, kSlow) != first) stable = 0;
    OK(stable, "same inputs give the same answer across 10000 calls");
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: pvtest <test.pdf>\n"); return 2; }
        [NSApplication sharedApplication];   // AppKit needs this before views exist

        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        NSError *err = nil;
        PVPDFSource *src = [[PVPDFSource alloc] initWithURL:url error:&err];
        if (!src) { fprintf(stderr, "cannot open %s: %s\n", argv[1],
                            [[err localizedDescription] UTF8String]); return 2; }

        TestSource(src);
        TestDispatchConstants();
        TestRenderSpeed(src);
        TestCache();
        TestCacheConverges();
        TestLayout(src);
        TestRenderQueue(src, url);
        TestStateStore();
        TestStateStoreCorruptFile();
        TestRunningLocation();
        TestRenderSuppressionPolicy();
        TestSchedulerBudgetArithmetic();
        TestScenarioReplay();
        if (argc > 2) TestRotation([NSString stringWithUTF8String:argv[2]]);
        if (argc > 3) TestArbitrary([NSString stringWithUTF8String:argv[3]]);

        printf("\n%d passed, %d failed\n", gPass, gFail);
        return gFail ? 1 : 0;
    }
}
