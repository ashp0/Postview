//  PVRenderQueue.h — prioritised, cancellable, background-priority page renderer.
//
//  The main thread never rasterises a page. Instead the view layer computes the
//  complete set of bitmaps it currently wants and hands it over with
//  -setDesiredRequests:, which atomically REPLACES the pending set. Anything the
//  user has scrolled past simply stops being wanted and is never rendered, which
//  is both the cancellation mechanism and the main battery saving: we do not
//  burn CPU rasterising pages that flew by.
//
//  Everything runs on one serial queue targeting the BACKGROUND global queue.
//  That is a deliberate and measured choice, not an oversight: on this hardware
//  the same page render costs ~84 mJ there against ~684 mJ at default priority,
//  because background QoS is confined to the efficiency cores. It is ~3.8x
//  slower in wall time and ~8x cheaper in energy.
//
//  A request may set `express`, which raises the QoS for that work via
//  dispatch_block_create_with_qos_class (10.10+, resolved dynamically so 10.9
//  simply keeps the background behaviour). The promoted block renders only the
//  express requests and then hands back, so the raised QoS cannot leak into
//  prefetch. It is reserved for the one page the user is visibly waiting on
//  with nothing cached to show.

#import "PVCommon.h"
#import "PVPDFSource.h"
#import "PVCostModel.h"

// Values taken from <dispatch/block.h> and <sys/qos.h>. They are spelled out
// rather than referenced so this file still compiles against the 10.9 headers.
// Getting one wrong is silent -- the express lane just stops promoting -- so
// pvtest pins them against the real SDK enums.
#define PV_BLOCK_ENFORCE_QOS_CLASS  ((uintptr_t)0x20)     // DISPATCH_BLOCK_ENFORCE_QOS_CLASS
#define PV_QOS_CLASS_UTILITY        ((unsigned int)0x11)  // QOS_CLASS_UTILITY

@class PVRenderQueue;

@protocol PVRenderQueueDelegate <NSObject>
- (void)renderQueue:(PVRenderQueue *)queue
       didRenderPage:(NSUInteger)page
               image:(CGImageRef)image
           pixelSize:(CGSize)px
             preview:(BOOL)preview;
@optional
// The same delivery, carrying what the rasterisation actually cost.
//
// Preferred over the method above when the delegate implements it; exactly one
// of the two is called per bitmap. Added rather than folded into the required
// method because the seconds are useful to precisely one caller -- the cache,
// which evicts by cost -- and every other implementor of this protocol is a
// test collector that would have had to grow a parameter it ignores.
//
// `renderSeconds` is wall-clock time inside -createImageForPage:pixelSize:, so
// it includes the bitmap allocation and the white fill as well as
// CGContextDrawPDFPage. That is the right quantity for both consumers: it is
// what a re-render would cost, which is what the cache is deciding about, and
// it is what the page has to be on screen long enough to absorb.
- (void)renderQueue:(PVRenderQueue *)queue
       didRenderPage:(NSUInteger)page
               image:(CGImageRef)image
           pixelSize:(CGSize)px
             preview:(BOOL)preview
       renderSeconds:(double)renderSeconds;
// CoreGraphics declined to produce a bitmap: a page object the document could
// not hand back, or a bitmap context that could not be allocated. Reported so
// the layer above can stop asking. Without it a page that cannot be rasterised
// never lands in the cache, so the wanted-set names it again on the very next
// scroll event and the queue rasterises it, fails, and is asked again -- for
// the rest of the session. Delivered on the main thread like a success.
- (void)renderQueue:(PVRenderQueue *)queue
        didFailPage:(NSUInteger)page
          pixelSize:(CGSize)px
            preview:(BOOL)preview;
@end

