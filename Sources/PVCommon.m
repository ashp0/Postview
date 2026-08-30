#import "PVCommon.h"
#import <pthread.h>
#import <string.h>
#import <dlfcn.h>

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

PVRamTier PVRamTierForBytes(unsigned long long bytes)
{
    // A pure function of a byte count, so pvtest can walk every tier on any
    // machine. A zero reading would otherwise silently select the smallest
    // budgets forever; treat an implausible answer as "assume a modest machine"
    // rather than as "assume the smallest one", which is a different claim.
    if (bytes == 0)          return PVRamTierSmall;
    if (bytes <= 2 * PV_GB)  return PVRamTierSmall;
    if (bytes <= 4 * PV_GB)  return PVRamTierMedium;
    if (bytes <= 8 * PV_GB)  return PVRamTierLarge;
    return PVRamTierHuge;
}

PVRamTier PVRamTierOfThisMachine(void)
{
    return PVRamTierForBytes(PVPhysicalMemory());
}

size_t PVPageCacheBudgetForTier(PVRamTier tier)
{
    switch (tier) {
        case PVRamTierSmall:  return  32 * 1024 * 1024;
        case PVRamTierMedium: return  64 * 1024 * 1024;
        case PVRamTierLarge:  return  96 * 1024 * 1024;
        // Four ceiling-sized pages rather than the three every tier below holds.
        //
        // The three tiers above are all exactly 3x their own ceiling, which is
        // what `ceiling = budget / 3 / 4` produced before task 3 split the two
        // apart. Three is enough for the two pages that can be on screen plus
        // one prefetched ahead, and on battery that is still all this tier asks
        // for -- PV_FULL_PREFETCH_PAGES is 1 and the wanted set is three pages
        // wide whatever the budget says.
        //
        // The fourth page is what PV_AC_FULL_PREFETCH_PAGES needs, and it is
        // the only reason this number is not 192 MB. On mains power the wanted
        // set becomes two visible plus two ahead, and a budget that holds only
        // three of them would make the fourth evict one of the first three and
        // be asked for again -- the exact loop PV_FULL_PREFETCH_PAGES's comment
        // describes, arrived at from the other direction.
        //
        // A ceiling, not a reservation, and the distinction carries the whole
        // argument. At fit-width a page is 7.11 Mpx, not the 16.78 Mpx ceiling,
        // so the battery wanted set occupies ~81 MB and the AC one ~108 MB.
        // 256 MB is reached only by a machine that is both plugged in and zoomed
        // to the ceiling, which is a 64 GB desktop being asked for the sharpest
        // page it can produce.
        case PVRamTierHuge:
        default:              return 256 * 1024 * 1024;
    }
}

size_t PVThumbCacheBudgetForTier(PVRamTier tier)
{
    switch (tier) {
        case PVRamTierSmall:  return  6 * 1024 * 1024;
        case PVRamTierMedium: return 10 * 1024 * 1024;
        case PVRamTierLarge:  return 16 * 1024 * 1024;
        // Thumbnails do not scale with the render ceiling -- a thumbnail is a
        // thumbnail at any zoom -- so this does not double with the tier above
        // it. It buys a longer strip of already-drawn thumbnails on a machine
        // that can spare it, and nothing else.
        case PVRamTierHuge:
        default:              return 24 * 1024 * 1024;
    }
}

size_t PVPageCacheBudget(void)  { return PVPageCacheBudgetForTier(PVRamTierOfThisMachine()); }
size_t PVThumbCacheBudget(void) { return PVThumbCacheBudgetForTier(PVRamTierOfThisMachine()); }

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

