// pvfuzz — feed malformed PDFs to PVPDFSource and check the VIEWER survives.
//
// Postview's central design claim is that PDF parsing and rasterisation both
// happen in a helper process, so a document that makes Quartz fault, hang or
// abort kills the helper and not the viewer. The suite tests corrupt *state
// files*; nothing feeds it a corrupt *document*. This does.
//
// What it asserts, per input:
//   * the viewer process is still alive afterwards (implicit: we keep running)
//   * opening either succeeds or reports an NSError -- never both, never neither
//   * a source that opened can be asked for a page without taking the process
//     down, and reports a typed failure when it cannot draw
//   * the call returns within a bound (a hang is a failure, not a slow pass)
//   * no helper process is left behind
//
// It is a probe, not a gate: it prints what happened and exits non-zero only if
// the viewer's own invariants were broken.

#import "PVPDFSource.h"
#import "PVCommon.h"
#include <sys/wait.h>
#include <stdio.h>
#include <stdlib.h>

static int gChecks, gFailures;
static void CHECK(int cond, const char *what, const char *detail)
{
    gChecks++;
    if (!cond) {
        gFailures++;
        printf("  FAIL  %s%s%s\n", what, detail ? " : " : "", detail ? detail : "");
    }
}

// How many helper processes THIS process is the parent of.
//
// Deliberately not a global count of PostviewRenderHelper. A global count is
// contaminated by any other Postview or test binary running on the same
// machine -- which is exactly what happened the first time this ran, with a
// soak in another terminal spawning helpers of its own. What this probe can
// speak for is its own children, so that is what it counts.
static int LiveHelpers(void)
{
    char cmd[256];
    snprintf(cmd, sizeof cmd,
             "/bin/ps -axo ppid=,comm= | /usr/bin/awk '$1==%d && $2 ~ /PostviewRenderHelper/' "
             "| /usr/bin/wc -l", (int)getpid());
    FILE *p = popen(cmd, "r");
    if (!p) return -1;
    char buf[64] = {0};
    if (!fgets(buf, sizeof buf, p)) { pclose(p); return -1; }
    pclose(p);
    return atoi(buf);
}

