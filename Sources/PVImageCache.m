#import "PVImageCache.h"
#include <limits.h>

@interface PVCacheEntry : NSObject {
@public
    CGImageRef full;  CGSize fullPx;  size_t fullBytes;
    CGImageRef prev;  CGSize prevPx;  size_t prevBytes;
    unsigned long long stamp;
    // GreedyDual values, one per bitmap rather than one per entry: an entry's
    // full bitmap and its preview are evicted in separate passes and are worth
    // very different amounts per byte, so a single number for both would be an
    // average of two things that are never compared with each other.
    //
    // Zero means "no measurement", which sorts equal to every other unmeasured
    // bitmap and leaves the stamp to break the tie -- so a cache that is never
    // told a cost behaves exactly as the LRU this replaced.
    double     fullH;
    double     prevH;
}
@end

@implementation PVCacheEntry
- (void)dealloc
{
    if (full) CGImageRelease(full);
    if (prev) CGImageRelease(prev);
    [super dealloc];
}
@end

@implementation PVImageCache

- (id)initWithBudget:(size_t)budget
{
    self = [super init];
    if (self) {
        PVLiveAdjust("PVImageCache", +1);
        _entries = [[NSMutableDictionary alloc] init];
        _budget  = budget;
        if (!_entries) { [self release]; return nil; }
    }
    return self;
}

- (void)dealloc
{
    PVLiveAdjust("PVImageCache", -1);
    // Releasing the entries frees every bitmap they hold, so the resident
    // census has to be told before that happens or a cache that is simply
    // thrown away leaves its bytes counted forever -- which across the soak's
    // document cycles would climb without bound and read as a leak in the one
    // number that exists to prove there isn't one.
    [self subtractBytes:_bytes];
    [_entries release];
    [super dealloc];
}

- (void)setPinnedPages:(NSRange)range { _pinned = range; }

// Is this page on screen right now? Eviction steps over the ones that are.
- (BOOL)isPinned:(NSUInteger)page
{
    return (_pinned.length > 0 && NSLocationInRange(page, _pinned));
}

// Every subtraction goes through here. _bytes is unsigned, and a single
// unbalanced subtraction would wrap it to ~2^64 and disable eviction for the
// rest of the process's life -- exactly the sort of slow-motion failure that
// only shows up after days of uptime.
//
// Both directions also mirror into the process-wide resident census, which is
// the reason additions were routed through a method of their own rather than
// left as `_bytes += n` at three call sites. The mirror has to see exactly what
// _bytes sees: a cache whose own accounting is right while the census drifts is
// worse than no census, because the drift is invisible and the number is still
// believed.
- (void)subtractBytes:(size_t)n
{
    size_t take = (n >= _bytes) ? _bytes : n;
    _bytes -= take;
    PVResidentSub(PVResidentCache, take);
}

- (void)addBytes:(size_t)n
{
    // The caller has already been past -canAddBytes:afterRemoving:, so this
    // cannot overflow; saturating anyway costs one comparison and means the
    // guarantee does not depend on a check in another method staying correct.
    if (n > SIZE_MAX - _bytes) n = SIZE_MAX - _bytes;
    _bytes += n;
    PVResidentAdd(PVResidentCache, n);
}

// `PVImageBytes` is derived from CoreGraphics rather than trusted input, but
// this is the last accounting boundary before an unsigned counter.  Refusing
// an image whose byte count cannot be represented keeps a corrupt or future
// CoreGraphics image from wrapping `_bytes` and disabling eviction forever.
- (BOOL)canAddBytes:(size_t)n afterRemoving:(size_t)oldBytes
{
    size_t base = (oldBytes >= _bytes) ? 0 : (_bytes - oldBytes);
    return (n != SIZE_MAX && n <= SIZE_MAX - base);
}

// A timestamp overflow is fantastically far away in normal use, but it is
// cheap to make the ordering total even then.  Resetting every stamp before
// the increment means the next access is always the newest entry rather than
// silently becoming the oldest one after wrapping to zero.
- (void)resetClockIfNeeded
{
    if (_clock != ULLONG_MAX) return;
    NSEnumerator *it = [_entries objectEnumerator];
    PVCacheEntry *entry;
    while ((entry = [it nextObject])) entry->stamp = 0;
    _clock = 0;
}

