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
    // The document paths THIS process has changed since its last successful
    // write.
    //
    // Every process loads the file once and, until now, wrote the whole
    // dictionary back. Two copies of Postview reading different documents --
    // which is the ordinary way a document-based app is used -- therefore each
    // held a snapshot taken at their own launch, and whichever quit last
    // overwrote everything the other had recorded. The user loses the reading
    // position in every document they had open in the other window.
    //
    // Writing only the keys this process actually touched, merged onto whatever
    // is on disk at write time, makes the two independent: they collide only
    // when they genuinely disagree about the same document, and then the later
    // write wins, which is the right answer.
    NSMutableSet        *_dirtyKeys;
}
+ (PVStateStore *)sharedStore;

// Designated initialiser. The shared store resolves its own path; naming the
// file explicitly exists so the on-disk format can be exercised against a
// scratch file instead of the reading positions the user actually cares about.
// A nil path gives a store that never touches the disk.
- (id)initWithPath:(NSString *)path;

// `columns` is how many pages were side by side: 1 for the single-page
// column, 2 for the spread. A file written by a build that predates the
// spread has no such key, and reads back as 1 -- the layout every one of
// those documents was actually last seen in.
//
// `cover` is the book layout: the first page alone, the rest paired. It is
// stored beside the count rather than folded into it -- there is no column
// count that means "two, offset by one" -- and it is normalised against the
// count at both ends, so a single column never comes back with a cover.
// Missing reads back as NO, which is what every file written before the
// layout existed correctly describes.
- (void)recordForURL:(NSURL *)url
                page:(NSUInteger)page
            fraction:(CGFloat)fraction
            zoomMode:(PVZoomMode)mode
                zoom:(CGFloat)zoom
             sidebar:(BOOL)sidebarVisible
             columns:(NSUInteger)columns
               cover:(BOOL)cover
         windowFrame:(NSString *)frameString;

- (BOOL)stateForURL:(NSURL *)url
               page:(NSUInteger *)outPage
           fraction:(CGFloat *)outFraction
           zoomMode:(PVZoomMode *)outMode
               zoom:(CGFloat *)outZoom
            sidebar:(BOOL *)outSidebar
            columns:(NSUInteger *)outColumns
              cover:(BOOL *)outCover
        windowFrame:(NSString **)outFrame;

- (void)flush;
@end
