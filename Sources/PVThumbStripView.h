//  PVThumbStripView.h — the on-demand thumbnail sidebar.
//
//  Nothing here exists until the user actually asks for thumbnails: the window
//  controller creates this view, a second PDF source and a second render queue
//  only when the sidebar is first shown, and tears all three down when it is
//  hidden. Thumbnails are rendered lazily for visible rows only.

#import "PVCommon.h"
#import "PVPDFSource.h"
#import "PVImageCache.h"

#define PV_THUMB_BOX_W   112.0
#define PV_THUMB_BOX_H   140.0
#define PV_THUMB_LABEL_H  15.0
#define PV_THUMB_GAP      10.0

@class PVThumbStripView;

@protocol PVThumbStripDelegate <NSObject>
- (void)thumbStrip:(PVThumbStripView *)strip didChoosePage:(NSUInteger)page;
@end

@interface PVThumbStripView : NSView {
    PVPDFSource  *_source;
    PVImageCache *_cache;
    NSUInteger    _pageCount;
    NSUInteger    _currentPage;
    CGFloat       _backingScale;
    NSDictionary *_labelAttrs;
    NSDictionary *_labelAttrsSelected;
    __unsafe_unretained id <PVThumbStripDelegate> _delegate;
}
- (id)initWithSource:(PVPDFSource *)source cache:(PVImageCache *)cache;
- (void)setDelegate:(id <PVThumbStripDelegate>)delegate;
- (void)setBackingScale:(CGFloat)scale;
- (void)setCurrentPage:(NSUInteger)page;
- (NSRect)rectForPage:(NSUInteger)index;
- (CGSize)pixelSizeForPage:(NSUInteger)index;
- (NSRange)pageRangeInRect:(NSRect)rect;
- (void)setNeedsDisplayForPage:(NSUInteger)index;
- (CGFloat)requiredWidth;
@end