- (PVCacheEntry *)entryForPage:(NSUInteger)page create:(BOOL)create
{
    [self resetClockIfNeeded];
    NSNumber *key = [NSNumber numberWithUnsignedLongLong:(unsigned long long)page];
    PVCacheEntry *e = [_entries objectForKey:key];
    if (!e && create) {
        e = [[[PVCacheEntry alloc] init] autorelease];
        [_entries setObject:e forKey:key];
    }
    if (e) e->stamp = ++_clock;
    return e;
}

- (CGImageRef)fullImageForPage:(NSUInteger)page pixelSize:(CGSize)px
{
    PVCacheEntry *e = [self entryForPage:page create:NO];
    if (!e || !e->full) return NULL;
    // Sizes are derived from rounded point sizes, so an exact match is expected.
    if (fabs(e->fullPx.width - px.width) > 0.5 || fabs(e->fullPx.height - px.height) > 0.5)
        return NULL;
    return e->full;
}

- (BOOL)hasFullImageForPage:(NSUInteger)page pixelSize:(CGSize)px
{
    NSNumber *key = [NSNumber numberWithUnsignedLongLong:(unsigned long long)page];
    PVCacheEntry *e = [_entries objectForKey:key];   // no stamp bump: this is a query
    if (!e || !e->full) return NO;
    return (fabs(e->fullPx.width  - px.width)  <= 0.5 &&
            fabs(e->fullPx.height - px.height) <= 0.5);
}

- (CGImageRef)placeholderImageForPage:(NSUInteger)page
{
    PVCacheEntry *e = [self entryForPage:page create:NO];
    if (!e) return NULL;
    if (e->full) return e->full;      // wrong scale, but sharper than the preview
    return e->prev;
}

- (BOOL)hasPreviewForPage:(NSUInteger)page
{
    NSNumber *key = [NSNumber numberWithUnsignedLongLong:(unsigned long long)page];
    PVCacheEntry *e = [_entries objectForKey:key];   // no stamp bump: this is a query
    return (e && e->prev);
}

- (BOOL)hasAnyImageForPage:(NSUInteger)page
{
    NSNumber *key = [NSNumber numberWithUnsignedLongLong:(unsigned long long)page];
    PVCacheEntry *e = [_entries objectForKey:key];
    return (e && (e->full || e->prev));
}

// Retain before releasing the outgoing image, not after. Storing an image over
// itself -- the same page delivered twice at the same size -- would otherwise
// drop the last reference we hold before taking the new one, and stay upright
// only because the caller happens to be holding one of its own for the length
// of the call. That is an invariant living in another file.
// The GreedyDual value for a bitmap that cost `seconds` and occupies `bytes`.
//
//   H = L + cost/size
//
// the classic GreedyDual-Size form. `cost/size` is the utility being protected:
// seconds of CPU saved per byte held, so a page that is expensive to rebuild
// earns residency and a page that is cheap does not, at equal bytes. `L` is the
// running inflation value, which is what keeps it from becoming a permanent
// ranking -- see -evictExcept:.
//
// An unmeasured bitmap gets exactly L, which is the same value every other
// unmeasured bitmap has, so ordering falls through to the stamp and the policy
// is the old LRU. That is deliberate: it is what makes the cost information an
// improvement to the ordering rather than a precondition for it.
- (double)gdsValueForSeconds:(double)seconds bytes:(size_t)bytes
{
    if (!isfinite(seconds) || seconds <= 0 || bytes == 0) return _gdsL;
    double utility = seconds / (double)bytes;
    if (!isfinite(utility)) return _gdsL;
    return _gdsL + utility;
}

- (void)setFullImage:(CGImageRef)img pixelSize:(CGSize)px forPage:(NSUInteger)page
       renderSeconds:(double)renderSeconds
{
    if (!img) return;
    PVCacheEntry *e = [self entryForPage:page create:YES];
    if (!e) return;
    CGImageRef incoming = CGImageRetain(img);
    size_t incomingBytes = PVImageBytes(incoming);
    if (![self canAddBytes:incomingBytes afterRemoving:e->fullBytes]) {
        CGImageRelease(incoming);
        return;
    }
    if (e->full) { [self subtractBytes:e->fullBytes]; CGImageRelease(e->full); }
    e->full      = incoming;
    e->fullPx    = px;
    e->fullBytes = PVImageBytes(incoming);
    e->fullH     = [self gdsValueForSeconds:renderSeconds bytes:e->fullBytes];
    [self addBytes:e->fullBytes];
    [self evictExcept:page];
}