double PVMaxRenderPixelsForTier(PVRamTier tier)
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
    // It then became `PVPageCacheBudget() / 3 / 4` -- literally derived from the
    // eviction budget. That is the coupling this table exists to break. The
    // property being protected is that two full pages plus previews fit what the
    // cache will hold, and that is an inequality between two numbers, not a
    // reason for one of them to BE the other. Written as a derivation, any cut
    // to the budget silently cut the ceiling too: at a 64 MB budget the ceiling
    // is 5.59 Mpx against a ~7.2 Mpx page, so every page in every scenario would
    // have come out downscaled and stretched, permanently, with no diagnostic.
    //
    // The values are exactly the ones that derivation produced, so no machine
    // renders a softer page than it did before the split; pvtest pins the two
    // larger tiers against regression and asserts the inequality on all three.
    // The numerators are one quarter of that tier's historical budget -- bytes
    // to pixels at 4 bytes per pixel -- and the /3 is the share of the cache one
    // page was allowed. Neither term moves when the budget moves now.
    // The fourth entry is the one number in this table that is not the old
    // derivation's output, because there was no fourth tier for it to produce.
    //
    // It is twice the third, and the reason is the zoom cliff. A US Letter page
    // at fit-width on a 2x display is 7.11 Mpx, so the >4 GB ceiling of
    // 8.39 Mpx is crossed at 1.09x zoom: from 9% magnification onwards
    // PVClampPixelSize scales the request down and -drawRect: stretches it back,
    // and the page is soft with nothing anywhere saying so. Doubling the
    // ceiling moves that cliff to sqrt(16.78/7.11) = 1.54x, which covers
    // ordinary reading magnification on a large display instead of failing
    // immediately below it.
    //
    // Not quadrupled to reach 2x zoom. That would need a 320 MB budget to keep
    // the inequality, and peak RSS is the one metric this app loses on -- see
    // ENGINEERING.md §6. 1.54x is the step that buys the common case
    // without spending the ground the app is already behind on.
    static const double kCeilingPixels[PVRamTierCount] = {
        ( 8.0 * 1024.0 * 1024.0) / 3.0,   //  <= 2 GB :  2.80 Mpx
        (16.0 * 1024.0 * 1024.0) / 3.0,   //  <= 4 GB :  5.59 Mpx
        (24.0 * 1024.0 * 1024.0) / 3.0,   //  <= 8 GB :  8.39 Mpx, cliff at 1.09x
        (48.0 * 1024.0 * 1024.0) / 3.0    //   > 8 GB : 16.78 Mpx, cliff at 1.54x
    };

    int idx = (int)tier;
    if (idx < 0 || idx >= PVRamTierCount) idx = PVRamTierLarge;
    double ceiling = kCeilingPixels[idx];
    if (ceiling > PV_MAX_PIXELS) ceiling = PV_MAX_PIXELS;
    if (ceiling < 1.0) ceiling = 1.0;
    return ceiling;
}

