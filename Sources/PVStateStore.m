#import "PVStateStore.h"
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

#define PV_MAX_REMEMBERED 400

// The largest state file that will be read at all.
//
// This is a plist in the user's own Application Support folder, and reading it
// used to mean handing an arbitrary-length file to NSDictionary and letting the
// parser allocate whatever it found before a single entry had been validated.
// A file that is corrupt, restored from something else, or simply enormous is
// then an allocation the size of the file, made at document-open time. Four
// mebibytes is about ten thousand remembered documents, twenty-five times the
// cap on how many are kept.
#define PV_MAX_STATE_FILE_BYTES (4ULL * 1024ULL * 1024ULL)

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
    _docs = [[NSMutableDictionary alloc] init];
    _dirtyKeys = [[NSMutableSet alloc] init];
    if (!_docs || !_dirtyKeys) { [self release]; return nil; }

    NSMutableDictionary *onDisk = PVLoadBoundedValidatedState(_path);
    if (onDisk) [_docs setDictionary:onDisk];

    // Pruned here rather than only on the way out. -flush prunes, but it
    // returns early when nothing is dirty -- so a store that has grown past the
    // cap (an older build's file, a restored backup) stayed entirely resident
    // for the life of the process unless the user happened to open a document,
    // and was written back at full size if they did. Marking it dirty is what
    // makes the trim reach the disk.
    if ([_docs count] > PV_MAX_REMEMBERED) {
        [self prune];
        _dirty = YES;
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

// Read the store, bounded, through ONE file descriptor.
//
// The size check and the read go through the same descriptor on purpose. Asking
// the file system for the size by path and then opening the path is two
// questions about two possibly different files: anything that can write to the
// folder can answer the first with a small file and the second with a huge one.
// One open, one fstat, one read closes that.
//
// Returns nil for anything it will not vouch for: unreadable, not a regular
// file, over the ceiling, not a plist, or not a dictionary.
static NSMutableDictionary *PVLoadBoundedValidatedState(NSString *path)
{
    if (!path) return nil;

    int fd = open([path fileSystemRepresentation], O_RDONLY);
    if (fd < 0) return nil;
    (void)fcntl(fd, F_SETFD, FD_CLOEXEC);

    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < 0 ||
        (unsigned long long)st.st_size > PV_MAX_STATE_FILE_BYTES) {
        close(fd);
        return nil;
    }

    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
    if (!data) { close(fd); return nil; }
    char *bytes = (char *)[data mutableBytes];
    size_t want = (size_t)st.st_size, got = 0;
    while (got < want) {
        ssize_t n = read(fd, bytes + got, want - got);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        got += (size_t)n;
    }
    close(fd);
    if (got != want) return nil;

    id onDisk = [NSPropertyListSerialization propertyListWithData:data
                                                          options:NSPropertyListImmutable
                                                           format:NULL
                                                            error:NULL];
    if (![onDisk isKindOfClass:[NSDictionary class]]) return nil;

    // Keep only the entries that have the shape the rest of this class expects,
    // so no later reader has to defend itself a second time.
    NSMutableDictionary *valid = [NSMutableDictionary dictionary];
    NSEnumerator *it = [(NSDictionary *)onDisk keyEnumerator];
    id key;
    while ((key = [it nextObject])) {
        if (![key isKindOfClass:[NSString class]]) continue;
        id value = [(NSDictionary *)onDisk objectForKey:key];
        if (![value isKindOfClass:[NSDictionary class]]) continue;
        [valid setObject:value forKey:key];
    }
    return valid;
}

// Drop the oldest entries until the dictionary is back within the cap.
//
// Total ordering, deliberately. Sorting on "seen" alone leaves entries with
// equal timestamps in whatever order the dictionary happened to enumerate them,
// so which document is forgotten depends on hash order -- and NaN, which a
// hand-edited or corrupted file can easily contain, compares false against
// everything, making the comparator not even a weak ordering. The path breaks
// ties, and a non-finite timestamp is read as "never seen".
static void PVPruneDictionaryDeterministically(NSMutableDictionary *docs)
{
    if ([docs count] <= PV_MAX_REMEMBERED) return;
    NSArray *keys = [[docs allKeys]
        sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            double ta = PVNumber([docs objectForKey:a], @"seen", 0);
            double tb = PVNumber([docs objectForKey:b], @"seen", 0);
            if (!isfinite(ta)) ta = 0;
            if (!isfinite(tb)) tb = 0;
            if (ta < tb) return (NSComparisonResult)NSOrderedAscending;
            if (ta > tb) return (NSComparisonResult)NSOrderedDescending;
            return [(NSString *)a compare:(NSString *)b options:NSLiteralSearch];
        }];
    NSUInteger excess = [docs count] - PV_MAX_REMEMBERED;
    NSUInteger i;
    for (i = 0; i < excess && i < [keys count]; i++)
        [docs removeObjectForKey:[keys objectAtIndex:i]];
}

