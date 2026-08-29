#import "PVStateStore.h"

#define PV_MAX_REMEMBERED 400

@implementation PVStateStore

+ (PVStateStore *)sharedStore
{
    static PVStateStore *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[PVStateStore alloc] init]; });
    return shared;
}

+ (NSString *)storePath
{
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES);
    if ([dirs count] == 0) return nil;
    NSString *dir = [[dirs objectAtIndex:0] stringByAppendingPathComponent:@"Postview"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:NULL];
    return [dir stringByAppendingPathComponent:@"DocumentState.plist"];
}

// Everything below this line treats the file on disk as untrusted input. It is
// a plist in the user's own Application Support folder: it can be hand-edited,
// restored from a backup written by a different version, or truncated by a
// filesystem that lost a write. Reading it back with the shape simply assumed
// meant that a string where a number belonged reached -unsignedLongLongValue
// and took the app down with an unrecognised selector -- at document-open time,
// on every open, until the user found and deleted the file.
- (id)init
{
    return [self initWithPath:[PVStateStore storePath]];
}

- (id)initWithPath:(NSString *)path
{
    self = [super init];
    if (!self) return nil;
    // Resolved once. -flush used to ask for it again on every write, which
    // re-created the containing directory each time for no reason.
    _path = [path copy];
    id onDisk = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    _docs = [[NSMutableDictionary alloc] init];
    if (![onDisk isKindOfClass:[NSDictionary class]]) return self;

    // Keep only the entries that have the shape the rest of this class expects,
    // so no later reader has to defend itself a second time.
    NSEnumerator *it = [(NSDictionary *)onDisk keyEnumerator];
    id key;
    while ((key = [it nextObject])) {
        if (![key isKindOfClass:[NSString class]]) continue;
        id value = [(NSDictionary *)onDisk objectForKey:key];
        if (![value isKindOfClass:[NSDictionary class]]) continue;
        [_docs setObject:value forKey:key];
    }
    return self;
}

// Typed readers. A missing or wrong-typed value yields the caller's fallback
// rather than a message to an object that cannot answer it.
static double PVNumber(NSDictionary *d, NSString *key, double fallback)
{
    id v = [d objectForKey:key];
    return [v isKindOfClass:[NSNumber class]] ? [v doubleValue] : fallback;
}

static NSString *PVString(NSDictionary *d, NSString *key)
{
    id v = [d objectForKey:key];
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : nil;
}

- (void)dealloc { [_docs release]; [_path release]; [super dealloc]; }

- (NSString *)keyForURL:(NSURL *)url
{
    if (![url isFileURL]) return nil;
    NSString *p = [[url path] stringByStandardizingPath];
    return ([p length] > 0) ? p : nil;
}