double PVMaxRenderPixels(void)
{
    return PVMaxRenderPixelsForTier(PVRamTierOfThisMachine());
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

void PVStatMax(PVStatKey key, double value)
{
    if (!PVStatsEnabled()) return;
    if (key < 0 || key >= PVStatCount) return;
    if (!isfinite(value)) return;
    pthread_mutex_lock(&sPVStatsLock);
    if (value > sPVStats[key]) sPVStats[key] = value;
    pthread_mutex_unlock(&sPVStatsLock);
}

double PVStatValue(PVStatKey key)
{
    if (!PVStatsEnabled()) return 0;
    if (key < 0 || key >= PVStatCount) return 0;
    pthread_mutex_lock(&sPVStatsLock);
    double v = sPVStats[key];
    pthread_mutex_unlock(&sPVStatsLock);
    return v;
}

#pragma mark - Resident rendered-pixel census

// One lock over both the per-bucket totals and the high-water marks. They are
// not independent quantities: a peak read from a total that another thread is
// halfway through updating is a number that describes no instant that ever
// existed. Taking them together is what makes the reported peak a real sample
// of the real sum.
static size_t          sPVResident[PVResidentBucketCount];
static size_t          sPVResidentPeak[PVResidentBucketCount];
static size_t          sPVResidentTotal;
static size_t          sPVResidentTotalPeak;
static pthread_mutex_t sPVResidentLock = PTHREAD_MUTEX_INITIALIZER;

void PVResidentAdd(PVResidentBucket bucket, size_t bytes)
{
    if (bucket < 0 || bucket >= PVResidentBucketCount) return;
    if (bytes == 0) return;

    pthread_mutex_lock(&sPVResidentLock);
    // Saturate rather than wrap. A wrapped total would read as near zero and
    // would then never trip the high-water mark again for the life of the
    // process -- the same class of silent, permanent failure the cache's own
    // byte counter guards against, and worth guarding here for the same reason
    // even though every input is a CoreGraphics row-stride product.
    if (bytes > SIZE_MAX - sPVResident[bucket]) sPVResident[bucket] = SIZE_MAX;
    else                                        sPVResident[bucket] += bytes;
    if (bytes > SIZE_MAX - sPVResidentTotal)    sPVResidentTotal = SIZE_MAX;
    else                                        sPVResidentTotal += bytes;

    if (sPVResident[bucket] > sPVResidentPeak[bucket])
        sPVResidentPeak[bucket] = sPVResident[bucket];
    if (sPVResidentTotal > sPVResidentTotalPeak)
        sPVResidentTotalPeak = sPVResidentTotal;

    double total       = (double)sPVResidentTotal;
    double undelivered = (double)sPVResident[PVResidentUndelivered];
    double cached      = (double)sPVResident[PVResidentCache];
    pthread_mutex_unlock(&sPVResidentLock);

    // Mirrored out to the census so `-PVStats YES` carries it to the showdown.
    // Done outside this lock: PVStatMax takes its own, and nesting two global
    // locks in a fixed order is a discipline that only has to be got wrong once.
    PVStatMax(PVStatPeakResidentBytes,    total);
    PVStatMax(PVStatPeakUndeliveredBytes, undelivered);
    PVStatMax(PVStatPeakCacheBytes,       cached);
}

void PVResidentSub(PVResidentBucket bucket, size_t bytes)
{
    if (bucket < 0 || bucket >= PVResidentBucketCount) return;
    if (bytes == 0) return;
    pthread_mutex_lock(&sPVResidentLock);
    // Clamp at zero. An unbalanced subtraction must not wrap the counter into
    // an enormous number that then suppresses every subsequent peak.
    size_t take = (bytes > sPVResident[bucket]) ? sPVResident[bucket] : bytes;
    sPVResident[bucket] -= take;
    sPVResidentTotal     = (take > sPVResidentTotal) ? 0 : (sPVResidentTotal - take);
    pthread_mutex_unlock(&sPVResidentLock);
}

size_t PVResidentBytes(PVResidentBucket bucket)
{
    if (bucket < 0 || bucket >= PVResidentBucketCount) return 0;
    pthread_mutex_lock(&sPVResidentLock);
    size_t v = sPVResident[bucket];
    pthread_mutex_unlock(&sPVResidentLock);
    return v;
}

size_t PVResidentTotal(void)
{
    pthread_mutex_lock(&sPVResidentLock);
    size_t v = sPVResidentTotal;
    pthread_mutex_unlock(&sPVResidentLock);
    return v;
}

size_t PVResidentHighWater(void)
{
    pthread_mutex_lock(&sPVResidentLock);
    size_t v = sPVResidentTotalPeak;
    pthread_mutex_unlock(&sPVResidentLock);
    return v;
}

size_t PVResidentHighWaterForBucket(PVResidentBucket bucket)
{
    if (bucket < 0 || bucket >= PVResidentBucketCount) return 0;
    pthread_mutex_lock(&sPVResidentLock);
    size_t v = sPVResidentPeak[bucket];
    pthread_mutex_unlock(&sPVResidentLock);
    return v;
}

void PVResidentReset(void)
{
    int i;
    pthread_mutex_lock(&sPVResidentLock);
    for (i = 0; i < PVResidentBucketCount; i++) {
        sPVResident[i]     = 0;
        sPVResidentPeak[i] = 0;
    }
    sPVResidentTotal     = 0;
    sPVResidentTotalPeak = 0;
    pthread_mutex_unlock(&sPVResidentLock);
}

NSString *PVStatsReport(void)
{
    if (!PVStatsEnabled()) return nil;
    double v[PVStatCount];
    int i;
    pthread_mutex_lock(&sPVStatsLock);
    for (i = 0; i < PVStatCount; i++) v[i] = sPVStats[i];
    pthread_mutex_unlock(&sPVStatsLock);

    double asked      = v[PVStatRendersFull] + v[PVStatRendersPreview];
    double suppressed = v[PVStatRequestsSuppressed] + v[PVStatMotionSuppressed];
    double total      = asked + suppressed;

    // The peaks are read from the resident census rather than from the array,
    // because that census is on in every build and this one is not: a run with
    // stats disabled still maintains the high-water marks, and reading them
    // here means the two can never disagree about the same run.
    const double kMB = 1024.0 * 1024.0;
    double peakResident    = (double)PVResidentHighWater() / kMB;
    double peakCache       = (double)PVResidentHighWaterForBucket(PVResidentCache) / kMB;
    double peakUndelivered = (double)PVResidentHighWaterForBucket(PVResidentUndelivered) / kMB;
    double peakRender      = (double)PVResidentHighWaterForBucket(PVResidentRender) / kMB;

    // Machine-readable on purpose: the benchmark greps these lines out of the
    // app's stderr and puts them in the TSV beside the CPU numbers.
    //
    // `requests.suppressed` keeps its old meaning -- dwell suppression only --
    // because runs recorded against it go back to the first profile. The motion
    // gate gets its own line and the two are totalled explicitly, so no column
    // silently changes what it counts.
    return [NSString stringWithFormat:
        @"PVSTAT renders.full %.0f\n"
         "PVSTAT renders.preview %.0f\n"
         "PVSTAT renders.failed %.0f\n"
         "PVSTAT megapixels.full %.2f\n"
         "PVSTAT megapixels.preview %.2f\n"
         "PVSTAT megapixels.total %.2f\n"
         "PVSTAT requests.suppressed %.0f\n"
         "PVSTAT requests.suppressed.motion %.0f\n"
         "PVSTAT requests.suppressed.total %.0f\n"
         "PVSTAT suppression.rate %.3f\n"
         "PVSTAT resident.peak.mb %.2f\n"
         "PVSTAT resident.peak.cache.mb %.2f\n"
         "PVSTAT resident.peak.undelivered.mb %.2f\n"
         "PVSTAT resident.peak.render.mb %.2f\n"
         // The cost model, in the terms it actually decides in. Both directions
         // and the measurement behind them, because a model that only ever
         // suppressed would be indistinguishable in these totals from a tighter
         // constant, and one that only ever admitted from a looser one.
         "PVSTAT cost.suppressed %.0f\n"
         "PVSTAT cost.admitted %.0f\n"
         "PVSTAT cost.render.seconds %.3f\n"
         "PVSTAT cost.render.samples %.0f\n"
         "PVSTAT cost.ms.per.mpx %.2f\n"
         "PVSTAT power.source %s\n",
        v[PVStatRendersFull], v[PVStatRendersPreview], v[PVStatRendersFailed],
        v[PVStatPixelsFull], v[PVStatPixelsPreview],
        v[PVStatPixelsFull] + v[PVStatPixelsPreview],
        v[PVStatRequestsSuppressed],
        v[PVStatMotionSuppressed],
        suppressed,
        (total > 0) ? (suppressed / total) : 0.0,
        peakResident, peakCache, peakUndelivered, peakRender,
        v[PVStatCostSuppressed], v[PVStatCostAdmitted],
        v[PVStatRenderSeconds], v[PVStatRenderSamples],
        // Measured over the whole run rather than taken from any one document's
        // EWMA: this line is for reading a recorded run back afterwards, and a
        // decaying average has no defined value once the process has exited.
        ((v[PVStatPixelsFull] + v[PVStatPixelsPreview]) > 0)
            ? (v[PVStatRenderSeconds] * 1000.0
               / (v[PVStatPixelsFull] + v[PVStatPixelsPreview]))
            : 0.0,
        (PVCurrentPowerSource() == PVPowerAC)      ? "ac"
        : (PVCurrentPowerSource() == PVPowerBattery) ? "battery" : "unknown"];
}

BOOL PVShouldRenderWhileMovingCost(double speed, double ageSeconds, double visibleSeconds,
                                   double predictedSeconds, double safetyFactor,
                                   double minDwell)
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

    // The floor, and the whole answer when there is no prediction.
    //
    // PV_MIN_VISIBLE_SECONDS is a claim about eyes -- a quarter of a second is
    // where a glimpse becomes a look -- and the cost model has nothing to say
    // about eyes. So the model is allowed to raise this bar and never to lower
    // it. A page that will be on screen for 40 ms is not worth rasterising
    // because nobody can read it, and that stays true on a document where the
    // render would have cost 11 ms and on a machine that is plugged in.
    double threshold = (isfinite(minDwell) && minDwell > 0) ? minDwell
                                                            : PV_MIN_VISIBLE_SECONDS;

    // A usable prediction raises it. This is the direction that matters on
    // expensive documents: 0.25 s admits a 657 ms render into a window it
    // cannot possibly finish in, and the bitmap arrives for a page that left
    // the screen a third of a second ago. Every guard is explicit because an
    // unusable prediction has to mean "no prediction", not "threshold zero".
    if (isfinite(predictedSeconds) && predictedSeconds > 0 &&
        isfinite(safetyFactor)    && safetyFactor    > 0) {
        double needed = predictedSeconds * safetyFactor;
        if (needed > threshold) threshold = needed;
    }

    // Fresh evidence of real speed: ask only for what can still be seen, and
    // only for what can be finished while it is.
    return (visibleSeconds > threshold);
}