static NSString *PVString(NSDictionary *d, NSString *key)
{
    id v = [d objectForKey:key];
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : nil;
}

- (void)dealloc
{
    [_docs release];
    [_dirtyKeys release];
    [_path release];
    [super dealloc];
}

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
    [_dirtyKeys addObject:key];
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
    PVPruneDictionaryDeterministically(_docs);
}

// Merge this process's changes onto whatever is on disk, under an exclusive
// lock, and write the result back.
//
// The lock is a sidecar file rather than the store itself, because the write is
// atomic-by-rename: -writeToFile:atomically: replaces the inode, so a lock held
// on the store would be a lock on a file that no longer exists the moment
// anyone writes. The sidecar is never renamed, so every process locks the same
// object.
//
// A process that cannot take the lock does not write. That is the safe failure:
// this process's positions stay in memory and _dirty stays set, so the next
// flush point tries again, and nothing another process recorded is lost.
- (void)flush
{
    if (!_dirty) return;
    if (!_path) {
        // A memory-only store has nowhere to write and nothing to merge with.
        [_dirtyKeys removeAllObjects];
        _dirty = NO;
        return;
    }

    NSString *lockPath = [_path stringByAppendingString:@".lock"];
    int fd = open([lockPath fileSystemRepresentation], O_CREAT | O_RDWR, 0600);
    if (fd < 0) return;
    (void)fcntl(fd, F_SETFD, FD_CLOEXEC);
    // LOCK_NB, and this is the whole reason the failure path above is written
    // the way it is.
    //
    // A blocking LOCK_EX waits for however long another process holds the
    // lock, and -flush is called from the main thread on close and on quit.
    // The holder is normally another Postview flushing a few kilobytes, which
    // is imperceptible -- but it does not have to be: the lock file can be on a
    // network volume that has stopped answering, or held by a process that has
    // been stopped, and then the wait is unbounded and the window will not
    // close. Trading a saved reading position for a hang is not a trade worth
    // making, and it is not even a real loss: _dirty stays set, so the position
    // is written at the next flush point instead.
    //
    // Bounded rather than single-shot, because the common contention really is
    // brief -- another Postview writing a few kilobytes -- and losing the
    // position to a 2 ms overlap would be a poor trade in the other direction.
    // A quarter of a second is far longer than any honest holder needs and far
    // shorter than a person notices at the moment a window closes.
    BOOL locked = NO;
    {
        double giveUpAt = PVMonotonicSeconds() + 0.25;
        for (;;) {
            if (flock(fd, LOCK_EX | LOCK_NB) == 0) { locked = YES; break; }
            if (errno != EWOULDBLOCK) break;
            if (PVMonotonicSeconds() >= giveUpAt) break;
            usleep(5000);
        }
    }
    if (!locked) {
        close(fd);
        return;
    }

    NSMutableDictionary *merged = PVLoadBoundedValidatedState(_path);
    if (!merged) merged = [NSMutableDictionary dictionary];

    NSEnumerator *it = [_dirtyKeys objectEnumerator];
    NSString *key;
    while ((key = [it nextObject])) {
        NSDictionary *value = [_docs objectForKey:key];
        if (value) [merged setObject:value forKey:key];
        else       [merged removeObjectForKey:key];
    }

    PVPruneDictionaryDeterministically(merged);

    // _dirty is cleared only on a successful write, so a failure -- a full
    // disk, a folder that has gone away -- is retried at the next flush point
    // rather than silently discarding the reading position.
    BOOL written = [merged writeToFile:_path atomically:YES];
    if (written) {
        // Adopt the merged view: this process now knows what the other one
        // recorded, so a later flush does not have to rediscover it.
        [_docs setDictionary:merged];
        [_dirtyKeys removeAllObjects];
        _dirty = NO;
    }

    flock(fd, LOCK_UN);
    close(fd);
}

@end
