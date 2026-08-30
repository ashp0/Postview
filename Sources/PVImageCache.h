//  PVImageCache.h — byte-budgeted LRU of rendered page bitmaps.
//
//  Each page gets one entry holding up to two images: the "full" bitmap at the
//  exact current pixel size, and a cheap "preview" bitmap at roughly a third of
//  that. Previews are ~9x smaller, so they survive eviction long after fulls are
//  gone, which is what makes scrolling back over already-visited pages instant.
//  Main thread only.

#import "PVCommon.h"

@interface PVImageCache : NSObject {
    NSMutableDictionary *_entries;    // NSNumber(page) -> PVCacheEntry
    unsigned long long   _clock;
    size_t               _bytes;
    size_t               _budget;
    // The pages currently on screen. Eviction steps over them; see -setPinnedPages:.
    NSRange              _pinned;
    // The GreedyDual inflation value. See -evictExcept:.
    //
    // Rises to the value of whatever was last thrown away, which is what stops
    // an expensive page that is never looked at again from being immortal:
    // every eviction raises the bar that a resident entry's original cost has
    // to clear, so age catches up with cost eventually and without a second
    // parameter to tune.
    double               _gdsL;
}
- (id)initWithBudget:(size_t)budget;

// The pages that are on screen right now. Eviction never touches them.
//
// Without this the cache and the layer above disagree about what has to be
// resident, and the disagreement does not settle. The render queue wants a
// full-resolution bitmap for every visible page; the cache, once the visible
// set no longer fits the budget, evicts the one that was least recently
// stored -- which is the other visible page. The next draw finds it missing,
// the wanted-set names it again, rendering it evicts the first, and the queue
// rasterises the same two heavy pages for as long as the window stays open,
// with the pages flickering between sharp and soft the whole time.
//
// Pinning makes the loop impossible rather than unlikely: a bitmap the layer
// above still wants is never the one thrown away, so every render lands
// somewhere that stops it being asked for again. When the visible set genuinely
// will not fit, the cache goes over budget by that much and no further --
// bounded by the visible page count times PVMaxRenderPixels(), which is a
// third of the budget each -- and comes straight back under as soon as the
// user scrolls. That is strictly cheaper than rendering forever, which is what
// it replaces. A zero-length range pins nothing.
- (void)setPinnedPages:(NSRange)range;

// Exact-size match only; NULL if the cached bitmap was rendered at another zoom.
- (CGImageRef)fullImageForPage:(NSUInteger)page pixelSize:(CGSize)px;
// The same question, asked without touching the cache. -fullImageForPage: bumps
// the entry's LRU stamp, which is right for a caller about to draw and wrong for
// one that is only deciding whether a request would have been made: counting a
// suppressed render must not reorder eviction, or the instrumentation changes
// the behaviour it was added to measure.
- (BOOL)hasFullImageForPage:(NSUInteger)page pixelSize:(CGSize)px;
// Best bitmap available for this page at any size, for use as a placeholder.
- (CGImageRef)placeholderImageForPage:(NSUInteger)page;
- (BOOL)hasPreviewForPage:(NSUInteger)page;
// Is there anything at all to draw for this page? Non-mutating: unlike
// -placeholderImageForPage: it does not bump the LRU stamp, so it is safe to
// call from policy code that is not actually about to draw.
- (BOOL)hasAnyImageForPage:(NSUInteger)page;

// Store a bitmap along with what it cost to produce.
//
// Two cached bitmaps of the same size are not interchangeable, and until the
// cost arrived here the eviction policy could not tell them apart. Measured:
// rebuilding a page of `heavy.pdf` costs 657 ms and a page of `text.pdf` costs
// 11.2 ms, and both occupy 27.1 MB. An LRU clock is as likely to discard the
// 657 ms page as the 11 ms one -- a 59:1 difference in the value of what is
// thrown away, invisible to the policy throwing it.
//
// Keeping the expensive one is better on every axis at once: identical bytes,
// less CPU, less energy, no change to any budget. It is the only change in
// ENGINEERING.md §4.4 that costs nothing to make.
//
// `renderSeconds` of 0 means "not measured", and is not the same as "free".
// With every entry unmeasured the ordering degrades exactly to the stamp-based
// LRU this replaced, which is what lets the old two-argument form below stay
// truthful rather than quietly meaning "evict me first".
- (void)setFullImage:(CGImageRef)img pixelSize:(CGSize)px forPage:(NSUInteger)page
       renderSeconds:(double)renderSeconds;
- (void)setPreviewImage:(CGImageRef)img pixelSize:(CGSize)px forPage:(NSUInteger)page
          renderSeconds:(double)renderSeconds;

// The same, with no cost measurement. Equivalent to passing 0 above.
- (void)setFullImage:(CGImageRef)img pixelSize:(CGSize)px forPage:(NSUInteger)page;
- (void)setPreviewImage:(CGImageRef)img pixelSize:(CGSize)px forPage:(NSUInteger)page;

- (void)dropFullImages;   // first response to memory pressure
- (void)removeAll;

// Instrumentation for the soak and UI tests: all three must stay bounded
// forever. -fullImageCount is the one that distinguishes "the pages on screen
// are sharp" from "the pages on screen and the prefetched ones are sharp",
// which is the difference memory-pressure handling turns on.
- (size_t)byteCount;
- (NSUInteger)entryCount;
- (NSUInteger)fullImageCount;
@end
