#import "PVRenderQueue.h"
#import <dlfcn.h>

// dispatch_block_create_with_qos_class is 10.10+. Resolving it dynamically
// keeps -Werror=unguarded-availability satisfied and lets a 10.9 machine fall
// back to plain background dispatch, which is exactly the old behaviour.
typedef dispatch_block_t (*PVBlockCreateQoS)(uintptr_t flags, unsigned int qos,
                                             int relative_priority, dispatch_block_t block);
static PVBlockCreateQoS PVBlockCreateWithQoS(void)
{
    static PVBlockCreateQoS fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (PVBlockCreateQoS)dlsym(RTLD_DEFAULT, "dispatch_block_create_with_qos_class");
    });
    return fn;
}

// Two requests describe the same bitmap. Sizes are derived from point sizes
// rounded to whole points, so an exact match is the expected case and the
// half-pixel tolerance only absorbs the float round trip.
static BOOL PVSameBitmap(PVRenderRequest *a, PVRenderRequest *b)
{
    return (a->page == b->page && a->preview == b->preview &&
            fabs(a->px.width  - b->px.width)  < 0.5 &&
            fabs(a->px.height - b->px.height) < 0.5);
}

@implementation PVRenderQueue

- (id)initWithSource:(PVPDFSource *)source label:(const char *)label
{
    self = [super init];
    if (!self) return nil;
    // Counted before the first failure exit, not after: -dealloc decrements
    // unconditionally, so an increment that happens later than the earliest
    // possible -release drives the census negative and quietly poisons the
    // one measurement the soak test actually trusts.
    PVLiveAdjust("PVRenderQueue", +1);
    if (!source) { [self release]; return nil; }
    _source   = [source retain];
    _lock     = [[NSLock alloc] init];
    _pending  = [[NSMutableArray alloc] init];
    _inFlight = [[NSMutableArray alloc] init];
    _queue    = dispatch_queue_create(label ? label : "com.postview.render", DISPATCH_QUEUE_SERIAL);
    if (!_lock || !_pending || !_inFlight || !_queue) { [self release]; return nil; }
    // Background priority: measured at ~1/8th the energy per page of default
    // priority on Apple silicon, because the work lands on efficiency cores.
    // The wall-time cost is bought back selectively by the express lane.
    dispatch_set_target_queue(_queue,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
    return self;
}

- (void)dealloc
{
    PVLiveAdjust("PVRenderQueue", -1);
    // Reaching -dealloc already proves no worker or delivery block is
    // outstanding: every one of them captures self and therefore holds a
    // reference for its whole life. -shutdown here is belt and braces for the
    // object that is released without ever having been shut down, so that its
    // pending set is dropped and its delegate cleared on the way out.
    [self shutdown];
    if (_queue) dispatch_release(_queue);
    [_inFlight release];
    [_pending release];
    [_lock release];
    [_source release];
    [super dealloc];
}

- (void)setDelegate:(id <PVRenderQueueDelegate>)delegate
{
    [_lock lock];
    _delegate = delegate;
    [_lock unlock];
}

- (BOOL)isIdle
{
    [_lock lock];
    BOOL idle = (!_running && [_inFlight count] == 0 && [_pending count] == 0);
    [_lock unlock];
    return idle;
}

- (NSUInteger)inFlightCount
{
    [_lock lock];
    NSUInteger n = [_inFlight count];
    [_lock unlock];
    return n;
}


// Called with _lock held.
- (BOOL)isInFlightLocked:(PVRenderRequest *)r
{
    NSUInteger i, n = [_inFlight count];
    for (i = 0; i < n; i++)
        if (PVSameBitmap((PVRenderRequest *)[_inFlight objectAtIndex:i], r)) return YES;
    return NO;
}

// Called with _lock held. Identity, not equality: the object removed is always
// the very object the worker added, so exactly one removal can ever match.
- (void)removeInFlightLocked:(PVRenderRequest *)r
{
    NSUInteger idx = [_inFlight indexOfObjectIdenticalTo:r];
    if (idx != NSNotFound) [_inFlight removeObjectAtIndex:idx];
}

- (void)setDesiredRequests:(NSArray *)requests
{
    [_lock lock];
    if (!_shutdown) {
        [_pending removeAllObjects];
        NSUInteger i, n = [requests count];
        for (i = 0; i < n; i++) {
            PVRenderRequest *r = [requests objectAtIndex:i];
            if (![r isKindOfClass:[PVRenderRequest class]]) continue;
            // Skip anything already being rasterised or already rasterised and
            // waiting to be delivered. Both are work whose result is on its way.
            if ([self isInFlightLocked:r]) continue;
            [_pending addObject:r];
        }
        // No express work left: whatever hand-back was owed has been settled,
        // and the next page the user waits on starts from a clean slate.
        if (![self pendingWantsExpressLocked]) _expressYielded = NO;
    }
    [_lock unlock];
    [self pump];
}

- (void)setSuspended:(BOOL)suspended
{
    [_lock lock];
    _suspended = suspended;
    [_lock unlock];
    if (!suspended) [self pump];
}

// Does the pending set contain anything the user is actively waiting on?
// Called with _lock held.
- (BOOL)pendingWantsExpressLocked
{
    NSUInteger i, n = [_pending count];
    for (i = 0; i < n; i++)
        if (((PVRenderRequest *)[_pending objectAtIndex:i])->express) return YES;
    return NO;
}

- (void)pump
{
    [_lock lock];
    if (_running || _suspended || _shutdown || [_pending count] == 0) {
        [_lock unlock];
        return;
    }
    _running = YES;
    BOOL wantExpress = [self pendingWantsExpressLocked];
    [_lock unlock];

    // The block references ivars, so it retains self: the queue object always
    // outlives the work it started, even if the owner releases it meanwhile.
    PVBlockCreateQoS mk = wantExpress ? PVBlockCreateWithQoS() : NULL;
    if (mk) {
        // The QoS promotion applies to the whole block, not to individual
        // requests, so the promoted block must render ONLY the express
        // requests and then hand back. Draining everything here would silently
        // run prefetch at ~8x the energy too, which is the opposite of the
        // point: the promotion is a bounded payment for the pages the user is
        // staring at, not a general speed-up.
        dispatch_block_t promoted = mk(PV_BLOCK_ENFORCE_QOS_CLASS, PV_QOS_CLASS_UTILITY, 0,
                                       ^{ [self drainExpressOnly:YES]; });
        if (promoted) {
            dispatch_async(_queue, promoted);
            Block_release(promoted);
            return;
        }
        // The promotion could not be created. Falling through is not merely a
        // missed optimisation: _running is already YES, so failing to dispatch
        // anything here would wedge the queue permanently.
    }
    dispatch_async(_queue, ^{ [self drainExpressOnly:NO]; });
}

// The worker loop. Runs on _queue only. When expressOnly is YES it consumes
// only the promoted requests and then returns, re-pumping so the remainder is
// picked up by a fresh block at ordinary background QoS.
- (void)drainExpressOnly:(BOOL)expressOnly
{
    if (expressOnly) {
        // The hand-back this block was dispatched for has happened.
        [_lock lock];
        _expressYielded = NO;
        [_lock unlock];
    }
    for (;;) {
        // One pool per page. Without this, a long uninterrupted run of renders
        // accumulates every autoreleased temporary for the life of the block,
        // which over a multi-day session is unbounded growth.
        @autoreleasepool {
            PVRenderRequest *req = nil;

            [_lock lock];
            if (_suspended || _shutdown || [_pending count] == 0) {
                // The read of the three stop conditions and the write that
                // gives up the running slot happen under one acquisition. Split
                // them and a -setSuspended:NO or -setDesiredRequests: landing
                // in between would see _running still YES, decline to dispatch,
                // and leave the queue asleep with work outstanding.
                _running = NO;
                [_lock unlock];
                return;
            }
            // An express request that arrived while this ordinary block was
            // mid-page has to be handed back, or it is rendered right here at
            // background QoS and the promotion is silently lost. -pump only
            // promotes when it is the one starting the work, and it declines
            // to start anything while a worker holds the running slot -- so
            // the worker gives the slot up and lets -pump have it.
            //
            // Without this the express lane was a coin toss: a page jump made
            // a second after a scroll stopped, while prefetch was still
            // working, took the ~1.4 s path instead of the ~0.37 s one, from
            // the same user action, with nothing visible to say why.
            //
            // Bounded to one hand-back per express episode by _expressYielded,
            // so a promotion that cannot be created (10.9 has no such call at
            // all, and the allocation can fail anywhere) costs one extra
            // dispatch and then renders at background QoS, rather than
            // bouncing between here and -pump.
            if (!expressOnly && !_expressYielded && PVBlockCreateWithQoS() &&
                [self pendingWantsExpressLocked]) {
                _expressYielded = YES;
                _running = NO;
                [_lock unlock];
                [self pump];
                return;
            }

            // Pick the most important outstanding request each time round, so a
            // set swapped in mid-render takes effect on the very next page.
            // Ties keep insertion order, which is what makes a page's preview
            // land immediately before its own full-resolution render.
            NSUInteger bestIdx = NSNotFound;
            int bestPri = INT_MAX;
            NSUInteger i, n = [_pending count];
            for (i = 0; i < n; i++) {
                PVRenderRequest *r = [_pending objectAtIndex:i];
                if (expressOnly && !r->express) continue;
                if (r->priority < bestPri) { bestPri = r->priority; bestIdx = i; }
            }
            if (bestIdx == NSNotFound) {
                // Express work is done; the rest belongs on the cheap lane.
                _running = NO;
                [_lock unlock];
                [self pump];
                return;
            }
            req = [[_pending objectAtIndex:bestIdx] retain];
            [_pending removeObjectAtIndex:bestIdx];
            [_inFlight addObject:req];
            [_lock unlock];

            CGImageRef img = NULL;
            @try {
                img = [_source createImageForPage:req->page pixelSize:req->px];
            } @catch (id ex) {
                img = NULL;      // a bad page must not wedge the queue forever
            }

            // Counted here rather than at delivery: this is where the pixels
            // were actually produced, and a bitmap that is rasterised and then
            // dropped because the queue shut down still cost the battery
            // exactly as much as one that arrived.
            if (PVStatsEnabled()) {
                if (!img) {
                    PVStatAdd(PVStatRendersFailed, 1);
                } else {
                    double mp = ((double)req->px.width * (double)req->px.height) / 1.0e6;
                    PVStatAdd(req->preview ? PVStatRendersPreview : PVStatRendersFull, 1);
                    PVStatAdd(req->preview ? PVStatPixelsPreview  : PVStatPixelsFull, mp);
                }
            }

            [_lock lock];
            BOOL dead = _shutdown;
            // Nothing will be delivered for a shut-down queue, so the in-flight
            // marker has to come off here instead. Every other path takes it
            // off in the delivery block, and exactly one of the two runs.
            if (dead) [self removeInFlightLocked:req];
            [_lock unlock];

            if (dead) {
                if (img) CGImageRelease(img);
            } else {
                // req is captured, so the block retains it: the descriptor
                // outlives this loop iteration and identifies the exact entry
                // to retire once the result has actually been handed over.
                dispatch_async(dispatch_get_main_queue(), ^{
                    [_lock lock];
                    id <PVRenderQueueDelegate> d = _shutdown ? nil : _delegate;
                    [self removeInFlightLocked:req];
                    [_lock unlock];
                    if (d) {
                        if (img) {
                            [d renderQueue:self didRenderPage:req->page image:img
                                 pixelSize:req->px preview:req->preview];
                        } else if ([d respondsToSelector:
                                       @selector(renderQueue:didFailPage:pixelSize:preview:)]) {
                            [d renderQueue:self didFailPage:req->page
                                 pixelSize:req->px preview:req->preview];
                        }
                    }
                    if (img) CGImageRelease(img);
                });
            }
            [req release];
        }
    }
}

- (void)shutdown
{
    [_lock lock];
    if (_shutdown) { [_lock unlock]; return; }
    _shutdown = YES;
    [_pending removeAllObjects];
    // _inFlight is deliberately left alone: each entry is owned by a worker
    // iteration or a delivery block that is still going to run, and each of
    // those retires its own entry. Clearing here would let the same page be
    // enqueued again by a request set that arrives before those blocks finish.
    //
    // Cleared under the lock: any delivery already queued for the main thread
    // reads nil here rather than a delegate that may be mid-dealloc.
    _delegate = nil;
    [_lock unlock];

    // Deliberately NOT dispatch_sync: draining synchronously would block the
    // main thread for the remainder of an in-flight page (up to ~350 ms at
    // background QoS on a heavy page), which is a visible hang on window close.
    // The worker sees _shutdown on its next iteration and exits; the block
    // holds its own reference to self until then.
}

@end