- (void)setPreviewImage:(CGImageRef)img pixelSize:(CGSize)px forPage:(NSUInteger)page
          renderSeconds:(double)renderSeconds
{
    if (!img) return;
    PVCacheEntry *e = [self entryForPage:page create:YES];
    if (!e) return;
    CGImageRef incoming = CGImageRetain(img);
    size_t incomingBytes = PVImageBytes(incoming);
    if (![self canAddBytes:incomingBytes afterRemoving:e->prevBytes]) {
        CGImageRelease(incoming);
        return;
    }
    if (e->prev) { [self subtractBytes:e->prevBytes]; CGImageRelease(e->prev); }
    e->prev      = incoming;
    e->prevPx    = px;
    e->prevBytes = PVImageBytes(incoming);
    e->prevH     = [self gdsValueForSeconds:renderSeconds bytes:e->prevBytes];
    [self addBytes:e->prevBytes];
    [self evictExcept:page];
}

- (void)setFullImage:(CGImageRef)img pixelSize:(CGSize)px forPage:(NSUInteger)page
{
    [self setFullImage:img pixelSize:px forPage:page renderSeconds:0];
}

- (void)setPreviewImage:(CGImageRef)img pixelSize:(CGSize)px forPage:(NSUInteger)page
{
    [self setPreviewImage:img pixelSize:px forPage:page renderSeconds:0];
}

// Drop the least recently touched full bitmaps first, then previews.
//
// Recency alone is not enough to protect the pages on screen, which is what
// this used to rely on. Two visible pages are stamped within microseconds of
// each other, so which of them is "least recent" is decided by nothing more
// than which was drawn first -- and when the two do not both fit, that is
// enough to evict one of them. -setPinnedPages: states the visible set
// outright instead of inferring it from timestamps.
//
// One sorted snapshot of the keys per call rather than a linear scan per
// eviction: the old form was O(n^2) in the number of cached pages and ran on
// the main thread on the way out of every render.
- (void)evictExcept:(NSUInteger)keepPage
{
    // Two independent ceilings, either of which can call for an eviction.
    //
    // Bytes is the binding one at the sizes this actually sees: a full page in
    // a 1200x706 window is ~28 MB, so the budget is spent after three of them
    // and the count below is never reached. The count matters at the other end
    // of the range -- a small page at a small zoom may be a megabyte or two,
    // where several dozen full bitmaps fit inside the same byte budget and the
    // cache would hold every page of a short document live at once.
    NSUInteger fulls = [self fullImageCount];
    if (_bytes <= _budget && fulls <= PV_MAX_FULL_IMAGES) return;

    NSNumber *keep = [NSNumber numberWithUnsignedLongLong:(unsigned long long)keepPage];
    NSMutableDictionary *entries = _entries;

    NSMutableArray *emptied = [NSMutableArray array];
    int pass;
    // Pass 0 drops full bitmaps and answers to both ceilings; pass 1 drops
    // previews and answers only to bytes. Previews are ~9x smaller and are what
    // makes scrolling back instant, so they are never evicted to satisfy a
    // limit that is about full bitmaps.
    for (pass = 0; pass < 2; pass++) {
        BOOL more = (pass == 0) ? (_bytes > _budget || fulls > PV_MAX_FULL_IMAGES)
                                : (_bytes > _budget);
        if (!more) continue;

        // Ordered per pass, because the two passes are ranking different
        // bitmaps: an entry's full bitmap and its preview have their own
        // GreedyDual values and there is no ordering that is correct for both.
        // Cheapest-to-rebuild first, oldest first among equals -- so with no
        // cost information anywhere this is exactly the stamp ordering it
        // replaced, and every test written against that ordering still describes
        // the code.
        BOOL fullPass = (pass == 0);
        NSArray *order = [[_entries allKeys] sortedArrayUsingComparator:^(id a, id b) {
            PVCacheEntry *ea = (PVCacheEntry *)[entries objectForKey:a];
            PVCacheEntry *eb = (PVCacheEntry *)[entries objectForKey:b];
            double ha = fullPass ? ea->fullH : ea->prevH;
            double hb = fullPass ? eb->fullH : eb->prevH;
            if (ha < hb) return (NSComparisonResult)NSOrderedAscending;
            if (ha > hb) return (NSComparisonResult)NSOrderedDescending;
            unsigned long long sa = ea->stamp, sb = eb->stamp;
            if (sa < sb) return (NSComparisonResult)NSOrderedAscending;
            if (sa > sb) return (NSComparisonResult)NSOrderedDescending;
            return (NSComparisonResult)NSOrderedSame;
        }];

        NSUInteger i, n = [order count];
        for (i = 0; i < n; i++) {
            more = (pass == 0) ? (_bytes > _budget || fulls > PV_MAX_FULL_IMAGES)
                               : (_bytes > _budget);
            if (!more) break;
            NSNumber *k = [order objectAtIndex:i];
            if ([k isEqualToNumber:keep]) continue;
            // A page on screen is one the layer above will immediately ask for
            // again, so evicting it does not free anything -- it just buys one
            // more render of the same page. Both loops can therefore finish
            // with _bytes still over budget; that is intended, and is bounded
            // by the visible set. See -setPinnedPages:.
            if ([self isPinned:[k unsignedLongLongValue]]) continue;
            PVCacheEntry *e = [_entries objectForKey:k];
            if (!e) continue;
            if (pass == 0) {
                if (!e->full) continue;
                // The inflation step, and the whole of what keeps this from
                // being a permanent ranking. L rises to the value of whatever
                // was just discarded, so every subsequent insertion starts from
                // a higher floor and a once-expensive page that nobody returns
                // to is eventually the cheapest thing resident. Without it a
                // 657 ms page would outlive the document.
                //
                // Guarded against moving backwards. The order is by ascending H
                // so this is already monotonic by construction, but the array
                // is rebuilt per pass while _bytes changes underneath it, and a
                // policy whose aging term could go down would age nothing.
                if (e->fullH > _gdsL) _gdsL = e->fullH;
                [self subtractBytes:e->fullBytes];
                CGImageRelease(e->full); e->full = NULL; e->fullBytes = 0;
                e->fullH = 0;
                if (fulls > 0) fulls--;
            } else {
                if (!e->prev) continue;
                if (e->prevH > _gdsL) _gdsL = e->prevH;
                [self subtractBytes:e->prevBytes];
                CGImageRelease(e->prev); e->prev = NULL; e->prevBytes = 0;
                e->prevH = 0;
            }
            if (!e->full && !e->prev) [emptied addObject:k];
        }
    }
    // Removal is deferred out of the walk: mutating _entries while a snapshot
    // of its keys is being consumed is safe, but removing inside the loop makes
    // the intent easy to break later.
    NSUInteger j, m = [emptied count];
    for (j = 0; j < m; j++) [_entries removeObjectForKey:[emptied objectAtIndex:j]];
}

