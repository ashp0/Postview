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

/* Render one page into caller-owned, zeroed-or-writable 32-bit host-order RGB. */
BOOL PVRenderPDFPageToBuffer(CGPDFDocumentRef document,
                            NSUInteger zeroBasedPage,
                            CGSize naturalSize,
                            size_t width,
                            size_t height,
                            void *buffer,
                            size_t bytesPerRow);

#endif
