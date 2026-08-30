//  pvband.m — Task 4 stage 1: is a band render half a page render?
//
//  ENGINEERING.md rejected viewport-height banding on render count and
//  pixel count, in a CPU-limited regime. ENGINEERING.md section 6 argues
//  the regime has flipped and the rejection should be re-costed. The model there
//  says the `read` workload goes from 7 whole-page renders to 17 band renders
//  for 16% more pixels, and that this fits inside a 1.7 s CPU surplus *if a band
//  render is genuinely a fraction of a page render*.
//
//  That "if" is the whole question, and it is not answerable from the model.
//  Every band render re-parses the page's content stream from the beginning:
//  CGContextDrawPDFPage has no notion of resuming. If that parse is a large
//  fixed cost, K bands cost K times it however few pixels each one covers, and
//  the arithmetic that says banding fits does not hold.
//
//  So this measures the fixed cost directly rather than inferring it. The same
//  page is rasterised as K bands that exactly tile it, for several K. Total
//  pixels are constant across K by construction, so any rise in total time with
//  K is per-render overhead, and a straight line through the points gives it in
//  milliseconds. Nothing here renders anything Postview would ship; it is an
//  experiment, run by `make band`, and its output belongs in ENGINEERING.md.
//
//  This host is not the arbiter and its seconds mean nothing. The RATIO is what
//  transfers, which is why the tool prints ratios and page-equivalents rather
//  than a verdict. Build it for both architectures and compare if in doubt.

#import "PVCommon.h"
#import "PVPDFSource.h"
#include <sys/resource.h>

// The showdown geometry, so the numbers line up with the recorded runs:
// a 1200x800 window, the page column inside the edge gaps, US Letter fit to
// that width, on a 2x display. ENGINEERING.md section 2 derives ~7.2 Mpx
// for exactly this and it is where "one full page bitmap is ~28 MB" comes from.
#define BAND_WINDOW_W   1200.0
#define BAND_WINDOW_H    800.0
#define BAND_SCALE         2.0

// The fraction of a bitmap that is not white, read from the bitmap's own bytes.
//
// A band that comes out blank costs almost nothing to rasterise, and a probe
// that timed blank bands would report banding as free. This is the measurement's
// alibi, so it is exact rather than sampled: an earlier version drew each band
// into a small scaled-down buffer, and the resampling alone moved the answer by
// three per cent between K=1 and K=8 -- the check was flagging a difference it
// had introduced itself.
//
// Every eighth pixel in both directions, with the same stride for every K, so
// the sampling density is identical by construction and no scaling is involved.
static double InkFraction(CGImageRef img)
{
    if (!img) return -1;
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    size_t bpr = CGImageGetBytesPerRow(img), bpp = CGImageGetBitsPerPixel(img) / 8;
    if (w == 0 || h == 0 || bpp < 3) return -1;

    CGDataProviderRef prov = CGImageGetDataProvider(img);
    if (!prov) return -1;
    CFDataRef data = CGDataProviderCopyData(prov);
    if (!data) return -1;
    const unsigned char *base = CFDataGetBytePtr(data);
    size_t len = (size_t)CFDataGetLength(data);
    if (!base || len < bpr * h) { CFRelease(data); return -1; }

    const size_t stride = 8;
    size_t x, y, seen = 0, inked = 0;
    for (y = 0; y < h; y += stride) {
        const unsigned char *row = base + y * bpr;
        for (x = 0; x < w; x += stride) {
            const unsigned char *px = row + x * bpp;
            // Only "is any channel dark here" is being asked, so which of the
            // three colour bytes is which does not matter.
            if (px[0] < 245 || px[1] < 245 || px[2] < 245) inked++;
            seen++;
        }
    }
    CFRelease(data);
    return seen ? (double)inked / (double)seen : -1;
}

static double CPUSeconds(void)
{
    struct rusage ru;
    if (getrusage(RUSAGE_SELF, &ru) != 0) return 0;
    return (double)ru.ru_utime.tv_sec + (double)ru.ru_utime.tv_usec / 1.0e6 +
           (double)ru.ru_stime.tv_sec + (double)ru.ru_stime.tv_usec / 1.0e6;
}