- (void)dropFullImages
{
    NSEnumerator *it = [_entries objectEnumerator];
    PVCacheEntry *e;
    NSMutableArray *emptied = [NSMutableArray array];
    while ((e = [it nextObject])) {
        if (e->full) {
            [self subtractBytes:e->fullBytes];
            CGImageRelease(e->full); e->full = NULL; e->fullBytes = 0;
            // Not folded into _gdsL. This is memory pressure discarding every
            // full bitmap at once, not the policy choosing between them, and
            // inflating the aging term by the most expensive page in the cache
            // would penalise everything rendered after a pressure event for
            // reasons that have nothing to do with what it cost.
            e->fullH = 0;
        }
    }
    // Entries that now hold nothing are dead weight; drop them so the
    // dictionary cannot grow without bound across a long session.
    it = [_entries keyEnumerator];
    NSNumber *k;
    while ((k = [it nextObject])) {
        PVCacheEntry *ent = [_entries objectForKey:k];
        if (!ent->full && !ent->prev) [emptied addObject:k];
    }
    NSUInteger j, m = [emptied count];
    for (j = 0; j < m; j++) [_entries removeObjectForKey:[emptied objectAtIndex:j]];
}

- (void)removeAll
{
    [_entries removeAllObjects];
    [self subtractBytes:_bytes];      // leaves _bytes at 0 and squares the census
    // The aging term goes with them. It is denominated in the utilities of the
    // bitmaps that were resident, and a cache emptied for a new document would
    // otherwise start with a floor set by the old one -- so the first several
    // pages of the new document would be inserted below it and evicted first,
    // for no reason connected to what they cost.
    _gdsL = 0;
}

- (size_t)byteCount { return _bytes; }
- (NSUInteger)entryCount { return [_entries count]; }

- (NSUInteger)fullImageCount
{
    NSUInteger n = 0;
    NSEnumerator *it = [_entries objectEnumerator];
    PVCacheEntry *e;
    while ((e = [it nextObject])) if (e->full) n++;
    return n;
}

@end
