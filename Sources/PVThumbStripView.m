#import "PVThumbStripView.h"

#define PV_ROW_H (PV_THUMB_BOX_H + PV_THUMB_LABEL_H + PV_THUMB_GAP)

@implementation PVThumbStripView

- (id)initWithSource:(PVPDFSource *)source cache:(PVImageCache *)cache
{
    self = [super initWithFrame:NSMakeRect(0, 0, PV_THUMB_BOX_W + 24, 200)];
    if (!self) return nil;
    if (!source || !cache) { [self release]; return nil; }
    PVLiveAdjust("PVThumbStripView", +1);
    _source       = [source retain];
    _cache        = [cache retain];
    _pageCount    = [source pageCount];
    _backingScale = 1.0;

    NSMutableParagraphStyle *ps = [[[NSMutableParagraphStyle alloc] init] autorelease];
    [ps setAlignment:NSCenterTextAlignment];
    _labelAttrs = [[NSDictionary alloc] initWithObjectsAndKeys:
        [NSFont systemFontOfSize:10], NSFontAttributeName,
        [NSColor colorWithCalibratedWhite:0.25 alpha:1.0], NSForegroundColorAttributeName,
        ps, NSParagraphStyleAttributeName, nil];
    _labelAttrsSelected = [[NSDictionary alloc] initWithObjectsAndKeys:
        [NSFont boldSystemFontOfSize:10], NSFontAttributeName,
        [NSColor whiteColor], NSForegroundColorAttributeName,
        ps, NSParagraphStyleAttributeName, nil];

    [self setFrameSize:NSMakeSize(PV_THUMB_BOX_W + 24,
                                  PV_THUMB_GAP + _pageCount * PV_ROW_H)];
    return self;
}

- (void)dealloc
{
    PVLiveAdjust("PVThumbStripView", -1);
    [_labelAttrsSelected release];
    [_labelAttrs release];
    [_cache release];
    [_source release];
    [super dealloc];
}

+ (BOOL)isCompatibleWithResponsiveScrolling { return YES; }
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque  { return YES; }

- (void)setDelegate:(id <PVThumbStripDelegate>)delegate { _delegate = delegate; }
- (CGFloat)requiredWidth { return PV_THUMB_BOX_W + 24; }
- (void)setBackingScale:(CGFloat)scale { _backingScale = (scale < 1.0) ? 1.0 : scale; }

- (void)setCurrentPage:(NSUInteger)page
{
    if (page == _currentPage || page >= _pageCount) return;
    NSUInteger old = _currentPage;
    _currentPage = page;
    [self setNeedsDisplayForPage:old];
    [self setNeedsDisplayForPage:page];
}

- (NSRect)rectForPage:(NSUInteger)index
{
    if (index >= _pageCount) return NSZeroRect;
    return NSMakeRect(12, PV_THUMB_GAP + index * PV_ROW_H, PV_THUMB_BOX_W, PV_THUMB_BOX_H);
}

// The thumbnail is aspect-fitted inside the fixed box, so rows stay uniform.
- (NSRect)imageRectForPage:(NSUInteger)index
{
    NSRect box = [self rectForPage:index];
    CGSize p = [_source pointSizeOfPage:index];
    if (p.width < 1 || p.height < 1) return box;
    CGFloat s = fmin(box.size.width / p.width, box.size.height / p.height);
    CGFloat w = floor(p.width * s + 0.5), h = floor(p.height * s + 0.5);
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    return NSMakeRect(floor(NSMidX(box) - w / 2.0 + 0.5),
                      floor(NSMidY(box) - h / 2.0 + 0.5), w, h);
}

- (CGSize)pixelSizeForPage:(NSUInteger)index
{
    NSRect r = [self imageRectForPage:index];
    return CGSizeMake(r.size.width * _backingScale, r.size.height * _backingScale);
}

