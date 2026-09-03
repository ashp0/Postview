#import "PVRenderCore.h"
#include "PVRenderProtocol.h"   /* PV_MAX_PDF_PAGES, which sizes the memo table */
#include <math.h>
#include <string.h>

static BOOL PVFiniteScalarCore(CGFloat value)
{
    return isfinite((double)value);
}

static BOOL PVFiniteRectCore(CGRect rect)
{
    return (PVFiniteScalarCore(rect.origin.x) &&
            PVFiniteScalarCore(rect.origin.y) &&
            PVFiniteScalarCore(rect.size.width) &&
            PVFiniteScalarCore(rect.size.height) &&
            rect.size.width >= 0 && rect.size.height >= 0);
}

static BOOL PVFiniteTransformCore(CGAffineTransform transform)
{
    return (PVFiniteScalarCore(transform.a) &&
            PVFiniteScalarCore(transform.b) &&
            PVFiniteScalarCore(transform.c) &&
            PVFiniteScalarCore(transform.d) &&
            PVFiniteScalarCore(transform.tx) &&
            PVFiniteScalarCore(transform.ty));
}

CGRect PVSafeCropBox(CGPDFPageRef page)
{
    if (!page) return CGRectMake(0, 0, 612, 792);
    CGRect media = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
    CGRect box = CGPDFPageGetBoxRect(page, kCGPDFCropBox);
    if (!PVFiniteRectCore(media)) media = CGRectZero;
    if (!PVFiniteRectCore(box) || CGRectIsEmpty(box) || CGRectIsNull(box)) {
        box = media;
    } else if (!CGRectIsEmpty(media)) {
        box = CGRectIntersection(box, media);
    }
    if (!PVFiniteRectCore(box) || CGRectIsEmpty(box) || CGRectIsNull(box) ||
        CGRectIsInfinite(box))
        box = CGRectMake(0, 0, 612, 792);
    return box;
}

int PVPageRotation(CGPDFPageRef page)
{
    if (!page) return 0;
    int rot = CGPDFPageGetRotationAngle(page) % 360;
    if (rot < 0) rot += 360;
    // Anything that is not a right angle is not something this viewer can lay
    // out, and the PDF specification does not permit it either. Treated as
    // upright rather than rounded to the nearest quadrant: a document that says
    // 37 degrees is a document making something up, and inventing a rotation
    // for it would only make the invention harder to see.
    if (rot != 90 && rot != 180 && rot != 270) rot = 0;
    return rot;
}

CGAffineTransform PVPageDrawingTransform(CGRect box, int rotation,
                                         size_t width, size_t height)
{
    double bw = (double)box.size.width;
    double bh = (double)box.size.height;
    if (!isfinite(bw) || !isfinite(bh) || !(bw > 0) || !(bh > 0) ||
        width == 0 || height == 0)
        return CGAffineTransformIdentity;

    // Content space -> upright display space, with the display corner at the
    // origin. /Rotate is clockwise as presented, and Quartz's y axis points up,
    // which is why 90 and 270 are not each other's transposes here.
    CGAffineTransform rotate;
    double dw, dh;
    switch (rotation) {
        case 90:
            rotate = CGAffineTransformMake(0, -1, 1, 0, 0, bw);
            dw = bh; dh = bw;
            break;
        case 180:
            rotate = CGAffineTransformMake(-1, 0, 0, -1, bw, bh);
            dw = bw; dh = bh;
            break;
        case 270:
            rotate = CGAffineTransformMake(0, 1, -1, 0, bh, 0);
            dw = bh; dh = bw;
            break;
        default:
            rotate = CGAffineTransformIdentity;
            dw = bw; dh = bh;
            break;
    }

    // Aspect-preserving fit, centred. The caller sizes its bitmap from the same
    // geometry, so the letterbox is normally zero and only ever absorbs the
    // sub-pixel rounding PVClampPixelSize leaves behind.
    double scale = (double)width / dw;
    double other = (double)height / dh;
    if (other < scale) scale = other;
    if (!isfinite(scale) || !(scale > 0)) return CGAffineTransformIdentity;

    double tx = ((double)width  - dw * scale) / 2.0;
    double ty = ((double)height - dh * scale) / 2.0;

    // Written in application order: move the crop box to the origin, rotate it,
    // scale it, then centre it.
    CGAffineTransform t =
        CGAffineTransformMakeTranslation(-box.origin.x, -box.origin.y);
    t = CGAffineTransformConcat(t, rotate);
    t = CGAffineTransformConcat(t, CGAffineTransformMakeScale(scale, scale));
    t = CGAffineTransformConcat(t, CGAffineTransformMakeTranslation(tx, ty));
    return t;
}

/* /F, PDF 1.7 table 8.16: bit 2 Hidden, bit 6 NoView. Both mean do not paint
 * this on screen, and a viewer that ignores them draws what the document asked
 * it to keep out of sight. */
