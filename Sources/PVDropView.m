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

- (void)dealloc { [self unregisterDraggedTypes]; [super dealloc]; }

- (void)setDrawsBackground:(BOOL)flag { _drawsBackground = flag; }
- (BOOL)isDropHighlighted { return _highlighted; }
- (BOOL)isOpaque { return _drawsBackground; }

+ (NSArray *)pdfPathsInDrag:(id <NSDraggingInfo>)info
{
    NSPasteboard *pb = [info draggingPasteboard];
    NSArray *paths = [pb propertyListForType:NSFilenamesPboardType];
    if (![paths isKindOfClass:[NSArray class]]) return nil;
    NSMutableArray *pdfs = [NSMutableArray array];
    NSUInteger i, n = [paths count];
    for (i = 0; i < n; i++) {
        id p = [paths objectAtIndex:i];
        if (![p isKindOfClass:[NSString class]]) continue;
        if ([[p pathExtension] caseInsensitiveCompare:@"pdf"] == NSOrderedSame)
            [pdfs addObject:p];
    }
    return ([pdfs count] > 0) ? pdfs : nil;
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

- (BOOL)performDragOperation:(id <NSDraggingInfo>)info
{
    NSArray *paths = [PVDropView pdfPathsInDrag:info];
    [self setHighlighted:NO];
    if (!paths) return NO;

    NSDocumentController *dc = [NSDocumentController sharedDocumentController];
    NSUInteger i, n = [paths count];
    for (i = 0; i < n; i++) {
        NSURL *url = [NSURL fileURLWithPath:[paths objectAtIndex:i]];
        // 10.9-compatible opener. The completion form is 10.7+, but this one
        // reports errors through the standard presenter, which is what we want.
        NSError *err = nil;
        id doc = [dc openDocumentWithContentsOfURL:url display:YES error:&err];
        if (!doc && err) [dc presentError:err];
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