@interface PVRenderQueue : NSObject {
    PVPDFSource      *_source;
    dispatch_queue_t  _queue;
    NSLock           *_lock;
    NSMutableArray   *_pending;
    // Work that has been taken off _pending and not yet accounted for by the
    // layer above. A request stays here from the moment the worker picks it up
    // until its result has been handed to the delegate on the main thread --
    // NOT merely until the rasterisation finishes. Those are different
    // instants, separated by one main-queue hop, and in between the cache does
    // not yet hold the bitmap: a wanted-set rebuilt in that window asked for a
    // page that was already rendered and sitting in the delivery queue, so a
    // heavy page could be rasterised two or three times over. Bounded by the
    // size of the pending set, because only the main thread adds to it.
    NSMutableArray   *_inFlight;
    BOOL              _running;
    BOOL              _suspended;
    BOOL              _shutdown;
    // Set when an ordinary worker has given up its slot so that pending
    // express work can be re-dispatched at raised QoS, and cleared when a
    // promoted block actually starts or when the express work goes away. It
    // exists to bound that hand-back to one per episode: if the promotion
    // cannot be created after all, the express work is simply rendered at
    // background QoS rather than handed back and forth forever.
    BOOL              _expressYielded;
    // Full-resolution bitmaps rasterised and not yet handed to the delegate.
    //
    // The quantity PV_MAX_INFLIGHT_FULL bounds. A bitmap counted here is ~28 MB
    // that the page cache's byte budget cannot see, because it is not in the
    // cache yet -- so a worker free to start the next full render before the
    // previous result has landed can stack up several of them behind a busy
    // main thread with nothing anywhere in the program able to say no.
    //
    // Incremented on the render queue the moment a full bitmap exists and is
    // going to be delivered; decremented on the main queue in the delivery
    // block. Exactly one of those two paths runs for any one bitmap: a queue
    // that has shut down never increments, because its result is released on
    // the spot instead of being dispatched.
    NSUInteger        _undeliveredFull;
    // Guarded by _lock. Read on the render queue and cleared under the lock by
    // -shutdown, so a delivery can never race a deallocating delegate.
    __unsafe_unretained id <PVRenderQueueDelegate> _delegate;
    // What this document's renders cost, measured. Owned here because the queue
    // is the only place that sees both ends of a rasterisation, and one per
    // queue because there is one queue per document and the whole point of the
    // model is that documents differ by up to 59x. The thumbnail queue keeps
    // its own for the same reason: a thumbnail is 1/100 the pixels of a page
    // and pays the same content-stream interpretation, so its rate is not the
    // page queue's rate and mixing them would be failure 2 in PVCostModel.h.
    PVCostModel      *_cost;
}
- (id)initWithSource:(PVPDFSource *)source label:(const char *)label;
- (void)setDelegate:(id <PVRenderQueueDelegate>)delegate;
- (void)setDesiredRequests:(NSArray *)requests;
- (void)setSuspended:(BOOL)suspended;
- (void)shutdown;                       // must be called before release
- (BOOL)isIdle;                         // for tests and soak instrumentation
- (NSUInteger)inFlightCount;            // ditto: must always return to zero
// Full bitmaps rasterised but not yet delivered. Never exceeds
// PV_MAX_INFLIGHT_FULL, and returns to zero like the two above.
- (NSUInteger)undeliveredFullCount;

// What this document's renders have been measured to cost. Never nil.
//
// Exposed rather than proxied because the scheduler asks it two different
// questions -- a prediction for a specific bitmap, and how many samples exist
// yet -- and wrapping each one here would put the model's interface in two
// files. Safe to call from any thread; see PVCostModel.h.
- (PVCostModel *)costModel;

// Predicted seconds for a bitmap of this size, or 0 when there is not yet
// enough evidence. A convenience over -costModel with one important addition:
// the size is clamped exactly as the renderer will clamp it, so a caller that
// asks about a bitmap larger than PVMaxRenderPixels() is told what the render
// it will actually get costs rather than what the one it asked for would have.
- (double)predictedSecondsForPixels:(CGSize)px preview:(BOOL)preview;

@end
