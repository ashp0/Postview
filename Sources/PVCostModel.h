//  PVCostModel.h — what a render of this document actually costs, measured.
//
//  Every gate in the scheduler is trying to ask one question: will this bitmap
//  finish before the page it is for has left the screen? Until this existed,
//  every one of them asked a proxy question instead -- is this under N
//  megapixels, will the page be visible for a quarter of a second, how many
//  neighbours should be prefetched -- and the proxy is wrong by up to 59x.
//
//  Measured, `make band`, ENGINEERING.md §2: two documents, identical
//  page geometry, identical bitmap, identical code path, back to back.
//
//      heavy.pdf   ~1400 bezier curves/page   7.11 Mpx   657.3 ms
//      text.pdf    dense 9 pt body text       7.11 Mpx    11.2 ms
//
//  A single constant asked to cover that range is wrong at both ends. It
//  suppresses text renders the machine could afford twenty-two times over, and
//  it admits a 657 ms render into a 250 ms window where the bitmap arrives for
//  a page that left a third of a second ago. That is not a tuning failure; no
//  value of the constant is right for both, which is what makes measuring the
//  only available answer.
//
//  ---------------------------------------------------------------------------
//  Why this is safe, given that two earlier attempts at it were not
//
//  PV_MIN_VISIBLE_SECONDS' own comment records two failures at deriving a
//  threshold from measured render time, and neither is a reason not to do it --
//  they are two specific mistakes, and this avoids both by construction.
//
//  1. "Feeding the measurement straight in made the decision an input to its own
//     measurement: suppressing renders left the estimate stale, and the stale
//     estimate decided whether to keep suppressing."
//
//     The loop needs suppression to be able to starve the sampler. It cannot
//     here, because the samples do not come from the renders the policy is
//     deciding about. -settleFired: and -didEndLiveScroll: ask for the sharp
//     pass unconditionally once movement stops, and PV_SPEED_FRESH_SECONDS
//     guarantees suppression expires on its own even if every timer were lost.
//     So every scroll episode ends in renders that no gate is allowed to
//     withhold, and those are the samples. A model that suppressed everything
//     during motion would still be fully fed.
//
//     Belt and braces on top of that: -predictedSecondsForPixels: answers "no
//     prediction" until PV_COST_MIN_SAMPLES observations exist, and the gate
//     reduces exactly to the old constant while it does.
//
//  2. "The estimate mixes two populations, because a preview costs about a
//     sixth of a full page and which one was rendered last depends on whether
//     you have just stopped scrolling, so the crossover moved by a factor of six
//     and the same scroll speed came out at 41% or 121% on consecutive runs."
//
//     That is the real defect and it is fixed by not mixing them. Two
//     independent estimates are kept, one per population, and a prediction is
//     only ever made from the one that matches. They are genuinely different
//     rates rather than a constant factor apart: ENGINEERING.md §2 splits
//     the cost into destination traffic (proportional to pixels) and
//     content-stream interpretation (proportional to operator count, and paid
//     in full however few pixels are being drawn). A preview is 1/9 the pixels
//     and re-walks the whole content stream, so on text its ms-per-megapixel is
//     several times a full page's -- which is exactly the six-fold crossover the
//     old attempt was measuring without knowing it.
//
//  ---------------------------------------------------------------------------
//  Why milliseconds per megapixel, rather than fitting the two terms
//
//  The two-mechanism model above suggests a two-parameter fit -- a fixed
//  per-render interpretation cost plus a per-pixel fill cost -- and that would
//  be a better description of the physics. It is not what this does. Fitting
//  two parameters online needs a regression over samples that vary in size, and
//  within one document at one zoom they barely vary at all: previews and fulls
//  are the only two sizes in play, which is two clusters and no leverage. The
//  fit would be dominated by whichever cluster arrived last, which is the same
//  instability as failure 2 wearing a better hat.
//
//  Splitting by population and keeping a simple rate per population gets the
//  same information out of the same samples without any of that: the fixed term
//  is not estimated, it is absorbed into whichever rate it belongs to, and each
//  rate is only ever used to predict its own kind of render.

#import "PVCommon.h"
#import <pthread.h>

// Weight given to a new observation.
//
// A rate that reaches ~95% of a step change after twelve samples. Slow enough
// that one unusual page -- a scanned cover, a full-page photograph in a text
// document -- does not move the policy for the rest of the session, and fast
// enough to cross the whole 59x range within one screenful of scrolling if the
// document genuinely changes character partway through.
#define PV_COST_EWMA_ALPHA      0.22

// Observations required before a prediction is offered at all.
//
// Below this -predictedSecondsForPixels: returns 0 and every gate falls back to
// its constant, which is the behaviour the app had before this file existed.
// Three rather than one because the first render of a document is the least
// representative one it will ever do: cold caches everywhere, fonts not yet
// parsed, and on the very first page CoreGraphics has the document's shared
// resources still to build.
#define PV_COST_MIN_SAMPLES     3

// Hard bounds on a rate, in milliseconds per megapixel.
//
// Not tuning. These exist so that a pathological sample -- a machine that went
// to sleep mid-render, a clock that stepped, a page that hit swap -- cannot put
// the scheduler somewhere it will not come back from. The band is deliberately
// enormous: `text.pdf` measures 1.6 ms/Mpx and `heavy.pdf` 92 ms/Mpx, so the
// whole measured range of real documents sits comfortably inside it and these
// only ever catch nonsense.
#define PV_COST_MIN_MS_PER_MPX  0.01
#define PV_COST_MAX_MS_PER_MPX  20000.0

@interface PVCostModel : NSObject {
    // Updated on a render queue, read from the main thread. One mutex rather
    // than an atomic per field, because a prediction has to see a rate and its
    // sample count agree -- a reader that saw the count cross
    // PV_COST_MIN_SAMPLES while the rate was still the seed would predict from
    // a number that was never a measurement.
    pthread_mutex_t _lock;
    // Whether _lock was successfully initialised. -dealloc must not destroy a
    // mutex that pthread_mutex_init never touched, and -init's failure path
    // reaches -dealloc through -release.
    BOOL            _lockInitialized;
    // Index 0 is full-resolution, index 1 is preview. Two populations, never
    // mixed: see the header note above.
    double          _msPerMpx[2];
    double          _samples[2];
}

// One observation. `px` must be the size actually rasterised -- the clamped
// size, not the requested one -- or the rate is computed against pixels that
// were never drawn. Safe to call from any thread. Non-finite or non-positive
// input is discarded rather than folded in.
- (void)recordSeconds:(double)seconds pixels:(CGSize)px preview:(BOOL)preview;

// Predicted seconds to rasterise this bitmap, or 0 when there is not yet enough
// evidence to say. Callers must treat 0 as "no prediction" and fall back to
// their constant; PVShouldRenderWhileMovingCost does exactly that.
- (double)predictedSecondsForPixels:(CGSize)px preview:(BOOL)preview;

// The current rate and how many observations are behind it. For the census and
// for tests; nothing in the policy path needs them.
- (double)msPerMegapixelForPreview:(BOOL)preview;
- (NSUInteger)sampleCountForPreview:(BOOL)preview;

// Forget everything. Used when the document's geometry changes enough that past
// samples describe a different workload -- and by tests, which need a clean
// measurement window.
- (void)reset;
@end