enum { PVAnnotFlagHidden = (1 << 1), PVAnnotFlagNoView = (1 << 5) };

static BOOL PVAnnotationIsDrawable(CGPDFDictionaryRef annot)
{
    if (!annot) return NO;

    /* A popup is the window belonging to another annotation's note, drawn only
     * while that note is open and never as part of the page. */
    const char *subtype = NULL;
    if (CGPDFDictionaryGetName(annot, "Subtype", &subtype) && subtype &&
        strcmp(subtype, "Popup") == 0)
        return NO;

    CGPDFInteger flags = 0;
    if (CGPDFDictionaryGetInteger(annot, "F", &flags) &&
        (flags & (PVAnnotFlagHidden | PVAnnotFlagNoView)))
        return NO;

    /* No /AP is no appearance stream. Link annotations are the common case and
     * they draw nothing, which is why this is not simply "has annotations". */
    CGPDFDictionaryRef ap = NULL;
    if (!CGPDFDictionaryGetDictionary(annot, "AP", &ap) || !ap) return NO;

    /* /N is the appearance stream, or -- for a multi-state annotation such as a
     * checkbox -- a dictionary of them keyed by /AS. Either has something. */
    CGPDFObjectRef normal = NULL;
    if (!CGPDFDictionaryGetObject(ap, "N", &normal) || !normal) return NO;

    CGPDFObjectType type = CGPDFObjectGetType(normal);
    return (type == kCGPDFObjectTypeStream || type == kCGPDFObjectTypeDictionary);
}

/* Counters for PV_HELPER_DIAGNOSTICS. Plain statics because the helper serves
 * one command at a time on one thread, and because the viewer never compiles
 * this path at all -- PVAnnotationRender is in the helper's object list alone.
 * Nothing branches on them: a diagnostic that changed behaviour would be a
 * second code path to reason about, and this file is on the render hot path. */
static PVAnnotationStats gAnnotStats;

PVAnnotationStats PVAnnotationStatsSnapshot(void)
{
    return gAnnotStats;
}

BOOL PVPageHasDrawableAnnotations(CGPDFPageRef page)
{
    if (!page) return NO;
    CGPDFDictionaryRef dict = CGPDFPageGetDictionary(page);
    if (!dict) return NO;

    CGPDFArrayRef annots = NULL;
    if (!CGPDFDictionaryGetArray(dict, "Annots", &annots) || !annots) return NO;

    gAnnotStats.probed++;

    /* The length comes out of the document, so this loop used to be bounded by
     * nothing at all. Past the cap the page is answered YES unread, which is
     * the safe direction: a wrong YES costs a slower render, a wrong NO draws
     * the page blank. See PV_MAX_ANNOTS_SCAN. */
    size_t count = CGPDFArrayGetCount(annots), i;
    if (count > PV_MAX_ANNOTS_SCAN) {
        gAnnotStats.capped++;
        return YES;
    }

    for (i = 0; i < count; i++) {
        CGPDFDictionaryRef annot = NULL;
        if (CGPDFArrayGetDictionary(annots, i, &annot) &&
            PVAnnotationIsDrawable(annot))
            return YES;
    }
    return NO;
}

/* --- The memo table ------------------------------------------------------- */
/*
 * Two bits per page, sized at compile time from the same constant the protocol
 * refuses a longer document with, so nothing the helper is allowed to open can
 * outgrow it. 25000 bytes of BSS: untouched in a process that never opens an
 * annotated document, and never allocated, resized or freed.
 */
#define PV_ANNOT_MEMO_BYTES ((size_t)((PV_MAX_PDF_PAGES + 3) / 4))

enum { PVAnnotUnknown = 0, PVAnnotClean = 1, PVAnnotNeedsPDFKit = 2 };

static unsigned char gAnnotMemo[PV_ANNOT_MEMO_BYTES];
static size_t        gAnnotMemoPages;

void PVAnnotationMemoReset(size_t pageCount)
{
    if (pageCount > (size_t)PV_MAX_PDF_PAGES) pageCount = (size_t)PV_MAX_PDF_PAGES;
    gAnnotMemoPages = pageCount;
    /* Only the prefix in use: a hundred-page document does not pay to clear the
     * hundred thousand the table could hold. */
    memset(gAnnotMemo, 0, (pageCount + 3) / 4);
    memset(&gAnnotStats, 0, sizeof gAnnotStats);
}

static unsigned PVAnnotMemoGet(size_t page)
{
    return (unsigned)((gAnnotMemo[page >> 2] >> ((page & 3u) * 2u)) & 3u);
}

static void PVAnnotMemoSet(size_t page, unsigned value)
{
    unsigned char *slot = &gAnnotMemo[page >> 2];
    unsigned shift = (unsigned)((page & 3u) * 2u);
    *slot = (unsigned char)((*slot & ~(3u << shift)) | ((value & 3u) << shift));
}

