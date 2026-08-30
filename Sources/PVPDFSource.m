#import "PVPDFSource.h"

// Layout is deliberately precomputed so neither the main thread nor the
// renderer has to ask CoreGraphics for page geometry again.  Put a finite
// bound on that up front: an intentionally hostile PDF can otherwise name
// enough pages to make the bookkeeping allocations overflow or exhaust the
// machine before it has displayed anything useful.  One hundred thousand
// pages is already far beyond the documents this viewer can present well on
// its target hardware (and still leaves the two geometry tables under 5 MB).
#define PV_MAX_PDF_PAGES ((size_t)100000)

static NSError *PVError(NSInteger code, NSString *desc, NSString *reason)
{
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (desc)   [info setObject:desc   forKey:NSLocalizedDescriptionKey];
    if (reason) [info setObject:reason forKey:NSLocalizedRecoverySuggestionErrorKey];
    return [NSError errorWithDomain:@"PostviewErrorDomain" code:code userInfo:info];
}

static BOOL PVFiniteScalar(CGFloat value)
{
    return isfinite((double)value);
}

static BOOL PVFiniteRect(CGRect rect)
{
    return (PVFiniteScalar(rect.origin.x) && PVFiniteScalar(rect.origin.y) &&
            PVFiniteScalar(rect.size.width) && PVFiniteScalar(rect.size.height) &&
            rect.size.width >= 0 && rect.size.height >= 0);
}

static BOOL PVFiniteTransform(CGAffineTransform transform)
{
    return (PVFiniteScalar(transform.a) && PVFiniteScalar(transform.b) &&
            PVFiniteScalar(transform.c) && PVFiniteScalar(transform.d) &&
            PVFiniteScalar(transform.tx) && PVFiniteScalar(transform.ty));
}

// The visible area of a page: the crop box, clipped to the media box, with
// sane fallbacks for malformed files.
static CGRect PVCropBox(CGPDFPageRef page)
{
    CGRect media = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
    CGRect box   = CGPDFPageGetBoxRect(page, kCGPDFCropBox);
    if (!PVFiniteRect(media)) media = CGRectZero;
    if (!PVFiniteRect(box) || CGRectIsEmpty(box) || CGRectIsNull(box)) {
        box = media;
    } else if (!CGRectIsEmpty(media)) {
        box = CGRectIntersection(box, media);
    }
    if (!PVFiniteRect(box) || CGRectIsEmpty(box) || CGRectIsNull(box) || CGRectIsInfinite(box))
        box = CGRectMake(0, 0, 612, 792);
    return box;
}

@implementation PVPDFSource

- (id)initWithURL:(NSURL *)url error:(NSError **)outError
{
    return [self initWithURL:url geometryFrom:nil error:outError];
}

- (id)initWithURL:(NSURL *)url geometryFrom:(PVPDFSource *)other error:(NSError **)outError
{
    self = [super init];
    if (!self) return nil;

    PVLiveAdjust("PVPDFSource", +1);
    // CoreGraphics' create routine is a C API and its NULL-argument contract
    // is not a useful recovery path.  Validate the one external input before
    // handing it over so an invalid URL is always an ordinary open failure.
    if (![url isKindOfClass:[NSURL class]] || ![url isFileURL]) {
        if (outError) *outError = PVError(1, @"This file could not be opened.",
            @"Postview can open local PDF files only.");
        [self release];
        return nil;
    }
    _url = [url copy];
    _doc = CGPDFDocumentCreateWithURL((CFURLRef)url);
    if (!_doc) {
        if (outError) *outError = PVError(2, @"This file could not be opened.",
            @"It does not appear to be a readable PDF document.");
        [self release];
        return nil;
    }
    if (CGPDFDocumentIsEncrypted(_doc) && !CGPDFDocumentIsUnlocked(_doc)) {
        if (outError) *outError = PVError(3, @"This PDF is password protected.",
            @"Postview cannot unlock encrypted documents. Open it in Preview, "
            @"then re-save it without a password.");
        [self release];
        return nil;
    }

    size_t pageCount = CGPDFDocumentGetNumberOfPages(_doc);
    if (pageCount == 0) {
        if (outError) *outError = PVError(4, @"This PDF has no pages.", nil);
        [self release];
        return nil;
    }
    if (pageCount > PV_MAX_PDF_PAGES || pageCount > (SIZE_MAX / sizeof(CGSize))) {
        if (outError) *outError = PVError(5, @"This PDF is too large to open safely.",
            @"It has more pages than Postview can lay out within its fixed memory limit.");
        [self release];
        return nil;
    }
    _pageCount = (NSUInteger)pageCount;

    // Precompute every page's displayed size once, so that layout on the main
    // thread never has to touch the CGPDFDocument again.
    _sizes = (CGSize *)calloc(_pageCount, sizeof(CGSize));
    if (!_sizes) {
        // Every other failure path here sets outError. This one did not, and
        // -[PVDocument readFromURL:] then returned NO with *outError still nil,
        // which is the one thing AppKit's open path is not prepared for.
        if (outError) *outError = PVError(6, @"This PDF could not be opened.",
            @"There was not enough memory to lay out its pages.");
        [self release];
        return nil;
    }

    if (other && other != self && [other pageCount] == _pageCount) {
        @try {
            NSUInteger i;
            _maxSize = CGSizeMake(1, 1);
            for (i = 0; i < _pageCount; i++) {
                CGSize s = [other pointSizeOfPage:i];
                if (!(s.width > 1) || s.width  > 20000) s.width  = 612;
                if (!(s.height > 1) || s.height > 20000) s.height = 792;
                _sizes[i] = s;
                if (s.width  > _maxSize.width)  _maxSize.width  = s.width;
                if (s.height > _maxSize.height) _maxSize.height = s.height;
            }
        } @catch (id exception) {
            if (outError) *outError = PVError(7, @"This PDF could not be opened.",
                @"Its page geometry could not be read safely.");
            [self release];
            return nil;
        }
        return self;
    }

    @try {
        _maxSize = CGSizeMake(1, 1);
        for (NSUInteger i = 0; i < _pageCount; i++) {
            CGSize s = CGSizeMake(612, 792);            // US Letter fallback
            CGPDFPageRef page = CGPDFDocumentGetPage(_doc, (size_t)i + 1);
            if (page) {
                CGRect box = PVCropBox(page);
                int rot = CGPDFPageGetRotationAngle(page) % 360;
                if (rot < 0) rot += 360;
                s = (rot == 90 || rot == 270)
                      ? CGSizeMake(box.size.height, box.size.width)
                      : box.size;
            }
            // Clamp pathological geometry so layout math stays sane.
            if (!(s.width  > 1) || s.width  > 20000) s.width  = 612;
            if (!(s.height > 1) || s.height > 20000) s.height = 792;
            _sizes[i] = s;
            if (s.width  > _maxSize.width)  _maxSize.width  = s.width;
            if (s.height > _maxSize.height) _maxSize.height = s.height;
        }
    } @catch (id exception) {
        if (outError) *outError = PVError(7, @"This PDF could not be opened.",
            @"Its page geometry could not be read safely.");
        [self release];
        return nil;
    }
    return self;
}

