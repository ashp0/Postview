#import "PVRenderCore.h"
#include <math.h>

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
            CGContextDrawPDFPage(context, page);
            result = PVRenderCoreOK;
        }
    } @catch (id exception) {
        result = PVRenderCoreDrawFailure;
    } @finally {
        CGContextRelease(context);
    }
    return result;
}