// The original three-argument form, preserved exactly.
//
// Not merely a convenience: this is the shape the policy is tested in, by an
// exhaustive sweep and a determinism check that between them are most of what
// anyone knows about the scheduler's safety. Expressing it as the cost-aware
// function with no cost is what makes "the cost model's absence is the old
// policy" a fact about the code rather than a claim in a comment -- and pvtest
// re-asserts the equivalence across the same sweep, so the two cannot drift.
BOOL PVShouldRenderWhileMoving(double speed, double ageSeconds, double visibleSeconds)
{
    return PVShouldRenderWhileMovingCost(speed, ageSeconds, visibleSeconds,
                                         0.0, 0.0, PV_MIN_VISIBLE_SECONDS);
}

#pragma mark - Power source

// The override, and whether it is in force. Written once at launch from
// -PVPowerState and by pvtest; read on the main thread. Not guarded, because
// both writers run before or between the reads that matter and a torn read of
// an enum this small is not representable on either architecture this ships to.
static PVPowerSource sPVPowerOverride;
static BOOL          sPVPowerOverrideOn;

void PVSetPowerSourceOverride(PVPowerSource source, BOOL enabled)
{
    sPVPowerOverride   = source;
    sPVPowerOverrideOn = enabled;
}

PVPowerSource PVPowerSourceFromString(NSString *s)
{
    if (![s isKindOfClass:[NSString class]]) return PVPowerUnknown;
    NSString *v = [[s stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    // IOKit's own spellings first, then the ones a person would type at a shell.
    // "Unknown" is the answer for everything else, including nil and "" -- an
    // unreadable setting must not be able to select the expensive branch.
    if ([v isEqualToString:@"acpower"]     || [v isEqualToString:@"ac"] ||
        [v isEqualToString:@"ac power"]    || [v isEqualToString:@"mains"] ||
        [v isEqualToString:@"plugged"])    return PVPowerAC;
    if ([v isEqualToString:@"batterypower"] || [v isEqualToString:@"battery"] ||
        [v isEqualToString:@"battery power"] ||
        [v isEqualToString:@"unplugged"])  return PVPowerBattery;
    return PVPowerUnknown;
}

// IOKit, resolved at runtime. See the header for why this is not a link-time
// dependency: `make verify` allow-lists every dylib the shipping binary may
// load, and adding one to that list to read a boolean is a poor trade.
typedef CFTypeRef   (*PVIOPSCopyInfo)(void);
typedef CFStringRef (*PVIOPSProvidingType)(CFTypeRef);

static void PVPowerSymbols(PVIOPSCopyInfo *outCopy, PVIOPSProvidingType *outType)
{
    static PVIOPSCopyInfo      sCopy;
    static PVIOPSProvidingType sType;
    static dispatch_once_t     once;
    dispatch_once(&once, ^{
        // RTLD_DEFAULT would usually find these, because AppKit pulls IOKit in
        // transitively -- but "usually" is the wrong basis for a lookup whose
        // failure silently changes the scheduler's policy. Open it by path and
        // deliberately never close it: the handle lives for the process, and a
        // dlclose here would invalidate the two pointers below.
        void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (!h) return;
        sCopy = (PVIOPSCopyInfo)dlsym(h, "IOPSCopyPowerSourcesInfo");
        sType = (PVIOPSProvidingType)dlsym(h, "IOPSGetProvidingPowerSourceType");
        if (!sCopy || !sType) { sCopy = NULL; sType = NULL; }
    });
    *outCopy = sCopy;
    *outType = sType;
}

// How long an answer is reused before the kernel is asked again.
//
// The wanted-set builder consults the policy on every scroll event, which is
// 60-120 times a second during a gesture. IOPSCopyPowerSourcesInfo allocates
// and copies a CF dictionary; doing that per event would cost more main-thread
// time than the entire policy it feeds can save. Five seconds is far below any
// rate at which a charger is plugged and unplugged and far above the event
// rate.
#define PV_POWER_CACHE_SECONDS  5.0

// -PVPowerState (auto|battery|ac), read the same two ways PVStatsEnabled reads
// -PVStats: the environment for a directly-executed binary, and the argument
// domain so that `open --args -PVPowerState battery` works through
// LaunchServices, which is the launch path a benchmark has to use if it wants
// to measure what a user gets.
//
// Tools/showdown.sh needs this and the reason is specific: the arbiter machine
// is a Mac Pro, which has no battery, so every trial recorded there would take
// the AC branch and stop describing the case the project exists to optimise.
// Pinning it makes the recorded numbers comparable with the ones already in
// ENGINEERING.md instead of silently measuring a different program.
//
// A programmatic override already in force wins. pvtest sets one before
// anything reads the power source, and a defaults value quietly replacing it
// would make the test's own configuration depend on call order.
static void PVApplyPowerDefaultOnce(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (sPVPowerOverrideOn) return;
        NSString *v = nil;
        const char *env = getenv("POSTVIEW_POWER");
        if (env && env[0]) v = [NSString stringWithUTF8String:env];
        if ([v length] == 0)
            v = [[NSUserDefaults standardUserDefaults] stringForKey:@"PVPowerState"];
        if ([v length] == 0) return;
        // "auto" is spelled out rather than being the absence of a value, so a
        // script can pass it explicitly and mean it.
        if ([[v lowercaseString] isEqualToString:@"auto"]) return;
        PVPowerSource forced = PVPowerSourceFromString(v);
        // An unrecognised string leaves the override off rather than pinning
        // Unknown: a typo should fall back to asking the machine, not to
        // permanently answering "I don't know".
        if (forced != PVPowerUnknown) PVSetPowerSourceOverride(forced, YES);
    });
}