- (void)recordForURL:(NSURL *)url
                page:(NSUInteger)page
            fraction:(CGFloat)fraction
            zoomMode:(PVZoomMode)mode
                zoom:(CGFloat)zoom
             sidebar:(BOOL)sidebarVisible
         windowFrame:(NSString *)frameString
{
    NSString *key = [self keyForURL:url];
    if (!key) return;

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    [d setObject:[NSNumber numberWithUnsignedLongLong:(unsigned long long)page] forKey:@"page"];
    [d setObject:[NSNumber numberWithDouble:(double)fraction] forKey:@"fraction"];
    [d setObject:[NSNumber numberWithInt:(int)mode]           forKey:@"zoomMode"];
    [d setObject:[NSNumber numberWithDouble:(double)zoom]     forKey:@"zoom"];
    [d setObject:[NSNumber numberWithBool:sidebarVisible]     forKey:@"sidebar"];
    if (frameString) [d setObject:frameString forKey:@"windowFrame"];

    // Nothing has moved since the last time this document was recorded, so
    // there is nothing to write. This matters because the store is flushed
    // every time the app is deactivated: without the comparison, switching away
    // from Postview and back a hundred times in a day is a hundred identical
    // plist writes, and on the spinning disk this app is aimed at each one is a
    // real cost. Writes now happen in proportion to reading, not to Cmd-Tab.
    NSDictionary *previous = [_docs objectForKey:key];
    if ([previous isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *before = [[previous mutableCopy] autorelease];
        [before removeObjectForKey:@"seen"];    // a timestamp is not a change
        if ([before isEqualToDictionary:d]) return;
    }

    // Stamped only on a real change, so "seen" means "when the reading position
    // last moved", which is the more useful thing for -prune to sort on anyway.
    [d setObject:[NSNumber numberWithDouble:[NSDate timeIntervalSinceReferenceDate]]
          forKey:@"seen"];
    [_docs setObject:d forKey:key];
    _dirty = YES;
}

- (BOOL)stateForURL:(NSURL *)url
               page:(NSUInteger *)outPage
           fraction:(CGFloat *)outFraction
           zoomMode:(PVZoomMode *)outMode
               zoom:(CGFloat *)outZoom
            sidebar:(BOOL *)outSidebar
        windowFrame:(NSString **)outFrame
{
    NSString *key = [self keyForURL:url];
    if (!key) return NO;
    NSDictionary *d = [_docs objectForKey:key];
    if (![d isKindOfClass:[NSDictionary class]]) return NO;

    if (outPage) {
        // Clamped before the cast: a negative or absurd stored page must not
        // become a huge NSUInteger that the caller then trusts as an index.
        // The bound is 2^53 rather than NSUIntegerMax because (double)NSUIntegerMax
        // rounds UP to 2^64, so comparing against it lets through exactly the
        // value whose cast is undefined. 2^53 is the largest integer a double
        // holds exactly, and is nine orders of magnitude past any page count.
        double p = PVNumber(d, @"page", 0);
        if (!(p >= 0) || p > 9007199254740992.0) p = 0;
        *outPage = (NSUInteger)p;
    }
    if (outFraction) {
        double f = PVNumber(d, @"fraction", 0);
        if (!isfinite(f) || f < 0) f = 0;
        if (f > 1) f = 1;
        *outFraction = (CGFloat)f;
    }
    if (outZoom) {
        double z = PVNumber(d, @"zoom", 1.0);
        if (!isfinite(z)) z = 1.0;
        *outZoom = (CGFloat)z;
    }
    if (outSidebar)  *outSidebar  = (PVNumber(d, @"sidebar", 0) != 0);
    if (outMode) {
        double m = PVNumber(d, @"zoomMode", PVZoomModeFitWidth);
        if (!(m >= 0) || m > 3) m = PVZoomModeFitWidth;
        *outMode = (PVZoomMode)(int)m;
    }
    if (outFrame)    *outFrame    = PVString(d, @"windowFrame");
    return YES;
}

- (void)prune
{
    if ([_docs count] <= PV_MAX_REMEMBERED) return;
    NSArray *keys = [[_docs allKeys] sortedArrayUsingComparator:^(id a, id b) {
        double ta = PVNumber([_docs objectForKey:a], @"seen", 0);
        double tb = PVNumber([_docs objectForKey:b], @"seen", 0);
        if (ta < tb) return (NSComparisonResult)NSOrderedAscending;
        if (ta > tb) return (NSComparisonResult)NSOrderedDescending;
        return (NSComparisonResult)NSOrderedSame;
    }];
    NSUInteger excess = [_docs count] - PV_MAX_REMEMBERED;
    NSUInteger i;
    for (i = 0; i < excess; i++) [_docs removeObjectForKey:[keys objectAtIndex:i]];
}

- (void)flush
{
    if (!_dirty) return;
    [self prune];
    // _dirty is cleared only on a successful write, so a failure -- a full
    // disk, a folder that has gone away -- is retried at the next flush point
    // rather than silently discarding the reading position.
    if (_path && [_docs writeToFile:_path atomically:YES]) _dirty = NO;
}

@end
