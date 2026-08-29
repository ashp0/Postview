//  PVStateStore.h — remembers where you were in each document.
//
//  Position is stored as a page index plus a fraction into that page, not as a
//  raw scroll offset, so it restores correctly even if you reopen at a different
//  zoom or window size. Writes are deliberately rare: everything is kept in
//  memory and flushed only when a document closes, when the app is deactivated,
//  and at quit. Nothing polls, and no timer ever runs.

#import "PVCommon.h"

@interface PVStateStore : NSObject {
    NSMutableDictionary *_docs;    // path -> state dictionary
    NSString            *_path;    // resolved once; nil means memory only
    BOOL                 _dirty;
}
+ (PVStateStore *)sharedStore;

// Designated initialiser. The shared store resolves its own path; naming the
// file explicitly exists so the on-disk format can be exercised against a
// scratch file instead of the reading positions the user actually cares about.
// A nil path gives a store that never touches the disk.
- (id)initWithPath:(NSString *)path;

- (void)recordForURL:(NSURL *)url
                page:(NSUInteger)page
            fraction:(CGFloat)fraction
            zoomMode:(PVZoomMode)mode
                zoom:(CGFloat)zoom
             sidebar:(BOOL)sidebarVisible
         windowFrame:(NSString *)frameString;

- (BOOL)stateForURL:(NSURL *)url
               page:(NSUInteger *)outPage
           fraction:(CGFloat *)outFraction
           zoomMode:(PVZoomMode *)outMode
               zoom:(CGFloat *)outZoom
            sidebar:(BOOL *)outSidebar
        windowFrame:(NSString **)outFrame;

- (void)flush;
@end