PVPowerSource PVCurrentPowerSource(void)
{
    PVApplyPowerDefaultOnce();
    if (sPVPowerOverrideOn) return sPVPowerOverride;

    static PVPowerSource sCached;
    static double        sCachedAt;
    double now = [NSDate timeIntervalSinceReferenceDate];
    // The `now < sCachedAt` half catches the clock moving backwards, which
    // would otherwise pin a stale answer until it caught up again.
    if (sCachedAt > 0 && now >= sCachedAt && (now - sCachedAt) < PV_POWER_CACHE_SECONDS)
        return sCached;

    PVIOPSCopyInfo      copyInfo = NULL;
    PVIOPSProvidingType typeOf   = NULL;
    PVPowerSymbols(&copyInfo, &typeOf);

    PVPowerSource result = PVPowerUnknown;
    if (copyInfo && typeOf) {
        CFTypeRef blob = copyInfo();
        if (blob) {
            CFStringRef kind = typeOf(blob);
            if (kind) result = PVPowerSourceFromString((NSString *)kind);
            CFRelease(blob);
        }
    }
    // A desktop with no battery at all reports AC, which is the answer we want
    // and the reason this is not phrased as "is there a battery".
    sCached   = result;
    sCachedAt = now;
    return result;
}

#pragma mark - The render policy

