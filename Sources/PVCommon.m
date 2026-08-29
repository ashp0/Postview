#import "PVCommon.h"
#import <pthread.h>
#import <string.h>

NSString * const PVMemoryPressureNotification = @"PVMemoryPressureNotification";

#define PV_GB (1024ULL * 1024ULL * 1024ULL)

// Installed RAM cannot change during the life of a process, so it is resolved
// once. That matters more than it looks: PVMaxRenderPixels() is derived from it
// and is consulted on every single render, on the render queue's thread. Asking
// a shared Foundation singleton for it there made the ceiling -- a value that
// must be identical for every render in a session -- depend on a global object
// reached from two threads. Resolving it once makes all three budgets constants.
static unsigned long long PVPhysicalMemory(void)
{
    static unsigned long long sRAM;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        unsigned long long r = [[NSProcessInfo processInfo] physicalMemory];
        // A zero reading would silently select the smallest budgets forever;
        // treat an implausible answer as "assume a modest machine" explicitly.
        sRAM = (r > 0) ? r : (2 * PV_GB);
    });
    return sRAM;
}

size_t PVPageCacheBudget(void)
{
    unsigned long long ram = PVPhysicalMemory();
    if (ram <= 2 * PV_GB) return 32 * 1024 * 1024;
    if (ram <= 4 * PV_GB) return 64 * 1024 * 1024;
    return 96 * 1024 * 1024;
}

size_t PVThumbCacheBudget(void)
{
    unsigned long long ram = PVPhysicalMemory();
    if (ram <= 2 * PV_GB) return 6 * 1024 * 1024;
    if (ram <= 4 * PV_GB) return 10 * 1024 * 1024;
    return 16 * 1024 * 1024;
}

NSImage *PVToolbarImageNamed(NSString *name)
{
    if ([name length] == 0) return nil;
    // Cached: -[NSToolbar delegate] is asked to build its items again on every
    // toolbar reconfiguration and on every window, and re-reading and
    // re-parsing the same PDF each time is work with no result that differs.
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSMutableDictionary alloc] init]; });

    NSImage *img = [cache objectForKey:name];
    if (img) return img;

    NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:@"pdf"];
    if (!path) return nil;
    img = [[[NSImage alloc] initWithContentsOfFile:path] autorelease];
    if (!img) return nil;
    [img setTemplate:YES];
    [cache setObject:img forKey:name];
    return img;
}

#pragma mark - Live-instance census

static const char * const kPVTracked[] = {
    "PVWindowController", "PVPDFSource", "PVRenderQueue",
    "PVImageCache", "PVPageView", "PVThumbStripView", NULL
};
static long sPVLive[sizeof(kPVTracked) / sizeof(kPVTracked[0])];
static pthread_mutex_t sPVLiveLock = PTHREAD_MUTEX_INITIALIZER;

const char * const *PVLiveTrackedClasses(void) { return kPVTracked; }

static int PVLiveSlot(const char *cls)
{
    int i;
    for (i = 0; kPVTracked[i]; i++)
        if (strcmp(kPVTracked[i], cls) == 0) return i;
    return -1;
}

void PVLiveAdjust(const char *cls, int delta)
{
    int slot = PVLiveSlot(cls);
    if (slot < 0) return;
    pthread_mutex_lock(&sPVLiveLock);
    sPVLive[slot] += delta;
    pthread_mutex_unlock(&sPVLiveLock);
}

long PVLiveCount(const char *cls)
{
    int slot = PVLiveSlot(cls);
    if (slot < 0) return -1;
    pthread_mutex_lock(&sPVLiveLock);
    long v = sPVLive[slot];
    pthread_mutex_unlock(&sPVLiveLock);
    return v;
}

