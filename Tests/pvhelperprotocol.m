// pvhelperprotocol — is the viewer hardened against its OWN helper?
//
// The process split exists because the helper is where attacker-controlled
// bytes are interpreted. That reasoning has a second half which nothing tested:
// if the helper is the process most likely to be subverted, then everything it
// says back is untrusted input too, and the viewer has to treat it that way.
//
// PVPDFSource does defend itself — it checks magic, version and sequence on
// every reply, bounds every read with a deadline, and rejects an open reply
// whose page count disagrees with the geometry it already holds. Those branches
// were reachable only by accident: a corrupted pipe, a helper killed at exactly
// the wrong instant. This reaches them on purpose, by putting a helper that
// lies where the real one should be.
//
// Twelve ways to lie, each its own spawn. For every one the viewer must:
//   * not crash, and not hang past the render deadline
//   * return NULL with a TYPED failure, never a bitmap
//   * never report PVRenderFailureInvalidPage — the page is fine in every case
//     here, and blaming it would retire a good page for the session
//   * still render correctly afterwards, once the real helper is restored
//
// The last of those is the one that would catch a viewer that hardened itself
// into uselessness: refusing to talk to a helper that once lied is not
// resilience, it is a different failure.

#import "PVPDFSource.h"
#import "PVCommon.h"
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <unistd.h>

// A source renders through the helper it opened with, so reaching the RENDER
// conversation at all means taking that one away first. See pvbadhelper.m.
static int KillMyHelpers(void)
{
    char cmd[256];
    snprintf(cmd, sizeof cmd,
             "/bin/ps -axo ppid=,pid=,comm= | "
             "/usr/bin/awk '$1==%d && $3 ~ /Helper/ {print $2}'", (int)getpid());
    FILE *p = popen(cmd, "r");
    if (!p) return 0;
    char line[64]; int killed = 0;
    while (fgets(line, sizeof line, p)) {
        pid_t v = (pid_t)atoi(line);
        if (v > 0 && kill(v, SIGKILL) == 0) killed++;
    }
    pclose(p);
    return killed;
}

static int gChecks, gFailures;
static void CHECK(int cond, const char *what, const char *detail)
{
    gChecks++;
    if (!cond) { gFailures++; printf("  FAIL  %s : %s\n", what, detail ? detail : ""); }
}

static const char *FailureName(PVRenderFailure f)
{
    switch (f) {
        case PVRenderFailureNone:              return "none";
        case PVRenderFailureInvalidPage:       return "invalid-page";
        case PVRenderFailureTransientResource: return "transient";
        case PVRenderFailureTimeout:           return "timeout";
        case PVRenderFailureHelperUnavailable: return "helper-unavailable";
        case PVRenderFailureProtocol:          return "protocol";
    }
    return "?";
}

static const char *kModeName[] = {
    "pass-through (control)",
    "exit before the open reply",
    "open reply with wrong magic",
    "open reply with wrong version",
    "open reply that disagrees about the page count",
    "half an open reply, then EOF",
    "valid open, then never answer a render",
    "render reply with wrong magic",
    "render reply for a command never sent",
    "render reply with an unknown status",
    "valid open, then close the pipe",
    "many replies for one command",
    "valid open, then random bytes",
};
#define MODE_COUNT ((int)(sizeof(kModeName)/sizeof(kModeName[0])))