PVRenderPolicy PVRenderPolicyFor(PVPowerSource power, PVRamTier tier,
                                 NSUInteger pressureReports)
{
    PVRenderPolicy p;

    // The battery answer, which is also the Unknown answer, and which is
    // exactly the behaviour the app had before this function existed. Stated
    // first and unconditionally so that every branch below is visibly a
    // departure from it rather than an independent set of numbers.
    p.fullPrefetchPages      = PV_FULL_PREFETCH_PAGES;
    p.dwellSafetyFactor      = PV_DWELL_SAFETY_BATTERY;
    p.minDwellSeconds        = PV_MIN_VISIBLE_SECONDS;
    p.fullRendersWhileMoving = NO;

    if (power == PVPowerAC) {
        // Nothing here is free -- it is all more CPU for less latency. It is
        // only correct because the energy is arriving down a wall socket, so
        // the one thing that must never happen is this branch being taken on a
        // machine running on its battery. PVPowerUnknown deliberately does not
        // reach it.
        p.fullPrefetchPages      = PV_AC_FULL_PREFETCH_PAGES;
        p.dwellSafetyFactor      = PV_DWELL_SAFETY_AC;
        // The motion gate becomes a per-page question instead of a blanket no.
        //
        // On battery, refusing every full-resolution bitmap while the document
        // moves is right, because the common case is a flick past pages nobody
        // will read. On AC that same rule refuses a sharp page during a slow
        // deliberate scroll of a document whose pages cost 11 ms -- work the
        // machine finishes twenty times over inside the dwell it was given.
        // Opening the gate does not render everything: the dwell test still
        // runs per page, still floored at PV_MIN_VISIBLE_SECONDS, and a genuine
        // flick still suppresses because the page is gone in 20 ms whatever it
        // would have cost.
        p.fullRendersWhileMoving = YES;
    }

    // Memory pressure outranks the power source in both directions, and it is
    // applied after the AC branch precisely so it can undo it. A machine that
    // is compressing and swapping is not made better by being plugged in --
    // the swap is costing it far more time and power than any render this
    // policy could withhold.
    if (pressureReports >= 1) {
        p.fullPrefetchPages      = 0;
        p.fullRendersWhileMoving = NO;
    }
    if (pressureReports >= 2) {
        // Only previews from here. See _pressureReports: answering a second
        // report the same way as the first is the loop that keeps a tight
        // machine tight for hours.
        p.dwellSafetyFactor      = PV_DWELL_SAFETY_BATTERY;
        p.minDwellSeconds        = PV_MIN_VISIBLE_SECONDS;
    }

    // The prefetch depth is the one field that can put the cache into the
    // thrash loop, so it is clamped here rather than trusted to the table
    // above. A policy that does not fit is reduced until it does, and pvtest
    // asserts that the reduction was never needed -- a silent clamp that is
    // load-bearing would be a constant nobody could find.
    while (p.fullPrefetchPages > 0 && !PVRenderPolicyFitsCache(p, tier))
        p.fullPrefetchPages--;

    return p;
}

