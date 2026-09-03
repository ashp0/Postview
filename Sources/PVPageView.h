//  PVPageView.h — the scrolling document view.
//
//  Pages are laid out in ROWS. A row holds one page in the ordinary
//  single-page column and two side by side in the two-page spread, and the
//  number of columns is the only thing that differs between them: there is no
//  second layout path, no second drawing path, and nothing outside this class
//  has to know which one is in force. Everything the controller asks for is
//  still asked in pages -- which pages are visible, which page is at the top,
//  where a page is -- and the answers happen to come from a row.
//
//  -drawRect: never rasterises PDF content. It only blits bitmaps that the
//  render queue has already produced, which is what keeps scrolling smooth:
//  exposing a strip of a page costs a memcpy, not a page render. When a bitmap
//  at the exact zoom is not ready yet, a lower resolution one is stretched over
//  the gap so the user never sees a blank page.

#import "PVCommon.h"
#import "PVPDFSource.h"
#import "PVImageCache.h"

@class PVPageView;

// The vertical band one row of pages occupies.
//
// The search for what is on screen runs over these rather than over the page
// frames, and that is not a convenience. A binary search needs its predicate
// to be monotonic in the index it searches, and page frames stop being so the
// moment a row can hold two of them: facing pages are aligned at their tops,
// so a tall page beside a short one gives the LOWER page index the greater
// maximum y, and a search over frames can then step past the very row it is
// looking for. Rows are monotonic by construction -- each one begins below the
// last -- so the search is over the thing that actually has the property.
typedef struct {
    CGFloat y;         // top of the row, in the flipped view's coordinates
    CGFloat height;    // the tallest page in it
} PVPageRow;

// Pinch-to-zoom. The view recognises the gesture and reports it; deciding what
// a zoom means -- the limits, the mode, what stays under the fingers, when to
// re-render -- belongs to the controller, which is where every other zoom in
// the app is already decided.
@protocol PVPageViewDelegate <NSObject>
// The fingers have gone down. Sent exactly once before any -magnifyBy:.
- (void)pageViewWillMagnify:(PVPageView *)view atPoint:(NSPoint)pointInView;
// A step of the gesture. `factor` is relative to the previous step, so the
// controller multiplies rather than tracking a baseline of its own.
- (void)pageView:(PVPageView *)view magnifyBy:(CGFloat)factor;
// The fingers have come off. Sent exactly once, whichever way the system
// chose to tell us the gesture had finished.
- (void)pageViewDidMagnify:(PVPageView *)view;
@optional
// Two-finger double tap: the system's "zoom this in, or put it back" gesture.
- (void)pageViewSmartMagnify:(PVPageView *)view atPoint:(NSPoint)pointInView;
@end

@interface PVPageView : NSView {
    PVPDFSource   *_source;
    PVImageCache  *_cache;
    NSMutableData *_frames;        // NSRect, one per page
    NSMutableData *_rows;          // PVPageRow, one per row
    NSUInteger     _rowCount;
    // Pages per row: 1 for the single-page column, 2 for the spread. Held
    // here rather than as a "mode" because the layout below needs a count and
    // nothing else about it.
    //
    // This is the count that has been ASKED for. It is not the one any query
    // may be answered from: -setColumns: moves it, and the row table that
    // describes the geometry is not rebuilt until the next layout pass, so
    // between those two moments the two disagree.
    NSUInteger     _columns;
    // The column count the row table was actually built with.
    //
    // Every question about where something is -- which pages a rect covers,
    // which row a page belongs to -- is answered from this and never from
    // _columns, because those answers index the row table and must use the
    // shape the row table actually has. Using the requested count instead is
    // not a stale answer but an out-of-range one: with _columns at 2 and a
    // table still holding one row per page, `row * columns` runs off the end
    // of the document, and the range built from it underflows to a length of
    // billions. Nothing in the app can currently observe that window -- the
    // controller always relayouts in the same turn of the run loop that it
    // sets the count -- which is exactly the kind of guarantee that holds
    // until someone adds a call between the two.
    NSUInteger     _laidOutColumns;
    // The cover layout: the first page alone, the rest paired 2-3, 4-5, the
    // way a book opens on a title page. Requested and laid-out halves, held
    // apart for exactly the reason the column count is -- every query indexes
    // the row table, so it must use the pairing the table was built with and
    // not the one that has been asked for.
    BOOL           _cover;
    BOOL           _laidOutCover;
    // The column count or the cover flag changed and the geometry has not
    // caught up yet. The early-out in -setZoom:... compares zoom, scale and
    // width, none of which move when only the shape of a row does -- so
    // without this, turning the spread on while the window sat still was a
    // layout that never ran.
    BOOL           _layoutDirty;
    NSUInteger     _pageCount;
    CGFloat        _zoom;
    CGFloat        _backingScale;
    CGFloat        _contentWidth;
    NSColor       *_backgroundColor;
    BOOL           _laidOut;
    // A pinch is in progress. Tracked because the two systems this has to run
    // on disagree about how a gesture ends; see -magnifyWithEvent:.
    BOOL           _magnifying;

