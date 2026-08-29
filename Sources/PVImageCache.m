#import "PVImageCache.h"
#include <limits.h>

@interface PVCacheEntry : NSObject {
@public
    CGImageRef full;  CGSize fullPx;  size_t fullBytes;
    CGImageRef prev;  CGSize prevPx;  size_t prevBytes;
    unsigned long long stamp;
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
- (void)subtractBytes:(size_t)n
{
    _bytes = (n >= _bytes) ? 0 : (_bytes - n);
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
- (void)setFullImage:(CGImageRef)img pixelSize:(CGSize)px forPage:(NSUInteger)page
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
    _bytes      += e->fullBytes;
    [self evictExcept:page];
}

- (void)setPreviewImage:(CGImageRef)img pixelSize:(CGSize)px forPage:(NSUInteger)page
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
    _bytes      += e->prevBytes;
    [self evictExcept:page];
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
    NSArray *order = [[_entries allKeys] sortedArrayUsingComparator:^(id a, id b) {
        unsigned long long sa = ((PVCacheEntry *)[entries objectForKey:a])->stamp;
        unsigned long long sb = ((PVCacheEntry *)[entries objectForKey:b])->stamp;
        if (sa < sb) return (NSComparisonResult)NSOrderedAscending;
        if (sa > sb) return (NSComparisonResult)NSOrderedDescending;
        return (NSComparisonResult)NSOrderedSame;
    }];

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
                [self subtractBytes:e->fullBytes];
                CGImageRelease(e->full); e->full = NULL; e->fullBytes = 0;
                if (fulls > 0) fulls--;
            } else {
                if (!e->prev) continue;
                [self subtractBytes:e->prevBytes];
                CGImageRelease(e->prev); e->prev = NULL; e->prevBytes = 0;
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

- (void)removeAll { [_entries removeAllObjects]; _bytes = 0; }

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
