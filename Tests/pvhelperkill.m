// pvhelperkill — kill the render helper and check the viewer recovers.
//
// The fuzzer next door asks whether a hostile DOCUMENT can kill the viewer, and
// the answer is no. But most of what it exercises is Quartz's parser inside a
// process built to die safely. This asks the other half, and the half that is
// Postview's own code: when the helper really does die, does the viewer come
// back?
//
// That path is not small. -createImageForPage: has to notice the helper is
// gone, classify the failure as transient rather than as a page that will never
// draw, kill and reap what is left, and let -ensureRenderHelper: start a fresh
// one on the next call. Get the classification wrong and a page briefly starved
// of a helper is retired for the rest of the session; get the reaping wrong and
// a long session accumulates zombies. Nothing in the suite killed a helper.
//
// Three arms:
//   A  kill between renders          -- the ordinary recovery path
//   B  kill DURING a render, repeatedly, from another thread -- the racy one
//   C  a torn-off document           -- kill and then immediately release
//
// The assertions are about the VIEWER, not about any single render succeeding:
// a render that loses its helper is allowed to fail, and is required to say so
// with a typed reason and to be followed by one that works.

#import "PVPDFSource.h"
#import "PVCommon.h"
#include <sys/wait.h>
#include <signal.h>
#include <unistd.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

static int gChecks, gFailures;
static void CHECK(int cond, const char *what, const char *detail)
{
    gChecks++;
    if (!cond) { gFailures++; printf("  FAIL  %s : %s\n", what, detail ? detail : ""); }
}

// The pids of every PostviewRenderHelper this process is the parent of.
static int MyHelpers(pid_t *out, int max)
{
    char cmd[256];
    snprintf(cmd, sizeof cmd,
             "/bin/ps -axo ppid=,pid=,comm= | "
             "/usr/bin/awk '$1==%d && $3 ~ /PostviewRenderHelper/ {print $2}'",
             (int)getpid());
    FILE *p = popen(cmd, "r");
    if (!p) return 0;
    int n = 0;
    char line[64];
    while (n < max && fgets(line, sizeof line, p)) {
        pid_t v = (pid_t)atoi(line);
        if (v > 0) out[n++] = v;
    }
    pclose(p);
    return n;
}

static int KillMyHelpers(void)
{
    pid_t pids[64];
    int n = MyHelpers(pids, 64), i, killed = 0;
    for (i = 0; i < n; i++)
        if (kill(pids[i], SIGKILL) == 0) killed++;
    return killed;
}

