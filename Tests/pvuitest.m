//  pvuitest.m — drives a real PVWindowController and snapshots it, so the
//  sidebar, page jumping and position saving can be verified without needing
//  Accessibility permission to click things.   make uitest

#import "PVCommon.h"
#import "PVPDFSource.h"
#import "PVWindowController.h"
#import "PVImageCache.h"
#import "PVRenderQueue.h"
#import "PVStateStore.h"
#import "PVWelcomeWindowController.h"
#import "PVDropView.h"
#import "PVPageView.h"
#import <objc/runtime.h>

// Declared, not added: every one of these already exists on the class. The
// controller has no reason to advertise them, and the test has no reason to
// reach around them.
// Counts what -updateVisibleContent hands to the render queue.
//
// -setDesiredRequests: is the only way work reaches the queue, so intercepting
// it counts requests as the scheduler issued them -- before the queue's own
// coalescing drops duplicates, which is what we want here: the question is what
// the scheduler asked for, not what survived.
static BOOL       PVCountRequests = NO;
static NSUInteger PVFullRequestCount = 0;
static NSUInteger PVPreviewRequestCount = 0;

@interface PVRenderQueue (PVTestCounting)
- (void)pvCountingSetDesiredRequests:(NSArray *)requests;
@end

@implementation PVRenderQueue (PVTestCounting)
- (void)pvCountingSetDesiredRequests:(NSArray *)requests
{
    if (PVCountRequests) {
        NSUInteger i, n = [requests count];
        for (i = 0; i < n; i++) {
            PVRenderRequest *r = [requests objectAtIndex:i];
            if (![r isKindOfClass:[PVRenderRequest class]]) continue;
            if (r->preview) PVPreviewRequestCount++; else PVFullRequestCount++;
        }
    }
    // Swapped, so this name now reaches the original implementation.
    [self pvCountingSetDesiredRequests:requests];
}
@end

static void PVInstallRequestCounter(void)
{
    Method a = class_getInstanceMethod([PVRenderQueue class], @selector(setDesiredRequests:));
    Method b = class_getInstanceMethod([PVRenderQueue class], @selector(pvCountingSetDesiredRequests:));
    if (a && b) method_exchangeImplementations(a, b);
}

@interface PVWindowController (PVTestHooks)
- (BOOL)pageIsUnrenderable:(NSUInteger)page;
- (void)notePageFailed:(NSUInteger)page;
- (void)resetRenderFailures;
- (void)updateVisibleContent;
- (void)memoryPressure:(NSNotification *)note;
- (void)showSidebar;
- (void)hideSidebar;
- (void)renderQueue:(PVRenderQueue *)queue didFailPage:(NSUInteger)page
          pixelSize:(CGSize)px preview:(BOOL)preview;
- (BOOL)worthRenderingDuringScroll:(NSUInteger)page;
- (NSUInteger)currentPageWithFraction:(CGFloat *)outFraction;
- (double)secondsPageStaysVisible:(NSUInteger)page;
- (void)willStartLiveScroll:(NSNotification *)note;
- (void)didEndLiveScroll:(NSNotification *)note;
- (void)scrollToPage:(NSUInteger)page fraction:(CGFloat)fraction;
- (void)pageViewWillMagnify:(PVPageView *)v atPoint:(NSPoint)p;
- (void)pageView:(PVPageView *)v magnifyBy:(CGFloat)factor;
- (void)pageViewDidMagnify:(PVPageView *)v;
- (void)pageViewSmartMagnify:(PVPageView *)v atPoint:(NSPoint)p;
- (void)scrollViewFrameChanged:(NSNotification *)note;
- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar *)tb;
- (NSApplicationPresentationOptions)window:(NSWindow *)window
     willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)proposedOptions;
@end

// Stands in for a real drag. Only -draggingPasteboard is consulted by the drop
// view, so this is all the protocol surface the test needs.
@interface PVFakeDrag : NSObject { NSPasteboard *_pb; }
- (id)initWithPaths:(NSArray *)paths;
- (NSPasteboard *)draggingPasteboard;
@end

@implementation PVFakeDrag
- (id)initWithPaths:(NSArray *)paths
{
    self = [super init];
    if (self) {
        _pb = [[NSPasteboard pasteboardWithUniqueName] retain];
        [_pb declareTypes:[NSArray arrayWithObject:NSFilenamesPboardType] owner:nil];
        [_pb setPropertyList:paths forType:NSFilenamesPboardType];
    }
    return self;
}
- (NSPasteboard *)draggingPasteboard { return _pb; }
- (void)dealloc { [_pb releaseGlobally]; [_pb release]; [super dealloc]; }
@end

static int gPass = 0, gFail = 0;
static void OK(int cond, const char *what)
{
    if (cond) { gPass++; printf("  ok    %s\n", what); }
    else      { gFail++; printf("  FAIL  %s\n", what); }
}