double PVMaxRenderPixels(void)
{
    // A bitmap the cache cannot keep is worse than a smaller one it can.
    //
    // This used to allow one bitmap of twice the whole page-cache budget. With
    // two pages on screen -- the ordinary case at any zoom above fit-page --
    // storing the second evicted the first, the next draw found the first
    // missing, the wanted-set asked for it again, and storing it evicted the
    // second. Nothing landed in the cache to break the cycle, so the render
    // queue rasterised the same two heavy pages forever: a background thread
    // at 100% on a document nobody is touching, pages visibly flickering
    // between sharp and soft, for as long as the window stays open. On a
    // Retina 2 GB machine that began at 200% zoom, and on an 8 GB machine at
    // 400%; the old ceiling of 36 Mpx is 137 MB, which no budget here can hold
    // at all.
    //
    // A third of the budget is the largest share that leaves the visible set
    // resident: two full-resolution pages come to two thirds, and the cheap
    // previews -- a ninth the size each -- fit in what is left. Past it a page
    // is rendered slightly downscaled and stretched, which is what
    // PVPDFSource already does above the ceiling. Soft and stable beats sharp
    // and thrashing, and on the machines this targets it also keeps a single
    // page from being tens of megabytes of a two-gigabyte machine.
    double byBudget = (double)PVPageCacheBudget() / 3.0 / 4.0;   // 4 bytes per pixel
    double ceiling  = (byBudget < PV_MAX_PIXELS) ? byBudget : PV_MAX_PIXELS;
    if (ceiling < 1.0) ceiling = 1.0;
    return ceiling;
}

#pragma mark - Rasterisation census

static double         sPVStats[PVStatCount];
static pthread_mutex_t sPVStatsLock = PTHREAD_MUTEX_INITIALIZER;

BOOL PVStatsEnabled(void)
{
    // Resolved once: getenv on the render thread for every page would be a
    // lock-free read of a mutable global, and the answer cannot change.
    //
    // Two ways in, because there are two ways to start a Mac application and
    // only one of them carries a shell environment. Running the executable
    // directly inherits POSTVIEW_STATS; going through LaunchServices -- which
    // is what `open` does, and what a benchmark has to use if it wants to
    // measure the same launch path a user gets -- does not, so the argument
    // domain is honoured too and `open --args -PVStats YES` works. The
    // argument domain is volatile, so nothing is written to the user's
    // preferences either way.
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *v = getenv("POSTVIEW_STATS");
        enabled = (v && v[0] && strcmp(v, "0") != 0);
        if (!enabled)
            enabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"PVStats"];
    });
    return enabled;
}

void PVStatAdd(PVStatKey key, double delta)
{
    if (!PVStatsEnabled()) return;
    if (key < 0 || key >= PVStatCount) return;
    pthread_mutex_lock(&sPVStatsLock);
    sPVStats[key] += delta;
    pthread_mutex_unlock(&sPVStatsLock);
}

NSString *PVStatsReport(void)
{
    if (!PVStatsEnabled()) return nil;
    double v[PVStatCount];
    int i;
    pthread_mutex_lock(&sPVStatsLock);
    for (i = 0; i < PVStatCount; i++) v[i] = sPVStats[i];
    pthread_mutex_unlock(&sPVStatsLock);

    double asked = v[PVStatRendersFull] + v[PVStatRendersPreview];
    double total = asked + v[PVStatRequestsSuppressed];
    // Machine-readable on purpose: the benchmark greps these lines out of the
    // app's stderr and puts them in the TSV beside the CPU numbers.
    return [NSString stringWithFormat:
        @"PVSTAT renders.full %.0f\n"
         "PVSTAT renders.preview %.0f\n"
         "PVSTAT renders.failed %.0f\n"
         "PVSTAT megapixels.full %.2f\n"
         "PVSTAT megapixels.preview %.2f\n"
         "PVSTAT megapixels.total %.2f\n"
         "PVSTAT requests.suppressed %.0f\n"
         "PVSTAT suppression.rate %.3f\n",
        v[PVStatRendersFull], v[PVStatRendersPreview], v[PVStatRendersFailed],
        v[PVStatPixelsFull], v[PVStatPixelsPreview],
        v[PVStatPixelsFull] + v[PVStatPixelsPreview],
        v[PVStatRequestsSuppressed],
        (total > 0) ? (v[PVStatRequestsSuppressed] / total) : 0.0];
}

BOOL PVShouldRenderWhileMoving(double speed, double ageSeconds, double visibleSeconds)
{
    // Not-a-number is not evidence of anything. Every comparison below would
    // be false for a NaN, which would silently mean "suppress"; say the safe
    // thing explicitly instead.
    if (!isfinite(speed) || !isfinite(visibleSeconds)) return YES;

    // At rest. Nothing is going anywhere, so nothing is too late.
    if (!(speed > PV_MIN_SCROLL_SPEED)) return YES;

    // A measurement that is not about now cannot justify withholding a page.
    // ageSeconds is infinite when nothing has been measured yet, and negative
    // if the clock moved backwards under us; both land here and render.
    if (!(ageSeconds >= 0) || !(ageSeconds < PV_SPEED_FRESH_SECONDS)) return YES;

    // Fresh evidence of real speed: ask only for what can still be seen.
    return (visibleSeconds > PV_MIN_VISIBLE_SECONDS);
}

