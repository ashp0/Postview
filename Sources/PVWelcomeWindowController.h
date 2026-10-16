//  PVWelcomeWindowController.h — the empty state.
//
//  Launching Postview from its icon opens this and nothing else: no document,
//  no Open panel, no file reopened from a previous session. It waits for a PDF
//  to be dropped anywhere on it, offers the documents you had open recently,
//  and closes itself as soon as a document window exists.

#import "PVCommon.h"

@class PVDropView;

@interface PVWelcomeWindowController : NSWindowController
    <NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate>
{
    PVDropView     *_dropView;
    NSScrollView   *_recentScroll;
    NSTableView    *_recentTable;
    // The recent documents that still exist on disk, newest first. A snapshot
    // taken when the window is shown, not a second copy of the history:
    // NSDocumentController owns the list, this holds what is currently on
    // screen from it.
    NSMutableArray *_recents;
    // Which check of the history against the disk is the current one, and
    // which was last put on screen. The check runs off the main thread (see
    // -reloadRecents), so an older one can finish after a newer one started,
    // and the same one can be offered twice; both are refused by these.
    unsigned long   _recentsGeneration;
    unsigned long   _appliedGeneration;
}
+ (PVWelcomeWindowController *)sharedController;
+ (void)showWelcome;
+ (void)hideWelcomeIfShowing;

// Re-read the document history and rebuild the list. Called whenever the
// window is about to be shown, which is the only time it can have changed
// without the window being on screen to notice.
- (void)reloadRecents;
@end
