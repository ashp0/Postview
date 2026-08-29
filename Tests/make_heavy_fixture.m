// Generates a deliberately heavy multi-page test PDF: lots of vector paths and
// text per page, which is exactly the kind of document that makes Preview crawl.
#import <Cocoa/Cocoa.h>
int main(int argc, const char **argv) {
  @autoreleasepool {
    int pages = (argc > 2) ? atoi(argv[2]) : 60;
    NSURL *out = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
    CGRect media = CGRectMake(0,0,612,792);
    CGContextRef c = CGPDFContextCreateWithURL((CFURLRef)out, &media, NULL);
    for (int p = 0; p < pages; p++) {
      CGContextBeginPage(c, &media);
      CGContextSetRGBFillColor(c, 1,1,1,1); CGContextFillRect(c, media);
      // heavy vector content
      srandom(p * 7919);
      for (int i = 0; i < 1400; i++) {
        CGContextSetRGBStrokeColor(c, (random()%100)/100.0,(random()%100)/100.0,(random()%100)/100.0,0.55);
        CGContextSetLineWidth(c, 0.4 + (random()%20)/20.0);
        CGContextMoveToPoint(c, random()%612, random()%792);
        CGContextAddCurveToPoint(c, random()%612,random()%792, random()%612,random()%792, random()%612,random()%792);
        CGContextStrokePath(c);
      }
      NSString *label = [NSString stringWithFormat:@"Page %d", p+1];
      NSMutableString *body = [NSMutableString string];
      for (int l = 0; l < 40; l++) [body appendFormat:@"Line %d of page %d — the quick brown fox jumps over the lazy dog. 0123456789\n", l+1, p+1];
      NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithCGContext:c flipped:NO];
      [NSGraphicsContext saveGraphicsState]; [NSGraphicsContext setCurrentContext:gc];
      [[NSColor colorWithWhite:1 alpha:0.85] setFill]; NSRectFillUsingOperation(NSMakeRect(40,40,532,712), NSCompositingOperationSourceOver);
      [label drawAtPoint:NSMakePoint(60,730) withAttributes:@{NSFontAttributeName:[NSFont boldSystemFontOfSize:28]}];
      [body drawInRect:NSMakeRect(60,60,500,650) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:11]}];
      [NSGraphicsContext restoreGraphicsState];
      CGContextEndPage(c);
    }
    CGPDFContextClose(c); CGContextRelease(c);
  }
  return 0;
}
