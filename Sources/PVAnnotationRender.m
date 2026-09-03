#import "PVAnnotationRender.h"
#import <objc/message.h>
#import <dlfcn.h>
#include <unistd.h>            /* alarm() */
#include "PVRenderProtocol.h"  /* PV_OPEN_ALARM_SECONDS */

/* PDFDisplayBox. Spelled out rather than imported: importing PDFKit's headers
 * would be harmless, but nothing else here refers to the framework at build
 * time and keeping it that way makes the link flags self-evidently unchanged. */
enum { PVPDFDisplayBoxCropBox = 1 };

#import "PVRenderCore.h"

/* ------------------------------------------------------------------------- */

/* Resolved once, on the first page that needs them. A failure is remembered as
 * a failure: a machine without Quartz is not going to grow one, and retrying
 * the dlopen for every page of a document would turn a missing framework into
 * a per-page cost. */
static BOOL       gPDFKitTried  = NO;
static BOOL       gPDFKitUsable = NO;
static Class      gPDFDocument  = Nil;
static Class      gNSGraphicsContext = Nil;

static void PVLoadPDFKitOnce(void)
{
    if (gPDFKitTried) return;
    gPDFKitTried = YES;

    /* The umbrella, because PDFKit is a subframework of it on 10.9 and its
     * binary is not at a path worth hard-coding. RTLD_LAZY: nothing here calls
     * a C symbol out of it, only Objective-C classes, which the runtime
     * registers as the image loads. */
    if (!dlopen("/System/Library/Frameworks/Quartz.framework/Quartz", RTLD_LAZY))
        return;

    gPDFDocument       = NSClassFromString(@"PDFDocument");
    gNSGraphicsContext = NSClassFromString(@"NSGraphicsContext");
    gPDFKitUsable      = (gPDFDocument != Nil && gNSGraphicsContext != Nil);
}

/* The document the helper was given. Copied once at install time and never
 * mutated, so the render path reads it without synchronisation. */
static NSString *gDocumentPath = nil;

/* The one PDFDocument this helper will ever build.
 *
 * It used to be built inside the draw function, per call, and thrown away on
 * the way out -- an entire xref parse and page-tree walk of the whole document
 * to draw ONE page. For OSTEP that is 675 pages re-read every time page 1 is
 * rasterised, which is every zoom change, every cache eviction and every scroll
 * back to the cover. PVAnnotationRender.h has always described the intended
 * behaviour: PDFKit opens the file "lazily, the first time a page actually
 * needs it". The lazy part was designed and documented; the code did it eagerly
 * and then did it again.
 *
 * Held for the life of the process with no eviction policy, because the
 * lifetime is already bounded by machinery that exists: PVPDFSource retires a
 * helper after PV_HELPER_MAX_RENDERS and kills one that misses its deadline, so
 * this memory is reclaimed on a boundary the viewer already chooses. Memory
 * spent in a disposable child process to save CPU in the parent is the trade
 * this project is explicitly making.
 *
 * `tried` is separate from the instance so that a document PDFKit cannot read
 * is not re-parsed once per page to reach the same answer -- the same reasoning
 * as gPDFKitTried above. Neither is synchronised: the helper reads one command
 * at a time, on one thread. */
static id   gDocumentInstance = nil;
static BOOL gDocumentTried    = NO;

/* Build it once, under the allowance for a PARSE rather than for a draw.
 *
 * The caller already runs inside alarm(PVRenderAlarmSeconds(w, h)), so this was
 * never unbounded. But that allowance is sized for rasterising a bitmap -- a
 * floor plus a per-megapixel term -- and parsing a document is not proportional
 * to the bitmap being drawn. The first annotated page is very often a thumbnail
 * or a preview, whose allowance is barely the floor, and a large document
 * parsed under a 15-second DRAW budget would kill a perfectly healthy helper on
 * the one page unlucky enough to pay for the parse.
 *
 * So the parse gets PV_OPEN_ALARM_SECONDS, the allowance the protocol already
 * reserves for walking a page tree, and the caller's remaining time is put back
 * afterwards. alarm() returns what was left of the previous alarm, and a
 * returned 0 correctly restores "no alarm pending". Being slightly generous
 * here is safe by design: the helper's alarm is only ever the ORPHAN fail-safe,
 * because a live parent enforces its own deadline and kills the helper itself.
 */
