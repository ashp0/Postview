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
#include <sys/resource.h>   // the scroll-back probe reports process CPU
#include <stdlib.h>          // setenv, for the rasterisation census

// The census is off unless asked for, and PVStatsEnabled() resolves it once via
// dispatch_once -- so it has to be set before anything at all touches it, which
// means before main() runs rather than at the top of main(). A constructor is
// the only place early enough that is still inside this file.
//
// Turning it on for the whole suite only adds counting; no decision anywhere
// reads a counter. It is on so that [5g5] can assert the motion gate actually
// increments the counter that was added for it -- an uncounted counter is
// exactly the bug being fixed, and it would be absurd to reintroduce it here.
__attribute__((constructor)) static void PVEnableStatsForTests(void)
{
    setenv("POSTVIEW_STATS", "1", 1);
}

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
// The bounds-change handler, which is where the wanted-set rebuild early-out
// lives. Missing here it still dispatched -- the selector exists -- but the
// compiler inferred a return type of id for a void method and said so on every
// build, and a warning that is always present is a warning nobody reads.
- (void)clipBoundsChanged:(NSNotification *)note;
- (void)scrollToPage:(NSUInteger)page fraction:(CGFloat)fraction;
- (void)scrollClipTo:(NSPoint)p;
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

// Drive the viewport the way an input device does, and count what the scheduler
// asks for.
//
// Both devices reach the scheduler through exactly one door. -keyDown: calls
// -[PVPageView scrollByPoints:], which calls -[NSClipView scrollToPoint:]; the
// trackpad and wheel are handled by NSScrollView itself, because PVPageView
// deliberately does NOT override -scrollWheel: (that is the precondition for
// +isCompatibleWithResponsiveScrolling). Both end at the same clip-view bounds
// change and therefore at -clipBoundsChanged:.
//
// So moving the clip view directly is not an approximation of either device --
// it is the code both of them run. The ONLY thing that differs between them is
// the pair of live-scroll notifications AppKit posts for gestures and not for
// keys, and `gesture` adds exactly those.
//
// usleep rather than the run loop, so both variants present the same elapsed
// time between bounds changes and are therefore judged at the same speed. The
// bounds notification is posted synchronously by -scrollToPoint:, so nothing
// here needs the run loop to run.
static void DriveScroll(PVWindowController *wc, NSScrollView *sv,
                        BOOL gesture, CGFloat step, useconds_t gapUs, int steps,
                        int warmup, NSUInteger *outFulls, NSUInteger *outPreviews)
{
    NSClipView *clip = [sv contentView];

    // Both variants start from rest with no speed history, which is what
    // -willStartLiveScroll: does for a gesture. Stated for the keyboard variant
    // too, or the comparison would be between a fresh gesture and whatever the
    // previous phase of the test left behind.
    [wc setValue:[NSNumber numberWithDouble:0.0] forKey:@"_scrollSpeed"];
    [wc setValue:[NSNumber numberWithDouble:0.0] forKey:@"_lastScrollTime"];

    if (gesture)
        [[NSNotificationCenter defaultCenter]
            postNotificationName:NSScrollViewWillStartLiveScrollNotification object:sv];

    // `warmup` moves happen before the counters are armed.
    //
    // Speed is computed from the gap between two bounds changes, so the FIRST
    // change of any movement carries no speed measurement at all, and the policy
    // renders when it has no evidence -- deliberately, and documented in
    // PVShouldRenderWhileMoving. A gesture is exempt from that one event because
    // AppKit says a scroll is beginning before it begins; the keyboard has no
    // such announcement, and nothing can invent one from a single key press that
    // is genuinely indistinguishable from a deliberate page-down.
    //
    // That one event is the whole of the difference between the devices. With
    // warmup 0 it is included and the counts differ by it; with warmup 1 the
    // comparison is between two movements that both have a speed, which is where
    // the claim "one path, one policy" is either true or false.
    PVFullRequestCount = 0; PVPreviewRequestCount = 0;

    int i;
    for (i = 0; i < steps; i++) {
        if (i == warmup) {
            PVFullRequestCount = 0; PVPreviewRequestCount = 0;
            PVCountRequests = YES;
        }
        NSRect vis = [clip documentVisibleRect];
        CGFloat maxY = NSHeight([[sv documentView] frame]) - NSHeight(vis);
        CGFloat y = NSMinY(vis) + step;
        if (y > maxY) y = maxY;
        if (y < 0) y = 0;
        [clip scrollToPoint:NSMakePoint(NSMinX(vis), y)];
        [sv reflectScrolledClipView:clip];
        if (gapUs) usleep(gapUs);
    }

    PVCountRequests = NO;
    if (outFulls)    *outFulls    = PVFullRequestCount;
    if (outPreviews) *outPreviews = PVPreviewRequestCount;

    if (gesture)
        [[NSNotificationCenter defaultCenter]
            postNotificationName:NSScrollViewDidEndLiveScrollNotification object:sv];
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

        // Pinned to battery for the whole suite, and this is load-bearing
        // rather than tidy.
        //
        // Almost everything below asserts the scheduler's cautious behaviour --
        // no full-resolution bitmaps while the document moves, prefetch of one
        // page, the motion gate reporting what it withheld. That is the battery
        // policy. On mains power PVRenderPolicyFor deliberately opens the motion
        // gate, so on a desktop, or on a laptop that happens to be charging,
        // those assertions would fail for a reason that is not a regression --
        // and, far worse, would pass or fail depending on where the machine was
        // plugged in when the suite ran. A gate whose verdict depends on that is
        // not a gate.
        //
        // The AC branch is not skipped: TestPowerAwareScheduling below turns it
        // on explicitly, asserts what it changes, and turns it back off. This is
        // the same reason Tools/showdown.sh pins -PVPowerState battery.
        PVSetPowerSourceOverride(PVPowerBattery, YES);

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

        // The strip rebuilds its wanted set only when the visible range changes
        // -- the same early-out -clipBoundsChanged: has for the page view, and
        // worth it for the same reason: dragging the strip posts a bounds
        // notification per frame, and an identical range gives an identical
        // answer.
        //
        // The failure it can cause is the one pinned here. -hideSidebar empties
        // the thumbnail cache, and reopening the strip at the page it was closed
        // on produces the identical visible range -- so an early-out that
        // remembered that range across the hide would recognise it, decline to
        // ask, and leave a sidebar of empty boxes until something else moved it.
        // Driven through the real show/hide rather than by reading the flag,
        // because the flag being right is not the claim; the thumbnails coming
        // back is.
        printf("\n[5c] the thumbnail early-out is reset when the cache is emptied\n");
        {
            PVImageCache *tc = [wc valueForKey:@"_thumbCache"];
            [wc showSidebar];
            OK(PumpUntil(^{ return (BOOL)([tc entryCount] > 0); }, 20.0),
               "reopening the sidebar renders thumbnails");
            NSUInteger firstFill = [tc entryCount];
            [wc hideSidebar];
            OK([tc entryCount] == 0, "hiding it empties the cache again");
            [wc showSidebar];
            OK(PumpUntil(^{ return (BOOL)([tc entryCount] >= firstFill); }, 20.0),
               "reopening at the same page refills it: the early-out is not sticky");
            [wc hideSidebar];
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

        // The keep-test applied to an arriving bitmap, which is the other half
        // of what the wanted-set asked for and until now did not match it.
        //
        // Prefetch only ever looks forward along _lastDirection. The keep-test
        // was symmetric, so a full bitmap arriving for the page one BEHIND a
        // moving viewport was stored -- ~28 MB in the profiling window, for a
        // page nothing had asked about and that already has a preview. The two
        // now agree: PV_FULL_PREFETCH_PAGES ahead, nothing behind.
        //
        // Driven by handing the controller a delivery directly, because that is
        // the decision under test. Waiting for the real queue to produce a
        // bitmap for a page outside the visible range would be testing the
        // prefetch policy instead, and would be timing-dependent.
        printf("\n[5g3] an arriving full bitmap is kept ahead of the viewport, not behind it\n");
        {
            PVRenderQueue *pq     = [wc valueForKey:@"_pageQueue"];
            PVImageCache  *pcache = [wc valueForKey:@"_pageCache"];

            [wc goToPageNumber:20];
            PumpUntil(^{ return [pq isIdle]; }, 60.0);
            [wc updateVisibleContent];          // establishes _lastRequestRange

            NSRange vis = [[wc valueForKey:@"_lastRequestRange"] rangeValue];
            NSInteger behind = (NSInteger)vis.location - 1;
            NSInteger ahead  = (NSInteger)NSMaxRange(vis);
            OK(behind >= 0 && ahead < (NSInteger)[[wc valueForKey:@"_source"] pageCount],
               "the probe has a page on each side of the visible range to test with");

            // One small synthetic bitmap, delivered as though it were a full
            // page. Size does not matter to the keep-test; only the page index
            // and the direction of travel do.
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGContextRef bc = CGBitmapContextCreate(NULL, 32, 32, 8, 0, cs,
                (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host);
            CGColorSpaceRelease(cs);
            CGImageRef img = bc ? CGBitmapContextCreateImage(bc) : NULL;
            if (bc) CGContextRelease(bc);
            CGSize px = CGSizeMake(32, 32);

            if (!img) {
                OK(NO, "could not build the synthetic bitmap for the delivery probe");
            } else {
                // Travelling forwards.
                [wc setValue:[NSNumber numberWithBool:YES] forKey:@"_hasMovedViewport"];
                [wc setValue:[NSNumber numberWithInt:1]    forKey:@"_lastDirection"];

                [pcache removeAll];
                [wc renderQueue:pq didRenderPage:(NSUInteger)ahead image:img
                      pixelSize:px preview:NO];
                OK([pcache fullImageForPage:(NSUInteger)ahead pixelSize:px] != NULL,
                   "forwards: the page ahead of the viewport is kept");

                [pcache removeAll];
                [wc renderQueue:pq didRenderPage:(NSUInteger)behind image:img
                      pixelSize:px preview:NO];
                OK([pcache fullImageForPage:(NSUInteger)behind pixelSize:px] == NULL,
                   "forwards: the page behind it is dropped, not stored");

                // A preview for the same trailing page is still kept. This is
                // the thing that makes scrolling back instant, and it is ~1/9
                // the pixels, so it is not what the memory work is aimed at.
                [pcache removeAll];
                [wc renderQueue:pq didRenderPage:(NSUInteger)behind image:img
                      pixelSize:px preview:YES];
                OK([pcache hasPreviewForPage:(NSUInteger)behind],
                   "...but its preview is kept: preview retention stays symmetric");

                // Travelling backwards: the window flips with the direction.
                [wc setValue:[NSNumber numberWithInt:-1] forKey:@"_lastDirection"];

                [pcache removeAll];
                [wc renderQueue:pq didRenderPage:(NSUInteger)behind image:img
                      pixelSize:px preview:NO];
                OK([pcache fullImageForPage:(NSUInteger)behind pixelSize:px] != NULL,
                   "backwards: the window flips and the page above is kept");

                [pcache removeAll];
                [wc renderQueue:pq didRenderPage:(NSUInteger)ahead image:img
                      pixelSize:px preview:NO];
                OK([pcache fullImageForPage:(NSUInteger)ahead pixelSize:px] == NULL,
                   "backwards: the page below is now the trailing one and is dropped");

                // Before the viewport has ever moved there is no direction to
                // widen along, and none is invented: the window is the visible
                // range exactly, which is also all the wanted-set asks for.
                [wc setValue:[NSNumber numberWithBool:NO] forKey:@"_hasMovedViewport"];
                [wc setValue:[NSNumber numberWithInt:1]   forKey:@"_lastDirection"];
                [pcache removeAll];
                [wc renderQueue:pq didRenderPage:(NSUInteger)ahead image:img
                      pixelSize:px preview:NO];
                OK([pcache fullImageForPage:(NSUInteger)ahead pixelSize:px] == NULL,
                   "before the first movement the window is the visible range and nothing more");

                [pcache removeAll];
                [wc renderQueue:pq didRenderPage:vis.location image:img
                      pixelSize:px preview:NO];
                OK([pcache fullImageForPage:vis.location pixelSize:px] != NULL,
                   "...and a visible page is always kept, in every direction");

                CGImageRelease(img);
                [wc setValue:[NSNumber numberWithBool:YES] forKey:@"_hasMovedViewport"];
            }
        }

        // The cost of the change above, measured rather than assumed.
        //
        // Dropping the trailing page's full bitmap means a scroll-back
        // re-renders it. ENGINEERING.md section 4.3 says that is the price
        // and says to measure it; this is the measurement. Page forward N, page
        // back over the same N, and report what the scheduler asked for and what
        // the process actually spent on each leg.
        //
        // The bound asserted is the theoretical worst case of the change: at
        // most one extra full-resolution render per page revisited. Anything
        // above that is not the trailing page being re-rendered, it is the cache
        // thrashing, which is a different and much more expensive failure.
        printf("\n[5g4] scroll-back probe: what the directional keep-window costs\n");
        {
            PVRenderQueue *pq     = [wc valueForKey:@"_pageQueue"];
            PVImageCache  *pcache = [wc valueForKey:@"_pageCache"];
            const NSInteger kSteps = 8;
            const NSInteger kStart = 10;

            [pcache removeAll];
            [wc goToPageNumber:kStart];
            PumpUntil(^{ return [pq isIdle]; }, 60.0);

            struct rusage ru;
            double cpu0 = 0, cpu1 = 0, cpu2 = 0;
            if (getrusage(RUSAGE_SELF, &ru) == 0)
                cpu0 = (double)ru.ru_utime.tv_sec + (double)ru.ru_utime.tv_usec / 1.0e6 +
                       (double)ru.ru_stime.tv_sec + (double)ru.ru_stime.tv_usec / 1.0e6;

            PVFullRequestCount = 0; PVPreviewRequestCount = 0; PVCountRequests = YES;

            // A settle after every jump, not just an idle queue. A page jump
            // moves the viewport, which registers as motion, which closes the
            // full-resolution gate -- so the queue goes idle at once having
            // asked for nothing, and a probe that only waited for idle would
            // measure a scroll rather than a reader. PV_SETTLE_SECONDS past the
            // last movement the sharp pass is asked for, and that pass is the
            // work this probe exists to count.
            NSInteger step;
            for (step = 1; step <= kSteps; step++) {
                [wc goToPageNumber:kStart + step];
                Pump(PV_SETTLE_SECONDS + PV_SPEED_FRESH_SECONDS);
                PumpUntil(^{ return [pq isIdle]; }, 60.0);
            }
            NSUInteger fullsForward = PVFullRequestCount;
            if (getrusage(RUSAGE_SELF, &ru) == 0)
                cpu1 = (double)ru.ru_utime.tv_sec + (double)ru.ru_utime.tv_usec / 1.0e6 +
                       (double)ru.ru_stime.tv_sec + (double)ru.ru_stime.tv_usec / 1.0e6;

            PVFullRequestCount = 0;
            for (step = kSteps - 1; step >= 0; step--) {
                [wc goToPageNumber:kStart + step];
                Pump(PV_SETTLE_SECONDS + PV_SPEED_FRESH_SECONDS);
                PumpUntil(^{ return [pq isIdle]; }, 60.0);
            }
            NSUInteger fullsBack = PVFullRequestCount;
            PVCountRequests = NO;
            if (getrusage(RUSAGE_SELF, &ru) == 0)
                cpu2 = (double)ru.ru_utime.tv_sec + (double)ru.ru_utime.tv_usec / 1.0e6 +
                       (double)ru.ru_stime.tv_sec + (double)ru.ru_stime.tv_usec / 1.0e6;

            printf("  forward %ld pages : %lu full requests, %.2f s CPU\n",
                   (long)kSteps, (unsigned long)fullsForward, cpu1 - cpu0);
            printf("  back    %ld pages : %lu full requests, %.2f s CPU\n",
                   (long)kSteps, (unsigned long)fullsBack, cpu2 - cpu1);
            printf("  scroll-back cost : %+ld full requests, %+.2f s CPU\n",
                   (long)fullsBack - (long)fullsForward, (cpu2 - cpu1) - (cpu1 - cpu0));
            printf("  (this host is not the arbiter; the ratio is the point, not the seconds)\n");

            OK(fullsForward > 0, "the forward leg asked for full-resolution bitmaps at all");
            char msg[200];
            snprintf(msg, sizeof msg,
                     "the return leg costs at most one extra full render per page "
                     "(%lu back vs %lu forward, bound %ld)",
                     (unsigned long)fullsBack, (unsigned long)fullsForward,
                     (long)fullsForward + kSteps);
            OK((NSInteger)fullsBack <= (NSInteger)fullsForward + kSteps, msg);
        }

        // Device parity, measured rather than argued.
        //
        // The claim under test is that trackpad/wheel scrolling and keyboard
        // scrolling reach the render scheduler through one path and are decided
        // by one policy. [5g2] shows the policy is device-independent; this
        // shows the two devices actually produce the same requests, by driving
        // the same viewport at the same speed with and without the live-scroll
        // notifications that are the only thing AppKit does differently for a
        // gesture.
        //
        // Written to fail if anyone reintroduces a device test. The original bug
        // was exactly that -- `!_liveScrolling && !_liveZooming` guarding the
        // expensive half of the work -- and it would show up here as a keyboard
        // count that is not the gesture count.
        printf("\n[5g5] trackpad and keyboard reach the scheduler through one path\n");
        {
            PVRenderQueue *pq     = [wc valueForKey:@"_pageQueue"];
            PVImageCache  *pcache = [wc valueForKey:@"_pageCache"];
            NSScrollView  *sv     = [wc valueForKey:@"_scrollView"];

            [wc goToPageNumber:8];
            PumpUntil(^{ return [pq isIdle]; }, 60.0);
            Pump(PV_SETTLE_SECONDS + PV_SPEED_FRESH_SECONDS);
            PumpUntil(^{ return [pq isIdle]; }, 60.0);

            // Fast: 300 pt every 5 ms is 60,000 pt/s, a hard flick. Once either
            // device is moving at a measured speed, neither may ask for a
            // full-resolution bitmap and neither may ask for a preview of a page
            // that will be gone before it arrives.
            NSUInteger kbFull = 0, kbPrev = 0, tpFull = 0, tpPrev = 0;

            [pcache removeAll];
            DriveScroll(wc, sv, NO,  300, 5000, 12, 1, &kbFull, &kbPrev);
            [pcache removeAll];
            DriveScroll(wc, sv, YES, 300, 5000, 12, 1, &tpFull, &tpPrev);

            printf("  flick (~60,000 pt/s), once moving: keyboard %lu full / %lu preview,"
                   "  trackpad %lu full / %lu preview\n",
                   (unsigned long)kbFull, (unsigned long)kbPrev,
                   (unsigned long)tpFull, (unsigned long)tpPrev);

            OK(kbFull == 0, "flick, keyboard: no full-resolution bitmap is asked for");
            OK(tpFull == 0, "flick, trackpad: no full-resolution bitmap is asked for");
            OK(kbFull == tpFull && kbPrev == tpPrev,
               "flick: the two devices ask for exactly the same set");

            // The first bounds change of a movement, which is the one place the
            // two devices genuinely differ and the reason the comparison above
            // skips it.
            //
            // A gesture is announced before it starts, so its first event is
            // already known to be a scroll. A key press is not announced and the
            // first one is indistinguishable from a deliberate single page-down,
            // so the policy does what it does everywhere else with no evidence:
            // it renders. That costs one wanted-set rebuild per scroll episode --
            // per episode, not per key, because a gap under half a second keeps
            // the speed measurement alive across the whole of a held key.
            //
            // Recorded rather than removed. Removing it means either rendering
            // nothing on a single deliberate page-down, which is the case
            // `read` is made of and where sharp pages are the whole point, or
            // inferring a scroll from key auto-repeat -- a behaviour change that
            // moves CPU and must be judged on the Mavericks machine, not here.
            NSUInteger kbFirst = 0, tpFirst = 0, kbFirstPrev = 0, tpFirstPrev = 0;
            [pcache removeAll];
            DriveScroll(wc, sv, NO,  300, 5000, 12, 0, &kbFirst, &kbFirstPrev);
            [pcache removeAll];
            DriveScroll(wc, sv, YES, 300, 5000, 12, 0, &tpFirst, &tpFirstPrev);
            printf("  flick including its first event : keyboard %lu full,"
                   "  trackpad %lu full  (difference is the announced-gesture bit)\n",
                   (unsigned long)kbFirst, (unsigned long)tpFirst);
            OK(tpFirst == 0,
               "an announced gesture asks for nothing even on its first event");
            OK(kbFirst <= 2,
               "an unannounced scroll costs at most one rebuild's worth of full requests");

            // The motion gate's own counter. Before this key existed the gate
            // appeared in no column of any profile: `scroll` reported zero
            // suppressed requests while the gate was suppressing everything,
            // because the PVStatAdd it would have run sits inside the branch the
            // gate closes. Both flicks above ran with the gate shut, so the
            // counter must have moved -- and the dwell counter must not have,
            // since at 60,000 pt/s the gate closes before any page is dwell-tested.
            double motion = PVStatValue(PVStatMotionSuppressed);
            printf("  motion-gate suppressions counted so far: %.0f "
                   "(dwell: %.0f)\n", motion, PVStatValue(PVStatRequestsSuppressed));
            OK(PVStatsEnabled(), "the census is enabled for this suite");
            OK(motion > 0,
               "the motion gate now reports the full renders it withheld");

            // The paired RSS reading. The showdown subtracts this from the
            // resident high-water mark to say how much of the peak is NOT
            // rendered pixels, and that subtraction is only a quantity if both
            // terms describe the same instant -- which is the whole reason the
            // app takes the reading itself instead of the sampler taking a
            // maximum of its own.
            //
            // Asserted as an inequality rather than a value, because the value
            // is whatever this machine's frameworks weigh. The inequality is
            // the part that would break if the pairing did: RSS at the moment
            // the bitmaps peaked cannot be smaller than the bitmaps, since they
            // are resident memory and are counted in it.
            double rssAtPeak = PVStatValue(PVStatRSSAtPeakResident);
            double residentPeak = (double)PVResidentHighWater();
            printf("  rss at the bitmap peak: %.1f MB, bitmaps %.1f MB\n",
                   rssAtPeak / (1024.0 * 1024.0), residentPeak / (1024.0 * 1024.0));
            OK(rssAtPeak > 0,
               "RSS is sampled at the instant the bitmap census peaks");
            OK(rssAtPeak >= residentPeak,
               "...and is never smaller than the bitmaps it contains");

            // Slow: 8 pt every 40 ms is 200 pt/s, a deliberate read-along drag.
            // Every page survives the dwell test at that speed, so the per-page
            // policy says "render" for both devices -- and here the two DO
            // diverge, because -viewportIsMoving short-circuits on the gesture
            // flag before it ever consults the speed.
            //
            // Reported, not asserted equal, because it is a deliberate trade and
            // not the bug: the flag covers the first bounds change of a flick,
            // where no speed has been measured yet and the alternative is
            // rasterising whole pages at 60,000 pt/s. What it costs is that a
            // slow trackpad drag holds the sharp pass until the fingers lift,
            // where a slow keyboard scroll gets it PV_SETTLE_SECONDS after the
            // last key. Both end in the same call; only the trigger differs.
            // Counted over the whole episode, first event included, because the
            // question here is what a slow movement costs in total on each
            // device rather than whether the two agree once under way.
            [pcache removeAll];
            DriveScroll(wc, sv, NO,  8, 40000, 6, 0, &kbFull, &kbPrev);
            [pcache removeAll];
            DriveScroll(wc, sv, YES, 8, 40000, 6, 0, &tpFull, &tpPrev);

            printf("  drag  (~200 pt/s), whole episode : keyboard %lu full / %lu preview,"
                   "  trackpad %lu full / %lu preview\n",
                   (unsigned long)kbFull, (unsigned long)kbPrev,
                   (unsigned long)tpFull, (unsigned long)tpPrev);
            printf("  (the announced gesture makes the trackpad the more conservative\n"
                   "   of the two at every speed; it never makes it the less)\n");
            OK(tpFull <= kbFull,
               "a gesture never asks for MORE full bitmaps than the keyboard at the same speed");

            // The end of the gesture is the settle, and it is the same settle.
            // -didEndLiveScroll: and -settleFired: both zero the speed, clear
            // _haveRequestState and call -updateVisibleContent; this asserts the
            // outcome rather than the identity of the two methods.
            [pcache removeAll];
            PVFullRequestCount = 0; PVCountRequests = YES;
            [[NSNotificationCenter defaultCenter]
                postNotificationName:NSScrollViewDidEndLiveScrollNotification object:sv];
            NSUInteger afterGestureEnd = PVFullRequestCount;

            [pcache removeAll];
            PVFullRequestCount = 0;
            [wc setValue:[NSNumber numberWithDouble:0.0] forKey:@"_scrollSpeed"];
            [wc setValue:[NSNumber numberWithDouble:0.0] forKey:@"_lastScrollTime"];
            [wc setValue:[NSNumber numberWithBool:NO]    forKey:@"_haveRequestState"];
            [wc updateVisibleContent];
            NSUInteger afterKeyboardSettle = PVFullRequestCount;
            PVCountRequests = NO;

            printf("  settle: gesture end asks for %lu full, keyboard settle asks for %lu\n",
                   (unsigned long)afterGestureEnd, (unsigned long)afterKeyboardSettle);
            OK(afterGestureEnd > 0 && afterGestureEnd == afterKeyboardSettle,
               "both devices end their movement in the same sharp pass");
            OK(![[wc valueForKey:@"_liveScrolling"] boolValue],
               "the gesture flag is clear once the gesture has ended");

            PumpUntil(^{ return [pq isIdle]; }, 90.0);
        }

        // The AC branch, driven through the same real controller as everything
        // above, because a policy that is only ever exercised as a pure function
        // is a policy nobody has run.
        //
        // Two claims, and the second matters more than the first. On mains power
        // the blanket motion gate is replaced by a per-page cost question, so a
        // slow deliberate drag does ask for sharp pages where on battery it asks
        // for none. But the cost question still has to refuse a genuine flick --
        // if plugging in a laptop turned the flick pathology back on, this whole
        // branch would be a regression wearing a feature's clothes.
        printf("\n[5g6] on mains power the motion gate becomes a per-page cost question\n");
        {
            PVRenderQueue *pq     = [wc valueForKey:@"_pageQueue"];
            PVImageCache  *pcache = [wc valueForKey:@"_pageCache"];
            NSScrollView  *sv     = [wc valueForKey:@"_scrollView"];
            PVCostModel   *cost   = [pq costModel];

            [wc goToPageNumber:8];
            PumpUntil(^{ return [pq isIdle]; }, 60.0);
            Pump(PV_SETTLE_SECONDS + PV_SPEED_FRESH_SECONDS);
            PumpUntil(^{ return [pq isIdle]; }, 60.0);

            // The model has to have something to say before its effect can be
            // asserted, and by this point in the suite the document has been
            // rendered many times over. Checked rather than assumed: if it were
            // empty the AC branch would fall back to the constant and the test
            // below would be measuring nothing.
            printf("  cost model: %lu full samples at %.1f ms/Mpx, "
                   "%lu preview samples at %.1f ms/Mpx\n",
                   (unsigned long)[cost sampleCountForPreview:NO],
                   [cost msPerMegapixelForPreview:NO],
                   (unsigned long)[cost sampleCountForPreview:YES],
                   [cost msPerMegapixelForPreview:YES]);
            OK([cost sampleCountForPreview:NO] >= PV_COST_MIN_SAMPLES,
               "the cost model has measured this document by now");

            NSUInteger acFull = 0, acPrev = 0, batFull = 0, batPrev = 0;

            // A slow deliberate drag, the same one [5g5] uses, on each branch.
            //
            // Counted over the whole episode -- warmup 0 -- and that is not a
            // detail. Six 8 pt steps move the viewport 48 pt, which does not
            // change the visible page range, so -clipBoundsChanged:'s early-out
            // correctly declines to rebuild the wanted set for every event after
            // the first. Skipping the first event would leave nothing to count
            // on either branch and the test would pass by measuring silence.
            // A gesture is announced before it starts, so `moving` is already
            // true on that first event and the battery branch is still being
            // asked the question it refuses.
            // _haveRequestState is cleared before each drag, symmetrically.
            //
            // Without it the second of the two runs measures the early-out
            // rather than the policy: -clipBoundsChanged: rebuilds the wanted
            // set only when the page range, the direction or the motion state
            // has changed, and two consecutive slow drags over 48 pt change none
            // of the three -- so the second one would record zero requests on
            // whichever branch happened to go second and the comparison would be
            // between a policy and an optimisation. This is the same thing
            // -settleFired: does, for the same stated reason.
            PVSetPowerSourceOverride(PVPowerBattery, YES);
            [pcache removeAll];
            [wc setValue:[NSNumber numberWithBool:NO] forKey:@"_haveRequestState"];
            DriveScroll(wc, sv, YES, 8, 40000, 6, 0, &batFull, &batPrev);
            PumpUntil(^{ return [pq isIdle]; }, 90.0);

            PVSetPowerSourceOverride(PVPowerAC, YES);
            [pcache removeAll];
            [wc setValue:[NSNumber numberWithBool:NO] forKey:@"_haveRequestState"];
            DriveScroll(wc, sv, YES, 8, 40000, 6, 0, &acFull, &acPrev);
            PumpUntil(^{ return [pq isIdle]; }, 90.0);

            printf("  slow drag (~200 pt/s): battery %lu full / %lu preview,"
                   "  AC %lu full / %lu preview\n",
                   (unsigned long)batFull, (unsigned long)batPrev,
                   (unsigned long)acFull,  (unsigned long)acPrev);
            OK(batFull == 0, "battery: a slow gesture drag asks for no sharp pages");
            OK(acFull > 0,   "AC: the same drag does ask for sharp pages");

            // And the safety property, which must hold on every power source
            // and on every machine. At 60,000 pt/s a page is on screen for
            // roughly 20 ms, so no prediction and no power source can make
            // rasterising it worth anything -- the dwell floor refuses it before
            // the cost model is even consulted.
            NSUInteger acFlick = 0, acFlickPrev = 0;
            [pcache removeAll];
            DriveScroll(wc, sv, YES, 300, 5000, 12, 1, &acFlick, &acFlickPrev);
            PumpUntil(^{ return [pq isIdle]; }, 90.0);
            printf("  flick (~60,000 pt/s) on AC: %lu full / %lu preview\n",
                   (unsigned long)acFlick, (unsigned long)acFlickPrev);
            OK(acFlick == 0,
               "AC: a genuine flick still asks for no full-resolution bitmaps");

            // Prefetch depth follows the policy, and the delivery keep-window
            // has to agree with it. These two numbers describe one window from
            // opposite ends; if they disagree the extra page is rasterised,
            // dropped on delivery, and asked for again on the next event.
            PVRenderPolicy acPolicy  = PVRenderPolicyFor(PVPowerAC, PVRamTierOfThisMachine(), 0);
            PVRenderPolicy batPolicy = PVRenderPolicyFor(PVPowerBattery, PVRamTierOfThisMachine(), 0);
            printf("  prefetch depth on this machine (tier %d): battery %lu, AC %lu\n",
                   (int)PVRamTierOfThisMachine(),
                   (unsigned long)batPolicy.fullPrefetchPages,
                   (unsigned long)acPolicy.fullPrefetchPages);
            OK(acPolicy.fullPrefetchPages >= batPolicy.fullPrefetchPages,
               "AC never prefetches less than battery");
            OK(PVRenderPolicyFitsCache(acPolicy, PVRamTierOfThisMachine()),
               "this machine's AC prefetch depth fits its own cache budget");

            // Back to battery for everything that follows, so the rest of the
            // suite keeps asserting the policy it was written against.
            PVSetPowerSourceOverride(PVPowerBattery, YES);
            [pcache removeAll];
            PumpUntil(^{ return [pq isIdle]; }, 90.0);
        }

        printf("\n[5g7] an arrow press moves the viewport by one eighth of itself\n");
        {
            // PVArrowScrollForViewportHeight is pinned by pvtest as a pure
            // function. What that cannot show is that -keyDown: actually calls
            // it, which is the half the showdown measures: the recorded failure
            // was 200 presses moving Postview 6 pages against Preview's 13, and
            // it was a real NSEvent that produced it. So this drives a real
            // NSEvent through the real view and reads the clip view afterwards.
            PVPageView   *pv   = [wc valueForKey:@"_pageView"];
            NSScrollView *sv   = [wc valueForKey:@"_scrollView"];
            NSClipView   *clip = [sv contentView];

            [wc goToPageNumber:8];
            Pump(0.05);

            NSString *down = [NSString stringWithFormat:@"%C",
                                  (unichar)NSDownArrowFunctionKey];
            NSString *up   = [NSString stringWithFormat:@"%C",
                                  (unichar)NSUpArrowFunctionKey];
            NSEvent *downEvent =
                [NSEvent keyEventWithType:NSEventTypeKeyDown
                                 location:NSZeroPoint
                            modifierFlags:0
                                timestamp:0
                             windowNumber:[[wc window] windowNumber]
                                  context:nil
                               characters:down
              charactersIgnoringModifiers:down
                                isARepeat:NO
                                  keyCode:125];
            NSEvent *upEvent =
                [NSEvent keyEventWithType:NSEventTypeKeyDown
                                 location:NSZeroPoint
                            modifierFlags:0
                                timestamp:0
                             windowNumber:[[wc window] windowNumber]
                                  context:nil
                               characters:up
              charactersIgnoringModifiers:up
                                isARepeat:NO
                                  keyCode:126];

            CGFloat viewport = NSHeight([clip documentVisibleRect]);
            CGFloat expected = PVArrowScrollForViewportHeight(viewport);

            CGFloat before = NSMinY([clip documentVisibleRect]);
            [pv keyDown:downEvent];
            CGFloat afterDown = NSMinY([clip documentVisibleRect]);
            [pv keyDown:upEvent];
            CGFloat afterUp = NSMinY([clip documentVisibleRect]);

            OK(fabs((afterDown - before) - expected) < 1.0,
               "a Down press moves the viewport by the computed step");
            OK(fabs(afterUp - before) < 1.0,
               "an Up press puts it back");
            OK(expected > 60.0,
               "the step is larger than the flat 60 pt that failed the showdown");

            // Ten presses travel ten steps, so the showdown's 200 are not
            // being eaten by rounding inside -scrollByPoints:.
            CGFloat start = NSMinY([clip documentVisibleRect]);
            int kp;
            for (kp = 0; kp < 10; kp++) [pv keyDown:downEvent];
            CGFloat travelled = NSMinY([clip documentVisibleRect]) - start;
            OK(fabs(travelled - 10.0 * expected) < 2.0,
               "ten presses travel ten steps, with no drift");

            [wc goToPageNumber:8];
            Pump(0.05);
        }

        printf("\n[5g8] a programmatic scroll records where it actually landed\n");
        {
            // _lastScrollY is the controller's memory of where the viewport was,
            // and -clipBoundsChanged: measures both direction and speed as the
            // difference between it and what the clip view reports next.
            //
            // Every programmatic scroll rounds its target to a whole point, and
            // AppKit constrains the result again to the document's bounds. The
            // two scrolling paths used to record the number they had ASKED for,
            // so the very next bounds notification measured up to half a point
            // of travel that never happened. Half a point sits exactly on the
            // direction threshold (`y > _lastScrollY + 0.5`), and divided by the
            // 2 ms floor on a sample interval it is ~250 pt/s of scrolling
            // reported for a viewport that was standing still -- into an
            // estimator that is deliberately seeded from its first sample.
            //
            // Asserted as an exact equality on purpose. This is not a tolerance
            // question: the recorded position either is where the viewport is or
            // it is a number about nothing.
            NSScrollView *sv   = [wc valueForKey:@"_scrollView"];
            NSClipView   *clip = [sv contentView];

            NSUInteger probes[4] = { 0, 3, 12, 37 };
            BOOL exact = YES, exactAfterFraction = YES;
            unsigned k;
            for (k = 0; k < 4; k++) {
                [wc scrollToPage:probes[k] fraction:0];
                Pump(0.05);
                double recorded = [[wc valueForKey:@"_lastScrollY"] doubleValue];
                double actual   = (double)NSMinY([clip documentVisibleRect]);
                if (recorded != actual) exact = NO;

                // A fractional offset is where the rounding actually bites: the
                // target is page origin + fraction * height, which is rarely a
                // whole number.
                [wc scrollToPage:probes[k] fraction:0.37f];
                Pump(0.05);
                recorded = [[wc valueForKey:@"_lastScrollY"] doubleValue];
                actual   = (double)NSMinY([clip documentVisibleRect]);
                if (recorded != actual) exactAfterFraction = NO;
            }
            OK(exact, "after a page jump the recorded position is the real one");
            OK(exactAfterFraction,
               "...and after a jump to a fractional offset, where rounding bites");

            // A target past the end is clamped by AppKit, not by the caller's
            // arithmetic, which is the other way the two used to disagree.
            [wc scrollClipTo:NSMakePoint(0, 1.0e9)];
            Pump(0.05);
            OK([[wc valueForKey:@"_lastScrollY"] doubleValue] ==
                   (double)NSMinY([clip documentVisibleRect]),
               "a scroll clamped by the document's own bounds is recorded as clamped");

            // The property all of that exists for: the notification a
            // programmatic scroll causes must measure no travel at all.
            [wc setValue:[NSNumber numberWithDouble:0.0] forKey:@"_scrollSpeed"];
            [wc setValue:[NSNumber numberWithDouble:
                             [NSDate timeIntervalSinceReferenceDate] - 0.003]
                  forKey:@"_lastScrollTime"];
            [wc scrollToPage:20 fraction:0.61f];
            [wc clipBoundsChanged:nil];
            OK([[wc valueForKey:@"_scrollSpeed"] doubleValue] == 0.0,
               "so the notification it causes reports no speed, because there was none");
        }

        printf("\n[5g9] a viewport with nothing in it forgets the set it just dropped\n");
        {
            // -updateVisibleContent's degenerate branch clears the cache's pin
            // and the queue's pending set, because neither describes anything
            // any more. _lastRequestRange / _haveRequestState are the record OF
            // that set, and -clipBoundsChanged: skips the whole rebuild whenever
            // the range it computes matches them.
            //
            // Leaving the record standing while emptying the two things it is a
            // record of is the one combination that cannot be right: a viewport
            // that goes empty and comes back to the same page range is then
            // recognised as unchanged, and the rebuild that would have re-pinned
            // the visible pages and re-requested their bitmaps never runs.
            //
            // Reached here by handing the controller a page view that has not
            // been laid out, which is exactly what -pageRangeInRect: answers
            // with an empty range for.
            PVPageView *real  = [[wc valueForKey:@"_pageView"] retain];
            PVImageCache *pc  = [wc valueForKey:@"_pageCache"];
            PVPDFSource  *psrc = [wc valueForKey:@"_source"];
            PVPageView *blank = [[PVPageView alloc] initWithSource:psrc cache:pc];

            [wc updateVisibleContent];
            OK([[wc valueForKey:@"_haveRequestState"] boolValue],
               "a laid-out viewport records the set it asked for");

            [wc setValue:blank forKey:@"_pageView"];
            [wc updateVisibleContent];
            OK(![blank isLaidOut], "the stand-in page view really has no layout");
            OK(![[wc valueForKey:@"_haveRequestState"] boolValue],
               "an empty viewport drops the record along with the set it describes");

            [wc setValue:real forKey:@"_pageView"];
            [blank release];
            [real release];
            // Put the controller back to a state the sections after this one can
            // rely on, rather than leaving them to inherit a torn-down one.
            [wc updateVisibleContent];
            PumpUntil(^{ return [(PVRenderQueue *)[wc valueForKey:@"_pageQueue"] isIdle]; }, 60.0);
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

            // Deliberately no event: -endGestureWithEvent: must not read one,
            // because the only way to reach it in a test is without one. The
            // current SDK annotates the parameter nonnull, so passing a literal
            // nil warns; a variable says the same thing without the diagnostic,
            // and the point of the check is that the implementation copes.
            NSEvent *noEvent = nil;

            [pv endGestureWithEvent:noEvent];      // the Mavericks route
            OK(![[wc valueForKey:@"_liveZooming"] boolValue],
               "-endGestureWithEvent: ends the gesture, which is how Mavericks ends it");
            OK(![[pv valueForKey:@"_magnifying"] boolValue],
               "and the view stops considering itself mid-gesture");

            // A second end -- a system that sends both a phase and a bracket --
            // must not report the gesture twice.
            [wc setValue:[NSNumber numberWithBool:YES] forKey:@"_liveZooming"];
            [pv endGestureWithEvent:noEvent];
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
            //
            // Waited for, not sampled once. These two used to be bare
            // comparisons taken the instant the page view count reached zero,
            // on the assumption that whatever the page view held died with it.
            // It does not have to: the render queue's worker block holds its own
            // reference to the source until it next looks at the stop flags, and
            // a delivery already queued holds the cache until it runs on the
            // main thread -- the same asynchronous unwind pvstress's
            // SettlesToZero exists for. So the assertion was racing, and it lost
            // roughly one run in three on this host: `and the parsed PDF behind
            // it` failed while `and the bitmap cache it held` passed, and both
            // passed on the immediately following run.
            //
            // A deadline keeps the assertion honest -- an object that never
            // comes back still fails, twenty seconds later -- while a single
            // sample was only ever asserting that this machine happened to be
            // quick enough. A flaky gate is worse than a missing one: it teaches
            // you to re-run until green, which is exactly how the ASan failure
            // in ENGINEERING.md section 9.6 survived for as long as it did.
            OK(PumpUntil(^{ return (BOOL)(PVLiveCount("PVImageCache") == cachesBefore); }, 20.0),
               "and the bitmap cache it held");
            OK(PumpUntil(^{ return (BOOL)(PVLiveCount("PVPDFSource") == sourcesBefore); }, 20.0),
               "and the parsed PDF behind it");
            printf("  (AppKit is still holding that window: isVisible=%d, never deallocated)\n",
                   (int)[heldWindow isVisible]);
            [heldWindow release];
        }

        printf("\n%d passed, %d failed\n", gPass, gFail);
        return (bad || gFail) ? 1 : 0;
    }
}