static NSData *ReadFile(const char *path)
{
    return [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
}

static BOOL WriteFile(NSData *d, NSString *path)
{
    return [d writeToFile:path atomically:YES];
}

// One trial: open, measure, ask for a page, tear down.
static void Trial(NSString *path, const char *label)
{
    double t0 = PVMonotonicSeconds();
    NSError *err = nil;
    PVPDFSource *src = [[PVPDFSource alloc] initWithURL:[NSURL fileURLWithPath:path]
                                                  error:&err];
    double openSeconds = PVMonotonicSeconds() - t0;

    char detail[512];

    // Exactly one of (source, error). A nil source with no error leaves the
    // caller nothing to present; a live source with an error is a contradiction.
    snprintf(detail, sizeof detail, "%s: src=%p err=%s", label, (void *)src,
             err ? [[err localizedDescription] UTF8String] : "(none)");
    CHECK((src != nil) != (err != nil) || (src != nil && err == nil),
          "open reports either a source or an error", detail);

    snprintf(detail, sizeof detail, "%s: open took %.2fs", label, openSeconds);
    CHECK(openSeconds < 45.0, "open returns within a bound", detail);

    if (src) {
        NSUInteger pages = [src pageCount];
        snprintf(detail, sizeof detail, "%s: pageCount=%lu", label,
                 (unsigned long)pages);
        CHECK(pages > 0, "an opened document has at least one page", detail);

        // Geometry must be finite and positive for every page we might lay out.
        NSUInteger i, checked = pages < 8 ? pages : 8;
        for (i = 0; i < checked; i++) {
            CGSize s = [src pointSizeOfPage:i];
            if (!(isfinite(s.width) && isfinite(s.height) &&
                  s.width > 0 && s.height > 0)) {
                snprintf(detail, sizeof detail, "%s: page %lu is %g x %g",
                         label, (unsigned long)i, (double)s.width, (double)s.height);
                CHECK(0, "every page has finite positive geometry", detail);
                break;
            }
        }

        // And it must be renderable-or-refusable, in bounded time, without
        // taking this process with it.
        double r0 = PVMonotonicSeconds();
        PVRenderFailure failure = PVRenderFailureNone;
        CGImageRef img = [src createImageForPage:0 pixelSize:CGSizeMake(400, 500)
                                     interactive:NO failure:&failure];
        double renderSeconds = PVMonotonicSeconds() - r0;

        snprintf(detail, sizeof detail, "%s: render took %.2fs", label, renderSeconds);
        CHECK(renderSeconds < 45.0, "render returns within a bound", detail);

        // A NULL bitmap must carry a reason; a non-NULL one must not claim one.
        snprintf(detail, sizeof detail, "%s: img=%p failure=%d", label,
                 (void *)img, (int)failure);
        CHECK(img ? (failure == PVRenderFailureNone)
                  : (failure != PVRenderFailureNone),
              "a failed render says why, a successful one does not", detail);

        if (img) CGImageRelease(img);
        [src release];
    }
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: pvfuzz <seed.pdf> <workdir> [rounds]\n");
            return 2;
        }
        NSData *seed = ReadFile(argv[1]);
        if (!seed || [seed length] < 64) {
            fprintf(stderr, "pvfuzz: seed unreadable or too small\n");
            return 2;
        }
        NSString *dir = [NSString stringWithUTF8String:argv[2]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil error:NULL];
        unsigned rounds = (argc > 3) ? (unsigned)atoi(argv[3]) : 60;

        int helpersBefore = LiveHelpers();
        printf("pvfuzz: seed %s (%lu bytes), %u mutation rounds\n",
               argv[1], (unsigned long)[seed length], rounds);
        printf("        helpers alive before: %d\n", helpersBefore);

        NSUInteger len = [seed length];
        const unsigned char *bytes = (const unsigned char *)[seed bytes];

        // ---- 1. synthesized pathological inputs -------------------------
        struct { const char *name; const char *content; size_t n; } synth[] = {
            { "empty",        "",                                  0  },
            { "header-only",  "%PDF-1.4\n",                        9  },
            { "not-a-pdf",    "this is plainly not a pdf at all\n", 33 },
            { "nul-bytes",    "\0\0\0\0\0\0\0\0",                   8  },
            { "bad-version",  "%PDF-9.9\n1 0 obj\n<<>>\nendobj\n",  30 },
            { "trailer-only", "trailer<</Root 1 0 R>>\n%%EOF\n",    28 },
        };
        for (unsigned i = 0; i < sizeof(synth)/sizeof(synth[0]); i++) {
            @autoreleasepool {
                NSString *p = [dir stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"synth-%s.pdf", synth[i].name]];
                WriteFile([NSData dataWithBytes:synth[i].content length:synth[i].n], p);
                Trial(p, synth[i].name);
            }
        }

        // A declared page count far beyond anything layable out.
        @autoreleasepool {
            NSMutableString *m = [NSMutableString stringWithString:@"%PDF-1.4\n"];
            [m appendString:@"1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n"];
            [m appendString:@"2 0 obj<</Type/Pages/Count 2147483647/Kids[]>>endobj\n"];
            [m appendString:@"trailer<</Root 1 0 R>>\n%%EOF\n"];
            NSString *p = [dir stringByAppendingPathComponent:@"synth-huge-count.pdf"];
            WriteFile([m dataUsingEncoding:NSASCIIStringEncoding], p);
            Trial(p, "huge-page-count");
        }

        // ---- 2. truncations ---------------------------------------------
        // A document cut short at every scale: the xref goes first, then the
        // page tree, then the content streams.
        double fractions[] = { 0.999, 0.99, 0.95, 0.9, 0.75, 0.5, 0.25, 0.1, 0.01 };
        for (unsigned i = 0; i < sizeof(fractions)/sizeof(fractions[0]); i++) {
            @autoreleasepool {
                NSUInteger cut = (NSUInteger)((double)len * fractions[i]);
                if (cut < 1) cut = 1;
                NSString *p = [dir stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"trunc-%03u.pdf",
                     (unsigned)(fractions[i] * 1000)]];
                WriteFile([NSData dataWithBytes:bytes length:cut], p);
                char lbl[64];
                snprintf(lbl, sizeof lbl, "truncated to %.1f%%", fractions[i] * 100);
                Trial(p, lbl);
            }
        }

        // ---- 3. targeted corruption -------------------------------------
        // Deterministic, so a failure here is reproducible: a fixed LCG rather
        // than rand(), seeded per round.
        for (unsigned r = 0; r < rounds; r++) {
            @autoreleasepool {
                NSMutableData *m = [NSMutableData dataWithData:seed];
                unsigned char *b = (unsigned char *)[m mutableBytes];
                unsigned long state = 0x9E3779B9u ^ (r * 2654435761u);
                // Between 1 and 64 byte flips, biased towards the front of the
                // file where the structure lives.
                unsigned flips = 1 + (r % 64);
                for (unsigned f = 0; f < flips; f++) {
                    state = state * 6364136223846793005ULL + 1442695040888963407ULL;
                    NSUInteger off = (NSUInteger)((state >> 33) % len);
                    if (r % 3 == 0) off = off % (len / 4 + 1);   // front-loaded
                    state = state * 6364136223846793005ULL + 1442695040888963407ULL;
                    b[off] = (unsigned char)((state >> 40) & 0xFF);
                }
                NSString *p = [dir stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"mut-%04u.pdf", r]];
                WriteFile(m, p);
                char lbl[64];
                snprintf(lbl, sizeof lbl, "mutation %u (%u flips)", r, flips);
                Trial(p, lbl);
            }
            if ((r + 1) % 10 == 0) {
                printf("  ... %u/%u mutations, %d checks, %d failures\n",
                       r + 1, rounds, gChecks, gFailures);
                fflush(stdout);
            }
        }

        // ---- 4. nothing left running ------------------------------------
        // Helpers are killed and reaped by -dealloc; give the scheduler a beat
        // before asking, so this measures leakage and not timing.
        usleep(500000);
        int helpersAfter = LiveHelpers();
        char detail[128];
        snprintf(detail, sizeof detail, "before=%d after=%d", helpersBefore, helpersAfter);
        CHECK(helpersAfter <= helpersBefore,
              "no render helper is left running after the run", detail);

        printf("\npvfuzz: %d checks, %d failures\n", gChecks, gFailures);
        printf("        the viewer process survived every input "
               "(it is still here to say so)\n");
        return gFailures ? 1 : 0;
    }
}