static id PVAnnotationDocument(void)
{
    if (gDocumentTried) return gDocumentInstance;
    gDocumentTried = YES;

    if ([gDocumentPath length] == 0) return nil;

    #define PV_MSGSEND(type) ((type)(void (*)(void))objc_msgSend)
    id (*msgSend)(id, SEL)        = PV_MSGSEND(id (*)(id, SEL));
    id (*msgSendObj)(id, SEL, id) = PV_MSGSEND(id (*)(id, SEL, id));
    #undef PV_MSGSEND

    NSURL *url = [NSURL fileURLWithPath:gDocumentPath];

    unsigned remaining = alarm(PV_OPEN_ALARM_SECONDS);
    /* +1 from alloc/init and deliberately not autoreleased: this outlives the
     * caller's pool by design, and is the process's for as long as it runs. */
    gDocumentInstance = msgSendObj(msgSend(gPDFDocument, @selector(alloc)),
                                   @selector(initWithURL:), url);
    alarm(remaining);

    return gDocumentInstance;
}

static BOOL PVDrawPageWithAnnotations(size_t oneBasedPage,
                                      CGRect box,
                                      CGContextRef context)
{
    NSString *documentPath = gDocumentPath;
    if (!context || [documentPath length] == 0 || oneBasedPage == 0) return NO;

    PVLoadPDFKitOnce();
    if (!gPDFKitUsable) return NO;

    /* Typed casts rather than bare objc_msgSend calls. On x86_64 the ABI hands
     * integer and pointer arguments the same way, so a wrong prototype here
     * would work by accident and break the day anything changes; naming the
     * signature is what makes that not a question. */
    /* Through a bare function pointer first. objc_msgSend is declared
     * variadic, and casting a variadic pointer straight to a fixed prototype
     * is what -Wcast-function-type-mismatch objects to -- rightly, since the
     * two are not interchangeable in general. On x86_64 this particular
     * conversion is the documented way to call it. */
    #define PV_MSGSEND(type) ((type)(void (*)(void))objc_msgSend)
    id   (*msgSend)(id, SEL)                     = PV_MSGSEND(id (*)(id, SEL));
    id   (*msgSendObj)(id, SEL, id)              = PV_MSGSEND(id (*)(id, SEL, id));
    id   (*msgSendUInt)(id, SEL, NSUInteger)     = PV_MSGSEND(id (*)(id, SEL, NSUInteger));
    void (*msgSendInt)(id, SEL, NSInteger)       = PV_MSGSEND(void (*)(id, SEL, NSInteger));
    id   (*msgSendPtrBool)(id, SEL, void *, BOOL) =
        PV_MSGSEND(id (*)(id, SEL, void *, BOOL));
    #undef PV_MSGSEND

    BOOL drew = NO;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    @try {
        /* Parsed on the first annotated page and kept; see PVAnnotationDocument.
         * Every later page of this document is a page lookup on an object that
         * is already open, which is what this path costs now. */
        id doc = PVAnnotationDocument();
        if (doc) {
            id page = msgSendUInt(doc, @selector(pageAtIndex:),
                                  (NSUInteger)(oneBasedPage - 1));
            if (page) {
                id gc = msgSendPtrBool(gNSGraphicsContext,
                            @selector(graphicsContextWithGraphicsPort:flipped:),
                            (void *)context, NO);
                if (gc) {
                    msgSend(gNSGraphicsContext, @selector(saveGraphicsState));
                    msgSendObj(gNSGraphicsContext,
                               @selector(setCurrentContext:), gc);

                    /* PDFKit draws in page space with the box's origin at the
                     * origin, exactly as CGContextDrawPDFPage does, so the
                     * caller's transform already places it correctly and the
                     * only thing left is the box offset. */
                    CGContextSaveGState(context);
                    CGContextTranslateCTM(context, -box.origin.x, -box.origin.y);
                    msgSendInt(page, @selector(drawWithBox:),
                               (NSInteger)PVPDFDisplayBoxCropBox);
                    CGContextRestoreGState(context);

                    msgSend(gNSGraphicsContext, @selector(restoreGraphicsState));
                    drew = YES;
                }
            }
        }
    } @catch (id exception) {
        /* A malformed page is a fact about the document, and the caller's
         * CoreGraphics render is still in the buffer. Losing the annotations is
         * strictly better than losing the page. */
        drew = NO;
    } @finally {
        [pool drain];
    }
    return drew;
}

void PVInstallAnnotationDrawHook(NSString *documentPath)
{
    if ([documentPath length] == 0) return;
    [gDocumentPath release];
    gDocumentPath = [documentPath copy];

    /* Naming a new document invalidates the one already parsed for the old one.
     * A helper serves exactly one document, so in the shipping path this always
     * clears nothing -- it is here so that "the cached document belongs to
     * gDocumentPath" is true by construction rather than by that being the only
     * way anyone happens to call it. */
    [gDocumentInstance release];
    gDocumentInstance = nil;
    gDocumentTried    = NO;

    PVSetAnnotationDrawHook(PVDrawPageWithAnnotations);
}
