#import "PVPageView.h"

// -accessibilityDisplayShouldReduceMotion is 10.12 and later, and this target
// builds against the 10.9 SDK, where NSWorkspace does not declare it. Declared
// here so the call below is an ordinary message send with the right signature
// rather than a cast of objc_msgSend to a shape the compiler has to be told to
// stop objecting to; the -respondsToSelector: guard at the call site is what
// makes it safe on a system that has never heard of it.
@interface NSWorkspace (PVReduceMotion)
- (BOOL)accessibilityDisplayShouldReduceMotion;
@end

@implementation PVPageView

- (id)initWithSource:(PVPDFSource *)source cache:(PVImageCache *)cache
{
    self = [super initWithFrame:NSMakeRect(0, 0, 600, 800)];
    if (!self) return nil;
    if (!source || !cache) { [self release]; return nil; }
    PVLiveAdjust("PVPageView", +1);
    _source       = [source retain];
    _cache        = [cache retain];
    _pageCount    = [source pageCount];
    if (_pageCount == 0 || _pageCount > (NSUInteger)(SIZE_MAX / sizeof(NSRect))) {
        [self release];
        return nil;
    }
    _frames       = [[NSMutableData alloc] initWithLength:_pageCount * sizeof(NSRect)];
    if (!_frames) { [self release]; return nil; }
    _zoom         = 1.0;
    _backingScale = 1.0;
    _contentWidth = 600;
    _columns      = 1;
    // Both start at one, and they agree until the first -setColumns:. The
    // laid-out count is what queries read; see PVPageView.h.
    _laidOutColumns = 1;
    // The row table is built by the first layout pass, which is where the
    // column count it has to be sized for is finally known.
    _layoutDirty  = YES;
    _backgroundColor = [[NSColor colorWithCalibratedWhite:0.42 alpha:1.0] retain];
    return self;
}

- (void)dealloc
{
    PVLiveAdjust("PVPageView", -1);
    // Reaching -dealloc at all proves the timer is already gone -- it retains
    // its target, so a live one makes this method unreachable. Here for the
    // same reason -[PVRenderQueue dealloc] calls -shutdown: the invariant is
    // worth stating where it would otherwise only be inferred, and it costs a
    // nil check. -endPan is not belt and braces: a view released while a
    // pushed cursor is still on the stack would leave the closed hand up.
    [self cancelScrollAnimation];
    [self endPan];
    [_backgroundColor release];
    [_rows release];
    [_frames release];
    [_cache release];
    [_source release];
    [super dealloc];
}

// Opting in to responsive scrolling lets AppKit pre-draw beyond the visible
// rect while the main thread is idle, so most scrolling exposes area we have
// already drawn. It requires that we do not override -scrollWheel:.
+ (BOOL)isCompatibleWithResponsiveScrolling { return YES; }

