// pvbadhelper — a render helper that lies, for testing the viewer's hardening.
//
// Postview splits parsing and drawing into a helper process so that a hostile
// DOCUMENT cannot take the viewer down. `pvfuzz` shows that it does not. But
// the split has a second consequence nothing tested: the helper is the process
// that handles attacker-controlled bytes, so the helper is the process most
// likely to be subverted — and the viewer believes what it says.
//
// The viewer does defend itself. It checks magic, version and sequence on every
// reply, bounds every read with a deadline, and refuses an open reply whose page
// count disagrees with the geometry it already has. Those checks were reachable
// only by accident. This makes them reachable on purpose.
//
// It is a shim, not a reimplementation. `copy` and `meta` are handed straight to
// the real helper by execv, so the document opens normally with real geometry;
// only the `render` conversation misbehaves. The mode, and the page count a
// valid-looking open reply needs, are read from a file because a helper is
// spawned with an empty environment by design.
//
// Usage is via pvhelperprotocol, which writes the mode file, drops this binary
// in beside itself as "PostviewRenderHelper", and drives PVPDFSource.

#import <Foundation/Foundation.h>
#include "PVRenderProtocol.h"
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>

#define MODE_FILE "/tmp/pvbadhelper-mode"

enum {
    BadNone = 0,          // pass everything through: the control
    BadExitBeforeOpen,    // die before the open reply
    BadOpenMagic,         // open reply, wrong magic
    BadOpenVersion,       // open reply, wrong version
    BadOpenPageCount,     // open reply that disagrees about the document
    BadOpenTruncated,     // half an open reply, then EOF
    BadRenderSilent,      // valid open, then never answer a render
    BadRenderMagic,       // valid open, then a reply with wrong magic
    BadRenderSequence,    // valid open, then a reply for a command never sent
    BadRenderStatusJunk,  // valid open, then an unknown status value
    BadRenderEOF,         // valid open, then close the pipe mid-conversation
    BadRenderFlood,       // valid open, then many replies for one command
    BadGarbage,           // valid open, then random bytes
    BadModeCount
};

static void ReadMode(int *mode, unsigned long long *pageCount)
{
    *mode = BadNone; *pageCount = 0;
    FILE *f = fopen(MODE_FILE, "r");
    if (!f) return;
    if (fscanf(f, "%d %llu", mode, pageCount) != 2) { *mode = BadNone; }
    fclose(f);
}

static void WriteAll(int fd, const void *buf, size_t n)
{
    const char *p = (const char *)buf;
    size_t off = 0;
    while (off < n) {
        ssize_t w = write(fd, p + off, n - off);
        if (w < 0) { if (errno == EINTR) continue; return; }
        if (w == 0) return;
        off += (size_t)w;
    }
}

// Hand this conversation to the genuine helper, which sits beside us.
static void PassThrough(const char *argv0, const char *snapshot, const char *mode)
{
    char real[4096];
    snprintf(real, sizeof real, "%s", argv0);
    char *slash = strrchr(real, '/');
    if (slash) *(slash + 1) = '\0'; else real[0] = '\0';
    strncat(real, "RealRenderHelper", sizeof(real) - strlen(real) - 1);
    const char *args[4] = { real, snapshot, mode, NULL };
    execv(real, (char *const *)args);
    _exit(70);            // execv only returns on failure
}