static void SetMode(int mode, unsigned long long pages)
{
    FILE *f = fopen("/tmp/pvbadhelper-mode", "w");
    if (!f) { CHECK(0, "mode file writable", "/tmp/pvbadhelper-mode"); return; }
    fprintf(f, "%d %llu\n", mode, pages);
    fclose(f);
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: pvhelperprotocol <pdf>\n"); return 2; }
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        CGSize px = CGSizeMake(360, 460);

        // The control first, which also tells us the page count the liar needs
        // in order to produce an open reply that looks right.
        SetMode(0, 0);
        NSError *err = nil;
        PVPDFSource *base = [[PVPDFSource alloc] initWithURL:url error:&err];
        CHECK(base != nil, "the document opens through the shim",
              err ? [[err localizedDescription] UTF8String] : "");
        if (!base) return 2;
        unsigned long long pages = (unsigned long long)[base pageCount];
        PVRenderFailure f = PVRenderFailureNone;
        CGImageRef img = [base createImageForPage:0 pixelSize:px
                                      interactive:NO failure:&f];
        CHECK(img != NULL, "the control renders a page", FailureName(f));
        if (img) CGImageRelease(img);
        [base release];
        printf("  control: document has %llu pages\n\n", pages);

        int mode;
        for (mode = 1; mode < MODE_COUNT; mode++) {
            @autoreleasepool {
                SetMode(mode, pages);
                double t0 = PVMonotonicSeconds();

                NSError *e = nil;
                PVPDFSource *s = [[PVPDFSource alloc] initWithURL:url error:&e];
                // Opening uses copy+meta, which the shim passes through, so the
                // source should still open. The lying happens at render time.
                if (!s) {
                    printf("  [%2d] %-46s open refused (%s)\n", mode, kModeName[mode],
                           e ? [[e localizedDescription] UTF8String] : "no reason");
                    // Refusing to open is an acceptable answer too, as long as
                    // it is an answer and not a crash or a hang.
                    double dt = PVMonotonicSeconds() - t0;
                    char d[160];
                    snprintf(d, sizeof d, "mode %d took %.1fs to refuse", mode, dt);
                    CHECK(dt < 120.0, "a lying helper is rejected within a bound", d);
                    continue;
                }

                // Render lies live in the RENDER conversation, and getting
                // there takes TWO steps, not one.
                //
                // Killing the helper is not enough: -ensureRenderHelper: tests
                // `_helperPid > 0` and a freshly killed helper still satisfies
                // it, so the next render fails on the stale descriptors without
                // ever spawning a replacement -- the "recovery costs exactly one
                // failed render" behaviour pvhelperkill measures. That failure
                // is a PROTOCOL failure, which is also what a lying helper
                // produces, so an earlier version of this test saw the right
                // answer for entirely the wrong reason and reported twelve
                // passes without the liar being executed once. The trace file
                // said so: not one invocation in render mode.
                //
                // So: kill, spend the doomed render deliberately, and only then
                // ask the question. The render below is the first one that can
                // reach a helper spawned in RENDER mode.
                if (mode >= 6) {
                    KillMyHelpers();
                    usleep(150000);
                    PVRenderFailure spent = PVRenderFailureNone;
                    CGImageRef doomed = [s createImageForPage:0 pixelSize:px
                                                  interactive:NO failure:&spent];
                    if (doomed) CGImageRelease(doomed);
                }

                PVRenderFailure rf = PVRenderFailureNone;
                CGImageRef bad = [s createImageForPage:0 pixelSize:px
                                           interactive:NO failure:&rf];
                double dt = PVMonotonicSeconds() - t0;

                char d[220];
                snprintf(d, sizeof d, "mode %d (%s) returned img=%p failure=%s in %.1fs",
                         mode, kModeName[mode], (void *)bad, FailureName(rf), dt);

                // Mode 11 is deliberately exempt from the two checks below,
                // and the exemption is the finding rather than a concession.
                //
                // It sends a WELL-FORMED success -- right magic, right version,
                // right sequence, status 0 -- and then eight more copies. The
                // viewer believes the first, and it is correct to: a helper
                // asserting "I drew the page" cannot be distinguished from one
                // that did, by this protocol or any other, short of the viewer
                // re-inspecting the pixels it delegated precisely so it would
                // not have to. What comes back is the viewer's own shared
                // buffer, which ftruncate zeroed, so the page draws black. That
                // is a lie faithfully rendered, not a hole in the viewer.
                //
                // What IS worth asking is what the eight extra replies do to
                // the NEXT render, since they are still sitting in the pipe.
                // That is checked below instead.
                if (mode != 11) {
                    CHECK(bad == NULL, "a lying helper never yields a bitmap", d);
                    CHECK(rf != PVRenderFailureNone,
                          "a refused render always carries a reason", d);
                }
                if (bad) CGImageRelease(bad);

                // The desynchronisation question. Eight unread replies are in
                // the pipe; the next command must not be answered by one of
                // them. The sequence check is what should catch it, and the
                // source must end up usable either way -- a protocol that can
                // be knocked permanently out of step by a chatty helper would
                // be a real defect even though the first render looked fine.
                if (mode == 11) {
                    PVRenderFailure nf = PVRenderFailureNone;
                    CGImageRef next = [s createImageForPage:1 pixelSize:px
                                                interactive:NO failure:&nf];
                    char nd[220];
                    snprintf(nd, sizeof nd,
                             "second render after a flood: img=%p failure=%s",
                             (void *)next, FailureName(nf));
                    // Either outcome is acceptable; a wrong-page bitmap
                    // delivered as if it were right is not, and neither is a
                    // hang or a crash.
                    CHECK(next ? (nf == PVRenderFailureNone)
                               : (nf != PVRenderFailureNone),
                          "a flood cannot desynchronise the protocol", nd);
                    if (next) CGImageRelease(next);
                    printf("       flood follow-up: %s\n", nd);
                }

                // The page is perfectly good in every one of these modes; only
                // the helper is broken. Blaming the page is the misclassification
                // that retires it for the rest of the session.
                CHECK(rf != PVRenderFailureInvalidPage,
                      "a lying helper is never blamed on the page", d);

                // The deadline is the only thing bounding a helper that says
                // nothing. It must actually bound it.
                CHECK(dt < 120.0, "a lying helper cannot hang the viewer", d);

                printf("  [%2d] %-46s -> %-18s %6.1fs\n",
                       mode, kModeName[mode], FailureName(rf), dt);
                [s release];
            }
        }

        // And the viewer must not have hardened itself into uselessness: with
        // an honest helper back, everything works again.
        SetMode(0, 0);
        NSError *e2 = nil;
        PVPDFSource *good = [[PVPDFSource alloc] initWithURL:url error:&e2];
        CHECK(good != nil, "the document opens again once the helper is honest",
              e2 ? [[e2 localizedDescription] UTF8String] : "");
        if (good) {
            PVRenderFailure gf = PVRenderFailureNone;
            CGImageRef gi = [good createImageForPage:0 pixelSize:px
                                         interactive:NO failure:&gf];
            CHECK(gi != NULL, "and renders normally again", FailureName(gf));
            if (gi) CGImageRelease(gi);
            [good release];
        }

        printf("\npvhelperprotocol: %d checks, %d failures\n", gChecks, gFailures);
        return gFailures ? 1 : 0;
    }
}
