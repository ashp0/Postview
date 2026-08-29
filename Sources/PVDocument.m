#import "PVDocument.h"
#import "PVWindowController.h"

@implementation PVDocument

// Parsing happens off the main thread, so opening a large PDF never beachballs.
+ (BOOL)canConcurrentlyReadDocumentsOfType:(NSString *)type { return YES; }
+ (BOOL)autosavesInPlace { return NO; }

- (id)init
{
    self = [super init];
    if (self) [self setHasUndoManager:NO];
    return self;
}

- (void)dealloc { [_source release]; [super dealloc]; }

- (BOOL)readFromURL:(NSURL *)url ofType:(NSString *)type error:(NSError **)outError
{
    PVPDFSource *src = [[PVPDFSource alloc] initWithURL:url error:outError];
    if (!src) return NO;
    [_source release];
    _source = src;
    return YES;
}

- (BOOL)isDocumentEdited { return NO; }
- (BOOL)isEntireFileLoaded { return YES; }

- (void)makeWindowControllers
{
    // AppKit does not call this when -readFromURL: reported failure, so _source
    // is always set in practice. Stated anyway: a window built on a nil source
    // is a zero-page viewer with a live render queue attached to nothing, and
    // it is not worth leaving that shape reachable.
    if (!_source) return;
    PVWindowController *wc = [[PVWindowController alloc] initWithSource:_source
                                                                   url:[self fileURL]];
    // Allocation failure has to remain an ordinary failed open, not become an
    // `addWindowController:nil` exception on a memory-constrained machine.
    if (wc) {
        [self addWindowController:wc];
        [wc release];
    }
}

@end
