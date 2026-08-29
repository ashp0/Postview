//  PVPageView.h — the scrolling document view.
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
    NSUInteger     _pageCount;
    CGFloat        _zoom;
    CGFloat        _backingScale;
    CGFloat        _contentWidth;
    NSColor       *_backgroundColor;
    BOOL           _laidOut;
    // A pinch is in progress. Tracked because the two systems this has to run
    // on disagree about how a gesture ends; see -magnifyWithEvent:.
    BOOL           _magnifying;
    __unsafe_unretained id <PVPageViewDelegate> _delegate;
}
- (id)initWithSource:(PVPDFSource *)source cache:(PVImageCache *)cache;
- (void)setDelegate:(id <PVPageViewDelegate>)delegate;

- (void)setZoom:(CGFloat)zoom backingScale:(CGFloat)scale containerWidth:(CGFloat)width;
- (CGFloat)zoom;

- (NSRect)rectForPage:(NSUInteger)index;
- (CGSize)pixelSizeForPage:(NSUInteger)index;      // exact bitmap size wanted
- (NSRange)pageRangeInRect:(NSRect)rect;
- (NSUInteger)pageAtTopOfRect:(NSRect)rect fraction:(CGFloat *)outFraction;
- (void)setNeedsDisplayForPage:(NSUInteger)index;
- (BOOL)isLaidOut;
@end
