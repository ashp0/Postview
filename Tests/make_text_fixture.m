// A text-heavy fixture: what `read` actually reads.
//
// build/heavy.pdf is 1400 random bezier curves per page. That is the right
// fixture for "make the renderer sweat", and the wrong one for the banding
// question: curves that span the page are re-processed by every band, but they
// are also cheap to reject, and the fixture has only ~40 lines of text. A book
// page is the opposite -- thousands of glyph-positioning operations in one
// content stream, all of which every band has to walk past to find its own.
//
// Banding has to be costed against both or it is costed against neither.
#import <Cocoa/Cocoa.h>
int main(int argc, const char **argv) {
  @autoreleasepool {
    int pages = (argc > 2) ? atoi(argv[2]) : 60;
    NSURL *out = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
    CGRect media = CGRectMake(0,0,612,792);
    CGContextRef c = CGPDFContextCreateWithURL((CFURLRef)out, &media, NULL);
    NSString *sample =
      @"The question is not whether a band is smaller than a page, which it "
      @"plainly is, but whether the work of producing one is smaller in the "
      @"same proportion. A content stream has no index; every band walks it "
      @"from the beginning. ";
    for (int p = 0; p < pages; p++) {
      CGContextBeginPage(c, &media);
      CGContextSetRGBFillColor(c, 1,1,1,1); CGContextFillRect(c, media);
      NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithGraphicsPort:(void *)c flipped:NO];
      [NSGraphicsContext saveGraphicsState]; [NSGraphicsContext setCurrentContext:gc];
      NSMutableString *body = [NSMutableString string];
      // ~62 lines of 9pt text: a dense trade-paperback page, and roughly the
      // glyph count of a journal article set two columns to a page.
      for (int l = 0; l < 26; l++) [body appendFormat:@"%d. %@\n", l+1, sample];
      [[NSString stringWithFormat:@"Chapter %d", p+1]
        drawAtPoint:NSMakePoint(60,742)
         withAttributes:@{NSFontAttributeName:[NSFont boldSystemFontOfSize:16]}];
      [body drawInRect:NSMakeRect(60,50,492,675)
        withAttributes:@{NSFontAttributeName:[NSFont fontWithName:@"Times-Roman" size:9]
                                             ?: [NSFont systemFontOfSize:9]}];
      [NSGraphicsContext restoreGraphicsState];
      CGContextEndPage(c);
    }
    CGPDFContextClose(c); CGContextRelease(c);
  }
  return 0;
}