- (BOOL)isFlipped   { return YES; }
- (BOOL)isOpaque    { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

- (CGFloat)zoom { return _zoom; }
- (NSUInteger)columns { return _columns ? _columns : 1; }
// The count the geometry on screen was built with, which is the only one the
// row table may be indexed by. Never the requested count: see PVPageView.h.
- (NSUInteger)laidOutColumns { return _laidOutColumns ? _laidOutColumns : 1; }
- (BOOL)cover { return _cover; }
- (BOOL)laidOutCover { return _laidOutCover; }
- (void)setDelegate:(id <PVPageViewDelegate>)delegate { _delegate = delegate; }

- (void)setColumns:(NSUInteger)columns
{
    if (columns < 1) columns = 1;
    if (columns > PV_MAX_PAGE_COLUMNS) columns = PV_MAX_PAGE_COLUMNS;
    if (columns == _columns) return;
    _columns = columns;
    _layoutDirty = YES;
}

- (void)setCover:(BOOL)cover
{
    cover = cover ? YES : NO;              // any non-zero BOOL, one value
    if (cover == _cover) return;
    _cover = cover;
    _layoutDirty = YES;
}

#pragma mark - Pinch to zoom

// Pinch-to-zoom, on Mavericks as well as on current systems.
//
// It never worked because it was never implemented: -magnifyWithEvent: is
// delivered to the view under the fingers and nothing here answered it, so the
// gesture went to the responder chain and fell off the end.
//
// Recognising the gesture is easy; knowing when it has *finished* is the part
// that differs across the range this app covers. 10.7 added -[NSEvent phase],
// and current systems report NSEventPhaseEnded on the last magnify event.
// Mavericks does not populate phase for gesture events at all -- there it is
// NSEventPhaseNone throughout -- and the end is signalled instead by
// -endGestureWithEvent:, the 10.5-era bracket that later systems deprecated
// and no longer send. Listening for only one of the two leaves the gesture
// permanently open on exactly the system this app is built for.
//
// So both are handled, and -finishMagnify guards against the end arriving
// twice on any system that decides to send both.
- (void)magnifyWithEvent:(NSEvent *)event
{
    if (!_magnifying) {
        _magnifying = YES;
        NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
        if ([_delegate respondsToSelector:@selector(pageViewWillMagnify:atPoint:)])
            [_delegate pageViewWillMagnify:self atPoint:p];
    }

    // -magnification is the change since the last event, as a fraction.
    CGFloat delta = [event magnification];
    if (isfinite(delta) && delta != 0) {
        CGFloat factor = 1.0 + delta;
        // A factor at or below zero would invert or collapse the document.
        if (factor > 0.01 && factor < 100.0) [_delegate pageView:self magnifyBy:factor];
    }

    NSEventPhase phase = [event phase];
    if (phase & (NSEventPhaseEnded | NSEventPhaseCancelled)) [self finishMagnify];
}

// The 10.5-era gesture bracket, which is what Mavericks actually sends.
- (void)beginGestureWithEvent:(NSEvent *)event { }
- (void)endGestureWithEvent:(NSEvent *)event   { [self finishMagnify]; }

- (void)finishMagnify
{
    if (!_magnifying) return;
    _magnifying = NO;
    [_delegate pageViewDidMagnify:self];
}

// Two-finger double tap.
- (void)smartMagnifyWithEvent:(NSEvent *)event
{
    if (![_delegate respondsToSelector:@selector(pageViewSmartMagnify:atPoint:)]) {
        [super smartMagnifyWithEvent:event];
        return;
    }
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    [_delegate pageViewSmartMagnify:self atPoint:p];
}

- (NSRect *)frameArray { return (NSRect *)[_frames mutableBytes]; }
- (PVPageRow *)rowArray { return (PVPageRow *)[_rows mutableBytes]; }
- (BOOL)isLaidOut { return _laidOut; }

// Pages in row `row`. A short row is the last one of a document that runs out
// mid-row, and -- in the cover layout -- the first one, which holds the page
// that stands alone.
//
// Indexed by ROW and not by first page. It used to take the first page and
// subtract it from the page count, which was a correct reading of "how many
// pages are left" only while every row before it had been full: in the cover
// layout row zero starts at page zero with a whole document ahead of it and
// still holds exactly one page, and that arithmetic said two.
//
// The shape is an argument rather than a read of the ivars because the two
// callers want different ones: the layout pass is building a table and passes
// the shape it is building it with, while every query is reading the table
// that exists and passes the shape it was built with. Those are the same
// except in the window -setColumns:/-setCover: opens, and that window is
// precisely where reading the wrong one indexes off the end of the document.
- (NSUInteger)pagesInRow:(NSUInteger)row columns:(NSUInteger)k cover:(BOOL)cover
{
    return PVPagesInRow(row, _pageCount, k, cover);
}

// The laid-out width of a row, gaps included. Cheap enough to recompute --
// there are at most PV_MAX_PAGE_COLUMNS terms in it -- that storing it would
// be a third array to keep in agreement with the other two.
- (CGFloat)widthOfRow:(NSUInteger)row columns:(NSUInteger)k cover:(BOOL)cover
{
    const NSRect *f = [self frameArray];
    if (!f) return 0;
    NSUInteger first = PVFirstPageOfRow(row, k, cover);
    NSUInteger count = [self pagesInRow:row columns:k cover:cover], j;
    CGFloat w = 0;
    for (j = 0; j < count; j++) {
        if (j) w += PV_PAGE_GAP;
        w += f[first + j].size.width;
    }
    return w;
}

#pragma mark - Layout

- (void)setZoom:(CGFloat)zoom backingScale:(CGFloat)scale containerWidth:(CGFloat)width
{
    if (zoom < PV_MIN_ZOOM) zoom = PV_MIN_ZOOM;
    if (zoom > PV_MAX_ZOOM) zoom = PV_MAX_ZOOM;
    if (scale < 1.0) scale = 1.0;

    if (!isfinite(zoom)) zoom = 1.0;
    if (!isfinite(scale)) scale = 1.0;
    if (!isfinite(width)) width = 600;

    CGFloat contentWidth = (width > 40) ? width : 40;
    // Laying out again for a geometry identical to the current one produces
    // the identical answer, and costs a pass over every page in the document
    // plus a full redraw. A window resized vertically, a split-view divider
    // settling, and every frame of a resize that has stopped changing width
    // all arrive here; a 1200-page document was being laid out for each of
    // them. Only the first call, when nothing has been laid out yet, must
    // always go through -- as must the first after the column count changes,
    // which none of the three compared quantities can tell you about.
    if (_laidOut && !_layoutDirty &&
        zoom == _zoom && scale == _backingScale && contentWidth == _contentWidth)
        return;

    // Past the early-out, so the geometry is genuinely about to move -- and an
    // animation in flight is aimed at an offset in the geometry that is about
    // to stop existing.
    //
    // The tick has a guard of its own, but it is a guard against MOVEMENT: it
    // compares where the document is against where it last put it, and a
    // relayout that leaves the offset where it was passes that check while
    // making the destination meaningless. Resizing the window vertically is
    // exactly that case -- the top of the document does not move -- so an
    // arrow held down through a resize finished by scrolling the reader off
    // the position -relayoutKeepingPage: had just taken care to preserve.
    //
    // Stated here rather than at each of the controller's five relayout paths
    // because this is where the geometry actually changes: the animation is
    // this view's, the frames are this view's, and one of them invalidating
    // the other is not a fact the callers should have to know.
    [self cancelScrollAnimation];

    // This call now owes a layout, and says so before it can fail to build
    // one. The three assignments below are the geometry a later call compares
    // itself against; a bail-out past them -- the row table is one allocation
    // and a machine short enough of memory to refuse it is a machine this
    // program is written to keep running on -- would leave the compared values
    // describing a layout that was never built, and the early-out above would
    // then agree with them forever. The frames on screen would stay at the old
    // zoom with no event coming that could ever repair them.
    //
    // Cleared at the bottom, on the one path that finishes.
    _layoutDirty = YES;

    _zoom = zoom;
    _backingScale = scale;
    _contentWidth = contentWidth;

    NSRect *f = [self frameArray];
    if (!f && _pageCount > 0) return;      // allocation failed; nothing is safe to lay out

    NSUInteger k = [self columns];
    // Normalised here, once, and it is this value that is published as
    // -laidOutCover below. A cover in a single column is not a layout: the
    // pairing functions already ignore it, but the placement loop asks the
    // flag directly, and left unnormalised it put page one in the recto slot
    // of a column that has no recto -- half a window to the right of every
    // other page in the document.
    BOOL cover = (_cover && k > 1);
    NSUInteger rowCount = PVRowCountForPages(_pageCount, k, cover);
    // Sized from a page count -[PVPDFSource init] has already bounded, and
    // never larger than the frame table beside it, so the multiplication that
    // -initWithLength: is given cannot overflow where that one did not.
    //
    // Built into a fresh allocation and swapped in only once it exists: on a
    // machine too short of memory to widen the table, the layout that is
    // already up there is left whole and on screen rather than being torn down
    // in favour of nothing.
    if (!_rows || rowCount != _rowCount) {
        NSMutableData *fresh =
            [[NSMutableData alloc] initWithLength:rowCount * sizeof(PVPageRow)];
        if (!fresh) return;
        [_rows release];
        _rows     = fresh;
        _rowCount = rowCount;
    }
    PVPageRow *rows = [self rowArray];
    if (!rows) return;

    CGFloat y = PV_EDGE_GAP;
    CGFloat widest = 0;
    NSUInteger r, j;

    for (r = 0; r < rowCount; r++) {
        NSUInteger first = PVFirstPageOfRow(r, k, cover);
        NSUInteger count = [self pagesInRow:r columns:k cover:cover];
        CGFloat rowWidth = 0, rowHeight = 0;

        for (j = 0; j < count; j++) {
            CGSize p = [_source pointSizeOfPage:first + j];
            // Round the on-screen size to whole points first, then derive the
            // pixel size from it. That guarantees bitmap pixels land exactly on
            // device pixels, so the common case is a 1:1 blit with no
            // resampling at all.
            CGFloat w = floor(p.width  * _zoom + 0.5);
            CGFloat h = floor(p.height * _zoom + 0.5);
            if (w < 1) w = 1;
            if (h < 1) h = 1;
            // Facing pages are aligned at the top, the way an open book is.
            // Their heights differ often enough -- a scanned document, a
            // landscape plate among portrait text -- that this has to be said
            // rather than assumed, and the row is as tall as the taller one.
            f[first + j] = NSMakeRect(0, y, w, h);
            if (j) rowWidth += PV_PAGE_GAP;
            rowWidth += w;
            if (h > rowHeight) rowHeight = h;
        }

        rows[r].y      = y;
        rows[r].height = rowHeight;
        // The cover page sits in the RIGHT-hand half of its row -- see the
        // placement loop below -- so the space it needs is not its own width
        // but the width of the spread it is half of. Counting only its own
        // would size the document too narrow for where the page is about to be
        // put, and the placement clamp would then pull it back out of the
        // recto position on exactly the documents whose first page is the
        // widest in them.
        //
        // A document of one page is not a book and gets no empty verso beside
        // it: the guard here is the same one the placement loop applies, so
        // the width reserved and the position chosen cannot disagree.
        if (cover && r == 0 && count == 1 && _pageCount > 1)
            rowWidth = rowWidth * 2 + PV_PAGE_GAP;
        if (rowWidth > widest) widest = rowWidth;
        y += rowHeight + PV_PAGE_GAP;
    }

    CGFloat totalHeight = (rowCount > 0) ? (y - PV_PAGE_GAP + PV_EDGE_GAP) : PV_EDGE_GAP * 2;
    CGFloat totalWidth  = widest + PV_EDGE_GAP * 2;
    if (totalWidth < _contentWidth) totalWidth = _contentWidth;

    // Centre each ROW horizontally within whatever width we end up with, and
    // lay its pages out left to right inside it. With one column this is the
    // page centred on its own, which is what it has always been; with two, the
    // pair is centred as a unit so the gutter between them sits in the middle
    // of the window rather than each page being centred on top of the other.
    //
    // The cover page is the exception, and it is what makes the layout a book
    // rather than a spread with a hole in it. A title page is a RIGHT-hand
    // page: centring it would put page one over the gutter and every page
    // after it half a page to one side, so the whole document would appear to
    // shift sideways as you turned off the first row.
    //
    // So the rule is the book's own: the gutter runs down the middle of the
    // document and the cover page is the page to the right of it. Its left
    // edge is `totalWidth/2 + PV_PAGE_GAP/2` -- the centre line, plus the half
    // of the gutter that belongs to the recto side.
    //
    // Work the centring above through for a pair of equal-width pages and it
    // gives the same number: the left page starts at (totalWidth - 2w - gap)/2,
    // so the right one starts at that plus w + gap, which is totalWidth/2 +
    // gap/2 with the w cancelling. Two facing pages of DIFFERENT widths are
    // centred as a unit, which puts their gutter off the centre line by half
    // the difference, and the cover does not follow it there -- it stays on
    // the centre line, which is the stable thing to align a whole document to
    // and does not require knowing anything about page two.
    for (r = 0; r < rowCount; r++) {
        NSUInteger first = PVFirstPageOfRow(r, k, cover);
        NSUInteger count = [self pagesInRow:r columns:k cover:cover];
        BOOL isCoverRow = (cover && r == 0 && count == 1 && _pageCount > 1);
        CGFloat x = isCoverRow
            ? floor(totalWidth / 2.0 + PV_PAGE_GAP / 2.0 + 0.5)
            : floor((totalWidth - [self widthOfRow:r columns:k cover:cover]) / 2.0 + 0.5);
        if (x < PV_EDGE_GAP) x = PV_EDGE_GAP;
        for (j = 0; j < count; j++) {
            f[first + j].origin.x = x;
            x += f[first + j].size.width + PV_PAGE_GAP;
        }
    }

    // The table now has the shape `k` and `cover` describe, and only here --
    // after every row of it has been written -- do they become the shape
    // queries may index it by. Every early return above leaves the previous
    // pair in place, which is the pair that still matches the table still up
    // there. Set together, because half of a shape is not a shape: a laid-out
    // count that has moved while the cover flag has not names rows that were
    // never built.
    _laidOutColumns = k;
    _laidOutCover   = cover;
    _layoutDirty = NO;
    _laidOut = YES;
    [self setFrameSize:NSMakeSize(totalWidth, totalHeight)];
    [self setNeedsDisplay:YES];
}

- (NSRect)rectForPage:(NSUInteger)index
{
    if (index >= _pageCount) return NSZeroRect;
    NSRect *f = [self frameArray];
    if (!f) return NSZeroRect;
    return f[index];
}

- (NSUInteger)firstPageOfRowContainingPage:(NSUInteger)index
{
    if (_pageCount == 0) return 0;
    if (index >= _pageCount) index = _pageCount - 1;
    return PVFirstPageOfRowContainingPage(index, [self laidOutColumns],
                                          [self laidOutCover]);
}

- (NSRect)rectForRowContainingPage:(NSUInteger)index
{
    if (index >= _pageCount) return NSZeroRect;
    NSUInteger k     = [self laidOutColumns];
    BOOL       cover = [self laidOutCover];
    NSUInteger row   = PVRowContainingPage(index, k, cover);
    NSUInteger first = PVFirstPageOfRow(row, k, cover);
    NSUInteger count = [self pagesInRow:row columns:k cover:cover], j;
    NSRect r = [self rectForPage:first];
    for (j = 1; j < count; j++) r = NSUnionRect(r, [self rectForPage:first + j]);
    return r;
}

- (CGSize)pixelSizeForPage:(NSUInteger)index
{
    NSRect r = [self rectForPage:index];
    return CGSizeMake(r.size.width * _backingScale, r.size.height * _backingScale);
}

- (NSRange)pageRangeInRect:(NSRect)rect
{
    // Before -setZoom:... has run every frame is NSZeroRect, and the search
    // below would then match every page in the document. On a large PDF that
    // turned the pre-layout draw into a full-length loop over thousands of
    // degenerate rects.
    if (_pageCount == 0 || !_laidOut || _rowCount == 0) return NSMakeRange(0, 0);
    PVPageRow *rows = [self rowArray];
    if (!rows) return NSMakeRange(0, 0);

    // Rows are stacked in increasing y, so a binary search finds the first one
    // whose bottom edge is still below the top of the rect. Over rows and not
    // over pages: see PVPageRow for why the page frames are not something a
    // binary search may be run against once a row can hold two of them.
    NSUInteger lo = 0, hi = _rowCount - 1, first = _rowCount;
    while (lo <= hi) {
        NSUInteger mid = lo + (hi - lo) / 2;
        if (rows[mid].y + rows[mid].height >= NSMinY(rect)) {
            first = mid;
            if (mid == 0) break;
            hi = mid - 1;
        } else {
            lo = mid + 1;
        }
    }
    if (first >= _rowCount) return NSMakeRange(_pageCount - 1, 0);

    NSUInteger last = first;
    while (last + 1 < _rowCount && rows[last + 1].y <= NSMaxY(rect)) last++;

    NSUInteger k     = [self laidOutColumns];
    BOOL       cover = [self laidOutCover];
    NSUInteger firstPage = PVFirstPageOfRow(first, k, cover);
    // The last page of the last row, asked for as a count rather than assumed
    // to be a full row's worth. In the cover layout row zero is short, so
    // `first row + k - 1` names a page that is in the NEXT row -- a range one
    // page too long, which asks the render queue for a page that is not on
    // screen at every scroll position that shows the cover.
    NSUInteger lastCount = [self pagesInRow:last columns:k cover:cover];
    NSUInteger lastPage  = PVFirstPageOfRow(last, k, cover) +
                           (lastCount ? lastCount - 1 : 0);
    if (lastPage >= _pageCount) lastPage = _pageCount - 1;
    if (firstPage > lastPage) firstPage = lastPage;
    return NSMakeRange(firstPage, lastPage - firstPage + 1);
}

- (NSUInteger)pageAtTopOfRect:(NSRect)rect fraction:(CGFloat *)outFraction
{
    NSRange r = [self pageRangeInRect:rect];
    NSUInteger p = r.location;
    if (p >= _pageCount) p = _pageCount ? _pageCount - 1 : 0;
    if (outFraction) {
        // Into the ROW, not into the page: the two pages of a spread occupy
        // the same band, and a fraction measured against one of them would not
        // survive being handed back to -scrollToPage:fraction:.
        NSRect f = [self rectForRowContainingPage:p];
        CGFloat frac = (f.size.height > 0) ? (NSMinY(rect) - NSMinY(f)) / f.size.height : 0;
        if (frac < 0) frac = 0;
        if (frac > 1) frac = 1;
        *outFraction = frac;
    }
    return p;
}

- (void)setNeedsDisplayForPage:(NSUInteger)index
{
    if (index >= _pageCount) return;
    [self setNeedsDisplayInRect:NSInsetRect([self rectForPage:index], -2, -2)];
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect
{
    const NSRect *rects = NULL;
    NSInteger rectCount = 0;
    [self getRectsBeingDrawn:&rects count:&rectCount];

    [_backgroundColor set];
    NSRectFillList(rects, rectCount);

    if (_pageCount == 0 || !_laidOut) return;

    CGContextRef ctx = (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];
    NSRange range = [self pageRangeInRect:dirtyRect];
    NSUInteger i;

    for (i = range.location; i < NSMaxRange(range) && i < _pageCount; i++) {
        NSRect r = [self rectForPage:i];
        if (!NSIntersectsRect(r, dirtyRect)) continue;

        // Cheap one-pixel drop shadow: a single extra rect fill, no blur pass.
        CGContextSetGrayFillColor(ctx, 0.28, 1.0);
        CGContextFillRect(ctx, NSRectToCGRect(NSOffsetRect(r, 1, 1)));

        CGContextSetGrayFillColor(ctx, 1.0, 1.0);
        CGContextFillRect(ctx, NSRectToCGRect(r));

        CGSize want = [self pixelSizeForPage:i];
        CGImageRef img = [_cache fullImageForPage:i pixelSize:want];
        BOOL exact = (img != NULL);
        if (!img) img = [_cache placeholderImageForPage:i];

        if (img) {
            // The cache hands out a borrowed reference. Nothing mutates the
            // cache between here and the blit today, which is the only reason
            // that is safe; one retain makes it safe regardless of what a
            // future -drawRect: ends up calling.
            CGImageRetain(img);
            CGContextSaveGState(ctx);
            CGContextClipToRect(ctx, NSRectToCGRect(r));
            // The view is flipped; images are not, so flip back around the page.
            CGContextTranslateCTM(ctx, r.origin.x, r.origin.y + r.size.height);
            CGContextScaleCTM(ctx, 1.0, -1.0);
            CGContextSetInterpolationQuality(ctx,
                exact ? kCGInterpolationNone : kCGInterpolationLow);
            CGContextDrawImage(ctx, CGRectMake(0, 0, r.size.width, r.size.height), img);
            CGContextRestoreGState(ctx);
            CGImageRelease(img);
        }

        CGContextSetGrayStrokeColor(ctx, 0.62, 1.0);
        CGContextSetLineWidth(ctx, 1.0);
        CGContextStrokeRect(ctx, NSRectToCGRect(NSInsetRect(r, 0.5, 0.5)));
    }
}

#pragma mark - Drag to pan

// Click and drag anywhere on the document to move it, the way a hand tool
// does. There is no text selection in this program and no tool palette to
// choose between, so the whole document area is the hand and the gesture needs
// no mode: a press that does not move is still just a press, and one that does
// is a pan.
//
// The content follows the hand. Drag upwards and the page goes up with the
// pointer, which uncovers what is below it and carries the reader forward
// through the document -- the same direction of travel as pushing the wheel
// away or swiping up on the trackpad, and the same as every other hand tool.
// The document is grabbed, not the scrollbar. (If the opposite is ever wanted,
// the two signs in -mouseDragged: are the whole of it.)
//
// Both axes, not just the vertical one. In a spread zoomed past the width of
// the window there is somewhere to go sideways, and a hand that could only
// move a document up and down would be the one place in the program where the
// horizontal scroll had to be found with the scroller.

// How far the mouse must travel before a press becomes a pan. Below this a
// click is a click: a hand resting on a mouse moves it a point or two while
// pressing the button, and without a deadband every click would nudge the
// document by that much.
#define PV_PAN_DEADBAND  3.0

- (BOOL)acceptsFirstMouse:(NSEvent *)event
{
    // A click that brings the window forward does not also pan it. Panning is
    // navigation within a document you are already reading; the first click on
    // a background window is how you choose which document that is, and
    // stealing it would move the page under a reader who was only activating
    // the window.
    return NO;
}

- (void)mouseDown:(NSEvent *)event
{
    NSClipView *clip = [[self enclosingScrollView] contentView];
    if (!clip) { [super mouseDown:event]; return; }

    // A press is the reader taking hold of the document, so an animated scroll
    // that is still running has been overruled. Cancelled before the anchor is
    // taken, so the offset recorded is the one the hand actually grabbed.
    [self cancelScrollAnimation];

    // And a pan that is somehow still open is ended before another begins.
    // Writing the flags below directly would clear _panMoved without popping
    // the cursor it stands for, and that push is then on the stack for the
    // rest of the session -- the closed hand left up over a document nobody
    // is dragging, which is the exact failure -endPan exists to prevent.
    //
    // Not defensive: a mouse-up is not guaranteed to arrive. A modal panel put
    // up mid-drag, a sheet opened from a notification, the process stopped
    // under a debugger and resumed -- each of them ends the drag by swallowing
    // its release, and the next press is then the second -mouseDown: in a row.
    [self endPan];

    // Clicking the page is now a gesture, so it is also how a reader says
    // which view they are addressing. The controller makes this view first
    // responder when the window opens and after the Go to Page sheet, but a
    // click on the thumbnail strip moves it -- and before the page could be
    // dragged there was no way to click your way back, only ⌘-something.
    [[self window] makeFirstResponder:self];

    _panning   = YES;
    _panMoved  = NO;
    _panAnchor = [event locationInWindow];
    _panOrigin = [clip documentVisibleRect].origin;
}

- (void)mouseDragged:(NSEvent *)event
{
    NSClipView *clip = [[self enclosingScrollView] contentView];
    if (!_panning || !clip) { [super mouseDragged:event]; return; }

    NSPoint p  = [event locationInWindow];
    CGFloat dx = p.x - _panAnchor.x;
    CGFloat dy = p.y - _panAnchor.y;
    if (!isfinite(dx) || !isfinite(dy)) return;

    if (!_panMoved) {
        if (fabs(dx) < PV_PAN_DEADBAND && fabs(dy) < PV_PAN_DEADBAND) return;
        _panMoved = YES;
        [[NSCursor closedHandCursor] push];
    }

    // Measured from the anchor every time rather than accumulated frame by
    // frame. An accumulating pan drifts away from the pointer: each frame's
    // rounding and each offset the scroll view clamps are lost, so after a
    // long drag the point under the hand is no longer the point the hand took
    // hold of. From the anchor, a clamp at the end of the document is simply
    // undone by dragging back.
    //
    // In WINDOW coordinates, and this is the whole reason the anchor is not
    // taken in the clip view's. A clip view's bounds origin IS the scroll
    // offset, so a window point converted into it moves as the document
    // scrolls: the delta then contains the travel already applied, the
    // subtraction below feeds its own output back in, and the document runs
    // away from the pointer instead of following it. The window does not move
    // during a drag, so the difference between two points in it is the
    // distance the hand has actually travelled and nothing else.
    //
    // Window coordinates are not flipped -- y grows upwards -- while the
    // scroll offset grows downwards, which is why the vertical term is added
    // and the horizontal one subtracted. Drag up: dy is positive, the offset
    // grows, the page rises with the hand and the reader goes forward. Drag
    // right: dx is positive, the offset shrinks, and the page follows the hand
    // to the right.
    NSScrollView *sv = [self enclosingScrollView];
    NSRect vis  = [clip documentVisibleRect];
    CGFloat maxX = NSWidth([self frame])  - NSWidth(vis);
    CGFloat maxY = NSHeight([self frame]) - NSHeight(vis);
    if (maxX < 0) maxX = 0;
    if (maxY < 0) maxY = 0;

    CGFloat x = _panOrigin.x - dx;
    CGFloat y = _panOrigin.y + dy;
    if (x < 0) x = 0; else if (x > maxX) x = maxX;
    if (y < 0) y = 0; else if (y > maxY) y = maxY;

    [clip scrollToPoint:NSMakePoint(x, y)];
    [sv reflectScrolledClipView:clip];
}

- (void)mouseUp:(NSEvent *)event
{
    if (!_panning) { [super mouseUp:event]; return; }
    [self endPan];
}

// The one place the pan is unwound, so the pushed cursor is popped exactly
// once however the gesture ended -- released, cancelled, or the window taken
// out from under it. An unbalanced push leaves the closed hand on screen for
// the rest of the session.
- (void)endPan
{
    if (_panMoved) [NSCursor pop];
    _panning  = NO;
    _panMoved = NO;
}

#pragma mark - Keyboard

// The one place the document's vertical offset is written, animated or not.
//
// Returns where the clip view ACTUALLY ended up, read back afterwards rather
// than reported from the request. Two things move it: the document being
// shorter than the request, and AppKit rounding the offset onto a device
// pixel. The second is half a point at most and would not matter anywhere
// else, but the animation's next frame compares where the view is against
// where this method put it in order to notice a scroll from somewhere else --
// and a comparison against a number the view was never at reads its own
// rounding as somebody else's scroll, and abandons the animation on the first
// frame of every press.
- (CGFloat)scrollToY:(CGFloat)y
{
    NSScrollView *sv = [self enclosingScrollView];
    NSClipView *clip = [sv contentView];
    if (!clip) return 0;
    NSRect vis = [clip documentVisibleRect];
    CGFloat maxY = NSHeight([self frame]) - NSHeight(vis);
    if (maxY < 0) maxY = 0;
    if (!isfinite(y)) y = NSMinY(vis);
    if (y > maxY) y = maxY;
    if (y < 0) y = 0;
    [clip scrollToPoint:NSMakePoint(NSMinX(vis), y)];
    [sv reflectScrolledClipView:clip];
    return NSMinY([clip documentVisibleRect]);
}

// The immediate jump: what every key has always done, and what the arrow keys
// still do on battery. Cancels an animation first, so a held Down that ends in
// a Page Down does not have the two of them writing the offset in turn.
- (void)scrollByPoints:(CGFloat)dy
{
    [self cancelScrollAnimation];
    NSClipView *clip = [[self enclosingScrollView] contentView];
    if (!clip) return;
    [self scrollToY:NSMinY([clip documentVisibleRect]) + dy];
}

#pragma mark - Animated scrolling

- (BOOL)isScrollAnimating { return _scrollTimer != nil; }

- (void)cancelScrollAnimation
{
    if (!_scrollTimer) return;
    [_scrollTimer invalidate];
    // The timer holds the only reference this object has to it, and it has
    // just been told to let go of its target; releasing here is what keeps the
    // ivar from being a dangling pointer the next -isScrollAnimating reads.
    [_scrollTimer release];
    _scrollTimer = nil;
}

// Should this press be animated?
//
// Two conditions, and neither of them is a preference the user has to find. The
// power source is the one section 4.2 already decides every other cost by, and
// the accessibility setting is the one the system has for people who have asked
// not to be shown movement -- it is 10.12 and later, so it is asked for by
// selector and its absence on Mavericks means the same as it being off.
- (BOOL)shouldAnimateScroll
{
    if (!PVSmoothScrollForPower(PVCurrentPowerSource())) return NO;
    NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    if ([ws respondsToSelector:@selector(accessibilityDisplayShouldReduceMotion)] &&
        [ws accessibilityDisplayShouldReduceMotion])
        return NO;
    return YES;
}

// Scroll by `dy`, over PV_SMOOTH_SCROLL_SECONDS rather than at once.
//
// The travel is exactly the travel of the jump this replaces. That is the
// property the retarget below exists to preserve: a second press arriving
// mid-animation adds its step to the DESTINATION, not to wherever the document
// has got to, so holding the key down for n presses covers n steps and not
// some fraction of them that depends on the key repeat rate. Without that, the
// same keystrokes would move the reader a different distance on mains than on
// battery, and the showdown's travel fairness check -- which is measured in
// pages moved per keystroke -- would be comparing two different documents'
// worth of scrolling.
- (void)scrollByPoints:(CGFloat)dy animated:(BOOL)animated
{
    if (!animated || !isfinite(dy) || dy == 0) { [self scrollByPoints:dy]; return; }

    NSClipView *clip = [[self enclosingScrollView] contentView];
    if (!clip) return;
    CGFloat now = NSMinY([clip documentVisibleRect]);

    // A running animation whose destination is still ahead of the document is
    // extended; anything else starts from where the document actually is. The
    // second case covers the animation that has landed, and the one that was
    // abandoned because something else scrolled the view.
    //
    // "Running" is not enough on its own, and the extra term is the same test
    // the tick makes: is this animation still the only thing moving the
    // document? A timer that is alive has not necessarily been asked yet --
    // the wheel, a scroller drag or a restore can land in the sixtieth of a
    // second between two frames -- and adding a step to _scrollTo there would
    // carry the reader to a destination measured from before that scroll,
    // which is a keystroke landing somewhere it was never aimed. Asked here
    // because this is the only other place _scrollTo is read.
    BOOL stillOurs = (_scrollTimer != nil) &&
                     (fabs(now - _scrollLastSet) <= PV_SMOOTH_SCROLL_EPSILON);
    CGFloat base = stillOurs ? _scrollTo : now;
    CGFloat maxY = NSHeight([self frame]) - NSHeight([clip documentVisibleRect]);
    if (maxY < 0) maxY = 0;
    CGFloat target = base + dy;
    if (target > maxY) target = maxY;
    if (target < 0) target = 0;

    // Already there -- the top of the document with Up held down, the bottom
    // with Down -- so there is nothing to animate and no timer worth waking
    // the processor for.
    if (fabs(target - now) < PV_SMOOTH_SCROLL_EPSILON) {
        [self cancelScrollAnimation];
        [self scrollToY:target];
        return;
    }

    _scrollFrom  = now;
    _scrollTo    = target;
    _scrollStart = PVMonotonicSeconds();
    // Re-based on every press, so the easing restarts from the document's
    // current speed rather than decelerating into a destination that has since
    // moved. A reader holding the key down sees one continuous movement.

    // Where the view is at the moment this animation takes charge of it. Every
    // frame from here on checks, against this, that it is still the only thing
    // moving the document.
    //
    // Stated whenever the press is starting from the document's actual
    // position rather than extending its own destination -- which is a timer
    // that does not exist yet OR one whose view has been scrolled out from
    // under it. The second case is a real keystroke and it used to be dropped:
    // the wheel moves the document between two frames, the arrow press
    // correctly re-bases on where it now is, and then the very next frame
    // compares that position against an offset from before the wheel, decides
    // somebody else is scrolling, and cancels -- so the press moves nothing at
    // all. Reproduced: a press in that window travelled 0 pt instead of 92.6.
    // The animation has just taken charge again, and this is it saying so.
    if (!stillOurs) _scrollLastSet = now;

    if (!_scrollTimer) {
        _scrollTimer = [[NSTimer timerWithTimeInterval:(1.0 / PV_SMOOTH_SCROLL_HZ)
                                                target:self
                                              selector:@selector(scrollAnimationTick:)
                                              userInfo:nil
                                               repeats:YES] retain];
        // Common modes, so the animation does not freeze for the length of a
        // menu tracking loop or a live resize and then jump to its destination
        // when the loop ends. It is a 140 ms animation; stalling it is more
        // visible than it running.
        [[NSRunLoop currentRunLoop] addTimer:_scrollTimer
                                     forMode:NSRunLoopCommonModes];
    }
}

- (void)scrollAnimationTick:(NSTimer *)timer
{
    NSClipView *clip = [[self enclosingScrollView] contentView];
    if (!clip) { [self cancelScrollAnimation]; return; }

    // Somebody else moved the document: a wheel, a trackpad, the scroller, or
    // the controller restoring a position. Whoever it was is more current than
    // an animation that was already in flight, so this one gets out of the way
    // rather than dragging the view back.
    //
    // Checked by comparing against the offset this view last WROTE, which is
    // the only way to notice a scroll that arrived through a path this class
    // deliberately does not override -- -scrollWheel: is not overridden here
    // and must not be, because responsive scrolling is conditioned on that.
    CGFloat now = NSMinY([clip documentVisibleRect]);
    if (fabs(now - _scrollLastSet) > PV_SMOOTH_SCROLL_EPSILON) {
        [self cancelScrollAnimation];
        return;
    }

    double elapsed = PVMonotonicSeconds() - _scrollStart;
    double t = elapsed / PV_SMOOTH_SCROLL_SECONDS;
    // A clock that ran backwards -- which PVMonotonicSeconds is chosen to
    // prevent, and which is still not worth spreading over a hundred frames --
    // ends the animation on its destination.
    if (!isfinite(t) || t < 0) t = 1.0;

    CGFloat y = _scrollFrom +
                (CGFloat)(PVSmoothScrollEase(t) * (double)(_scrollTo - _scrollFrom));
    _scrollLastSet = [self scrollToY:y];

    if (t >= 1.0 || fabs(_scrollTo - _scrollLastSet) < PV_SMOOTH_SCROLL_EPSILON) {
        // Land exactly, then stop. The last eased frame is within half a point
        // of the destination and not on it, and a scroll that stops half a
        // point short of a page boundary every time accumulates.
        _scrollLastSet = [self scrollToY:_scrollTo];
        [self cancelScrollAnimation];
    }
}

// A view with no window has nothing to animate into, and its timer would go on
// retaining it -- and the document behind it -- for as long as the run loop
// lives. This is the path a closing document actually takes: the controller
// detaches the whole view tree from the window on teardown.
- (void)viewWillMoveToWindow:(NSWindow *)newWindow
{
    if (!newWindow) {
        [self cancelScrollAnimation];
        [self endPan];
    }
    [super viewWillMoveToWindow:newWindow];
}

- (void)keyDown:(NSEvent *)event
{
    NSString *chars = [event charactersIgnoringModifiers];
    if ([chars length] == 0) { [super keyDown:event]; return; }

    unichar c = [chars characterAtIndex:0];
    BOOL shift = ([event modifierFlags] & NSShiftKeyMask) != 0;
    NSRect vis = [[[self enclosingScrollView] contentView] documentVisibleRect];
    CGFloat page = NSHeight(vis) - 40.0;
    if (page < 40) page = NSHeight(vis);
    // One eighth of a screenful, bounded. See PV_ARROW_VIEWPORT_FRACTION for
    // why this is a fraction of the viewport and not the flat 60 pt it was.
    CGFloat line = PVArrowScrollForViewportHeight(NSHeight(vis));

    // Only the arrow keys are animated, and only where the animation is free.
    //
    // The arrow is the key a reader HOLDS -- it is the one whose whole job is
    // to move the page a little at a time, and the only one where a jump per
    // press reads as the document stepping rather than scrolling. Space and
    // Page Down are deliberately left alone: a screenful is a jump on purpose,
    // and 140 ms of a whole viewport sliding past is a longer wait for the
    // page you asked for, not a smoother one. Home and End are jumps by
    // definition.
    //
    // Asked inside the two arrow cases rather than above the switch. It reads
    // the power source and the accessibility setting, and every other key here
    // -- and every key that falls through to -super, which is most of them --
    // was paying for an answer that could not change what it did.

    switch (c) {
        case ' ':                       [self scrollByPoints:shift ? -page : page]; return;
        case NSPageDownFunctionKey:     [self scrollByPoints:page];   return;
        case NSPageUpFunctionKey:       [self scrollByPoints:-page];  return;
        case NSDownArrowFunctionKey:
            [self scrollByPoints:line  animated:[self shouldAnimateScroll]]; return;
        case NSUpArrowFunctionKey:
            [self scrollByPoints:-line animated:[self shouldAnimateScroll]]; return;
        case NSHomeFunctionKey:         [self scrollByPoints:-1e9];   return;
        case NSEndFunctionKey:          [self scrollByPoints:1e9];    return;
        default: break;
    }
    [super keyDown:event];
}

@end