BOOL PVRenderPolicyFitsCache(PVRenderPolicy policy, PVRamTier tier)
{
    // Capacity in whole full-resolution bitmaps: the two that can be on screen
    // at any ordinary zoom, plus everything the prefetch will ask for ahead of
    // them. Every one of those is named by the same wanted set, so if they do
    // not all fit, storing the last evicts one of the others and the queue is
    // asked for it again on the very next scroll event.
    //
    // Deliberately not the inequality in PVMaxRenderPixelsForTier's comment.
    // That one adds PV_CACHE_SLACK_PREVIEWS and is about a different failure --
    // a budget that holds exactly two pages and nothing else evicts a preview
    // every time a page is stored. Previews are a ninth the size and are
    // evicted last by construction (-evictExcept: does not touch them for a
    // full-bitmap limit), so folding them in here would refuse a prefetch depth
    // that is in fact affordable. Both invariants hold; they are not the same
    // one and pvtest checks each separately.
    //
    // Evaluated at the ceiling, which is the worst case rather than the common
    // one: at fit-width a page is well under it. Sizing prefetch for the page
    // the user might zoom to is the conservative direction, and the whole point
    // of the check is that the loop it prevents is invisible from outside the
    // process.
    double perPage = PVMaxRenderPixelsForTier(tier) * 4.0;
    double wanted  = (2.0 + (double)policy.fullPrefetchPages) * perPage;
    // The +1 absorbs the float round trip on tiers where the two sides are
    // exactly equal by construction, which is every tier below Huge.
    return (wanted <= (double)PVPageCacheBudgetForTier(tier) + 1.0);
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
