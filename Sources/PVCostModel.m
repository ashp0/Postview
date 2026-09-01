#import "PVCostModel.h"

@implementation PVCostModel

- (id)init
{
    self = [super init];
    if (!self) return nil;
    // -release runs -dealloc, and -dealloc used to destroy the mutex
    // unconditionally. On the one path that reaches it with the mutex never
    // initialised -- this failure -- that is pthread_mutex_destroy on
    // uninitialised stack garbage, which is undefined rather than a clean
    // "could not allocate". The flag is the smallest thing that makes -dealloc
    // able to tell the two states apart.
    if (pthread_mutex_init(&_lock, NULL) != 0) {
        [self release];
        return nil;
    }
    _lockInitialized = YES;
    return self;
}

- (void)dealloc
{
    if (_lockInitialized) pthread_mutex_destroy(&_lock);
    [super dealloc];
}

- (void)reset
{
    pthread_mutex_lock(&_lock);
    _msPerMpx[0] = _msPerMpx[1] = 0;
    _samples[0]  = _samples[1]  = 0;
    pthread_mutex_unlock(&_lock);
}

- (void)recordSeconds:(double)seconds pixels:(CGSize)px preview:(BOOL)preview
{
    // A sample has to be a positive duration over a positive area. Anything
    // else is not a slow render, it is a broken measurement -- a clock that
    // stepped backwards, a zero-size bitmap, a NaN out of a failed clamp -- and
    // folding it in would move a rate that decays slowly enough to still be
    // wrong minutes later.
    if (!isfinite(seconds) || seconds <= 0) return;
    if (!isfinite(px.width) || !isfinite(px.height)) return;
    double mpx = ((double)px.width * (double)px.height) / 1.0e6;
    if (!(mpx > 0)) return;

    double rate = (seconds * 1000.0) / mpx;
    if (!isfinite(rate)) return;
    // Clamped before it is folded in, not after. A single absurd sample folded
    // in and then clamped still drags the stored rate; clamping the input keeps
    // every value the EWMA has ever seen inside the band.
    if (rate < PV_COST_MIN_MS_PER_MPX) rate = PV_COST_MIN_MS_PER_MPX;
    if (rate > PV_COST_MAX_MS_PER_MPX) rate = PV_COST_MAX_MS_PER_MPX;

    int i = preview ? 1 : 0;
    pthread_mutex_lock(&_lock);
    if (_samples[i] <= 0) {
        // Seeded from the first observation rather than from a constant. A
        // constant seed would be a claim about a document nobody has measured
        // yet, and the EWMA would spend its first several samples walking away
        // from it -- during which the model is at its least reliable and is
        // being consulted just as often.
        _msPerMpx[i] = rate;
    } else {
        _msPerMpx[i] = (PV_COST_EWMA_ALPHA * rate)
                     + ((1.0 - PV_COST_EWMA_ALPHA) * _msPerMpx[i]);
    }
    _samples[i] += 1.0;
    pthread_mutex_unlock(&_lock);

    // Recorded outside the lock: PVStatAdd takes a lock of its own, and taking
    // two in a fixed order here would be one more ordering for anyone changing
    // either to have to know about. Nothing reads these two back as a pair.
    PVStatAdd(preview ? PVStatRenderSecondsPreview : PVStatRenderSecondsFull, seconds);
    PVStatAdd(preview ? PVStatRenderSamplesPreview : PVStatRenderSamplesFull, 1);
}

- (double)predictedSecondsForPixels:(CGSize)px preview:(BOOL)preview
{
    if (!isfinite(px.width) || !isfinite(px.height)) return 0;
    double mpx = ((double)px.width * (double)px.height) / 1.0e6;
    if (!(mpx > 0)) return 0;

    int i = preview ? 1 : 0;
    pthread_mutex_lock(&_lock);
    double rate    = _msPerMpx[i];
    double samples = _samples[i];
    pthread_mutex_unlock(&_lock);

    // Not enough evidence. Zero is the caller's signal to use its constant, and
    // it is what makes the cost model's absence identical to the old policy
    // rather than merely similar to it.
    if (samples < PV_COST_MIN_SAMPLES) return 0;
    if (!(rate > 0) || !isfinite(rate)) return 0;

    double seconds = (rate * mpx) / 1000.0;
    return isfinite(seconds) ? seconds : 0;
}

- (double)msPerMegapixelForPreview:(BOOL)preview
{
    int i = preview ? 1 : 0;
    pthread_mutex_lock(&_lock);
    double v = _msPerMpx[i];
    pthread_mutex_unlock(&_lock);
    return v;
}

- (NSUInteger)sampleCountForPreview:(BOOL)preview
{
    int i = preview ? 1 : 0;
    pthread_mutex_lock(&_lock);
    double v = _samples[i];
    pthread_mutex_unlock(&_lock);
    return (NSUInteger)v;
}

@end