CGSize PVClampPixelSize(CGSize px)
{
    // Reject non-finite geometry before the size_t casts downstream, where NaN
    // or infinity would become an arbitrary allocation.
    if (!isfinite(px.width) || !isfinite(px.height)) return CGSizeZero;

    double dw = floor(px.width  + 0.5);
    double dh = floor(px.height + 0.5);
    if (!(dw >= 1)) dw = 1;
    if (!(dh >= 1)) dh = 1;

    // Past the ceiling, scale down to fit rather than refuse. Refusing produced
    // a page that stayed blank forever: nothing lands in the cache, so nothing
    // stops the wanted-set naming that page again on the very next scroll
    // event, and the render queue spins on it. A soft page is a far better
    // failure than no page.
    double ceiling = PVMaxRenderPixels();
    double total   = dw * dh;
    if (total > ceiling) {
        double k = sqrt(ceiling / total);
        dw = floor(dw * k);
        dh = floor(dh * k);
        if (!(dw >= 1)) dw = 1;
        if (!(dh >= 1)) dh = 1;
    }
    return CGSizeMake((CGFloat)dw, (CGFloat)dh);
}

size_t PVImageBytes(CGImageRef img)
{
    if (!img) return 0;
    size_t bpr = CGImageGetBytesPerRow(img);
    size_t h   = CGImageGetHeight(img);
    if (bpr == 0 || h == 0) return 0;
    // Guard the multiply: a corrupt image must not wrap the accumulator.
    if (h > (SIZE_MAX / bpr)) return SIZE_MAX;
    return bpr * h;
}

PVVolumeKind PVVolumeKindFromFlags(BOOL removable, BOOL ejectable, BOOL local)
{
    // A volume that is not local is a network mount: it can be dropped by
    // something that has nothing to do with the Mac in front of you -- a
    // sleeping server, a lost Wi-Fi association -- and the pages of any file
    // open on it stop arriving.
    if (!local) return PVVolumeNetwork;

    // Removable is media that leaves the drive; ejectable is the device or
    // image that leaves the machine, which is also what a mounted .dmg
    // reports. Either is gone in one keystroke, so they are one risk and get
    // one answer.
    if (removable || ejectable) return PVVolumeRemovable;

    return PVVolumeFixed;
}

PVVolumeKind PVVolumeKindForURL(NSURL *url)
{
    if (!url || ![url isFileURL]) return PVVolumeFixed;

    NSNumber *removable = nil, *ejectable = nil, *local = nil;
    if (![url getResourceValue:&removable forKey:NSURLVolumeIsRemovableKey error:NULL] ||
        ![url getResourceValue:&ejectable forKey:NSURLVolumeIsEjectableKey error:NULL] ||
        ![url getResourceValue:&local     forKey:NSURLVolumeIsLocalKey     error:NULL]) {
        return PVVolumeFixed;
    }
    // A key can be fetched successfully and still come back nil when the file
    // system does not implement it. Warning on a volume that declined to
    // describe itself would put a dialog in front of someone who has done
    // nothing wrong, so silence is the answer to a question with no answer.
    if (!removable || !ejectable || !local) return PVVolumeFixed;

    return PVVolumeKindFromFlags([removable boolValue],
                                 [ejectable boolValue],
                                 [local boolValue]);
}

@implementation PVRenderRequest

+ (PVRenderRequest *)page:(NSUInteger)p pixels:(CGSize)s priority:(int)pri preview:(BOOL)pv
{
    return [self page:p pixels:s priority:pri preview:pv express:NO];
}

+ (PVRenderRequest *)page:(NSUInteger)p pixels:(CGSize)s priority:(int)pri preview:(BOOL)pv
                  express:(BOOL)ex
{
    PVRenderRequest *r = [[[PVRenderRequest alloc] init] autorelease];
    r->page = p; r->px = s; r->priority = pri; r->preview = pv; r->express = ex;
    return r;
}
@end
