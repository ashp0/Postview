#import "PVPageView.h"

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
    _backgroundColor = [[NSColor colorWithCalibratedWhite:0.42 alpha:1.0] retain];
    return self;
}

- (void)dealloc
{
    PVLiveAdjust("PVPageView", -1);
    [_backgroundColor release];
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
- (void)setDelegate:(id <PVPageViewDelegate>)delegate { _delegate = delegate; }

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
- (BOOL)isLaidOut { return _laidOut; }

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
    // always go through.
    if (_laidOut && zoom == _zoom && scale == _backingScale && contentWidth == _contentWidth)
        return;

    _zoom = zoom;
    _backingScale = scale;
    _contentWidth = contentWidth;

    NSRect *f = [self frameArray];
    if (!f && _pageCount > 0) return;      // allocation failed; nothing is safe to lay out
    CGFloat y = PV_EDGE_GAP;
    CGFloat widest = 0;
    NSUInteger i;

    for (i = 0; i < _pageCount; i++) {
        CGSize p = [_source pointSizeOfPage:i];
        // Round the on-screen size to whole points first, then derive the pixel
        // size from it. That guarantees bitmap pixels land exactly on device
        // pixels, so the common case is a 1:1 blit with no resampling at all.
        CGFloat w = floor(p.width  * _zoom + 0.5);
        CGFloat h = floor(p.height * _zoom + 0.5);
        if (w < 1) w = 1;
        if (h < 1) h = 1;
        f[i] = NSMakeRect(0, y, w, h);
        if (w > widest) widest = w;
        y += h + PV_PAGE_GAP;
    }

    CGFloat totalHeight = (_pageCount > 0) ? (y - PV_PAGE_GAP + PV_EDGE_GAP) : PV_EDGE_GAP * 2;
    CGFloat totalWidth  = widest + PV_EDGE_GAP * 2;
    if (totalWidth < _contentWidth) totalWidth = _contentWidth;

    // Centre the page column horizontally within whatever width we end up with.
    for (i = 0; i < _pageCount; i++) {
        f[i].origin.x = floor((totalWidth - f[i].size.width) / 2.0 + 0.5);
        if (f[i].origin.x < PV_EDGE_GAP) f[i].origin.x = PV_EDGE_GAP;
    }

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
    if (_pageCount == 0 || !_laidOut) return NSMakeRange(0, 0);
    NSRect *f = [self frameArray];
    if (!f) return NSMakeRange(0, 0);

    // Pages are stacked in increasing y, so a binary search finds the first one
    // whose bottom edge is still below the top of the rect.
    NSUInteger lo = 0, hi = _pageCount - 1, first = _pageCount;
    while (lo <= hi) {
        NSUInteger mid = lo + (hi - lo) / 2;
        if (NSMaxY(f[mid]) >= NSMinY(rect)) {
            first = mid;
            if (mid == 0) break;
            hi = mid - 1;
        } else {
            lo = mid + 1;
        }
    }
    if (first >= _pageCount) return NSMakeRange(_pageCount ? _pageCount - 1 : 0, 0);

    NSUInteger last = first;
    while (last + 1 < _pageCount && NSMinY(f[last + 1]) <= NSMaxY(rect)) last++;
    return NSMakeRange(first, last - first + 1);
}

- (NSUInteger)pageAtTopOfRect:(NSRect)rect fraction:(CGFloat *)outFraction
{
    NSRange r = [self pageRangeInRect:rect];
    NSUInteger p = r.location;
    if (p >= _pageCount) p = _pageCount ? _pageCount - 1 : 0;
    if (outFraction) {
        NSRect f = [self rectForPage:p];
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

#pragma mark - Keyboard

- (void)scrollByPoints:(CGFloat)dy
{
    NSClipView *clip = [[self enclosingScrollView] contentView];
    if (!clip) return;
    NSRect vis = [clip documentVisibleRect];
    CGFloat maxY = NSHeight([self frame]) - NSHeight(vis);
    CGFloat y = NSMinY(vis) + dy;
    if (y > maxY) y = maxY;
    if (y < 0) y = 0;
    [clip scrollToPoint:NSMakePoint(NSMinX(vis), y)];
    [[self enclosingScrollView] reflectScrolledClipView:clip];
}

- (void)keyDown:(NSEvent *)event
{
    NSString *chars = [event charactersIgnoringModifiers];
    if ([chars length] == 0) { [super keyDown:event]; return; }

    unichar c = [chars characterAtIndex:0];
    BOOL shift = ([event modifierFlags] & NSEventModifierFlagShift) != 0;
    NSRect vis = [[[self enclosingScrollView] contentView] documentVisibleRect];
    CGFloat page = NSHeight(vis) - 40.0;
    if (page < 40) page = NSHeight(vis);
    // One eighth of a screenful, bounded. See PV_ARROW_VIEWPORT_FRACTION for
    // why this is a fraction of the viewport and not the flat 60 pt it was.
    CGFloat line = PVArrowScrollForViewportHeight(NSHeight(vis));

    switch (c) {
        case ' ':                       [self scrollByPoints:shift ? -page : page]; return;
        case NSPageDownFunctionKey:     [self scrollByPoints:page];   return;
        case NSPageUpFunctionKey:       [self scrollByPoints:-page];  return;
        case NSDownArrowFunctionKey:    [self scrollByPoints:line];   return;
        case NSUpArrowFunctionKey:      [self scrollByPoints:-line];  return;
        case NSHomeFunctionKey:         [self scrollByPoints:-1e9];   return;
        case NSEndFunctionKey:          [self scrollByPoints:1e9];    return;
        default: break;
    }
    [super keyDown:event];
}

@end