static void Pump(double seconds)
{
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

// Pump until the condition holds, or the deadline passes. Rendering runs at
// background QoS by design, so a fixed sleep has to be sized for the slowest
// plausible machine and then costs that long on every machine. Waiting on the
// condition itself takes as long as this machine actually needs, and a genuine
// regression still fails -- it just fails at the deadline instead of at once.
static BOOL PumpUntil(BOOL (^cond)(void), double deadline)
{
    double waited = 0;
    while (waited < deadline) {
        if (cond()) return YES;
        @autoreleasepool { Pump(0.05); }
        waited += 0.05;
    }
    return cond();
}

static void Snap(NSWindow *win, NSString *path)
{
    NSView *v = [win contentView];
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:[v bounds]];
    [v cacheDisplayInRect:[v bounds] toBitmapImageRep:rep];
    NSData *png = [rep representationUsingType:NSPNGFileType properties:
                   [NSDictionary dictionary]];
    [png writeToFile:path atomically:YES];
    printf("  snapshot -> %s\n", [path UTF8String]);
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: pvuitest <pdf> <outdir>\n"); return 2; }
        NSString *pdf = [NSString stringWithUTF8String:argv[1]];
        NSString *out = [NSString stringWithUTF8String:argv[2]];
        [[NSFileManager defaultManager] createDirectoryAtPath:out
                                 withIntermediateDirectories:YES attributes:nil error:NULL];

        [NSApplication sharedApplication];
        PVInstallRequestCounter();
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSURL *url = [NSURL fileURLWithPath:pdf];

        // Start from a known reading state. Without this the run inherits
        // whatever the previous run saved, so the zoom ratchets upwards on
        // every invocation until it pins at PV_MAX_ZOOM and the [4] snapshot
        // stops meaning anything. Only this fixture's entry is touched.
        [[PVStateStore sharedStore] recordForURL:url
                                            page:0
                                        fraction:0.0
                                        zoomMode:PVZoomModeFitWidth
                                            zoom:1.0
                                         sidebar:NO
                                     windowFrame:nil];

        NSError *err = nil;
        PVPDFSource *src = [[PVPDFSource alloc] initWithURL:url error:&err];
        if (!src) { fprintf(stderr, "open failed\n"); return 2; }

        PVWindowController *wc = [[PVWindowController alloc] initWithSource:src url:url];
        [wc showWindow:nil];
        [[wc window] setFrame:NSMakeRect(120, 120, 900, 760) display:YES];
        Pump(2.5);

        printf("\n[1] default view, fit width\n");
        Snap([wc window], [out stringByAppendingPathComponent:@"01-default.png"]);

        // Toolbar centring, checked at two very different window widths. This
        // is the regression that showed up as "the toolbar is not centred on an
        // iMac": with a plain trailing flexible space the controls drifted
        // further right the wider the window got.
        printf("\n[1b] the toolbar keeps its shape as the window widens\n");
        {
            // Checked on the LIVE toolbar rather than on freshly built items,
            // because what is being pinned is how AppKit lays them out -- which
            // is the part that has changed repeatedly between 10.9 and now, and
            // the part that produced the clipped zoom control on Mavericks.
            CGFloat widths[] = { 700, 900, 1900 };
            unsigned wi;
            for (wi = 0; wi < sizeof(widths)/sizeof(*widths); wi++) {
                NSRect f = [[wc window] frame];
                f.size.width = widths[wi];
                [[wc window] setFrame:f display:YES];
                Pump(0.4);

                NSArray *items = [[[wc window] toolbar] items];
                NSView *sidebar = nil, *zoom = nil;
                NSUInteger k;
                for (k = 0; k < [items count]; k++) {
                    NSToolbarItem *it = [items objectAtIndex:k];
                    if ([[it itemIdentifier] isEqualToString:@"PVToolbarSidebar"]) sidebar = [it view];
                    if ([[it itemIdentifier] isEqualToString:@"PVToolbarZoom"])    zoom    = [it view];
                }
                char msg[160];
                if (!sidebar || !zoom || ![sidebar window] || ![zoom window]) {
                    snprintf(msg, sizeof msg,
                             "both toolbar controls are on screen at %.0f pt wide", widths[wi]);
                    OK(NO, msg);
                    continue;
                }

                NSRect sr = [sidebar convertRect:[sidebar bounds] toView:nil];
                NSRect zr = [zoom    convertRect:[zoom    bounds] toView:nil];
                CGFloat windowW = NSWidth([[[wc window] contentView] bounds]);

                // Both fully inside the window, and not on top of each other.
                //
                // Deliberately not "leading" or "trailing": which edge they sit
                // at is the system's own convention and differs by release --
                // 10.9 packs them left with the title on its own row, macOS 11
                // and later reserve the leading region for the title and lay
                // them out trailing. Asserting one of those would be asserting
                // against the platform on the other. What must hold on every
                // release is that they are on screen, whole, and separate.
                snprintf(msg, sizeof msg,
                         "both controls are wholly inside the window at %.0f pt wide "
                         "(sidebar %.0f..%.0f, zoom %.0f..%.0f, window %.0f)",
                         widths[wi], NSMinX(sr), NSMaxX(sr), NSMinX(zr), NSMaxX(zr), windowW);
                // The couple of points of slack between the two is AppKit's own
                // item spacing: the boxes abut and the bezels sit inset within
                // them, so their frames touch by a point or two without the
                // controls ever overlapping on screen.
                OK(NSMinX(sr) >= -0.5 && NSMaxX(zr) <= windowW + 0.5 &&
                   NSMinX(zr) >= NSMaxX(sr) - 4.0, msg);

                // Same height, same vertical centre: they have to read as one
                // group, which they did not when they were built from
                // unrelated numbers.
                snprintf(msg, sizeof msg,
                         "the two controls share a height and a baseline at %.0f pt wide",
                         widths[wi]);
                OK(fabs(NSHeight(sr) - NSHeight(zr)) < 1.0 &&
                   fabs(NSMidY(sr) - NSMidY(zr)) < 1.0, msg);

                // Equal wrapper views are not enough.  Mavericks gives a
                // textured NSButton and a textured NSSegmentedControl
                // different native bezel heights inside those wrappers.  The
                // thumbnail control intentionally uses the same one-segment
                // segmented control as +/- so the pixels, not just the boxes,
                // stay aligned on that release.
                NSArray *ssubs = [sidebar subviews];
                NSArray *zsubs = [zoom subviews];
                NSView *scontrol = ([ssubs count] > 0) ? [ssubs objectAtIndex:0] : nil;
                NSView *zcontrol = ([zsubs count] > 0) ? [zsubs objectAtIndex:0] : nil;
                snprintf(msg, sizeof msg,
                         "the thumbnail and +/- use equal-height segmented controls at %.0f pt wide",
                         widths[wi]);
                OK([scontrol isKindOfClass:[NSSegmentedControl class]] &&
                   [zcontrol isKindOfClass:[NSSegmentedControl class]] &&
                   fabs(NSHeight([scontrol frame]) - NSHeight([zcontrol frame])) < 0.01,
                   msg);

                // And neither is clipped by the item that holds it: the zoom
                // control used to be given 74 points for two 36-point segments,
                // leaving nothing for the bezel and cutting the outer edge off
                // both magnifiers.  (zsubs is the one fetched above.)
                snprintf(msg, sizeof msg, "the zoom control is not clipped at %.0f pt wide",
                         widths[wi]);
                OK([zsubs count] > 0 &&
                   NSMaxX([(NSView *)[zsubs objectAtIndex:0] frame]) <= NSWidth([zoom bounds]) + 0.01,
                   msg);
            }
        }
        [[wc window] setFrame:NSMakeRect(120, 120, 900, 760) display:YES];
        Pump(0.4);

        // Both windows accept a dropped PDF over their whole surface, so the
        // accept/reject decision is worth pinning down -- and so is the fact
        // that it is the content view doing it, which is what makes the drop
        // work over the page, the sidebar and the margins rather than over one
        // panel in the empty state.
        printf("\n[1c] both windows accept a dropped PDF and refuse anything else\n");
        {
            PVWelcomeWindowController *welcome = [PVWelcomeWindowController sharedController];
            id drop = [[welcome window] contentView];

            PVFakeDrag *pdfDrag = [[PVFakeDrag alloc]
                initWithPaths:[NSArray arrayWithObject:pdf]];
            PVFakeDrag *txtDrag = [[PVFakeDrag alloc]
                initWithPaths:[NSArray arrayWithObject:@"/tmp/not-a-document.txt"]];
            PVFakeDrag *mixDrag = [[PVFakeDrag alloc]
                initWithPaths:[NSArray arrayWithObjects:@"/tmp/x.txt", pdf, nil]];

            OK([drop draggingEntered:(id)pdfDrag] == NSDragOperationCopy,
               "a dragged PDF is accepted");
            OK([drop draggingEntered:(id)txtDrag] == NSDragOperationNone,
               "a dragged non-PDF is refused");
            OK([drop draggingEntered:(id)mixDrag] == NSDragOperationCopy,
               "a mixed drag containing a PDF is accepted");
            OK([drop prepareForDragOperation:(id)txtDrag] == NO,
               "a non-PDF drop is rejected before it is performed");

            // The document window takes drops too, over its whole surface.
            id docDrop = [[wc window] contentView];
            OK([docDrop isKindOfClass:[PVDropView class]],
               "the document window's content view is the drop target");
            OK([docDrop draggingEntered:(id)pdfDrag] == NSDragOperationCopy,
               "a PDF dropped on an open document window is accepted");
            OK([docDrop draggingEntered:(id)txtDrag] == NSDragOperationNone,
               "a non-PDF dropped on a document window is refused");
            OK([docDrop isDropHighlighted],
               "a pending drop is registered as pending");
            [docDrop draggingExited:(id)txtDrag];
            OK(![docDrop isDropHighlighted], "and stops being pending when the drag leaves");

            // The page view sits on top of it and claims no drag types of its
            // own, which is what lets AppKit walk up to the content view. A
            // drag registered on the page view instead would be the old bug in
            // a new place: a drop target the size of one control.
            NSView *pv = [wc valueForKey:@"_pageView"];
            OK([[pv registeredDraggedTypes] count] == 0,
               "the page view claims no drags, so they reach the window's own target");

            [pdfDrag release]; [txtDrag release]; [mixDrag release];
        }

        // Recent documents come from NSDocumentController, which is already
        // keeping that list for the Open Recent menu and for the system's own
        // document history. A second list here would be a second thing to get
        // out of step, so what is checked is that the window mirrors that one
        // exactly -- not that some private copy has the right contents.
        //
        // The list itself cannot be written from here: NSDocumentController
        // matches a noted URL against the app's CFBundleDocumentTypes, and a
        // bare test executable has no Info.plist to declare any. It is the
        // bundle that makes recents work, and `make verify` is what checks the
        // bundle. So this drives -reloadRecents against whatever the system
        // does return, including nothing, and pins the behaviour either way.
        printf("\n[1d] the empty state offers the documents you had open\n");
        {
            PVWelcomeWindowController *welcome = [PVWelcomeWindowController sharedController];
            [welcome reloadRecents];

            NSTableView  *table  = [welcome valueForKey:@"_recentTable"];
            NSScrollView *scroll = [welcome valueForKey:@"_recentScroll"];
            NSArray      *recents = [welcome valueForKey:@"_recents"];
            OK(table != nil && scroll != nil, "the empty state has a recent-documents list");
            OK([table numberOfRows] == (NSInteger)[recents count],
               "the table agrees with the list behind it");

            // Whatever the system offers, every entry shown must be a file that
            // is still there: a row that opens an error panel is worse than no
            // row. Nothing is offered that -recentDocumentURLs did not name.
            NSArray *system = [[NSDocumentController sharedDocumentController] recentDocumentURLs];
            BOOL allReal = YES, allFromSystem = YES;
            NSUInteger ri;
            for (ri = 0; ri < [recents count]; ri++) {
                NSURL *u = [recents objectAtIndex:ri];
                if (![[NSFileManager defaultManager] fileExistsAtPath:[u path]]) allReal = NO;
                if (![system containsObject:u]) allFromSystem = NO;
            }
            OK(allReal, "every recent offered is a file that still exists");
            OK(allFromSystem, "nothing is offered that the document history did not name");
            OK([recents count] <= [system count],
               "the list is a filtered view of the history, never an addition to it");

            // The empty state has to be handled, and on this run it is the
            // state under test: with nothing to show, the list goes away and
            // the window says what to do instead of showing an empty box.
            OK([scroll isHidden] == ([recents count] == 0),
               "the list is on screen when there is something to show, and not when there is not");

            // A row has to be buildable and has to name its file, or it is a
            // row that cannot be clicked. Built directly so this is checked
            // even when the history is empty.
            NSTableCellView *row = (NSTableCellView *)[welcome tableView:table
                                        viewForTableColumn:[[table tableColumns] objectAtIndex:0]
                                                       row:0];
            if ([recents count] > 0) {
                OK(row != nil, "a row view is produced for the first recent");
                OK([[[row textField] stringValue] length] > 0, "the row names the document");
                OK([[row imageView] image] != nil, "the row shows the file's own icon");
            } else {
                OK(row == nil, "no row is produced when there is nothing to show");
                printf("  (document history is empty in a bare test binary; the bundle's\n");
                printf("   CFBundleDocumentTypes is what populates it -- see Info.plist)\n");
            }
        }

        printf("\n[2] thumbnails shown on request\n");
        [wc toggleSidebar:nil];
        Pump(3.0);
        Snap([wc window], [out stringByAppendingPathComponent:@"02-thumbnails.png"]);

        printf("\n[3] jump to page 37\n");
        [wc goToPageNumber:37];
        Pump(2.5);
        Snap([wc window], [out stringByAppendingPathComponent:@"03-page37.png"]);

        printf("\n[4] zoom in twice\n");
        [wc zoomIn:nil];
        [wc zoomIn:nil];
        Pump(2.5);
        Snap([wc window], [out stringByAppendingPathComponent:@"04-zoomed.png"]);

        printf("\n[5] thumbnails hidden again\n");
        [wc toggleSidebar:nil];
        Pump(1.0);
        Snap([wc window], [out stringByAppendingPathComponent:@"05-nothumbs.png"]);

        // The on-demand sidebar makes exactly one promise: it costs nothing
        // once it is put away. A thumbnail rasterised just before the sidebar
        // closed used to arrive afterwards and quietly re-fill the cache
        // -hideSidebar had emptied, where it then sat until the sidebar was
        // next opened. Re-opening and immediately closing reproduces that
        // ordering: renders are certainly in flight at the moment of the hide.
        printf("\n[5b] a thumbnail in flight when the sidebar closes is discarded\n");
        {
            PVImageCache *tc = [wc valueForKey:@"_thumbCache"];
            [wc showSidebar];
            Pump(0.25);                       // long enough to start, not to finish
            [wc hideSidebar];
            OK([tc entryCount] == 0, "hiding the sidebar empties the thumbnail cache");
            // Everything that was in flight at the moment of the hide has now
            // been delivered -- the queue only reports idle once its results
            // have reached the main thread.
            PVRenderQueue *tq = [wc valueForKey:@"_thumbQueue"];
            OK(PumpUntil(^{ return [tq isIdle]; }, 20.0),
               "the thumbnail queue drains after the sidebar is hidden");
            OK([tc entryCount] == 0,
               "a thumbnail delivered after the sidebar closed is not stored");
            OK([tc byteCount] == 0, "no thumbnail bytes are held once the sidebar is away");
        }

        // A page CoreGraphics will not rasterise never reaches the cache, so
        // the wanted-set names it again on the very next scroll event and the
        // queue tries it again -- for as long as the document stays open. The
        // attempt limit is what makes that terminate.
        printf("\n[5c] a page that cannot be rendered stops being asked for\n");
        {
            PVRenderQueue *pq = [wc valueForKey:@"_pageQueue"];
            [wc resetRenderFailures];
            OK(![wc pageIsUnrenderable:5], "a page starts out renderable");
            [wc renderQueue:pq didFailPage:5 pixelSize:CGSizeMake(10, 10) preview:NO];
            OK(![wc pageIsUnrenderable:5], "one failure is not enough to give up");
            [wc renderQueue:pq didFailPage:5 pixelSize:CGSizeMake(10, 10) preview:NO];
            OK(![wc pageIsUnrenderable:5], "two failures are not enough either");
            [wc renderQueue:pq didFailPage:5 pixelSize:CGSizeMake(10, 10) preview:NO];
            OK([wc pageIsUnrenderable:5], "the third failure retires the page");
            OK(![wc pageIsUnrenderable:6], "retiring one page does not retire its neighbour");

            // Asking again after nothing has changed must not restart the
            // cycle; asking again after the pixel size changes must.
            [wc updateVisibleContent];
            OK([wc pageIsUnrenderable:5], "a plain refresh does not un-retire the page");
            [wc zoomIn:nil];
            Pump(0.3);
            OK(![wc pageIsUnrenderable:5],
               "a zoom asks CoreGraphics a different question, so the page is retried");
            [wc zoomOut:nil];
            Pump(0.5);
        }

        // Under memory pressure the full-resolution bitmaps are dropped and the
        // previews kept. What must not happen is the prefetch that follows
        // asking for those same full bitmaps straight back: on a machine that
        // stays under pressure that is a render loop, which is the opposite of
        // shrinking.
        printf("\n[5d] memory pressure shrinks the cache and stays shrunk\n");
        {
            PVImageCache *pc = [wc valueForKey:@"_pageCache"];
            PVRenderQueue *pq = [wc valueForKey:@"_pageQueue"];
            // Counted from a clean cache, so the baseline is what one settled
            // pass actually asks for -- visible pages plus prefetch -- and not
            // a high-water mark left behind by everything above.
            [pc removeAll];
            [wc updateVisibleContent];
            OK(PumpUntil(^{ return [pq isIdle]; }, 60.0), "the first pass settles");
            NSUInteger normal = [pc fullImageCount];
            printf("  full bitmaps after a settled pass: %lu\n", (unsigned long)normal);
            OK(normal >= 2, "a settled pass renders the visible pages and prefetches ahead");

            [wc memoryPressure:nil];
            OK([pc fullImageCount] == 0, "pressure drops every full bitmap immediately");
            OK(PumpUntil(^{ return [pq isIdle]; }, 60.0), "the pass after pressure settles");
            NSUInteger after = [pc fullImageCount];
            printf("  full bitmaps after pressure settled: %lu\n", (unsigned long)after);
            OK(after > 0, "the pages actually on screen still go sharp again");
            OK(after < normal,
               "prefetch does not put back the full bitmaps pressure just dropped");

            // The second report, with no user action in between, is the one
            // that used to close a loop. Answering it the same way as the
            // first means: drop the bitmaps, render them again, be told to
            // drop them again -- for as long as the machine stays tight, with
            // a background thread busy throughout and the visible pages
            // flickering between sharp and soft. From the second report on,
            // nothing full-resolution is asked for at all until the user does
            // something.
            [wc memoryPressure:nil];
            OK([pc fullImageCount] == 0, "the second report drops the bitmaps too");
            OK(PumpUntil(^{ return [pq isIdle]; }, 60.0), "the pass after it settles");
            OK([pc fullImageCount] == 0,
               "a machine still under pressure is not asked to render again");
            OK([pc entryCount] > 0,
               "the previews are kept, so the document stays readable");

            // ...and the moment the user does anything, sharp pages come back.
            [wc goToPageNumber:2];
            OK(PumpUntil(^BOOL{ return (BOOL)([pc fullImageCount] > 0); }, 60.0),
               "a user action ends the backoff and the pages go sharp again");
            // Put the document back where the rest of the run expects to find
            // it: [6] reads the position this leaves behind off the disk.
            [wc goToPageNumber:37];
            PumpUntil(^{ return [pq isIdle]; }, 60.0);
        }

        // -scrollViewFrameChanged: deliberately skips the exact pass while the
        // user is dragging the window edge, and AppKit does not necessarily
        // post another frame change once they let go. Without a handler for
        // the end of the resize the document stayed soft until the next scroll.
        printf("\n[5e] the end of a live resize asks for sharp bitmaps\n");
        {
            // Checked synchronously, with no run loop in between: a notification
            // is delivered on the posting thread, so if the controller handles
            // this one the flag is already down by the time the post returns.
            // Waiting on a rendered bitmap instead would prove nothing -- any
            // of several notifications arriving during the wait triggers the
            // same pass. The handler is reached through NSWindow's delegate
            // registration, so this also pins the window delegate being set.
            [wc memoryPressure:nil];
            OK([[wc valueForKey:@"_pressureReports"] unsignedIntegerValue] > 0,
               "memory pressure arms prefetch suppression (test premise holds)");
            [[NSNotificationCenter defaultCenter]
                postNotificationName:NSWindowDidEndLiveResizeNotification
                              object:[wc window]];
            OK([[wc valueForKey:@"_pressureReports"] unsignedIntegerValue] == 0,
               "the end of a live resize is observed and starts a fresh exact pass");
            PumpUntil(^{ return [(PVRenderQueue *)[wc valueForKey:@"_pageQueue"] isIdle]; }, 60.0);
        }

        // A page that will be gone before its bitmap could arrive is not worth
        // rasterising. Without this the render queue saturated a core during
        // any fast scroll, producing previews for pages that had left the
        // screen long before they were delivered: measured at 128% of a core
        // flicking through a heavy document against 26% after, with what the
        // user sees unchanged, because what stopped being rendered was
        // precisely what was arriving too late to be seen.
        printf("\n[5f] pages flying past faster than they can be seen are not rendered\n");
        {
            PVImageCache  *pc = [wc valueForKey:@"_pageCache"];
            PVRenderQueue *pq = [wc valueForKey:@"_pageQueue"];
            [wc goToPageNumber:10];
            PumpUntil(^{ return [pq isIdle]; }, 60.0);
            // The page the viewport is actually sitting on, travelling
            // forwards. Stated rather than inherited, so the rule is measured
            // against a geometry the test knows and not whichever direction
            // the previous section happened to leave behind.
            NSUInteger onScreen = [wc currentPageWithFraction:NULL];
            [wc setValue:[NSNumber numberWithInt:1] forKey:@"_lastDirection"];

            // Standing still, everything is worth rendering however the rest
            // of the state is set: the rule only ever applies to a live scroll.
            [wc setValue:[NSNumber numberWithDouble:50000.0] forKey:@"_scrollSpeed"];
            OK([wc worthRenderingDuringScroll:onScreen],
               "not scrolling: the speed rule does not apply at all");

            [wc willStartLiveScroll:nil];
            OK([[wc valueForKey:@"_scrollSpeed"] doubleValue] == 0,
               "a new gesture starts from rest, not from the last one's speed");

            // A speed and the instant it was measured always move together:
            // -clipBoundsChanged: writes both, and the throttle disregards a
            // speed it cannot date (see PV_SPEED_FRESH_SECONDS, which is what
            // stops a document that has stopped moving from staying soft
            // forever). Setting the speed alone below therefore builds a state
            // the app cannot actually reach -- fast, but measured never -- and
            // the honest answer to it is the safe one: render.
            //
            // The gesture has just zeroed the clock, so the timestamp is
            // restated here to stand for the first bounds change of the
            // scroll. Without it these assertions test the staleness rule
            // rather than the speed rule they are written for.
            [wc setValue:[NSNumber numberWithDouble:[NSDate timeIntervalSinceReferenceDate]]
                  forKey:@"_lastScrollTime"];

            // The threshold is a constant, so these hold on every machine: a
            // page held on screen for many seconds is rendered, and one gone
            // within a glance is not.
            [wc setValue:[NSNumber numberWithDouble:50.0] forKey:@"_scrollSpeed"];
            OK([wc worthRenderingDuringScroll:onScreen],
               "a page held on screen for many seconds is always rendered");

            [wc setValue:[NSNumber numberWithDouble:50000.0] forKey:@"_scrollSpeed"];
            OK(![wc worthRenderingDuringScroll:onScreen],
               "a flick does not render pages that will be gone first");
            OK([wc secondsPageStaysVisible:onScreen] < PV_MIN_VISIBLE_SECONDS,
               "...because each page is on screen for less than a glance");

            // The two properties that make the rule safe on hardware nobody
            // here has measured: visible time falls as the scroll speeds up,
            // and the decision follows it. There is one crossover, so no
            // faster scroll ever renders something a slower one declined --
            // which is what stops the CPU cost swinging with the machine's
            // mood rather than with what the user is doing.
            BOOL monotoneTime = YES, monotoneDecision = YES;
            double prev = HUGE_VAL;
            BOOL prevDecision = YES;
            double sp;
            for (sp = 50; sp <= 128000; sp *= 2) {
                [wc setValue:[NSNumber numberWithDouble:sp] forKey:@"_scrollSpeed"];
                double t = [wc secondsPageStaysVisible:onScreen];
                BOOL d = [wc worthRenderingDuringScroll:onScreen];
                if (t > prev + 1e-9) monotoneTime = NO;
                if (d && !prevDecision) monotoneDecision = NO;
                prev = t; prevDecision = d;
            }
            OK(monotoneTime, "visible time falls monotonically as the scroll speeds up");
            OK(monotoneDecision, "and the decision follows it: one crossover, never a flip back");

            // A jump is not a speed. A page jump, a thumbnail click or the snap
            // at the end of a rubber-band moves the document thousands of
            // points between two events; folding that into the average reports
            // a scroll that never happened and stops rendering until it decays.
            [wc setValue:[NSNumber numberWithDouble:0.0] forKey:@"_scrollSpeed"];
            [wc setValue:[NSNumber numberWithDouble:0.0] forKey:@"_lastScrollTime"];
            [wc willStartLiveScroll:nil];
            [wc scrollToPage:2 fraction:0];
            [wc clipBoundsChanged:nil];
            [wc scrollToPage:900 fraction:0];      // a jump of most of a document
            [wc clipBoundsChanged:nil];
            OK([[wc valueForKey:@"_scrollSpeed"] doubleValue] <= PV_MAX_SCROLL_SPEED,
               "a jump across the document does not register as a scroll speed");
            // Leave a scroll in flight, which is the state the next check needs.
            [wc willStartLiveScroll:nil];

            // And the guarantee that makes all of it safe: stopping asks for
            // everything, at once. A flick that skipped every page on the way
            // past must still land on a sharp one.
            [pc removeAll];
            [wc setValue:[NSNumber numberWithDouble:50000.0] forKey:@"_scrollSpeed"];
            [wc updateVisibleContent];
            PumpUntil(^{ return [pq isIdle]; }, 10.0);
            OK([pc fullImageCount] == 0, "mid-flick, nothing was rendered at all");

            [wc didEndLiveScroll:nil];
            OK([[wc valueForKey:@"_scrollSpeed"] doubleValue] == 0,
               "the end of the scroll clears the speed");
            OK(PumpUntil(^BOOL{ return (BOOL)([pc fullImageCount] > 0); }, 60.0),
               "the moment it stops, the page the user landed on goes sharp");
            PumpUntil(^{ return [pq isIdle]; }, 60.0);
            [wc goToPageNumber:37];          // restore what [6] expects to read
            PumpUntil(^{ return [pq isIdle]; }, 60.0);
        }

        // The page column is centred inside a document view that is at least as
        // wide as the viewport. That makes the viewport width an input to where
        // the pages sit, even in the zoom modes that do not recompute their
        // zoom when the window changes size -- and those two used to return
        // early from -scrollViewFrameChanged: without laying out again. The
        // document view then kept its old, narrower width, and a narrower
        // document view is placed at the LEFT of its clip view: zoom in, go
        // full screen, and the page sat against the left edge with all the
        // gained width empty beside it.
        // The scheduler, end to end through the real controller: not "does the
        // policy function return NO" but "does -updateVisibleContent actually
        // stop asking for full-resolution bitmaps while the document moves".
        //
        // That distinction is the whole bug. The policy was correct and was
        // being consulted for previews; the full-resolution branch beside it
        // was gated on the live-scroll flags instead, which AppKit posts only
        // for gestures. Every keyboard scroll therefore asked for a whole-page
        // bitmap per visible page per key press, while the counter beside it
        // reported a healthy suppression rate for the cheap half of the work.
        //
        // Counted by intercepting the one call the controller uses to hand
        // work over, so this measures what was asked for rather than what
        // happened to survive the queue's own coalescing.
        printf("\n[5g2] the scheduler asks for no full bitmaps while the document moves\n");
        {
            PVRenderQueue *pq = [wc valueForKey:@"_pageQueue"];
            [wc goToPageNumber:20];
            PumpUntil(^{ return [pq isIdle]; }, 60.0);

            // Both measurements start from an empty cache. A page already
            // sharp is not asked for again, so measuring at rest against a
            // warm cache would compare "nothing left to want" with
            // "suppressed" and call them the same thing.
            PVImageCache *pcache = [wc valueForKey:@"_pageCache"];

            [pcache removeAll];
            PVFullRequestCount = 0; PVPreviewRequestCount = 0; PVCountRequests = YES;

            // At rest. The settle path states this outright, so state it here
            // the same way rather than waiting for a timer.
            [wc setValue:[NSNumber numberWithDouble:0.0] forKey:@"_scrollSpeed"];
            [wc setValue:[NSNumber numberWithDouble:0.0] forKey:@"_lastScrollTime"];
            [wc updateVisibleContent];
            NSUInteger fullsAtRest = PVFullRequestCount;

            // Moving fast, freshly measured: the flick case, same empty cache.
            [pcache removeAll];
            PVFullRequestCount = 0; PVPreviewRequestCount = 0;
            [wc setValue:[NSNumber numberWithDouble:20000.0] forKey:@"_scrollSpeed"];
            [wc setValue:[NSNumber numberWithDouble:[NSDate timeIntervalSinceReferenceDate]]
                  forKey:@"_lastScrollTime"];
            [wc updateVisibleContent];
            NSUInteger fullsMoving = PVFullRequestCount;

            PVCountRequests = NO;

            OK(fullsMoving == 0,
               "moving: not one full-resolution bitmap is asked for");
            OK(fullsAtRest > 0,
               "at rest: full-resolution bitmaps are asked for again");

            // The keyboard is the case that was broken, and it never sets the
            // live-scroll flags. Assert the decision does not depend on them.
            OK(![[wc valueForKey:@"_liveScrolling"] boolValue],
               "...and none of that involved a live-scroll notification");
        }

        printf("\n[5g] the page stays centred at every width, in every zoom mode\n");
        {
            PVPageView   *pv = [wc valueForKey:@"_pageView"];
            NSScrollView *sv = [wc valueForKey:@"_scrollView"];
            NSWindow     *w  = [wc window];

            struct { const char *name; SEL sel; } modes[] = {
                { "fit width",   @selector(zoomFitWidth:)   },
                { "fit page",    @selector(zoomFitPage:)    },
                { "actual size", @selector(zoomActualSize:) },
                { "custom zoom", @selector(zoomIn:)         },
            };
            CGFloat widths[] = { 700, 1100, 1900, 900 };   // ...including full-screen wide

            BOOL centred = YES, fills = YES;
            const char *worstMode = ""; CGFloat worstW = 0, worstLeft = 0, worstRight = 0;
            int mi, wi;
            for (mi = 0; mi < 4; mi++) {
                [wc performSelector:modes[mi].sel withObject:nil];
                for (wi = 0; wi < 4; wi++) {
                    NSRect fr = [w frame];
                    fr.size.width = widths[wi];
                    [w setFrame:fr display:YES];
                    [[NSNotificationCenter defaultCenter]
                        postNotificationName:NSViewFrameDidChangeNotification object:sv];
                    Pump(0.02);

                    CGFloat viewport = NSWidth([[sv contentView] bounds]);
                    CGFloat docW     = NSWidth([pv frame]);
                    NSRect  page     = [pv rectForPage:0];
                    CGFloat left  = NSMinX(page);
                    CGFloat right = docW - NSMaxX(page);

                    // The document view must never be narrower than the
                    // viewport, or AppKit pins it to the left and no amount of
                    // centring inside it can help.
                    if (docW < viewport - 0.5) fills = NO;
                    // And within it the page must sit in the middle, unless it
                    // is wider than the space and the margins are the minimum.
                    if (fabs(left - right) > 1.5 && left > PV_EDGE_GAP + 0.5) {
                        centred = NO;
                        worstMode = modes[mi].name; worstW = viewport;
                        worstLeft = left; worstRight = right;
                    }
                }
            }
            OK(fills, "the document view is never narrower than the viewport");
            if (!centred)
                printf("  worst: %s at %.0f pt wide -- left %.1f, right %.1f\n",
                       worstMode, worstW, worstLeft, worstRight);
            OK(centred, "the page is horizontally centred at every width and zoom mode");

            // Restore a sane window and mode for what follows.
            NSRect fr = [w frame]; fr.size.width = 900; [w setFrame:fr display:YES];
            [wc zoomFitWidth:nil];
            Pump(0.05);
        }

        // Pinch to zoom. It never worked on Mavericks because it was never
        // implemented: nothing answered -magnifyWithEvent:. Knowing when the
        // gesture has ENDED is the part that differs across the systems this
        // has to run on -- Mavericks does not populate NSEvent's phase for
        // gestures and signals the end with -endGestureWithEvent:, which
        // current systems no longer send. Both routes are handled, and both
        // are checked here, because a gesture that never ends leaves the
        // document permanently stretched and never re-rendered.
        printf("\n[5h] pinch to zoom, ending the way either system ends it\n");
        {
            PVPageView *pv = [wc valueForKey:@"_pageView"];
            [wc zoomFitWidth:nil];
            Pump(0.05);
            CGFloat before = [pv zoom];

            [wc pageViewWillMagnify:pv atPoint:NSMakePoint(300, 400)];
            OK([[wc valueForKey:@"_liveZooming"] boolValue],
               "the gesture is recognised as in progress");
            [wc pageView:pv magnifyBy:1.10];
            [wc pageView:pv magnifyBy:1.10];
            OK([pv zoom] > before, "the document zooms while the fingers move");
            OK(fabs([pv zoom] - before * 1.21) < 0.02,
               "successive steps multiply, so the gesture tracks the fingers");
            OK([[wc valueForKey:@"_zoomMode"] intValue] == PVZoomModeCustom,
               "a pinch leaves the zoom under the user's control, not snapped to a mode");

            [wc pageViewDidMagnify:pv];
            OK(![[wc valueForKey:@"_liveZooming"] boolValue], "and it ends");
            OK(PumpUntil(^{ return [(PVRenderQueue *)[wc valueForKey:@"_pageQueue"] isIdle]; }, 60.0),
               "the sharp pass is asked for once, when the fingers come off");

            // Limits: a pinch cannot drive the document outside the zoom range.
            int i;
            for (i = 0; i < 60; i++) [wc pageView:pv magnifyBy:1.3];
            OK([pv zoom] <= PV_MAX_ZOOM + 0.001, "a long pinch cannot exceed the maximum zoom");
            for (i = 0; i < 120; i++) [wc pageView:pv magnifyBy:0.8];
            OK([pv zoom] >= PV_MIN_ZOOM - 0.001, "or go below the minimum");

            // Nonsense from a misbehaving driver must not reach the layout.
            CGFloat sane = [pv zoom];
            [wc pageView:pv magnifyBy:(CGFloat)NAN];
            OK([pv zoom] == sane, "a non-finite magnification is ignored");

            // How the gesture ENDS is the part that differs by system, and the
            // view owns that decision, so it is driven through the view.
            // Gesture NSEvents have no public constructor, so the recognised
            // state is set the way -magnifyWithEvent: would have set it.
            [pv setDelegate:(id <PVPageViewDelegate>)wc];
            [pv setValue:[NSNumber numberWithBool:YES] forKey:@"_magnifying"];
            [wc pageViewWillMagnify:pv atPoint:NSMakePoint(300, 400)];
            OK([[wc valueForKey:@"_liveZooming"] boolValue], "a gesture is in progress");

            [pv endGestureWithEvent:nil];          // the Mavericks route
            OK(![[wc valueForKey:@"_liveZooming"] boolValue],
               "-endGestureWithEvent: ends the gesture, which is how Mavericks ends it");
            OK(![[pv valueForKey:@"_magnifying"] boolValue],
               "and the view stops considering itself mid-gesture");

            // A second end -- a system that sends both a phase and a bracket --
            // must not report the gesture twice.
            [wc setValue:[NSNumber numberWithBool:YES] forKey:@"_liveZooming"];
            [pv endGestureWithEvent:nil];
            OK([[wc valueForKey:@"_liveZooming"] boolValue],
               "a second end is ignored rather than reported again");
            [wc setValue:[NSNumber numberWithBool:NO] forKey:@"_liveZooming"];

            // Two-finger double tap toggles, and comes back.
            [wc zoomFitWidth:nil];
            [wc pageViewSmartMagnify:pv atPoint:NSMakePoint(300, 400)];
            OK([[wc valueForKey:@"_zoomMode"] intValue] == PVZoomModeActual,
               "a two-finger double tap goes to actual size");
            [wc pageViewSmartMagnify:pv atPoint:NSMakePoint(300, 400)];
            OK([[wc valueForKey:@"_zoomMode"] intValue] == PVZoomModeFitWidth,
               "and back to fit width");

            [wc zoomFitWidth:nil];
            [wc goToPageNumber:37];
            PumpUntil(^{ return [(PVRenderQueue *)[wc valueForKey:@"_pageQueue"] isIdle]; }, 60.0);
        }

        // Close the window the way the user would, then read back what was saved.
        [[wc window] performClose:nil];
        Pump(1.0);

        NSUInteger page = 0; CGFloat frac = 0, zoom = 0;
        PVZoomMode mode = PVZoomModeCustom; BOOL sidebar = YES;
        BOOL found = [[PVStateStore sharedStore] stateForURL:url page:&page fraction:&frac
                        zoomMode:&mode zoom:&zoom sidebar:&sidebar windowFrame:NULL];
        printf("\n[6] position saved on close: found=%d page=%lu (expect 36, i.e. page 37)"
               " sidebar=%d zoom=%.2f\n", (int)found, (unsigned long)page, (int)sidebar, zoom);
        int bad = 0;
        if (!found)       { printf("  FAIL no state saved\n"); bad = 1; }
        if (page != 36)   { printf("  FAIL expected page index 36\n"); bad = 1; }
        if (sidebar)      { printf("  FAIL sidebar should be recorded as hidden\n"); bad = 1; }
        // Two steps up from fit-width, which at this window size is ~1.2.
        // Pinned now that the run starts from a known state.
        OK(zoom > 1.0 && zoom < 3.0, "zoom lands on a sane step, not saturated at the limit");
        if (!bad) printf("  ok reading position and sidebar state persisted correctly\n");

        // Reopening is the other half of persistence, and the title bar has to
        // agree with it. The page number lives there now rather than in a
        // toolbar field, which is what let the toolbar lose the page field, the
        // count label, the two flexible spaces and the counterweight that used
        // to hold them in the middle of the window.
        //
        // The old failure this pins is unchanged in shape: the title is
        // rewritten only when the page CHANGES, so a document restored to page
        // 37 has to say 37 from the moment the window exists, not from the
        // first time the user scrolls.
        printf("\n[7] reopening restores the page, and the title bar says so\n");
        {
            PVWindowController *wc2 = [[PVWindowController alloc] initWithSource:src url:url];
            NSString *before = [[wc2 window] title];
            // Read BEFORE -showWindow:, which is the first thing that would
            // update the indicator.
            OK([before rangeOfString:@"page 37 of"].location != NSNotFound,
               "the title is correct from the moment the window is built");
            [wc2 showWindow:nil];
            NSString *after = [[wc2 window] title];
            printf("  title reads \"%s\" (expect page 37 of 60)\n", [after UTF8String]);
            OK([after rangeOfString:@"page 37 of 60"].location != NSNotFound,
               "the title shows the restored page and the page count");
            OK([after rangeOfString:@"heavy.pdf"].location != NSNotFound,
               "...and names the document, as a document window should");
            OK([[wc2 window] representedURL] != nil,
               "the window has a represented URL, so it gets a proxy icon");

            // The toolbar is two items now, and both draw from the bundled
            // artwork rather than from text. A missing asset is a blank
            // button, which is not something a build should be able to ship.
            OK(PVToolbarImageNamed(@"TB_contentAndThumbs") != nil, "the sidebar icon is in the bundle");
            OK(PVToolbarImageNamed(@"TB_zoomIn")  != nil, "the zoom-in icon is in the bundle");
            OK(PVToolbarImageNamed(@"TB_zoomOut") != nil, "the zoom-out icon is in the bundle");
            OK([PVToolbarImageNamed(@"TB_zoomIn") isTemplate],
               "icons are template images, so they tint instead of staying black");
            OK(PVToolbarImageNamed(@"TB_doesNotExist") == nil,
               "a missing asset reports itself rather than returning a blank image");

            NSApplicationPresentationOptions proposed =
                NSApplicationPresentationFullScreen | NSApplicationPresentationAutoHideMenuBar;
            NSApplicationPresentationOptions actual = [wc2 window:[wc2 window]
                willUseFullScreenPresentationOptions:proposed];
            OK((actual & proposed) == proposed &&
               (actual & NSApplicationPresentationAutoHideToolbar) != 0,
               "full screen detaches and hides the toolbar until the top-edge reveal");

            NSArray *ids = [wc2 toolbarDefaultItemIdentifiers:[[wc2 window] toolbar]];
            OK([ids count] == 2, "the toolbar is down to two items");

            // Every item the same height, and none of them clipped: the zoom
            // control used to be pinned to 74 points for two 36-point segments,
            // which left nothing for the bezel and cut the outer edge off both
            // magnifiers on Mavericks.
            BOOL sameHeight = YES, fits = YES, matchingControls = YES;
            CGFloat firstH = -1;
            CGFloat firstControlH = -1;
            NSUInteger ii;
            for (ii = 0; ii < [ids count]; ii++) {
                NSToolbarItem *it = [wc2 toolbar:[[wc2 window] toolbar]
                           itemForItemIdentifier:[ids objectAtIndex:ii]
                       willBeInsertedIntoToolbar:YES];
                NSView *v = [it view];
                if (!v) continue;          // the flexible space has no view
                if (fabs([v frame].size.height - [it minSize].height) > 0.01) sameHeight = NO;
                if (firstH < 0) firstH = [v frame].size.height;
                else if (fabs([v frame].size.height - firstH) > 0.01) sameHeight = NO;
                // The control inside must fit the box it was given, or it is
                // being clipped.
                NSArray *subs = [v subviews];
                if ([subs count] > 0) {
                    NSRect cf = [(NSView *)[subs objectAtIndex:0] frame];
                    if (![(NSView *)[subs objectAtIndex:0] isKindOfClass:[NSSegmentedControl class]])
                        matchingControls = NO;
                    if (firstControlH < 0) firstControlH = cf.size.height;
                    else if (fabs(cf.size.height - firstControlH) > 0.01) matchingControls = NO;
                    if (NSMaxX(cf) > NSWidth([v frame]) + 0.01 ||
                        NSMaxY(cf) > NSHeight([v frame]) + 0.01 ||
                        NSMinX(cf) < -0.01 || NSMinY(cf) < -0.01) fits = NO;
                }
            }
            OK(sameHeight, "every toolbar item is the same height");
            OK(matchingControls, "toolbar children are equal-height segmented controls on Mavericks");
            OK(fits, "no toolbar control is clipped by the item that holds it");

            [[wc2 window] performClose:nil];
            Pump(0.5);
            [wc2 release];
        }

        // The one invariant that AppKit will not maintain on Postview's behalf.
        // A window that has ever been ordered on screen is retained by AppKit
        // for the life of the process -- verified independently against a bare
        // NSWindow with none of this code in it: closed, ordered out, tabbing
        // disallowed, releasedWhenClosed either way, a shown window is simply
        // never deallocated. So the window cannot be trusted to release what it
        // owns, and what it owns is the entire page view, its bitmap cache and
        // the CGPDFDocument behind them. Closing a document has to hand that
        // back regardless, or a day of opening files leaves every one of them
        // resident until the app quits.
        printf("\n[8] closing a document releases its content even though AppKit\n"
               "    keeps the window alive forever\n");
        {
            long viewsBefore   = PVLiveCount("PVPageView");
            long cachesBefore  = PVLiveCount("PVImageCache");
            long sourcesBefore = PVLiveCount("PVPDFSource");
            NSWindow *heldWindow = nil;

            // Scoped: -valueForKey: hands back an autoreleased reference, and
            // the pool it would otherwise land in is main's, which does not
            // drain until the process exits. Without this the test itself keeps
            // the view tree alive and then reports the app for it.
            @autoreleasepool {
                NSError *e2 = nil;
                PVPDFSource *s3 = [[PVPDFSource alloc] initWithURL:url error:&e2];
                PVWindowController *wc3 = [[PVWindowController alloc] initWithSource:s3 url:url];
                [wc3 showWindow:nil];
                Pump(0.4);
                OK(PVLiveCount("PVPageView") == viewsBefore + 1,
                   "the new document has a page view");

                heldWindow = [[wc3 window] retain];
                [[wc3 window] performClose:nil];
                Pump(0.3);
                OK([[wc3 valueForKey:@"_splitView"] superview] == nil,
                   "closing detaches the view tree from the window");
                OK([heldWindow toolbar] == nil, "and takes the toolbar with it");

                [wc3 release];
                [s3 release];
            }

            OK(PumpUntil(^{ return (BOOL)(PVLiveCount("PVPageView") == viewsBefore); }, 20.0),
               "releasing the controller frees the page view");
            // The page view is what holds the cache and the document, so these
            // are the numbers that say the memory actually came back.
            OK(PVLiveCount("PVImageCache") == cachesBefore,
               "and the bitmap cache it held");
            OK(PVLiveCount("PVPDFSource") == sourcesBefore,
               "and the parsed PDF behind it");
            printf("  (AppKit is still holding that window: isVisible=%d, never deallocated)\n",
                   (int)[heldWindow isVisible]);
            [heldWindow release];
        }

        printf("\n%d passed, %d failed\n", gPass, gFail);
        return (bad || gFail) ? 1 : 0;
    }
}
