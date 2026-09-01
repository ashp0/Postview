#ifndef PV_RENDER_CORE_H
#define PV_RENDER_CORE_H

// Foundation, not Cocoa: this header is shared with the render helper, a
// process that must not link AppKit.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

CGRect PVSafeCropBox(CGPDFPageRef page);

/* /Rotate, normalised to 0, 90, 180 or 270. */
int PVPageRotation(CGPDFPageRef page);

// Content space -> bitmap space for one page: the validated crop box, rotated,
// fitted into `width` x `height` preserving aspect and centred.
//
// Ours rather than CGPDFPageGetDrawingTransform's, and that is the whole point.
// Quartz builds its transform around the page's RAW crop box, while both the
// clip below and the viewer's layout use the validated crop/media intersection.
// Where a document disagrees with itself -- a crop box outside the media box,
// or one that is empty, infinite or not a number -- those are two different
// rectangles, so the page was scaled and positioned as one shape and laid out
// as another. Deriving both from PVSafeCropBox is what makes them the same page.
CGAffineTransform PVPageDrawingTransform(CGRect box, int rotation,
                                         size_t width, size_t height);

// Why a render produced no pixels.
//
// A plain BOOL could not answer the only question the viewer actually asks:
// is this page worth asking for again? Every failure below used to arrive as
// the same NO, the helper turned all of them into EINVAL, and the viewer reads
// EINVAL as "the document will never draw this" and spends one of three
// permanent attempts. A machine that was briefly out of memory three times
// therefore retired a perfectly good page for the rest of the session.
//
// The split is between facts about the DOCUMENT, which repeat, and facts about
// the MACHINE at one instant, which do not.
typedef enum {
    PVRenderCoreOK = 0,
    // The page cannot be drawn as asked: no such page, a buffer whose shape
    // contradicts the request, geometry that is not a number. Repeating this
    // gets the same answer.
    PVRenderCoreInvalidPage,
    // Quartz could not be given the resources to draw into. Nothing about the
    // page is wrong; the machine was out of something. Worth asking again.
    PVRenderCoreTransientResource,
    // Drawing itself refused -- a non-finite transform from the page's own
    // boxes, or an exception raised out of CGContextDrawPDFPage. A property of
    // the content, kept separate from PVRenderCoreInvalidPage so that a
    // malformed page is distinguishable from a malformed request in a log.
    PVRenderCoreDrawFailure
} PVRenderCoreResult;

/* Render one page into caller-owned, zeroed-or-writable 32-bit host-order RGB. */
PVRenderCoreResult PVRenderPDFPageToBuffer(CGPDFDocumentRef document,
                            NSUInteger zeroBasedPage,
                            CGSize naturalSize,
                            size_t width,
                            size_t height,
                            void *buffer,
                            size_t bytesPerRow);

#endif
