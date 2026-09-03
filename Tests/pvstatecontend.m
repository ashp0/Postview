// pvstatecontend — do two Postviews quitting at once lose reading positions?
//
// PVStateStore's whole reason for merging rather than overwriting is that two
// copies of Postview reading different documents must not clobber each other.
// The suite exercises the merge through a scratch file in ONE process; nothing
// runs two processes at it. This does, with real forks and the real flock.
//
// It measures two different things and is careful not to confuse them:
//
//   PART A — correctness of the merge. Each child gets its own documents and
//   flushes until it succeeds. Every entry must survive. This is the property
//   the design promises outright, and any loss here is a defect.
//
//   PART B — the cost of the bound. -flush takes the lock with LOCK_EX|LOCK_NB
//   and gives up after 0.25 s, deliberately, so a wedged lock holder cannot
//   hang a window that is closing. The comment says a failed flush is retried
//   "at the next flush point" -- but at QUIT there is no next flush point. So
//   this arm has each child flush exactly ONCE, the way a quitting process
//   does, and counts what actually lands. That is not asserted as a bug; it is
//   the documented trade measured, so the size of it is known rather than
//   assumed.

#import "PVStateStore.h"
#import "PVCommon.h"
#include <sys/wait.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>

static int gChecks, gFailures;
static void CHECK(int cond, const char *what, const char *detail)
{
    gChecks++;
    if (!cond) { gFailures++; printf("  FAIL  %s : %s\n", what, detail ? detail : ""); }
}

static NSURL *DocURL(int child, int index)
{
    return [NSURL fileURLWithPath:
        [NSString stringWithFormat:@"/tmp/pv-contend-c%d-d%03d.pdf", child, index]];
}

// One child: record `docs` documents, then flush. `persist` decides whether it
// keeps trying (an app that goes on running) or flushes once (an app quitting).
static void ChildBody(NSString *path, int child, int docs, BOOL persist)
{
    @autoreleasepool {
        PVStateStore *s = [[PVStateStore alloc] initWithPath:path];
        int i;
        for (i = 0; i < docs; i++) {
            [s recordForURL:DocURL(child, i)
                       page:(NSUInteger)(child * 100 + i)
                   fraction:0.25
                   zoomMode:PVZoomModeFitWidth
                       zoom:1.0
                    sidebar:NO
                    columns:1
                      cover:NO
                windowFrame:@"{{0,0},{800,600}}"];
        }
        if (persist) {
            // Keep trying, the way a running app reaches its next flush point.
            double giveUp = PVMonotonicSeconds() + 20.0;
            NSUInteger want = (NSUInteger)docs, have = 0;
            do {
                [s flush];
                // Re-read to see whether our keys actually landed.
                @autoreleasepool {
                    PVStateStore *check = [[PVStateStore alloc] initWithPath:path];
                    have = 0;
                    for (i = 0; i < docs; i++) {
                        NSUInteger pg; CGFloat fr, zm; PVZoomMode md;
                        BOOL sb; NSUInteger cols; NSString *fm = nil;
                        if ([check stateForURL:DocURL(child, i) page:&pg fraction:&fr
                                      zoomMode:&md zoom:&zm sidebar:&sb
                                       columns:&cols cover:NULL windowFrame:&fm]) have++;
                    }
                    [check release];
                }
                if (have >= want) break;
                usleep(20000);
            } while (PVMonotonicSeconds() < giveUp);
        } else {
            [s flush];              // exactly once: this child is "quitting"
        }
        [s release];
    }
    _exit(0);
}

