//  PVDropView.h — the whole window is the drop target.
//
//  Both windows accept PDFs, and they accept them anywhere: dropping onto the
//  page, the thumbnail sidebar, the grey margin or the empty state all do the
//  same thing. That is what a document window on this system is expected to do,
//  and it used to work only over one 460x300 panel in the welcome window.
//
//  It works by being the window's contentView rather than a control inside it.
//  AppKit looks for a drag destination by hit-testing and then walking up the
//  view hierarchy, so a view that owns the whole window catches every drop that
//  no closer view claimed, without any of the subviews having to know.

#import "PVCommon.h"

@interface PVDropView : NSView {
    BOOL _highlighted;
    BOOL _drawsBackground;
    // Paths from the current drop that have not been opened yet.
    //
    // A drop opens one document per turn of the run loop rather than all of
    // them in one loop: see -openNextDroppedDocument. Nil whenever no sequence
    // is outstanding.
    NSMutableArray *_pendingDrops;
}
// Whether to paint anything at all. The welcome window's own content view draws
// the empty state; the document window's sits behind an opaque view tree and
// must not spend a fill on pixels nobody sees.
- (void)setDrawsBackground:(BOOL)flag;
- (BOOL)isDropHighlighted;

// Paints the "a drop will land here" ring, and nothing when no drop is
// pending. Part of the subclass contract: a subclass that overrides
// -drawRect: to draw its own content has to call this, or the window stops
// acknowledging drags without any other sign that something is wrong.
- (void)drawDropHighlight;

// The PDF paths in a drag, or nil if it holds none. Exposed so the highlight
// and the drop agree exactly about what counts.
//
// At most PV_MAX_DROPPED_DOCUMENTS are returned; `outTotal` receives how many
// were actually there, which is what the "too many" message needs and the only
// reason the two numbers are separate.
+ (NSArray *)pdfPathsInDrag:(id <NSDraggingInfo>)info
                 totalFound:(NSUInteger *)outTotal;
+ (NSArray *)pdfPathsInDrag:(id <NSDraggingInfo>)info;

// Abandon any drop still being opened. Called from -dealloc; exposed because a
// window closing mid-sequence has to be able to stop it too.
- (void)cancelPendingOpens;
@end