- (void)dealloc
{
    PVLiveAdjust("PVPDFSource", -1);
    if (_doc)   CGPDFDocumentRelease(_doc);
    if (_sizes) free(_sizes);
    [_url release];
    [super dealloc];
}

- (NSUInteger)pageCount            { return _pageCount; }
- (CGSize)maxPointSize             { return _maxSize; }

- (CGSize)pointSizeOfPage:(NSUInteger)index
{
    if (index >= _pageCount) return CGSizeMake(612, 792);
    return _sizes[index];
}

- (CGImageRef)createImageForPage:(NSUInteger)index pixelSize:(CGSize)px
{
    if (!_doc || index >= _pageCount) return NULL;
    // Rounding, the 1x1 floor and the pixel ceiling all live in
    // PVClampPixelSize so that the layer above can ask what it is going to get
    // without reimplementing the arithmetic. A non-finite request comes back
    // as a zero size and is refused here.
    CGSize use = PVClampPixelSize(px);
    if (!(use.width >= 1) || !(use.height >= 1)) return NULL;
    size_t w = (size_t)use.width;
    size_t h = (size_t)use.height;

    CGPDFPageRef page = CGPDFDocumentGetPage(_doc, (size_t)index + 1);
    if (!page) return NULL;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return NULL;
    // NoneSkipFirst + host byte order is the layout the window server blits
    // fastest; anything else forces a colour/format conversion on every draw.
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs,
        (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;

    // The pixels exist from here. Taken from the context rather than computed
    // from w*h*4 because CoreGraphics pads every row out to an alignment
    // boundary, and a census that understates by the padding is a census that
    // drifts further from the truth the narrower the page is.
    //
    // Balanced inside this one function, at every exit, so no caller can leak
    // it -- pvtest and pvuitest both call this method directly and neither
    // knows the census exists. The image that comes out is a separate claim
    // taken up by the render queue: see PVResidentUndelivered.
    size_t ctxBytes = CGBitmapContextGetBytesPerRow(ctx) * CGBitmapContextGetHeight(ctx);
    PVResidentAdd(PVResidentRender, ctxBytes);

    CGContextSetFillColorWithColor(ctx, CGColorGetConstantColor(kCGColorWhite));
    CGContextFillRect(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h));

    CGContextSetShouldAntialias(ctx, true);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    // The page background is always opaque white, so subpixel text rendering is
    // safe here and makes a real difference on non-Retina displays.
    CGContextSetShouldSmoothFonts(ctx, true);
    CGContextSetAllowsFontSubpixelPositioning(ctx, true);
    CGContextSetAllowsFontSubpixelQuantization(ctx, true);

    // CGPDFPageGetDrawingTransform only ever scales a page DOWN to fit; hand it
    // a rect bigger than the page and it silently centres the page at 100%
    // instead of filling. So ask it for the transform at the page's natural
    // size -- where it just handles the crop-box origin and /Rotate -- and do
    // the magnification ourselves.
    CGSize natural = (index < _pageCount && _sizes) ? _sizes[index] : CGSizeMake(612, 792);
    if (!(natural.width >= 1) || !(natural.height >= 1)) natural = CGSizeMake(612, 792);
    CGContextScaleCTM(ctx, (CGFloat)w / natural.width, (CGFloat)h / natural.height);

    CGAffineTransform t = CGPDFPageGetDrawingTransform(page, kCGPDFCropBox,
                              CGRectMake(0, 0, natural.width, natural.height), 0, true);
    // A malformed transform is not a recoverable drawing input.  Refuse it
    // before it reaches Quartz; returning NULL takes the bounded render-failure
    // path in PVRenderQueue instead of relying on undefined graphics behavior.
    if (!PVFiniteTransform(t)) {
        PVResidentSub(PVResidentRender, ctxBytes);
        CGContextRelease(ctx);
        return NULL;
    }
    CGContextConcatCTM(ctx, t);
    CGContextClipToRect(ctx, PVCropBox(page));
    CGContextDrawPDFPage(ctx, page);

    CGImageRef img = CGBitmapContextCreateImage(ctx);
    PVResidentSub(PVResidentRender, ctxBytes);
    CGContextRelease(ctx);
    return img;   // +1, caller releases
}

@end