// How many of the expected entries are actually on disk.
static int CountLanded(NSString *path, int children, int docs)
{
    int found = 0;
    @autoreleasepool {
        PVStateStore *s = [[PVStateStore alloc] initWithPath:path];
        int c, i;
        for (c = 0; c < children; c++) {
            for (i = 0; i < docs; i++) {
                NSUInteger pg; CGFloat fr, zm; PVZoomMode md;
                BOOL sb; NSUInteger cols; NSString *fm = nil;
                if ([s stateForURL:DocURL(c, i) page:&pg fraction:&fr zoomMode:&md
                              zoom:&zm sidebar:&sb columns:&cols cover:NULL
                           windowFrame:&fm]) {
                    found++;
                    // The value must be the one that child wrote, not a
                    // half-merged blend of two writers.
                    if (pg != (NSUInteger)(c * 100 + i)) {
                        char d[128];
                        snprintf(d, sizeof d, "child %d doc %d read back page %lu",
                                 c, i, (unsigned long)pg);
                        CHECK(0, "an entry holds the value its writer wrote", d);
                    }
                }
            }
        }
        [s release];
    }
    return found;
}

static BOOL FileIsValidPlist(NSString *path)
{
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) return NO;
    id o = [NSPropertyListSerialization propertyListWithData:d
                options:NSPropertyListImmutable format:NULL error:NULL];
    return [o isKindOfClass:[NSDictionary class]];
}

static void RunArm(const char *name, int children, int docs, BOOL persist)
{
    NSString *path = [NSString stringWithFormat:@"/tmp/pv-contend-%s.plist", name];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:
        [path stringByAppendingString:@".lock"] error:NULL];

    double t0 = PVMonotonicSeconds();
    int c;
    for (c = 0; c < children; c++) {
        pid_t pid = fork();
        if (pid == 0) ChildBody(path, c, docs, persist);
    }
    int alive = children, status = 0;
    while (alive > 0 && waitpid(-1, &status, 0) > 0) alive--;
    double elapsed = PVMonotonicSeconds() - t0;

    int landed = CountLanded(path, children, docs);
    int want = children * docs;

    printf("\n[%s] %d processes x %d documents, all flushing at once\n",
           name, children, docs);
    printf("   wall %.2f s   landed %d/%d (%.0f%%)\n",
           elapsed, landed, want, 100.0 * landed / want);

    char d[160];
    snprintf(d, sizeof d, "file is not a valid plist after %d concurrent writers",
             children);
    CHECK(FileIsValidPlist(path), "the state file is always readable", d);

    snprintf(d, sizeof d, "%d processes took %.2f s", children, elapsed);
    CHECK(elapsed < 60.0, "no writer hangs on the lock", d);

    if (persist) {
        snprintf(d, sizeof d, "landed %d of %d", landed, want);
        CHECK(landed == want,
              "every entry survives when writers retry (the merge promise)", d);
    } else {
        // Reported, not asserted: this is the documented trade, and what it
        // costs is a property of the machine's scheduling.
        printf("   NOTE: single-flush arm models processes QUITTING. -flush gives\n"
               "         up after 0.25 s and a quitting process has no next flush\n"
               "         point, so anything missing here is position lost on quit.\n");
        if (landed < want)
            printf("   >>>>  %d of %d entries did NOT survive simultaneous quit\n",
                   want - landed, want);
    }
}

int main(void)
{
    @autoreleasepool {
        printf("pvstatecontend: PVStateStore under real multi-process contention\n");
        // A: writers that keep trying. The merge must lose nothing.
        RunArm("retry", 8, 5, YES);
        // B: writers that flush once and exit, as at quit.
        RunArm("quit",  8, 5, NO);
        // B': harder -- more writers hitting the same 0.25 s window.
        RunArm("quit16", 16, 5, NO);
        // B'' -- as hard as this can be pushed without the 400-entry cap
        // legitimately pruning entries and confusing "dropped by the prune"
        // with "lost to the lock". 32 x 12 = 384, just under PV_MAX_REMEMBERED.
        RunArm("quit32", 32, 12, NO);
        // And the retry arm at the same width, where nothing may be lost.
        RunArm("retry32", 32, 12, YES);

        printf("\npvstatecontend: %d checks, %d failures\n", gChecks, gFailures);
        return gFailures ? 1 : 0;
    }
}
