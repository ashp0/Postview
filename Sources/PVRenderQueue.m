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
    return [self initWithSource:source label:label maxLanes:PV_MAX_RENDER_LANES];
}

- (id)initWithSource:(PVPDFSource *)source label:(const char *)label
            maxLanes:(NSUInteger)maxLanes
{
    self = [super init];
    if (!self) return nil;
    // Counted before the first failure exit, not after: -dealloc decrements
    // unconditionally, so an increment that happens later than the earliest
    // possible -release drives the census negative and quietly poisons the
    // one measurement the soak test actually trusts.
    PVLiveAdjust("PVRenderQueue", +1);
    if (!source) { [self release]; return nil; }
    _lock     = [[NSLock alloc] init];
    _pending  = [[NSMutableArray alloc] init];
    _inFlight = [[NSMutableArray alloc] init];
    _cost     = [[PVCostModel alloc] init];

    const char *baseLabel = label ? label : "com.postview.render";
    _laneSource[0] = [source retain];
    _laneQueue[0]  = dispatch_queue_create(baseLabel, DISPATCH_QUEUE_SERIAL);
    _laneCount     = 1;
    if (!_lock || !_pending || !_inFlight || !_laneQueue[0] || !_cost) {
        [self release];
        return nil;
    }

    // A second lane, on mains power and a machine with cores to spare.
    //
    // One serial lane is the right answer on the battery-powered Haswell this
    // was tuned on: a second lane there is a second core awake for the same
    // work, which costs energy and buys latency nobody asked for. It is the
    // wrong answer on the 12-core Xeon this also has to run well on, where a
    // single lane leaves eleven cores idle while the reader waits.
    //
    // Deliberately two, not activeProcessorCount. The transient cost of a
    // render is a full-page bitmap -- ~28 MB -- and PV_MAX_INFLIGHT_FULL bounds
    // how many of those may exist undelivered. That bound is a property of the
    // QUEUE, not of a lane, so it is enforced once in -bestPendingIndexLocked:
    // and both lanes obey it; without that, two lanes would simply double the
    // ~56 MiB ceiling and the memory argument the cap encodes would be void.
    //
    // Each lane needs its own PVPDFSource: CGPDFDocumentRef is not thread safe,
    // and this is the one thing that must not be shared. The snapshot bytes
    // underneath are shared, so the two lanes cannot read different documents.
    //
    // Decided once, at construction. A machine unplugged mid-document keeps the
    // lane it opened with rather than reshaping the queue underneath a running
    // render; the next document opened gets the answer for the new state.
    NSUInteger cores = [[NSProcessInfo processInfo] activeProcessorCount];
    // Gated on the machine HAVING a battery, not merely on where it is drawing
    // power from right now. The two are different questions and only one of
    // them keeps its answer.
    //
    // Deciding once from the charger was the bug: a quad-core MacBook Pro
    // reports eight logical cores and AC while it is plugged in, so it opened
    // with two lanes -- and kept them after the charger came out, because the
    // decision is made at construction and a document stays open. That is two
    // cores awake for the same work on the exact hardware the power policy
    // exists to protect, for as long as the reader keeps reading, with nothing
    // anywhere reporting it.
    //
    // Reshaping the queue when the charger moves was the other option and it is
    // worse: a lane cannot be withdrawn mid-render without either abandoning a
    // rasterisation or blocking on it, and the correct number of lanes for a
    // portable is one in both power states anyway. So the premise moves to
    // something that cannot go stale. A portable gets one lane; the 2013 Mac
    // Pro -- no battery, twelve cores, the machine the second lane was measured
    // on -- gets two. Power source is still required, so a desktop on a UPS
    // reporting battery stays conservative.
    BOOL useTwoLanes = (maxLanes >= 2 && PV_MAX_RENDER_LANES >= 2 &&
                        PVCurrentPowerSource() == PVPowerAC && cores >= 6 &&
                        !PVMachineHasInternalBattery());
    if (useTwoLanes) {
        PVPDFSource *second = [source newLaneSource];        // +1
        if (second) {
            char secondLabel[128];
            snprintf(secondLabel, sizeof(secondLabel), "%s.2", baseLabel);
            dispatch_queue_t q = dispatch_queue_create(secondLabel,
                                                       DISPATCH_QUEUE_SERIAL);
            if (q) {
                _laneSource[1] = second;                     // ownership moves
                _laneQueue[1]  = q;
                _laneCount     = 2;
            } else {
                [second release];
            }
        }
        // A lane that could not be built is not an error: one lane is the
        // shipping configuration, and the document opens either way.
    }
    // Background priority. Correct on every machine this ships to, but for two
    // different reasons, and the difference matters to anyone tuning from here.
    //
    // On Apple silicon the work lands on efficiency cores and a page costs
    // measurably less energy -- about an eighth of the same render at default
    // priority. The 2013 Mac Pro this actually targets has no efficiency cores:
    // its Xeon E5 v2 cores are homogeneous, so the same core does the same work
    // at the same frequency and a render is not one joule cheaper for being
    // backgrounded. What it buys there is lower scheduling priority, timer
    // coalescing and throttled I/O -- the render thread stays out of the way of
    // the UI, which is worth having, but it is not a discount on the render.
    //
    // Said explicitly because the energy win measured on the target comes from
    // doing less work (the motion gate), not from cheaper cores, and a change
    // reasoning from "renders are 1/8 price here" would be reasoning from
    // something untrue of the machine that decides. See ENGINEERING.md §5.
    NSUInteger lane;
    for (lane = 0; lane < _laneCount; lane++)
        dispatch_set_target_queue(_laneQueue[lane],
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
    return self;
}

// Which lane renders this page. Arithmetic, so it is the same answer every
// time and from every thread.
- (NSUInteger)laneForPage:(NSUInteger)page
{
    return (_laneCount > 1) ? (page % _laneCount) : 0;
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
    NSUInteger lane;
    for (lane = 0; lane < PV_MAX_RENDER_LANES; lane++) {
        if (_laneQueue[lane]) dispatch_release(_laneQueue[lane]);
        [_laneSource[lane] release];
    }
    [_inFlight release];
    [_pending release];
    [_lock release];
    [_cost release];
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
    BOOL anyRunning = NO;
    NSUInteger lane;
    for (lane = 0; lane < _laneCount; lane++)
        if (_laneRunning[lane]) { anyRunning = YES; break; }
    BOOL idle = (!anyRunning && [_inFlight count] == 0 && [_pending count] == 0);
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

- (NSUInteger)undeliveredFullCount
{
    [_lock lock];
    NSUInteger n = _undeliveredFull;
    [_lock unlock];
    return n;
}

- (NSUInteger)fullCapacityInUse
{
    // Read in ONE acquisition. Two calls would let a hand-over between the
    // reservation and the undelivered count land in between, and the sum of two
    // consistent numbers taken at different instants is a number that was never
    // true -- which is a poor thing to assert an invariant on.
    [_lock lock];
    NSUInteger n = _fullInProgress + _undeliveredFull;
    [_lock unlock];
    return n;
}

// Set once in -initWithSource:label:maxLanes: and never written again, so no
// lock is needed and taking one here would be a claim about mutability that is
// not true.
- (NSUInteger)laneCount { return _laneCount; }

- (PVCostModel *)costModel { return _cost; }

- (double)predictedSecondsForPixels:(CGSize)px preview:(BOOL)preview
{
    // Clamped here, exactly as -createImageForPage:pixelSize: will clamp it.
    // Asking the model about the size that was requested rather than the size
    // that will be drawn overstates the cost of every render above the ceiling
    // -- which on the tiers where the ceiling actually bites is every render --
    // and the overstatement then suppresses them. The clamp is a pure function
    // precisely so both sides can apply it and agree.
    return [_cost predictedSecondsForPixels:PVClampPixelSize(px) preview:preview];
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
        // No express work left to run: whatever hand-back was owed has been
        // settled, and the next page the user waits on starts from a clean
        // slate. Safe to clear while an express full render sits blocked behind
        // the in-flight cap -- a hand-back cannot then happen until the cap
        // opens, and the promoted block clears the flag itself when it does.
        if (![self pendingHasRunnableExpressLocked]) {
            NSUInteger lane;
            for (lane = 0; lane < _laneCount; lane++)
                _laneExpressYielded[lane] = NO;
        }
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

// The most important pending request that could actually be started right now,
// or NSNotFound. Called with _lock held.
//
// One function rather than a loop in -pump and another in the worker, because
// the two have to agree exactly. If -pump thinks there is work and the worker
// does not, every event dispatches a block that does nothing; if the worker
// thinks there is work and -pump does not, the queue goes to sleep holding it.
// Both are silent, and both are permanent.
//
// `fullsBlocked` is PV_MAX_INFLIGHT_FULL, enforced here and nowhere else. A
// blocked full request is skipped, not consumed: it stays in _pending and is
// picked up by the drain the delivery block re-dispatches once the count drops.
// The worker is never made to wait for it -- _queue is serial and previews come
// through this same loop, so a blocking wait here would stall the one path that
// keeps scrolling responsive in order to bound the one that does not.
// `lane` is the lane asking. Ordinary work is sharded by page, so a lane only
// ever sees the pages that belong to it; express work is exempt, because the
// point of the express lane is the one page the user is waiting on and making
// it queue behind that lane's other work would be the opposite of the point.
//
// NSNotFound for `lane` means "any lane", which is what the queue-wide
// questions (-isIdle's callers, -pump's early-out) need to ask.
- (NSUInteger)bestPendingIndexLocked:(BOOL)expressOnly forLane:(NSUInteger)lane
{
    // Both halves of the cap. A full render that is still running has not
    // produced a bitmap yet, but it is going to, and it is going to count --
    // so the slot has to be spoken for from the moment the work starts rather
    // than from the moment the pixels exist. Counting only the second half is
    // a limit with no reservation behind it: see _fullInProgress.
    BOOL fullsBlocked =
        (_fullInProgress + _undeliveredFull >= PV_MAX_INFLIGHT_FULL);
    NSUInteger bestIdx = NSNotFound;
    int bestPri = 0;
    NSUInteger i, n = [_pending count];
    // Ties keep insertion order, which is what makes a page's preview land
    // immediately before its own full-resolution render.
    for (i = 0; i < n; i++) {
        PVRenderRequest *r = [_pending objectAtIndex:i];
        if (expressOnly && !r->express) continue;
        if (fullsBlocked && !r->preview) continue;
        if (lane != NSNotFound && !r->express &&
            [self laneForPage:r->page] != lane) continue;
        // "Nothing chosen yet" is asked directly rather than encoded as a
        // sentinel priority. It used to start at INT_MAX and compare `<`, which
        // silently made INT_MAX the one priority that could never be scheduled:
        // a request carrying it was skipped by every pass, forever, and the
        // queue simply held it.
        if (bestIdx == NSNotFound || r->priority < bestPri) {
            bestPri = r->priority;
            bestIdx = i;
        }
    }
    return bestIdx;
}

- (NSUInteger)bestPendingIndexLocked:(BOOL)expressOnly
{
    return [self bestPendingIndexLocked:expressOnly forLane:NSNotFound];
}

// Is there express work that could be started right now? Called with _lock held.
//
// "Could be started", not "exists": an express request for a full bitmap while
// the in-flight cap is closed is work that this pass cannot do. Answering YES
// for it would have -pump build a promoted block that finds nothing to render,
// hands back, and is built again -- a dispatch loop at raised QoS, which is the
// most expensive way this program could possibly spin.
//
// Gating the express lane on the cap costs nothing perceptible. The cap is only
// closed when two full bitmaps are already waiting on the main thread, which
// means the main thread is busy, which means a third bitmap could not have been
// drawn any sooner than the moment those two are taken off its queue.
- (BOOL)pendingHasRunnableExpressLocked
{
    return ([self bestPendingIndexLocked:YES] != NSNotFound);
}

// Start every lane that is idle and has work of its own.
//
// Each lane is examined and claimed under the one lock, so two -pump calls
// racing from different threads cannot both claim the same lane, and a lane
// already inside a drain is simply skipped.
- (void)pump
{
    NSUInteger lane;
    for (lane = 0; lane < PV_MAX_RENDER_LANES; lane++) {
        [_lock lock];
        // Nothing *runnable*, rather than nothing pending: with the in-flight
        // cap closed the pending set can be non-empty and still have nothing
        // this pass may start. Dispatching then would burn a block per event to
        // discover it.
        if (lane >= _laneCount || _laneRunning[lane] || _suspended || _shutdown ||
            [self bestPendingIndexLocked:NO forLane:lane] == NSNotFound) {
            [_lock unlock];
            continue;
        }
        _laneRunning[lane] = YES;
        // Express work is not sharded, so the first idle lane to reach here
        // takes it; the other lane then finds nothing express left and starts
        // its own ordinary work.
        BOOL wantExpress =
            ([self bestPendingIndexLocked:YES forLane:lane] != NSNotFound);
        [_lock unlock];

        // The block references ivars, so it retains self: the queue object
        // always outlives the work it started, even if the owner releases it
        // meanwhile.
        PVBlockCreateQoS mk = wantExpress ? PVBlockCreateWithQoS() : NULL;
        if (mk) {
            // The QoS promotion applies to the whole block, not to individual
            // requests, so the promoted block must render ONLY the express
            // requests and then hand back. Draining everything here would
            // silently run prefetch at ~8x the energy too, which is the
            // opposite of the point: the promotion is a bounded payment for the
            // pages the user is staring at, not a general speed-up.
            dispatch_block_t promoted =
                mk(PV_BLOCK_ENFORCE_QOS_CLASS, PV_QOS_CLASS_UTILITY, 0,
                   ^{ [self drainLane:lane expressOnly:YES]; });
            if (promoted) {
                dispatch_async(_laneQueue[lane], promoted);
                Block_release(promoted);
                continue;
            }
            // The promotion could not be created. Falling through is not merely
            // a missed optimisation: _laneRunning[lane] is already YES, so
            // failing to dispatch anything here would wedge this lane
            // permanently.
        }
        dispatch_async(_laneQueue[lane], ^{ [self drainLane:lane expressOnly:NO]; });
    }
}

// The worker loop. Runs on _queue only. When expressOnly is YES it consumes
// only the promoted requests and then returns, re-pumping so the remainder is
// picked up by a fresh block at ordinary background QoS.
- (void)drainLane:(NSUInteger)lane expressOnly:(BOOL)expressOnly
{
    if (lane >= PV_MAX_RENDER_LANES) return;
    if (expressOnly) {
        // The hand-back this block was dispatched for has happened.
        [_lock lock];
        _laneExpressYielded[lane] = NO;
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
                // in between would see this lane still running, decline to
                // dispatch, and leave it asleep with work outstanding.
                _laneRunning[lane] = NO;
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
            // Bounded to one hand-back per express episode by
            // _laneExpressYielded, so a promotion that cannot be created (10.9
            // has no such call at all, and the allocation can fail anywhere)
            // costs one extra dispatch and then renders at background QoS,
            // rather than bouncing between here and -pump.
            if (!expressOnly && !_laneExpressYielded[lane] && PVBlockCreateWithQoS() &&
                [self pendingHasRunnableExpressLocked]) {
                _laneExpressYielded[lane] = YES;
                _laneRunning[lane] = NO;
                [_lock unlock];
                [self pump];
                return;
            }

            // Pick the most important request that can be started right now, so
            // a set swapped in mid-render takes effect on the very next page.
            NSUInteger bestIdx = [self bestPendingIndexLocked:expressOnly
                                                      forLane:lane];
            if (bestIdx == NSNotFound) {
                _laneRunning[lane] = NO;
                [_lock unlock];
                // Two different reasons to be here, and only one of them is
                // worth another dispatch.
                //
                // Express work is done: the remainder belongs on the cheap lane,
                // so hand it straight over. -pump re-checks under the lock and
                // declines if there is genuinely nothing runnable, so this
                // cannot become a loop.
                //
                // Everything left is a full render held back by the in-flight
                // cap: pumping would find the same closed gate and dispatch
                // nothing. The delivery block that opens the gate is the thing
                // that restarts this, and it always runs -- a bitmap counted
                // against the cap has a main-queue block already dispatched for
                // it by construction.
                if (expressOnly) [self pump];
                return;
            }
            req = [[_pending objectAtIndex:bestIdx] retain];
            [_pending removeObjectAtIndex:bestIdx];
            [_inFlight addObject:req];
            // The slot is claimed here, under the same acquisition that took
            // the work. -bestPendingIndexLocked: has just decided there is room
            // for this bitmap; releasing the lock before recording that it is
            // taken would let the other lane make the same decision from the
            // same numbers.
            BOOL reservedFull = !req->preview;
            if (reservedFull) _fullInProgress++;
            [_lock unlock];

            CGImageRef img = NULL;
            // Bracketing only the rasterisation, and nothing on either side of
            // it. The lock acquisitions, the accounting and the dispatch below
            // are this file's overhead, not the document's cost, and folding
            // them into the rate would make the model's answer depend on how
            // contended the queue happened to be -- which is a property of the
            // scroll, which is what the model is being consulted about.
            double t0 = PVMonotonicSeconds();
            PVRenderFailure failure = PVRenderFailureNone;
            @try {
                // This lane's own source, never another lane's: a source owns
                // one helper process and one serial pipe to it, and the two
                // lanes run concurrently by construction.
                // The express flag reaches the helper, not just this queue.
                // Promoting the dispatch block promotes the thread that waits
                // on a pipe; the drawing happens in another process, and until
                // the flag travelled with the command that process stayed
                // backgrounded no matter what the reader was waiting for.
                img = [_laneSource[lane] createImageForPage:req->page
                                                  pixelSize:req->px
                                                interactive:req->express
                                                    failure:&failure];
            } @catch (id ex) {
                img = NULL;      // a bad page must not wedge the queue forever
                failure = PVRenderFailureProtocol;
            }
            // An exception, or a source that returned NULL without saying why,
            // must not arrive at the delegate as "no failure": that reads as
            // success everywhere the reason is consulted.
            if (!img && failure == PVRenderFailureNone)
                failure = PVRenderFailureProtocol;
            double renderSeconds = PVMonotonicSeconds() - t0;

            // Only successful renders are sampled. A NULL is CoreGraphics
            // declining, which takes an early return out of
            // -createImageForPage: and costs almost nothing -- recording it as
            // a fast render would tell the model this document is cheap on the
            // strength of work that was never done, and a page that fails
            // repeatedly would drag the rate down every time the wanted set
            // named it again.
            // The size that was actually rasterised, not the size that was
            // asked for. -createImageForPage: clamps its input to
            // PVMaxRenderPixels() and draws the clamped bitmap, so above the
            // ceiling the two differ -- and the cost model was already using
            // the clamped figure while the census below used the requested one.
            // The census then reported megapixels that were never drawn and a
            // ms/Mpx rate derived by dividing real seconds by imaginary pixels,
            // which understates the rate exactly when the pages are largest.
            CGSize actual = PVClampPixelSize(req->px);

            if (img) {
                [_cost recordSeconds:renderSeconds
                              pixels:actual
                             preview:req->preview];
            }

            // Counted here rather than at delivery: this is where the pixels
            // were actually produced, and a bitmap that is rasterised and then
            // dropped because the queue shut down still cost the battery
            // exactly as much as one that arrived.
            if (PVStatsEnabled()) {
                if (!img) {
                    PVStatAdd(PVStatRendersFailed, 1);
                } else {
                    double mp = ((double)actual.width * (double)actual.height) / 1.0e6;
                    PVStatAdd(req->preview ? PVStatRendersPreview : PVStatRendersFull, 1);
                    PVStatAdd(req->preview ? PVStatPixelsPreview  : PVStatPixelsFull, mp);
                }
            }

            // Read before the image can be handed anywhere else. Both the byte
            // claim below and its release have to use the same number, and
            // asking the image again after the delegate has had it would be
            // asking about an object this block no longer solely owns.
            size_t imgBytes = PVImageBytes(img);

            [_lock lock];
            // The reservation ends where the rasterisation ends, and the
            // hand-over to _undeliveredFull happens in the same acquisition.
            // Split across two, the total would dip below the real figure for
            // the instant in between and a third lane could squeeze through it.
            if (reservedFull && _fullInProgress > 0) _fullInProgress--;
            BOOL dead = _shutdown;
            // Nothing will be delivered for a shut-down queue, so the in-flight
            // marker has to come off here instead. Every other path takes it
            // off in the delivery block, and exactly one of the two runs.
            if (dead) [self removeInFlightLocked:req];
            // The in-flight cap counts bitmaps that are going to be delivered.
            // A failed render produced no pixels and a shut-down queue will
            // deliver nothing, so neither is counted -- and `counted` is carried
            // into the delivery block rather than recomputed there, so the
            // decrement cannot disagree with the increment about what happened.
            BOOL counted = (!dead && img != NULL && !req->preview);
            if (counted) _undeliveredFull++;
            // A slot was held and is not being handed on: the render failed, so
            // the gate has just opened without any delivery block being
            // dispatched to notice. Something has to re-pump, or a full request
            // this pass skipped for want of a slot waits for whatever the user
            // happens to do next.
            BOOL reopenedSlot = (reservedFull && !counted && !dead);
            [_lock unlock];

            if (dead) {
                if (img) CGImageRelease(img);
            } else {
                if (img) PVResidentAdd(PVResidentUndelivered, imgBytes);
                // req is captured, so the block retains it: the descriptor
                // outlives this loop iteration and identifies the exact entry
                // to retire once the result has actually been handed over.
                dispatch_async(dispatch_get_main_queue(), ^{
                    [_lock lock];
                    id <PVRenderQueueDelegate> d = _shutdown ? nil : _delegate;
                    [self removeInFlightLocked:req];
                    // Released here rather than after the delegate call, and
                    // unconditionally: this is the one place the count comes
                    // down, so it must run whether or not there is still a
                    // delegate to hand the bitmap to.
                    if (counted && _undeliveredFull > 0) _undeliveredFull--;
                    [_lock unlock];
                    // The byte claim is handed over at the same instant. Inside
                    // the delegate call the image either reaches a cache, whose
                    // own accounting takes it up, or is dropped; holding the
                    // claim across the call would count one bitmap twice for
                    // the duration of it, in the one figure that exists to be
                    // compared against RSS.
                    if (img) PVResidentSub(PVResidentUndelivered, imgBytes);
                    if (d) {
                        if (img) {
                            // Exactly one of the two delivery methods runs. The
                            // cost-carrying one is preferred where it exists so
                            // the cache can evict by what a page would cost to
                            // rebuild rather than by when it was last touched.
                            if ([d respondsToSelector:
                                    @selector(renderQueue:didRenderPage:image:pixelSize:preview:renderSeconds:)]) {
                                [d renderQueue:self didRenderPage:req->page image:img
                                     pixelSize:req->px preview:req->preview
                                 renderSeconds:renderSeconds];
                            } else {
                                [d renderQueue:self didRenderPage:req->page image:img
                                     pixelSize:req->px preview:req->preview];
                            }
                        } else if ([d respondsToSelector:
                                       @selector(renderQueue:didFailPage:pixelSize:preview:failure:)]) {
                            [d renderQueue:self didFailPage:req->page
                                 pixelSize:req->px preview:req->preview
                                   failure:failure];
                        } else if ([d respondsToSelector:
                                       @selector(renderQueue:didFailPage:pixelSize:preview:)]) {
                            [d renderQueue:self didFailPage:req->page
                                 pixelSize:req->px preview:req->preview];
                        }
                    }
                    if (img) CGImageRelease(img);
                    // The gate has just opened by one. Anything the worker
                    // skipped for want of a slot is still in _pending and needs
                    // a drain dispatched at it; without this the deferred full
                    // render would wait for whatever the user happened to do
                    // next. Only when this delivery was actually holding a slot,
                    // so previews do not each cost a spurious dispatch.
                    if (counted) [self pump];
                });
            }
            // The other half of that gate. A reservation released without a
            // bitmap dispatches no delivery block, so this is the only thing
            // that can tell the OTHER lane a slot came free -- this one is
            // about to look for itself on the next turn of the loop.
            if (reopenedSlot) [self pump];
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
