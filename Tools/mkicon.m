//  mkicon.m — generates Postview.iconset. Built for the HOST machine only;
//  it never ships inside the app, so it is free to use modern APIs.
//  usage: mkicon <output.iconset directory>
//
//  Drawn rather than traced: every size is rendered from the same code at its
//  own resolution, so the 16 pt icon is not a resampled 1024 pt one. That also
//  lets the detail thin out as the icon shrinks -- the trees, the reflection,
//  the lens rings and the traffic lights are all skipped below the size at
//  which they stop being shapes and start being noise. What survives at 16 pt
//  is the silhouette: a rounded window with a bright landscape in it and a dark
//  loupe over one corner.

#import <Cocoa/Cocoa.h>

#pragma mark - Small drawing helpers

static void RoundRect(CGContextRef c, CGRect r, CGFloat radius)
{
    if (radius > r.size.width  / 2) radius = r.size.width  / 2;
    if (radius > r.size.height / 2) radius = r.size.height / 2;
    CGContextMoveToPoint(c, CGRectGetMinX(r) + radius, CGRectGetMinY(r));
    CGContextAddArcToPoint(c, CGRectGetMaxX(r), CGRectGetMinY(r), CGRectGetMaxX(r), CGRectGetMaxY(r), radius);
    CGContextAddArcToPoint(c, CGRectGetMaxX(r), CGRectGetMaxY(r), CGRectGetMinX(r), CGRectGetMaxY(r), radius);
    CGContextAddArcToPoint(c, CGRectGetMinX(r), CGRectGetMaxY(r), CGRectGetMinX(r), CGRectGetMinY(r), radius);
    CGContextAddArcToPoint(c, CGRectGetMinX(r), CGRectGetMinY(r), CGRectGetMaxX(r), CGRectGetMinY(r), radius);
    CGContextClosePath(c);
}

// A vertical gradient between two RGBA colours, over the current clip.
static void VGradient(CGContextRef c, CGRect r,
                      const CGFloat top[4], const CGFloat bottom[4])
{
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat comps[8];
    memcpy(comps,     bottom, 4 * sizeof(CGFloat));
    memcpy(comps + 4, top,    4 * sizeof(CGFloat));
    CGFloat locs[2] = { 0.0, 1.0 };
    CGGradientRef g = CGGradientCreateWithColorComponents(cs, comps, locs, 2);
    CGContextDrawLinearGradient(c, g,
        CGPointMake(CGRectGetMidX(r), CGRectGetMinY(r)),
        CGPointMake(CGRectGetMidX(r), CGRectGetMaxY(r)), 0);
    CGGradientRelease(g);
    CGColorSpaceRelease(cs);
}

