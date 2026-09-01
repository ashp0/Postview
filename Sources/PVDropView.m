#import "PVDropView.h"

@implementation PVDropView

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        // NSFilenamesPboardType rather than NSPasteboardTypeFileURL: the latter
        // is 10.13+, and this app still has to run on 10.9.
        [self registerForDraggedTypes:[NSArray arrayWithObject:NSFilenamesPboardType]];
    }
    return self;
}

- (void)dealloc
{
    // Before anything else: a scheduled -openNextDroppedDocument holds no
    // reference to this view, so one left armed here fires into freed memory.
    [self cancelPendingOpens];
    [self unregisterDraggedTypes];
    [super dealloc];
}

- (void)setDrawsBackground:(BOOL)flag { _drawsBackground = flag; }
- (BOOL)isDropHighlighted { return _highlighted; }
- (BOOL)isOpaque { return _drawsBackground; }

// The most documents one drop will open.
//
// A pasteboard is not a user gesture with a natural size: a Finder
// select-all in a folder of scanned pages, or any script that writes a
// pasteboard, can hand over thousands of paths, and each one becomes a
// synchronous -openDocumentWithContentsOfURL: -- a document, a window
// controller, a PVPDFSource with its own snapshot copy of the file, a render
// helper process, and a render queue. That is not a slow drop; it is the app
// unresponsive for minutes and a machine out of file descriptors.
//
// Thirty-two is far more than anyone drops deliberately and far less than
// anything that hurts.
#define PV_MAX_DROPPED_DOCUMENTS 32

// The PDFs in a drag, at most PV_MAX_DROPPED_DOCUMENTS of them, with the true
// count reported separately.
//
// Collection stops at the cap rather than gathering everything and slicing
// afterwards. This runs on -draggingEntered: as well as on the drop, so it is
// on the path of every drag that crosses the window -- scanning ten thousand
// pasteboard entries to build an array of which thirty-two will be used, once
// per drag event, is work with no purpose. The scan still runs to the end,
// because the total is what the message below needs, but it stops allocating.
+ (NSArray *)pdfPathsInDrag:(id <NSDraggingInfo>)info
                 totalFound:(NSUInteger *)outTotal
{
    if (outTotal) *outTotal = 0;
    NSPasteboard *pb = [info draggingPasteboard];
    NSArray *paths = [pb propertyListForType:NSFilenamesPboardType];
    if (![paths isKindOfClass:[NSArray class]]) return nil;
    NSMutableArray *pdfs = [NSMutableArray array];
    NSUInteger total = 0;
    NSUInteger i, n = [paths count];
    for (i = 0; i < n; i++) {
        id p = [paths objectAtIndex:i];
        if (![p isKindOfClass:[NSString class]]) continue;
        if ([[p pathExtension] caseInsensitiveCompare:@"pdf"] != NSOrderedSame)
            continue;
        total++;
        if ([pdfs count] < (NSUInteger)PV_MAX_DROPPED_DOCUMENTS)
            [pdfs addObject:p];
    }
    if (outTotal) *outTotal = total;
    return ([pdfs count] > 0) ? pdfs : nil;
}

+ (NSArray *)pdfPathsInDrag:(id <NSDraggingInfo>)info
{
    return [self pdfPathsInDrag:info totalFound:NULL];
}

#pragma mark - Dragging destination

- (void)setHighlighted:(BOOL)flag
{
    if (flag == _highlighted) return;
    _highlighted = flag;
    [self setNeedsDisplay:YES];
}

- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)info
{
    if (![PVDropView pdfPathsInDrag:info]) return NSDragOperationNone;
    [self setHighlighted:YES];
    return NSDragOperationCopy;
}

- (void)draggingExited:(id <NSDraggingInfo>)info  { [self setHighlighted:NO]; }
- (void)draggingEnded:(id <NSDraggingInfo>)info   { [self setHighlighted:NO]; }

- (BOOL)prepareForDragOperation:(id <NSDraggingInfo>)info
{
    return ([PVDropView pdfPathsInDrag:info] != nil);
}

