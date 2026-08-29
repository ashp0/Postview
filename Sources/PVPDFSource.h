//  PVPDFSource.h — a CGPDFDocument wrapper with precomputed page geometry.
//
//  Threading contract: -initWithURL: does all CoreGraphics work up front and
//  caches every page size. After init, -pointSizeOfPage: reads only immutable
//  memory and is safe from any thread, while -createImageForPage:pixelSize:
//  touches the CGPDFDocumentRef and must be called from one queue only.
//  (CGPDFDocument is not thread safe, so each render queue owns its own source.)

#import "PVCommon.h"

@interface PVPDFSource : NSObject {
    CGPDFDocumentRef  _doc;
    NSUInteger        _pageCount;
    CGSize           *_sizes;      // rotation-corrected point sizes
    CGSize            _maxSize;
    NSURL            *_url;
}
- (id)initWithURL:(NSURL *)url error:(NSError **)outError;
// Same, but copies page geometry from an already-open source instead of
// re-walking the page tree. The CGPDFDocumentRef is still separate, so the
// two sources can safely render on two different queues.
- (id)initWithURL:(NSURL *)url geometryFrom:(PVPDFSource *)other error:(NSError **)outError;
- (NSUInteger)pageCount;
- (CGSize)pointSizeOfPage:(NSUInteger)index;   // 0-based
- (CGSize)maxPointSize;
// Returns a +1 retained CGImageRef, or NULL. Owning queue only.
//
// CF_RETURNS_RETAINED is what makes that sentence checkable. The bitmap
// travels from the render queue's worker, through a block, onto the main
// thread and into the cache, and the balancing release is three files away
// from the create; stating the ownership in the type lets the static analyser
// follow it instead of taking the comment's word for it.
- (CGImageRef)createImageForPage:(NSUInteger)index pixelSize:(CGSize)px CF_RETURNS_RETAINED;
@end