    // The animated arrow-key scroll, when one is running. See
    // -scrollByPoints:animated: for what each field is for and why the
    // destination is tracked separately from where the document currently is.
    //
    // The timer RETAINS this view, and through it the cache and the document
    // behind it, so it is not merely a wakeup left running: it is the whole
    // document graph held resident by a scroll nobody is watching. Invalidated
    // when the animation lands, when the view leaves its window, and by
    // -cancelScrollAnimation, which the controller calls on teardown for the
    // same reason it cancels its own two timers there.
    NSTimer       *_scrollTimer;
    CGFloat        _scrollFrom;      // where the animation started, in points
    CGFloat        _scrollTo;        // where it is going: the sum of every
                                     // press so far, not where the view is now
    CGFloat        _scrollLastSet;   // the position this view last wrote, so a
                                     // scroll from anywhere else can be seen
    double         _scrollStart;     // PVMonotonicSeconds() at the first frame

    // Drag-to-pan. The mouse-down point in WINDOW coordinates and the scroll
    // offset at that moment.
    //
    // The window, because it is the only frame of reference in the drag that
    // does not move while the drag moves it. This view scrolls under the
    // pointer, and a clip view's bounds origin IS the scroll offset -- so a
    // delta measured in either one already contains the travel that has been
    // applied, and feeding it back in makes the document run away from the
    // pointer. See -mouseDragged:.
    BOOL           _panning;
    BOOL           _panMoved;        // the hand has left the deadband
    NSPoint        _panAnchor;       // mouse-down, in window coordinates
    NSPoint        _panOrigin;       // documentVisibleRect origin at mouse-down

    __unsafe_unretained id <PVPageViewDelegate> _delegate;
}
- (id)initWithSource:(PVPDFSource *)source cache:(PVImageCache *)cache;
- (void)setDelegate:(id <PVPageViewDelegate>)delegate;

- (void)setZoom:(CGFloat)zoom backingScale:(CGFloat)scale containerWidth:(CGFloat)width;
- (CGFloat)zoom;

// How many pages sit side by side. Clamped to 1...PV_MAX_PAGE_COLUMNS. Takes
// effect at the next -setZoom:backingScale:containerWidth:, which the
// controller always issues straight afterwards; on its own this only records
// the intent, so that one relayout serves both changes.
- (void)setColumns:(NSUInteger)columns;
- (NSUInteger)columns;

// The cover layout: page one on its own, the rest in pairs. Takes effect at
// the next -setZoom:backingScale:containerWidth: exactly as -setColumns: does,
// and has no effect at all in a single column -- there is no pairing there for
// a cover page to be the exception to, and PVPagesInFirstRow normalises that
// rather than leaving each caller to remember it.
- (void)setCover:(BOOL)cover;
- (BOOL)cover;
// The cover flag the geometry on screen was built with. The companion to
// -laidOutColumns, and like it the only one a row or range answer may be
// derived from.
- (BOOL)laidOutCover;
// The column count the geometry currently on screen was built with. Equal to
// -columns except between a -setColumns: and the layout that answers it, and
// it is this one -- never -columns -- that every row and range answer is
// derived from. Exposed so a test can hold the two apart on purpose.
- (NSUInteger)laidOutColumns;

- (NSRect)rectForPage:(NSUInteger)index;
// The band the page's whole row occupies: the union of the frames of the
// pages sharing it. Identical to -rectForPage: in the single-page column.
//
// This, not the page rect, is what a scroll position means. A reading
// position is stored as a page plus a fraction into it, and the two facing
// pages of a spread are at the same height -- so the fraction has to be into
// the row for the position to survive being restored, or reopening a document
// in the spread lands the reader somewhere they never were.
- (NSRect)rectForRowContainingPage:(NSUInteger)index;
// The first page of the row `index` sits in: `index` itself when there is one
// column, and the even-indexed page of the pair when there are two.
- (NSUInteger)firstPageOfRowContainingPage:(NSUInteger)index;
- (CGSize)pixelSizeForPage:(NSUInteger)index;      // exact bitmap size wanted
- (NSRange)pageRangeInRect:(NSRect)rect;
- (NSUInteger)pageAtTopOfRect:(NSRect)rect fraction:(CGFloat *)outFraction;
- (void)setNeedsDisplayForPage:(NSUInteger)index;
- (BOOL)isLaidOut;

// Stop any animated scroll that is running and leave the document exactly
// where the animation had got to.
//
// Idempotent, and safe to call when nothing is animating. The controller calls
// it on teardown -- an NSTimer retains its target, so a live one here holds
// the whole document graph past the point the controller has finished with it
// -- and it is called internally by every other way of moving the document, so
// that a wheel, a drag or a jump is never fought by a scroll that was already
// on its way somewhere else.
- (void)cancelScrollAnimation;
// Whether one is running. For the tests, which have to be able to tell an
// animation that was declined from one that finished in the same instant.
- (BOOL)isScrollAnimating;
@end