- (NSRange)pageRangeInRect:(NSRect)rect
{
    if (_pageCount == 0) return NSMakeRange(0, 0);
    NSInteger first = (NSInteger)floor((NSMinY(rect) - PV_THUMB_GAP) / PV_ROW_H);
    NSInteger last  = (NSInteger)ceil((NSMaxY(rect) - PV_THUMB_GAP) / PV_ROW_H);
    if (first < 0) first = 0;
    if (last >= (NSInteger)_pageCount) last = (NSInteger)_pageCount - 1;
    if (last < first) return NSMakeRange(0, 0);
    return NSMakeRange((NSUInteger)first, (NSUInteger)(last - first + 1));
}

- (void)setNeedsDisplayForPage:(NSUInteger)index
{
    if (index >= _pageCount) return;
    NSRect r = [self rectForPage:index];
    r.size.height += PV_THUMB_LABEL_H;
    [self setNeedsDisplayInRect:NSInsetRect(r, -6, -6)];
}

- (void)drawRect:(NSRect)dirtyRect
{
    const NSRect *rects = NULL;
    NSInteger rectCount = 0;
    [self getRectsBeingDrawn:&rects count:&rectCount];
    [[NSColor colorWithCalibratedWhite:0.90 alpha:1.0] set];
    NSRectFillList(rects, rectCount);

    CGContextRef ctx = (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];
    NSRange range = [self pageRangeInRect:dirtyRect];
    NSUInteger i;

    for (i = range.location; i < NSMaxRange(range) && i < _pageCount; i++) {
        NSRect box = [self rectForPage:i];
        NSRect lbl = NSMakeRect(0, NSMaxY(box) + 1, NSWidth([self frame]), PV_THUMB_LABEL_H);
        BOOL selected = (i == _currentPage);

        if (selected) {
            [[NSColor colorWithCalibratedRed:0.20 green:0.44 blue:0.82 alpha:1.0] set];
            NSRectFill(NSInsetRect(NSUnionRect(box, lbl), -5, -4));
        }

        NSRect ir = [self imageRectForPage:i];
        CGContextSetGrayFillColor(ctx, 1.0, 1.0);
        CGContextFillRect(ctx, NSRectToCGRect(ir));

        CGImageRef img = [_cache placeholderImageForPage:i];
        if (img) {
            CGImageRetain(img);          // borrowed from the cache; see PVPageView
            CGContextSaveGState(ctx);
            CGContextTranslateCTM(ctx, ir.origin.x, ir.origin.y + ir.size.height);
            CGContextScaleCTM(ctx, 1.0, -1.0);
            CGContextSetInterpolationQuality(ctx, kCGInterpolationLow);
            CGContextDrawImage(ctx, CGRectMake(0, 0, ir.size.width, ir.size.height), img);
            CGContextRestoreGState(ctx);
            CGImageRelease(img);
        }

        CGContextSetGrayStrokeColor(ctx, 0.55, 1.0);
        CGContextSetLineWidth(ctx, 1.0);
        CGContextStrokeRect(ctx, NSRectToCGRect(NSInsetRect(ir, 0.5, 0.5)));

        NSString *num = [NSString stringWithFormat:@"%lu", (unsigned long)(i + 1)];
        [num drawInRect:lbl withAttributes:selected ? _labelAttrsSelected : _labelAttrs];
    }
}

- (void)mouseDown:(NSEvent *)event
{
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    NSInteger idx = (NSInteger)floor((p.y - PV_THUMB_GAP) / PV_ROW_H);
    if (idx < 0 || idx >= (NSInteger)_pageCount) return;
    // A row is taller than the thumbnail plus its label by PV_THUMB_GAP. The
    // division above maps that gap onto the row above it, so a click in the
    // empty space between two thumbnails used to jump the document. Only the
    // occupied part of the row counts; the full width does, as in any list.
    NSRect row = NSMakeRect(0, PV_THUMB_GAP + (CGFloat)idx * PV_ROW_H,
                            NSWidth([self bounds]), PV_THUMB_BOX_H + PV_THUMB_LABEL_H);
    if (!NSPointInRect(p, row)) return;
    [self setCurrentPage:(NSUInteger)idx];
    [_delegate thumbStrip:self didChoosePage:(NSUInteger)idx];
}

@end
