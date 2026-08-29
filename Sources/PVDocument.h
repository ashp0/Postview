//  PVDocument.h — read-only NSDocument wrapper.
//  Using NSDocument gives Open Recent, drag-and-drop opening, "Open With",
//  multiple windows and reopen-at-launch without writing any of it.

#import "PVCommon.h"
#import "PVPDFSource.h"

@interface PVDocument : NSDocument {
    PVPDFSource *_source;
}
@end