// Count processes that are our children AND have exited without being reaped.
// A zombie here is the viewer failing to waitpid what it killed.
static int MyZombies(void)
{
    char cmd[256];
    snprintf(cmd, sizeof cmd,
             "/bin/ps -axo ppid=,stat= | /usr/bin/awk '$1==%d && $2 ~ /^Z/' | /usr/bin/wc -l",
             (int)getpid());
    FILE *p = popen(cmd, "r");
    if (!p) return -1;
    char buf[32] = {0};
    if (!fgets(buf, sizeof buf, p)) { pclose(p); return -1; }
    pclose(p);
    return atoi(buf);
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

// ---- arm B's killer thread -------------------------------------------------
//
// Atomics, not `volatile`. This started as two volatile ints and
// ThreadSanitizer reported a data race on the stop flag -- correctly:
// `volatile` orders nothing between threads and is not a synchronisation
// primitive, whatever its reputation suggests. The race was in this harness and
// never in Postview, but that is exactly why it had to go: a probe that reports
// a race of its own cannot be trusted when it reports none anywhere else, and
// the whole value of running this arm under TSan is the sentence "the only
// races here are none".
static int gKillerRun;
static int gKillCount;
static void *KillerThread(void *unused)
{
    (void)unused;
    while (__atomic_load_n(&gKillerRun, __ATOMIC_SEQ_CST)) {
        __atomic_fetch_add(&gKillCount, KillMyHelpers(), __ATOMIC_SEQ_CST);
        usleep(15000 + (rand() % 25000));   // 15-40 ms
    }
    return NULL;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: pvhelperkill <pdf> [rounds]\n"); return 2; }
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        int rounds = (argc > 2) ? atoi(argv[2]) : 40;

        NSError *err = nil;
        PVPDFSource *src = [[PVPDFSource alloc] initWithURL:url error:&err];
        CHECK(src != nil, "the fixture opens", err ? [[err localizedDescription] UTF8String] : "");
        if (!src) return 2;

        CGSize px = CGSizeMake(420, 540);

        // Baseline: one render that must simply work.
        PVRenderFailure f = PVRenderFailureNone;
        CGImageRef img = [src createImageForPage:0 pixelSize:px interactive:NO failure:&f];
        CHECK(img != NULL, "a render works before anything is killed", FailureName(f));
        if (img) CGImageRelease(img);

        // ---- A: kill between renders -----------------------------------
        printf("\n[A] SIGKILL the helper between renders, %d rounds\n", rounds);
        int recovered = 0, firstTry = 0;
        for (int r = 0; r < rounds; r++) {
            KillMyHelpers();
            // The very next render must either succeed outright (a fresh helper
            // was started for it) or fail with a TRANSIENT reason and then
            // succeed. What it must never do is report the PAGE as bad, because
            // the page is fine -- that is the misclassification that retires a
            // good page for the rest of the session.
            f = PVRenderFailureNone;
            img = [src createImageForPage:(NSUInteger)(r % 4) pixelSize:px
                              interactive:NO failure:&f];
            if (img) { firstTry++; recovered++; CGImageRelease(img); continue; }

            char d[160];
            snprintf(d, sizeof d, "round %d reported %s", r, FailureName(f));
            CHECK(f != PVRenderFailureInvalidPage,
                  "a killed helper is not reported as a bad page", d);

            f = PVRenderFailureNone;
            img = [src createImageForPage:(NSUInteger)(r % 4) pixelSize:px
                              interactive:NO failure:&f];
            snprintf(d, sizeof d, "round %d still failing: %s", r, FailureName(f));
            CHECK(img != NULL, "the render after a killed helper succeeds", d);
            if (img) { recovered++; CGImageRelease(img); }
        }
        printf("    recovered %d/%d  (%d needed no retry at all)\n",
               recovered, rounds, firstTry);

        // ---- B: kill DURING renders ------------------------------------
        printf("\n[B] a thread SIGKILLing helpers while renders run, %d renders\n",
               rounds);
        __atomic_store_n(&gKillerRun, 1, __ATOMIC_SEQ_CST);
        __atomic_store_n(&gKillCount, 0, __ATOMIC_SEQ_CST);
        pthread_t killer;
        pthread_create(&killer, NULL, KillerThread, NULL);

        int ok = 0, failed = 0, badClass = 0;
        for (int r = 0; r < rounds; r++) {
            f = PVRenderFailureNone;
            img = [src createImageForPage:(NSUInteger)(r % 4) pixelSize:px
                              interactive:NO failure:&f];
            if (img) { ok++; CGImageRelease(img); }
            else {
                failed++;
                // Same rule as arm A, and this is where it actually bites: a
                // render racing a SIGKILL must not come back as "this page
                // cannot be drawn".
                if (f == PVRenderFailureInvalidPage) badClass++;
                CHECK(f != PVRenderFailureNone,
                      "a failed render always carries a reason", FailureName(f));
            }
        }
        __atomic_store_n(&gKillerRun, 0, __ATOMIC_SEQ_CST);
        pthread_join(killer, NULL);

        char d[200];
        snprintf(d, sizeof d, "%d of %d failures were misreported as a bad page",
                 badClass, failed);
        CHECK(badClass == 0, "no killed render is blamed on the page", d);
        printf("    %d rendered, %d failed, %d kills delivered\n", ok, failed,
               __atomic_load_n(&gKillCount, __ATOMIC_SEQ_CST));

        // The document must still be usable once the killing stops.
        f = PVRenderFailureNone;
        img = [src createImageForPage:0 pixelSize:px interactive:NO failure:&f];
        CHECK(img != NULL, "the document still renders after the killing stops",
              FailureName(f));
        if (img) CGImageRelease(img);

        // ---- C: kill, then tear down immediately ------------------------
        printf("\n[C] kill the helper and release the source at once\n");
        for (int r = 0; r < 10; r++) {
            @autoreleasepool {
                NSError *e = nil;
                PVPDFSource *s = [[PVPDFSource alloc] initWithURL:url error:&e];
                if (!s) { CHECK(0, "source opens in teardown arm", ""); break; }
                PVRenderFailure lf = PVRenderFailureNone;
                CGImageRef i2 = [s createImageForPage:0 pixelSize:px
                                          interactive:NO failure:&lf];
                if (i2) CGImageRelease(i2);
                KillMyHelpers();
                [s release];          // must not hang, must reap what it killed
            }
        }
        CHECK(1, "releasing a source whose helper was just killed does not hang", "");

        [src release];

        // ---- leftovers --------------------------------------------------
        usleep(400000);
        pid_t left[64];
        int stillAlive = MyHelpers(left, 64);
        int zombies = MyZombies();
        snprintf(d, sizeof d, "%d helper(s) still running", stillAlive);
        CHECK(stillAlive == 0, "no helper outlives the sources that owned them", d);
        snprintf(d, sizeof d, "%d unreaped child(ren)", zombies);
        CHECK(zombies <= 0, "nothing killed is left unreaped", d);

        printf("\npvhelperkill: %d checks, %d failures\n", gChecks, gFailures);
        return gFailures ? 1 : 0;
    }
}