// One band of a page: a bitmap `bandH` pixels tall whose content is the slice of
// the page starting `originY` pixels from the top, at full page resolution.
//
// Deliberately the same setup as -[PVPDFSource createImageForPage:pixelSize:]
// -- same colour space, same bitmap layout, same antialiasing and font flags,
// same drawing transform -- with one extra translation. A measurement of a
// cheaper renderer would not answer the question being asked.
static CGImageRef CreateBand(CGPDFDocumentRef doc, CGSize pageNatural, size_t index,
                             size_t fullW, size_t fullH, size_t originY, size_t bandH)
{
    if (bandH == 0 || fullW == 0) return NULL;
    CGPDFPageRef page = CGPDFDocumentGetPage(doc, index + 1);
    if (!page) return NULL;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return NULL;
    CGContextRef ctx = CGBitmapContextCreate(NULL, fullW, bandH, 8, 0, cs,
        (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;

    CGContextSetFillColorWithColor(ctx, CGColorGetConstantColor(kCGColorWhite));
    CGContextFillRect(ctx, CGRectMake(0, 0, (CGFloat)fullW, (CGFloat)bandH));
    CGContextSetShouldAntialias(ctx, true);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextSetShouldSmoothFonts(ctx, true);
    CGContextSetAllowsFontSubpixelPositioning(ctx, true);
    CGContextSetAllowsFontSubpixelQuantization(ctx, true);

    // Bitmap contexts are bottom-left origin, bands are counted from the top.
    // The band covering rows [originY, originY+bandH) of a fullH-tall page sits
    // at this offset once the page is drawn at full size.
    CGFloat shiftUp = (CGFloat)((long long)fullH - (long long)originY - (long long)bandH);
    CGContextTranslateCTM(ctx, 0, -shiftUp);

    CGContextScaleCTM(ctx, (CGFloat)fullW / pageNatural.width,
                           (CGFloat)fullH / pageNatural.height);
    CGAffineTransform t = CGPDFPageGetDrawingTransform(page, kCGPDFCropBox,
                              CGRectMake(0, 0, pageNatural.width, pageNatural.height), 0, true);
    CGContextConcatCTM(ctx, t);
    // Everything outside the context's own bounds is clipped by CoreGraphics.
    // The content stream is still walked in full, which is exactly the cost
    // under measurement.
    CGContextDrawPDFPage(ctx, page);

    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return img;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: pvband <test.pdf> [pages] [reps]\n"); return 2; }
        [NSApplication sharedApplication];

        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        NSError *err = nil;
        PVPDFSource *src = [[PVPDFSource alloc] initWithURL:url error:&err];
        if (!src) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }
        CGPDFDocumentRef doc = CGPDFDocumentCreateWithURL((CFURLRef)url);
        if (!doc) { fprintf(stderr, "cannot re-open %s for banding\n", argv[1]); return 2; }

        size_t pages = (argc > 2) ? (size_t)atoi(argv[2]) : 6;
        int    reps  = (argc > 3) ? atoi(argv[3]) : 3;
        if (pages == 0 || pages > [src pageCount]) pages = [src pageCount];
        if (reps < 1) reps = 1;

        // Fit the first page to the showdown window's page column.
        CGSize natural = [src pointSizeOfPage:0];
        double colW    = BAND_WINDOW_W - 2.0 * PV_EDGE_GAP;
        double zoom    = colW / natural.width;
        size_t fullW   = (size_t)floor(colW * BAND_SCALE + 0.5);
        size_t fullH   = (size_t)floor(natural.height * zoom * BAND_SCALE + 0.5);
        size_t viewPx  = (size_t)floor(BAND_WINDOW_H * BAND_SCALE + 0.5);

        printf("Banding cost probe (Task 4 stage 1)\n");
        printf("  document        : %s (%lu pages, measuring %lu)\n",
               argv[1], (unsigned long)[src pageCount], (unsigned long)pages);
        printf("  page bitmap     : %lu x %lu = %.2f Mpx  (%.1f MB at 4 bytes/px)\n",
               (unsigned long)fullW, (unsigned long)fullH,
               (double)(fullW * fullH) / 1.0e6,
               (double)(fullW * fullH * 4) / (1024.0 * 1024.0));
        printf("  viewport height : %lu px, so a viewport band is %.2f of a page\n",
               (unsigned long)viewPx, (double)viewPx / (double)fullH);
        printf("  repetitions     : %d per configuration\n", reps);
        printf("  NOTE: seconds on this host are not the Mavericks machine's. The\n");
        printf("        quantity that transfers is the per-render fixed cost as a\n");
        printf("        FRACTION of a whole-page render.\n\n");

        // K bands that exactly tile the page. K=1 is the whole-page render the
        // app does today, so it is the denominator of everything below.
        const size_t kSplits[] = { 1, 2, 3, 4, 6, 8 };
        const size_t nSplits = sizeof(kSplits) / sizeof(kSplits[0]);
        double totals[sizeof(kSplits) / sizeof(kSplits[0])];
        size_t renders[sizeof(kSplits) / sizeof(kSplits[0])];

        size_t si;
        double inkPerK[sizeof(kSplits) / sizeof(kSplits[0])];
        for (si = 0; si < nSplits; si++) {
            size_t K = kSplits[si];
            size_t bandH = (fullH + K - 1) / K;

            // Before the clock starts: are these bands actually drawing the
            // document? The mean ink across the bands of one page must be close
            // to the ink of the whole-page render, or the tiling is wrong and
            // every number below is a measurement of blank paper.
            {
                double ink = 0; size_t nb = 0, y = 0, k;
                for (k = 0; k < K; k++) {
                    size_t h = bandH;
                    if (y + h > fullH) h = fullH - y;
                    if (h == 0) break;
                    @autoreleasepool {
                        CGImageRef im = CreateBand(doc, [src pointSizeOfPage:0], 0,
                                                   fullW, fullH, y, h);
                        // Constant sampling density: 64 columns across the page
                        // width, and however many rows that scale gives this
                        // band. Every K therefore samples the same pixels.
                        double f = InkFraction(im);
                        if (im) CGImageRelease(im);
                        if (f >= 0) { ink += f * (double)h; nb += h; }
                    }
                    y += h;
                }
                inkPerK[si] = (nb > 0) ? ink / (double)nb : -1;
            }

            double cpu0 = CPUSeconds();
            size_t nrend = 0;
            int rep;
            for (rep = 0; rep < reps; rep++) {
                size_t p;
                for (p = 0; p < pages; p++) {
                    CGSize nat = [src pointSizeOfPage:p];
                    size_t y = 0, k;
                    for (k = 0; k < K; k++) {
                        size_t h = bandH;
                        if (y + h > fullH) h = fullH - y;
                        if (h == 0) break;
                        @autoreleasepool {
                            CGImageRef im = CreateBand(doc, nat, p, fullW, fullH, y, h);
                            if (im) { nrend++; CGImageRelease(im); }
                        }
                        y += h;
                    }
                }
            }
            totals[si]  = CPUSeconds() - cpu0;
            renders[si] = nrend;
            printf("  K=%lu  band %5lu px  %4lu renders  %7.3f s CPU  "
                   "%6.1f ms/render  %5.3f x whole-page   ink %.3f\n",
                   (unsigned long)K, (unsigned long)bandH, (unsigned long)nrend,
                   totals[si], 1000.0 * totals[si] / (double)(nrend ? nrend : 1),
                   totals[si] / (totals[0] > 0 ? totals[0] : 1), inkPerK[si]);
        }

        // Total pixels are identical for every K by construction, so any change
        // in total time with K is not pixel work. A straight line through the
        // points would be the obvious summary and would be wrong: the cost does
        // not rise with K at all on the documents measured so far, it FALLS and
        // then flattens, and a least-squares fit reports that as a negative
        // per-render overhead -- a quantity that does not exist. Report the
        // shape instead and let it say what it says.
        //
        // Two candidate mechanisms, and the tool cannot distinguish them: a
        // 27 MB destination bitmap does not fit any cache on any machine, where
        // a 3 MB band does; and CoreGraphics rejects geometry outside the clip
        // early enough that a band pays little for the content it does not
        // cover. Both predict a fall that flattens once the band is small
        // enough, which is what the table shows.
        printf("\n  Marginal cost of splitting further, in page-equivalents:\n");
        for (si = 1; si < nSplits; si++) {
            double prev = totals[si - 1] / (totals[0] > 0 ? totals[0] : 1);
            double cur  = totals[si]     / (totals[0] > 0 ? totals[0] : 1);
            printf("    K=%lu -> K=%lu : %+.3f    (%lu extra renders)\n",
                   (unsigned long)kSplits[si - 1], (unsigned long)kSplits[si],
                   cur - prev, (unsigned long)(renders[si] - renders[si - 1]));
        }

        // The configuration that matters. A viewport band is ~0.53 of a page at
        // the showdown geometry, so K=2 is what "render viewport-height bands"
        // actually costs; the larger K are here to show where the curve flattens
        // and thus what mechanism is at work, not because anyone would build them.
        double k2Total   = (nSplits > 1) ? totals[1] / (totals[0] > 0 ? totals[0] : 1) : 1.0;
        double perBandK2 = k2Total / 2.0;
        printf("\n  At K=2 (the viewport-band case):\n");
        printf("    a whole page costs 1.000 page-equivalents in 1 render\n");
        printf("    two bands cost %.3f page-equivalents in 2 renders\n", k2Total);
        printf("    so ONE band costs %.3f of a page render, against %.3f if a band\n",
               perBandK2, 0.5);
        printf("    render were exactly proportional to its pixels\n");
        double fixed = (k2Total - 1.0);   // page-equivalents added by the extra render
        printf("    per-extra-render overhead: %+.3f page-equivalents\n", fixed);

        // The decision, in the brief's own terms. `read` visits 7 pages today at
        // 1 render each; the banding model says 17 band renders and +16% pixels.
        // Both are converted to page-equivalents using the fixed cost just
        // measured, and compared against the CPU surplus the showdown recorded.
        const double kReadPageRenders = 7.0;
        const double kReadBandRenders = 17.0;
        const double kBandPixelFactor = 1.16;
        // Area, scaled by the measured cost of covering that area with bands
        // instead of with pages. Not "pixels plus K times an overhead": the
        // per-render term is not constant across K on either document measured,
        // so extrapolating one from K=2 out to seventeen renders would be
        // inventing a model the data does not support. K=2 is the configuration
        // anyone would actually build, so its measured cost is the one applied.
        double bandArea = kReadPageRenders * kBandPixelFactor;   // in page-areas
        double bandCost = bandArea * k2Total;
        // The ink column above is the measurement's own alibi. Every K tiles the
        // same page, so every K must find the same ink; a K whose bands are
        // blank would be fast for a reason that has nothing to do with banding.
        {
            double worst = 0;
            for (si = 1; si < nSplits; si++) {
                double d = fabs(inkPerK[si] - inkPerK[0]);
                if (d > worst) worst = d;
            }
            printf("\n  Ink agreement across K: worst deviation %.4f from the whole-page\n"
                   "  render's %.4f. %s\n", worst, inkPerK[0],
                   (inkPerK[0] > 0.01 && worst < 0.01)
                       ? "The bands are drawing the document."
                       : "*** SUSPECT: the bands do not agree with the page. ***");
        }

        printf("\n  Applied to the `read` workload from ENGINEERING.md section 6:\n");
        printf("    today            : %.1f page renders\n", kReadPageRenders);
        printf("    banded (modelled): %.1f renders, %.0f%% more pixels\n",
               kReadBandRenders, (kBandPixelFactor - 1.0) * 100.0);
        printf("    banded cost      : %.2f page-equivalents  (%.2f page-areas x %.3f measured)\n",
               bandCost, bandArea, k2Total);
        printf("    recorded surplus : read CPU 3.45 s vs Preview 5.18 s = 1.73 s\n");
        printf("    today's 7 renders are 3.45 s, so one page-equivalent = %.2f s\n",
               3.45 / kReadPageRenders);
        printf("    banded would cost: %.2f s, i.e. %+.2f s against a 1.73 s surplus\n",
               bandCost * 3.45 / kReadPageRenders,
               bandCost * 3.45 / kReadPageRenders - 3.45);

        CGPDFDocumentRelease(doc);
        [src release];
        return 0;
    }
}
