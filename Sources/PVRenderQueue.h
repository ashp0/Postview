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
    // Guarded by _lock. Read on the render queue and cleared under the lock by
    // -shutdown, so a delivery can never race a deallocating delegate.
    __unsafe_unretained id <PVRenderQueueDelegate> _delegate;
}
- (id)initWithSource:(PVPDFSource *)source label:(const char *)label;
- (void)setDelegate:(id <PVRenderQueueDelegate>)delegate;
- (void)setDesiredRequests:(NSArray *)requests;
- (void)setSuspended:(BOOL)suspended;
- (void)shutdown;                       // must be called before release
- (BOOL)isIdle;                         // for tests and soak instrumentation
- (NSUInteger)inFlightCount;            // ditto: must always return to zero

@end