int main(int argc, const char *argv[])
{
    if (argc != 3) return 2;

    int mode; unsigned long long pageCount;
    ReadMode(&mode, &pageCount);

    // WHICH conversation to poison, and why it is not simply "the render one".
    //
    // A source that opens a document keeps the helper it used to read the page
    // geometry and renders through that same process -- -ensureRenderHelper:
    // finds `_helperPid` still live and returns immediately, so a helper
    // spawned in RENDER mode never happens for a freshly opened document at
    // all. The first version of this shim poisoned only "render" and was never
    // once invoked in that mode; every lie passed straight through and every
    // assertion passed for the wrong reason.
    //
    // So the open-reply lies are told in META, which is the mode a real
    // document actually opens with, and the render lies are told in RENDER,
    // which pvhelperprotocol reaches by killing the helper first. Copying is
    // always passed through: it happens before any of this matters.
    {
        BOOL isMeta   = (strcmp(argv[2], PV_HELPER_MODE_META) == 0);
        BOOL isRender = (strcmp(argv[2], PV_HELPER_MODE_RENDER) == 0);
        BOOL openLie   = (mode >= BadExitBeforeOpen && mode <= BadOpenTruncated);
        BOOL renderLie = (mode >= BadRenderSilent   && mode <= BadGarbage);
        if (mode == BadNone ||
            (isMeta   && !openLie) ||
            (isRender && !renderLie) ||
            (!isMeta && !isRender))
            PassThrough(argv[0], argv[1], argv[2]);
    }

    switch (mode) {
        case BadExitBeforeOpen:
            _exit(3);

        case BadOpenTruncated: {
            PVRenderOpenReply r;
            memset(&r, 0, sizeof r);
            r.magic = PV_RENDER_PROTOCOL_MAGIC;
            r.version = PV_RENDER_PROTOCOL_VERSION;
            r.pageCount = pageCount;
            WriteAll(STDOUT_FILENO, &r, sizeof(r) / 2);   // half a reply
            _exit(0);
        }

        default: break;
    }

    // Everything below sends an open reply first, correct or otherwise.
    PVRenderOpenReply open;
    memset(&open, 0, sizeof open);
    open.magic   = (mode == BadOpenMagic)   ? 0xDEADBEEFu : PV_RENDER_PROTOCOL_MAGIC;
    open.version = (mode == BadOpenVersion) ? 999u        : PV_RENDER_PROTOCOL_VERSION;
    open.status  = PVRenderOpenOK;
    open.geometryCount = 0;
    open.pageCount = (mode == BadOpenPageCount) ? (pageCount + 4242ULL) : pageCount;
    WriteAll(STDOUT_FILENO, &open, sizeof open);

    if (mode == BadOpenMagic || mode == BadOpenVersion || mode == BadOpenPageCount) {
        // The viewer should reject this and kill us; wait to be killed rather
        // than exiting, so the test measures its reaction and not our exit.
        for (;;) pause();
    }

    // Now serve (badly) whatever render commands arrive.
    for (;;) {
        PVRenderCommand cmd;
        size_t off = 0;
        BOOL eof = NO;
        while (off < sizeof cmd) {
            ssize_t n = read(STDIN_FILENO, (char *)&cmd + off, sizeof(cmd) - off);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { eof = YES; break; }
            off += (size_t)n;
        }
        if (eof) _exit(0);

        switch (mode) {
            case BadRenderSilent:
                // Say nothing at all, ever. The viewer's deadline is the only
                // thing that can end this.
                for (;;) pause();

            case BadRenderEOF:
                close(STDOUT_FILENO);
                for (;;) pause();

            case BadGarbage: {
                unsigned char junk[sizeof(PVRenderReply) * 3];
                unsigned i;
                for (i = 0; i < sizeof junk; i++) junk[i] = (unsigned char)(i * 37 + 11);
                WriteAll(STDOUT_FILENO, junk, sizeof junk);
                break;
            }

            default: {
                PVRenderReply r;
                memset(&r, 0, sizeof r);
                r.magic    = (mode == BadRenderMagic) ? 0x0BADF00Du
                                                      : PV_RENDER_PROTOCOL_MAGIC;
                r.version  = PV_RENDER_PROTOCOL_VERSION;
                r.sequence = (mode == BadRenderSequence) ? (cmd.sequence ^ 0x5555ULL)
                                                         : cmd.sequence;
                r.status   = (mode == BadRenderStatusJunk) ? 0x7FFFFFFF : 0;
                WriteAll(STDOUT_FILENO, &r, sizeof r);
                if (mode == BadRenderFlood) {
                    int k;
                    for (k = 0; k < 8; k++) WriteAll(STDOUT_FILENO, &r, sizeof r);
                }
                break;
            }
        }
    }
    return 0;
}