BOOL PVPageNeedsAnnotationDraw(CGPDFPageRef page, size_t zeroBasedPage)
{
    /* A page outside the table is answered correctly, just not remembered. The
     * protocol makes that unreachable for a document this helper opened; it is
     * here so the bound is enforced by arithmetic rather than by trusting a
     * caller two processes away to have checked. */
    if (zeroBasedPage >= gAnnotMemoPages)
        return PVPageHasDrawableAnnotations(page);

    unsigned cached = PVAnnotMemoGet(zeroBasedPage);
    if (cached != PVAnnotUnknown) {
        gAnnotStats.memoHits++;
        return (cached == PVAnnotNeedsPDFKit) ? YES : NO;
    }

    BOOL needs = PVPageHasDrawableAnnotations(page);
    PVAnnotMemoSet(zeroBasedPage, needs ? PVAnnotNeedsPDFKit : PVAnnotClean);
    return needs;
}

/* Set once, before any render, by the helper's main(). Not synchronised for
 * that reason: it is written before the first command is read and only read
 * afterwards. */
static PVAnnotationDrawHook gAnnotationDrawHook = NULL;

void PVSetAnnotationDrawHook(PVAnnotationDrawHook hook)
{
    gAnnotationDrawHook = hook;
}

PVRenderCoreResult PVRenderPDFPageToBuffer(CGPDFDocumentRef document,
                            NSUInteger zeroBasedPage,
                            CGSize naturalSize,
                            size_t width,
                            size_t height,
                            void *buffer,
                            size_t bytesPerRow)
{
    if (!document || !buffer || width == 0 || height == 0)
        return PVRenderCoreInvalidPage;
    if (bytesPerRow < width * 4 || height > SIZE_MAX / bytesPerRow)
        return PVRenderCoreInvalidPage;
    // Still validated, though the transform no longer derives from it: a
    // command carrying a natural size the page cannot have is a command from a
    // caller that has lost track of this document, and rendering it would put
    // pixels in a buffer sized for something else.
    if (!isfinite(naturalSize.width) || !isfinite(naturalSize.height) ||
        !(naturalSize.width >= 1) || !(naturalSize.height >= 1))
        return PVRenderCoreInvalidPage;

    CGPDFPageRef page = CGPDFDocumentGetPage(document, (size_t)zeroBasedPage + 1);
    if (!page) return PVRenderCoreInvalidPage;

    // The two allocations below are the reason this function stopped returning
    // a BOOL. Neither says anything about the page: both are Quartz declining
    // to hand out memory, which is the definition of worth-trying-again.
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (!colorSpace) return PVRenderCoreTransientResource;
    CGContextRef context = CGBitmapContextCreate(buffer, width, height, 8,
        bytesPerRow, colorSpace,
        (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(colorSpace);
    if (!context) return PVRenderCoreTransientResource;

    PVRenderCoreResult result = PVRenderCoreDrawFailure;
    @try {
        CGContextSetFillColorWithColor(context,
            CGColorGetConstantColor(kCGColorWhite));
        CGContextFillRect(context, CGRectMake(0, 0, width, height));
        CGContextSetShouldAntialias(context, true);
        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
        CGContextSetShouldSmoothFonts(context, true);
        CGContextSetAllowsFontSubpixelPositioning(context, true);
        CGContextSetAllowsFontSubpixelQuantization(context, true);

        // One rectangle, used twice. See PVPageDrawingTransform.
        CGRect box = PVSafeCropBox(page);
        CGAffineTransform transform =
            PVPageDrawingTransform(box, PVPageRotation(page), width, height);
        if (PVFiniteTransformCore(transform)) {
            CGContextConcatCTM(context, transform);
            CGContextClipToRect(context, box);

            /* PDFKit draws the content stream AND the annotations, so this
             * replaces the Quartz draw rather than adding to it -- drawing both
             * would paint the content twice and compose transparency wrongly.
             * A NO from the hook means PDFKit was unavailable and nothing was
             * drawn, so the page still gets its content the ordinary way.
             *
             * Spelled out rather than folded into one condition because the
             * three outcomes are now counted separately, and `needed` differing
             * from `drawn` is the only signal that a page went out silently
             * without its annotations. */
            BOOL drewWithPDFKit = NO;
            if (gAnnotationDrawHook != NULL &&
                PVPageNeedsAnnotationDraw(page, (size_t)zeroBasedPage)) {
                gAnnotStats.needed++;
                drewWithPDFKit = gAnnotationDrawHook((size_t)zeroBasedPage + 1,
                                                     box, context);
                if (drewWithPDFKit) gAnnotStats.drawn++;
                else                gAnnotStats.declined++;
            }
            if (!drewWithPDFKit) CGContextDrawPDFPage(context, page);

            result = PVRenderCoreOK;
        }
    } @catch (id exception) {
        result = PVRenderCoreDrawFailure;
    } @finally {
        CGContextRelease(context);
    }
    return result;
}
