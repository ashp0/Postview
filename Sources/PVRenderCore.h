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

/*
 * Does this page carry annotations that would draw something?
 *
 * Pure CoreGraphics, so both processes can ask. It matters because
 * CGContextDrawPDFPage draws a page's content stream and NOTHING else:
 * annotations are separate objects with their own appearance streams, and a
 * page whose content lives in them renders blank. See PVAnnotationRender.h.
 */
BOOL PVPageHasDrawableAnnotations(CGPDFPageRef page);

/*
 * The most /Annots entries this will look at on one page.
 *
 * The array's length comes out of the document, so the loop it drives was
 * bounded by nothing but an attacker's patience. A page past this cap is
 * answered YES without being read further, which is the conservative direction:
 * YES routes the page through PDFKit, and the worst a wrong YES can do is draw
 * the page correctly by a slower path. A wrong NO would draw it blank.
 *
 * 256 because no page in any document measured here carries a tenth of that,
 * and a page that does is not one the fast path was going to help.
 */
#define PV_MAX_ANNOTS_SCAN ((size_t)256)

/*
 * The same question, answered once per page for the life of the process.
 *
 * PVPageHasDrawableAnnotations is cheap but not free, and the render path asks
 * it again on every re-render of the same page -- every zoom change, every
 * cache eviction, every scroll back to the cover. The verdict cannot change,
 * because the document is an immutable snapshot for as long as this process
 * holds it, so it is worth exactly one dictionary probe per page ever.
 *
 * Two bits per page in a table fixed at compile time: no allocation, no
 * resizing, and no page index that can fall outside it, because the protocol
 * already refuses a document longer than PV_MAX_PDF_PAGES. An index past the
 * table is answered by probing without memoising rather than by growing.
 */
BOOL PVPageNeedsAnnotationDraw(CGPDFPageRef page, size_t zeroBasedPage);

/*
 * Forget every memoised verdict. Called once by the helper's main() after the
 * document is opened; a helper serves exactly one document, so this exists to
 * make the starting state explicit rather than to support reuse.
 */
void PVAnnotationMemoReset(size_t pageCount);

/*
 * What the annotation path actually did, for PV_HELPER_DIAGNOSTICS.
 *
 * `needed` against `drawn` is the number worth watching: they should be equal.
 * A gap means PDFKit was wanted and declined -- those pages rendered without
 * their annotations, which is the silent blank-page failure this whole path
 * exists to prevent, and nothing else would report it.
 */
typedef struct {
    unsigned long probed;    /* pages whose /Annots array was read at all   */
    unsigned long memoHits;  /* pages answered from the table, no probe     */
    unsigned long needed;    /* pages that wanted the PDFKit path           */
    unsigned long drawn;     /* pages PDFKit actually drew                  */
    unsigned long declined;  /* pages PDFKit was asked for and refused      */
    unsigned long capped;    /* pages past PV_MAX_ANNOTS_SCAN               */
} PVAnnotationStats;

PVAnnotationStats PVAnnotationStatsSnapshot(void);

/*
 * How a page with annotations gets drawn instead.
 *
 * A function pointer rather than a direct call because the only thing that can
 * draw an appearance stream is PDFKit, which is AppKit-based, and the viewer
 * must not link it -- see the Makefile's note on the helper. The helper
 * installs this; in the application it stays NULL and nothing changes.
 *
 * Returns YES having drawn the whole page, annotations included. NO means it
 * drew nothing and the caller should fall back to CGContextDrawPDFPage.
 */
typedef BOOL (*PVAnnotationDrawHook)(size_t oneBasedPage,
                                     CGRect box,
                                     CGContextRef context);
void PVSetAnnotationDrawHook(PVAnnotationDrawHook hook);

/* Render one page into caller-owned, zeroed-or-writable 32-bit host-order RGB. */
PVRenderCoreResult PVRenderPDFPageToBuffer(CGPDFDocumentRef document,
                            NSUInteger zeroBasedPage,
                            CGSize naturalSize,
                            size_t width,
                            size_t height,
                            void *buffer,
                            size_t bytesPerRow);

#endif