static void RadialGradient(CGContextRef c, CGPoint centre, CGFloat radius,
                           const CGFloat inner[4], const CGFloat outer[4])
{
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat comps[8];
    memcpy(comps,     inner, 4 * sizeof(CGFloat));
    memcpy(comps + 4, outer, 4 * sizeof(CGFloat));
    CGFloat locs[2] = { 0.0, 1.0 };
    CGGradientRef g = CGGradientCreateWithColorComponents(cs, comps, locs, 2);
    CGContextDrawRadialGradient(c, g, centre, 0, centre, radius,
                                kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(g);
    CGColorSpaceRelease(cs);
}

static void FillCircle(CGContextRef c, CGPoint p, CGFloat r)
{
    CGContextFillEllipseInRect(c, CGRectMake(p.x - r, p.y - r, 2 * r, 2 * r));
}

// Adds a circle to the current path WITHOUT filling it, for clipping.
// -CGContextFillEllipseInRect fills immediately and leaves the path empty, and
// -CGContextClip on an empty path is a no-op rather than a clip to nothing --
// so using the filling form before a clip silently leaves the clip wide open,
// and the next gradient floods the whole icon.
static void CirclePath(CGContextRef c, CGPoint p, CGFloat r)
{
    CGContextAddEllipseInRect(c, CGRectMake(p.x - r, p.y - r, 2 * r, 2 * r));
}

#pragma mark - The landscape inside the window

// A ridge line across `r`, given as normalised (x, height) peaks. Drawn as a
// filled polygon down to the waterline so it can also be flipped to make its
// own reflection.
static void RidgePath(CGContextRef c, CGRect r, CGFloat baseY,
                      const CGFloat *peaks, int n)
{
    CGContextMoveToPoint(c, CGRectGetMinX(r), baseY);
    int i;
    for (i = 0; i < n; i++) {
        CGFloat x = CGRectGetMinX(r) + peaks[i * 2] * r.size.width;
        CGFloat y = baseY + peaks[i * 2 + 1] * r.size.height;
        CGContextAddLineToPoint(c, x, y);
    }
    CGContextAddLineToPoint(c, CGRectGetMaxX(r), baseY);
    CGContextClosePath(c);
}

// Alternating peaks and valleys. Kept in one place so the reflection is drawn
// from exactly the same numbers as the range above it.
static const CGFloat kRidgeFar[] = {
    0.00, 0.10,  0.09, 0.34,  0.17, 0.16,  0.27, 0.46,  0.34, 0.22,
    0.44, 0.52,  0.52, 0.28,  0.61, 0.48,  0.70, 0.20,  0.79, 0.40,
    0.88, 0.18,  0.96, 0.33,  1.00, 0.14
};
static const int kRidgeFarN = (int)(sizeof(kRidgeFar) / sizeof(kRidgeFar[0]) / 2);

static void DrawTrees(CGContextRef c, CGRect band, CGFloat S, int count, CGFloat scale)
{
    // Deterministic: the icon must come out identical on every build.
    unsigned seed = 12345u;
    int i;
    for (i = 0; i < count; i++) {
        seed = seed * 1103515245u + 12345u;
        CGFloat t  = (CGFloat)((seed >> 16) & 0x7fff) / 32767.0;
        seed = seed * 1103515245u + 12345u;
        CGFloat t2 = (CGFloat)((seed >> 16) & 0x7fff) / 32767.0;

        CGFloat x = CGRectGetMinX(band) + t * band.size.width;
        CGFloat h = band.size.height * (0.55 + t2 * 0.75) * scale;
        CGFloat w = h * 0.42;
        CGFloat y = CGRectGetMinY(band);
        CGContextMoveToPoint(c, x - w / 2, y);
        CGContextAddLineToPoint(c, x, y + h);
        CGContextAddLineToPoint(c, x + w / 2, y);
        CGContextClosePath(c);
        CGContextFillPath(c);
    }
    (void)S;
}

static void DrawLandscape(CGContextRef c, CGRect photo, CGFloat S)
{
    BOOL fine = (S >= 64);
    CGFloat waterY = CGRectGetMinY(photo) + photo.size.height * 0.38;

    // Sky.
    CGContextSaveGState(c);
    CGContextClipToRect(c, photo);
    {
        const CGFloat top[4]    = { 0.20, 0.44, 0.74, 1.0 };
        const CGFloat bottom[4] = { 0.78, 0.88, 0.95, 1.0 };
        VGradient(c, photo, top, bottom);
    }

    CGRect range = CGRectMake(CGRectGetMinX(photo), waterY,
                              photo.size.width, photo.size.height * 0.48);

    // The lake first, so the range can be reflected into it.
    CGRect lake = CGRectMake(CGRectGetMinX(photo), CGRectGetMinY(photo),
                             photo.size.width, waterY - CGRectGetMinY(photo));
    {
        const CGFloat top[4]    = { 0.40, 0.57, 0.70, 1.0 };
        const CGFloat bottom[4] = { 0.18, 0.31, 0.45, 1.0 };
        CGContextSaveGState(c);
        CGContextClipToRect(c, lake);
        VGradient(c, lake, top, bottom);
        CGContextRestoreGState(c);
    }

    if (fine) {
        // The range, mirrored into the water and dimmed. Drawn before the real
        // one so the waterline stays crisp.
        CGContextSaveGState(c);
        CGContextClipToRect(c, lake);
        CGContextTranslateCTM(c, 0, 2 * waterY);
        CGContextScaleCTM(c, 1, -1);
        CGContextSetRGBFillColor(c, 0.30, 0.40, 0.50, 0.80);
        RidgePath(c, range, waterY, kRidgeFar, kRidgeFarN);
        CGContextFillPath(c);
        CGContextRestoreGState(c);
    }

    if (fine) {
        CGContextSaveGState(c);
        CGContextSetRGBStrokeColor(c, 0.86, 0.92, 0.97, 0.55);
        CGContextSetLineWidth(c, fmax(0.75, S * 0.004));
        CGContextMoveToPoint(c, CGRectGetMinX(photo), waterY);
        CGContextAddLineToPoint(c, CGRectGetMaxX(photo), waterY);
        CGContextStrokePath(c);
        CGContextRestoreGState(c);
    }

    // The range itself.
    CGContextSetRGBFillColor(c, 0.42, 0.47, 0.53, 1.0);
    RidgePath(c, range, waterY, kRidgeFar, kRidgeFarN);
    CGContextFillPath(c);

    if (fine) {
        // Snow: the same ridge, clipped to its top third.
        CGContextSaveGState(c);
        RidgePath(c, range, waterY, kRidgeFar, kRidgeFarN);
        CGContextClip(c);
        CGContextClipToRect(c, CGRectMake(CGRectGetMinX(range),
                                          waterY + range.size.height * 0.26,
                                          range.size.width, range.size.height));
        CGContextSetRGBFillColor(c, 0.96, 0.97, 0.99, 1.0);
        CGContextFillRect(c, CGRectMake(CGRectGetMinX(range), waterY,
                                        range.size.width, range.size.height * 2));
        CGContextRestoreGState(c);

        // A dark conifer treeline along the shore, heavier at the edges.
        CGRect treeBand = CGRectMake(CGRectGetMinX(photo), waterY,
                                     photo.size.width, photo.size.height * 0.15);
        CGContextSetRGBFillColor(c, 0.13, 0.24, 0.17, 1.0);
        DrawTrees(c, treeBand, S, 26, 1.0);

        // A stony foreground bank across the bottom: one shape, with rounded
        // bumps along its top edge. Drawn as a bank rather than as loose
        // stones because loose stones at this size are a row of brown eggs.
        CGFloat bankH = photo.size.height * 0.075;
        CGFloat bankY = CGRectGetMinY(photo) + bankH;
        CGContextSetRGBFillColor(c, 0.38, 0.35, 0.32, 1.0);
        CGContextMoveToPoint(c, CGRectGetMinX(photo), CGRectGetMinY(photo));
        CGContextAddLineToPoint(c, CGRectGetMinX(photo), bankY);
        unsigned seed = 99u;
        int i, bumps = 7;
        for (i = 0; i <= bumps; i++) {
            seed = seed * 1103515245u + 12345u;
            CGFloat t = (CGFloat)((seed >> 16) & 0x7fff) / 32767.0;
            CGFloat x = CGRectGetMinX(photo) + photo.size.width * ((CGFloat)i / bumps);
            CGFloat y = bankY + bankH * (0.10 + t * 0.55);
            CGContextAddQuadCurveToPoint(c,
                x - photo.size.width / (bumps * 2.0), y + bankH * 0.30, x, y);
        }
        CGContextAddLineToPoint(c, CGRectGetMaxX(photo), CGRectGetMinY(photo));
        CGContextClosePath(c);
        CGContextFillPath(c);
    }

    CGContextRestoreGState(c);
}

#pragma mark - The loupe

static void DrawLoupe(CGContextRef c, CGPoint centre, CGFloat R, CGFloat S)
{
    BOOL fine = (S >= 64);

    // Handle, angled away from the lens towards the bottom-right corner.
    CGFloat a = -0.72;                        // radians from +x, pointing down-right
    CGPoint h0 = CGPointMake(centre.x + cos(a) * R * 0.92,
                             centre.y + sin(a) * R * 0.92);
    CGPoint h1 = CGPointMake(centre.x + cos(a) * R * 1.62,
                             centre.y + sin(a) * R * 1.62);
    CGContextSaveGState(c);
    CGContextSetShadowWithColor(c, CGSizeMake(0, -R * 0.06), R * 0.16,
        CGColorGetConstantColor(kCGColorBlack));
    CGContextSetLineCap(c, kCGLineCapRound);
    CGContextSetLineWidth(c, R * 0.34);
    CGContextSetRGBStrokeColor(c, 0.11, 0.11, 0.12, 1.0);
    CGContextMoveToPoint(c, h0.x, h0.y);
    CGContextAddLineToPoint(c, h1.x, h1.y);
    CGContextStrokePath(c);
    CGContextRestoreGState(c);

    // Barrel: a thick dark ring, lit from above.
    CGContextSaveGState(c);
    CGContextSetShadowWithColor(c, CGSizeMake(0, -R * 0.08), R * 0.22,
        CGColorGetConstantColor(kCGColorBlack));
    CGContextSetRGBFillColor(c, 0.10, 0.10, 0.11, 1.0);
    FillCircle(c, centre, R);
    CGContextRestoreGState(c);

    if (fine) {
        // A brushed collar around the lower half of the barrel, as on the
        // reference: a lighter ring peeking out from under the black.
        CGContextSaveGState(c);
        CGContextSetLineWidth(c, R * 0.075);
        CGContextSetRGBStrokeColor(c, 0.62, 0.63, 0.66, 0.85);
        CGContextAddArc(c, centre.x, centre.y, R * 0.955, M_PI * 1.12, M_PI * 1.88, 0);
        CGContextStrokePath(c);
        CGContextRestoreGState(c);

        // A highlight along the top of the barrel.
        CGContextSaveGState(c);
        CGContextSetLineWidth(c, R * 0.07);
        CGContextSetRGBStrokeColor(c, 0.45, 0.46, 0.49, 0.9);
        CGContextAddArc(c, centre.x, centre.y, R * 0.93, M_PI * 0.15, M_PI * 0.85, 0);
        CGContextStrokePath(c);
        CGContextRestoreGState(c);
    }

    // Glass.
    CGFloat gr = R * 0.70;
    CGContextSaveGState(c);
    CirclePath(c, centre, gr);
    CGContextClip(c);
    {
        const CGFloat inner[4] = { 0.99, 0.99, 1.00, 1.0 };
        const CGFloat outer[4] = { 0.72, 0.79, 0.86, 1.0 };
        RadialGradient(c, CGPointMake(centre.x - gr * 0.25, centre.y + gr * 0.25),
                       gr * 1.55, inner, outer);
    }
    if (fine) {
        // Concentric rings: the one detail that reads as "lens" rather than
        // "white disc", and the first thing to go when the icon is small.
        CGContextSetLineWidth(c, fmax(0.6, R * 0.022));
        CGContextSetRGBStrokeColor(c, 0.55, 0.62, 0.70, 0.40);
        int i;
        for (i = 1; i <= 3; i++) {
            CGFloat rr = gr * (0.24 * (CGFloat)i);
            CGContextAddArc(c, centre.x, centre.y, rr, 0, M_PI * 2, 0);
            CGContextStrokePath(c);
        }
        // A soft sheen across the upper left.
        CGContextSetRGBFillColor(c, 1.0, 1.0, 1.0, 0.55);
        CGContextSaveGState(c);
        CGContextTranslateCTM(c, centre.x - gr * 0.30, centre.y + gr * 0.42);
        CGContextRotateCTM(c, -0.5);
        CGContextScaleCTM(c, 1.0, 0.42);
        FillCircle(c, CGPointZero, gr * 0.62);
        CGContextRestoreGState(c);
    }
    CGContextRestoreGState(c);

    // The inner lip between glass and barrel.
    CGContextSetLineWidth(c, fmax(0.75, R * 0.035));
    CGContextSetRGBStrokeColor(c, 0.05, 0.05, 0.06, 1.0);
    CGContextAddArc(c, centre.x, centre.y, gr, 0, M_PI * 2, 0);
    CGContextStrokePath(c);
}

#pragma mark - The whole icon

static void DrawIcon(CGContextRef c, CGFloat S)
{
    CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
    CGContextSetShouldAntialias(c, true);

    BOOL fine = (S >= 64);

    // The window body, with room below it for its own shadow and room at the
    // bottom-right for the loupe to overhang.
    CGFloat m     = S * 0.070;
    CGRect  body  = CGRectMake(m, m * 1.35, S - 2 * m, S - m * 2.35);
    CGFloat rad   = S * 0.150;

    CGContextSaveGState(c);
    CGColorRef sh = CGColorCreateGenericGray(0.0, 0.34);
    CGContextSetShadowWithColor(c, CGSizeMake(0, -S * 0.014), S * 0.040, sh);
    CGColorRelease(sh);
    CGContextSetGrayFillColor(c, 0.86, 1.0);
    RoundRect(c, body, rad);
    CGContextFillPath(c);
    CGContextRestoreGState(c);

    // Brushed aluminium: a light-to-mid vertical gradient over the whole body.
    CGContextSaveGState(c);
    RoundRect(c, body, rad);
    CGContextClip(c);
    {
        const CGFloat top[4]    = { 0.93, 0.93, 0.94, 1.0 };
        const CGFloat bottom[4] = { 0.76, 0.76, 0.78, 1.0 };
        VGradient(c, body, top, bottom);
    }

    // Title bar: slightly brighter, with a hairline under it.
    CGFloat titleH = body.size.height * 0.185;
    CGRect  title  = CGRectMake(CGRectGetMinX(body), CGRectGetMaxY(body) - titleH,
                                body.size.width, titleH);
    {
        const CGFloat top[4]    = { 0.98, 0.98, 0.99, 1.0 };
        const CGFloat bottom[4] = { 0.87, 0.87, 0.89, 1.0 };
        CGContextSaveGState(c);
        CGContextClipToRect(c, title);
        VGradient(c, title, top, bottom);
        CGContextRestoreGState(c);
    }
    CGContextSetRGBStrokeColor(c, 0.60, 0.60, 0.63, 1.0);
    CGContextSetLineWidth(c, fmax(0.75, S * 0.005));
    CGContextMoveToPoint(c, CGRectGetMinX(body), CGRectGetMinY(title));
    CGContextAddLineToPoint(c, CGRectGetMaxX(body), CGRectGetMinY(title));
    CGContextStrokePath(c);
    CGContextRestoreGState(c);

    // Traffic lights. Below 64 pt they are three smudges a pixel or two across,
    // so they are left out entirely rather than drawn as grey mush.
    if (fine) {
        CGFloat lr = titleH * 0.185;
        CGFloat ly = CGRectGetMidY(title);
        CGFloat lx = CGRectGetMinX(body) + body.size.width * 0.085;
        CGFloat gap = lr * 3.1;
        const CGFloat cols[3][3] = {
            { 0.93, 0.35, 0.32 }, { 0.96, 0.74, 0.25 }, { 0.36, 0.78, 0.35 }
        };
        int i;
        for (i = 0; i < 3; i++) {
            CGPoint p = CGPointMake(lx + i * gap, ly);
            CGContextSetRGBFillColor(c, cols[i][0] * 0.75, cols[i][1] * 0.75,
                                        cols[i][2] * 0.75, 1.0);
            FillCircle(c, p, lr);
            CGContextSetRGBFillColor(c, cols[i][0], cols[i][1], cols[i][2], 1.0);
            FillCircle(c, p, lr * 0.86);
            // A single specular dot, which is what makes them read as glass.
            CGContextSetRGBFillColor(c, 1.0, 1.0, 1.0, 0.55);
            FillCircle(c, CGPointMake(p.x - lr * 0.24, p.y + lr * 0.28), lr * 0.30);
        }
    }

    // The picture, inset in a recessed well.
    CGFloat pin  = body.size.width * 0.055;
    CGRect photo = CGRectMake(CGRectGetMinX(body) + pin,
                              CGRectGetMinY(body) + pin,
                              body.size.width - 2 * pin,
                              CGRectGetMinY(title) - CGRectGetMinY(body) - 1.6 * pin);
    CGFloat prad = rad * 0.42;

    CGContextSaveGState(c);
    CGColorRef inner = CGColorCreateGenericGray(0.0, 0.45);
    CGContextSetShadowWithColor(c, CGSizeMake(0, S * 0.004), S * 0.012, inner);
    CGColorRelease(inner);
    CGContextSetGrayFillColor(c, 0.30, 1.0);
    RoundRect(c, photo, prad);
    CGContextFillPath(c);
    CGContextRestoreGState(c);

    CGContextSaveGState(c);
    RoundRect(c, photo, prad);
    CGContextClip(c);
    DrawLandscape(c, photo, S);
    CGContextRestoreGState(c);

    // A hairline around the picture so it sits in the metal rather than on it.
    CGContextSetRGBStrokeColor(c, 0.42, 0.42, 0.45, 0.9);
    CGContextSetLineWidth(c, fmax(0.75, S * 0.005));
    RoundRect(c, photo, prad);
    CGContextStrokePath(c);

    // Body edge, last, so it sits over everything it encloses.
    CGContextSetRGBStrokeColor(c, 0.48, 0.48, 0.51, 1.0);
    CGContextSetLineWidth(c, fmax(0.75, S * 0.006));
    RoundRect(c, body, rad);
    CGContextStrokePath(c);

    // The loupe, over the bottom-right corner and slightly outside it: the
    // overhang is what gives the icon a silhouette that is still recognisable
    // at 16 pt, when everything inside the window has become three colours.
    DrawLoupe(c, CGPointMake(CGRectGetMaxX(body) - body.size.width * 0.245,
                             CGRectGetMinY(body) + body.size.height * 0.215),
              S * 0.212, S);
}

static void WritePNG(NSString *dir, NSString *name, int px)
{
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, px, px, 8, 0, cs,
        (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(cs);
    if (!c) return;
    DrawIcon(c, (CGFloat)px);
    CGImageRef img = CGBitmapContextCreateImage(c);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [png writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES];
    CGImageRelease(img);
    CGContextRelease(c);
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: mkicon <out.iconset>\n"); return 1; }
        NSString *dir = [NSString stringWithUTF8String:argv[1]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                 withIntermediateDirectories:YES attributes:nil error:NULL];
        struct { const char *name; int px; } items[] = {
            {"icon_16x16.png",16},      {"icon_16x16@2x.png",32},
            {"icon_32x32.png",32},      {"icon_32x32@2x.png",64},
            {"icon_128x128.png",128},   {"icon_128x128@2x.png",256},
            {"icon_256x256.png",256},   {"icon_256x256@2x.png",512},
            {"icon_512x512.png",512},   {"icon_512x512@2x.png",1024},
        };
        for (unsigned i = 0; i < sizeof(items)/sizeof(items[0]); i++)
            WritePNG(dir, [NSString stringWithUTF8String:items[i].name], items[i].px);
    }
    return 0;
}