// Open one document, then come back for the next on a later turn of the run
// loop.
//
// Opening is not cheap and it is not asynchronous: each document copies the
// whole file into a private snapshot, spawns a render helper, waits for it to
// describe every page, and builds a window. Thirty-two of those in one loop is
// several seconds during which the main thread does not draw, does not respond,
// and does not show the windows it has already made -- so a drop of a folder
// looks like a hang and then produces everything at once.
//
// One per turn instead. Each window appears as it is ready, the application
// stays responsive between them, and a user who did not mean it can close the
// first few or quit. -cancelPendingOpens stops the sequence if this view goes
// away underneath it.
- (void)openNextDroppedDocument
{
    if ([_pendingDrops count] == 0) {
        [_pendingDrops release];
        _pendingDrops = nil;
        return;
    }
    NSString *path = [[[_pendingDrops objectAtIndex:0] retain] autorelease];
    [_pendingDrops removeObjectAtIndex:0];

    NSDocumentController *dc = [NSDocumentController sharedDocumentController];
    NSURL *url = [NSURL fileURLWithPath:path];
    // 10.9-compatible opener. The completion form is 10.7+, but this one
    // reports errors through the standard presenter, which is what we want.
    NSError *err = nil;
    id doc = [dc openDocumentWithContentsOfURL:url display:YES error:&err];
    if (!doc && err) [dc presentError:err];

    if ([_pendingDrops count] > 0)
        [self performSelector:@selector(openNextDroppedDocument)
                   withObject:nil
                   afterDelay:0.0];
    else {
        [_pendingDrops release];
        _pendingDrops = nil;
    }
}

- (void)cancelPendingOpens
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(openNextDroppedDocument)
                                               object:nil];
    [_pendingDrops release];
    _pendingDrops = nil;
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)info
{
    NSUInteger total = 0;
    NSArray *paths = [PVDropView pdfPathsInDrag:info totalFound:&total];
    [self setHighlighted:NO];
    if (!paths) return NO;

    // A second drop replaces the first rather than interleaving with it: two
    // sequences taking turns would open both batches at half the rate and in an
    // order that belongs to neither.
    [self cancelPendingOpens];
    _pendingDrops = [[NSMutableArray alloc] initWithArray:paths];
    NSUInteger n = [paths count];

    // The first one immediately, so the drop visibly does something on the
    // gesture that caused it; the rest on their own turns.
    [self openNextDroppedDocument];

    // Said out loud rather than silently ignored. Opening 32 of 500 documents
    // and saying nothing looks exactly like a bug, and the user has no way to
    // tell which 32 they got.
    if (total > n) {
        NSAlert *alert = [[[NSAlert alloc] init] autorelease];
        [alert setMessageText:@"Too many documents in one drop"];
        [alert setInformativeText:[NSString stringWithFormat:
            @"Postview is opening the first %lu of %lu PDF files. Drop the rest "
            @"in another batch, or open them from the File menu.",
            (unsigned long)n, (unsigned long)total]];
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    }
    return YES;
}

#pragma mark - Drawing

// A ring just inside the window edge while a drop is pending. Drawn at the
// window's own boundary rather than around some inner well, because the whole
// window is what accepts the drop and the feedback should say so.
- (void)drawDropHighlight
{
    if (!_highlighted) return;
    NSRect b = NSInsetRect([self bounds], 2, 2);
    NSBezierPath *ring = [NSBezierPath bezierPathWithRect:b];
    [ring setLineWidth:4.0];
    [[NSColor colorWithCalibratedRed:0.20 green:0.44 blue:0.82 alpha:0.85] set];
    [ring stroke];
}

// The document window's drop view is the content view with the whole document
// on top of it, so nothing drawn here is ever seen there -- and that is right:
// dragging a file over an open document window is acknowledged by the drag
// image's own badge, the way it is everywhere else on this system, and a ring
// around the window would be Postview inventing a convention. The empty state
// is the case where there is nothing else to look at, and its own subclass
// draws the ring by calling -drawDropHighlight.
- (void)drawRect:(NSRect)dirty
{
    if (_drawsBackground) {
        [[NSColor colorWithCalibratedWhite:0.96 alpha:1.0] set];
        NSRectFill(dirty);
    }
    [self drawDropHighlight];
}

@end
