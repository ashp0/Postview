#ifndef PV_RENDER_PROTOCOL_H
#define PV_RENDER_PROTOCOL_H

#include <stdint.h>

// Bumped from 1 when the helper took over opening the document. A version-1
// helper answers render commands but never sends the open reply the parent now
// waits for, so the two cannot be mixed and the number has to move.
#define PV_RENDER_PROTOCOL_MAGIC   ((uint32_t)0x50565231) /* PVR1 */
#define PV_RENDER_PROTOCOL_VERSION ((uint32_t)2)
#define PV_RENDER_SHM_NAME_MAX     96

// Layout is precomputed so neither the main thread nor the renderer has to ask
// CoreGraphics for page geometry again. Put a finite bound on that up front: an
// intentionally hostile PDF can otherwise name enough pages to make the
// bookkeeping allocations overflow or exhaust the machine before it has
// displayed anything useful. One hundred thousand pages is already far beyond
// the documents this viewer can present well on its target hardware (and still
// leaves the geometry table under 4 MB on the wire).
//
// Shared with the helper rather than private to the viewer, because both ends
// now enforce it: the helper refuses to describe a longer document, and the
// parent refuses to believe one that claims to be.
#define PV_MAX_PDF_PAGES ((uint64_t)100000)

// How long one exchange may take before the helper is presumed wedged, and the
// helper's own fail-safe for the same exchange.
//
// This is the timeout the process boundary exists to make enforceable:
// CGContextDrawPDFPage cannot be interrupted, so the only way to bound it is to
// bound something that can be killed. Opening is given a flat allowance,
// because it may have to walk a hundred thousand pages.
//
// A RENDER's allowance is not flat, and this is the part that had to change.
// It was a flat twenty seconds, chosen when the drawing ran at ordinary
// priority and a full page took around three. Backgrounding the helper -- which
// is the whole thermal and battery policy -- made the same page take five times
// longer, and a bitmap at the machine's pixel ceiling was measured on the
// DEVELOPMENT host at 13-17 s against that 20 s limit. The target hardware is a
// 2013 Xeon and a 2013 Haswell, several times slower again. A reader who zoomed
// in would have had the helper killed mid-page, the render reported failed, and
// the page retried into the same wall.
//
// So the allowance scales with the work: a fixed floor for the parse and the
// process, plus a per-megapixel term set well above the measured rate (~1 s/Mpx
// here at background priority) to cover slower machines and a loaded system,
// and a ceiling so that a wedged helper is always eventually reclaimed. What is
// being bounded is "far longer than this could legitimately take", and that is
// a property of the bitmap, not a constant.
//
// The two ends are deliberately different numbers. The parent kills a helper
// that misses its deadline, so the helper's alarm only ever fires when there is
// no parent left to do it -- which is precisely the orphan the alarm exists
// for. An alarm shorter than the parent's deadline would instead kill healthy
// helpers doing slow but legitimate work.
#define PV_RENDER_DEADLINE_BASE     (15.0)
#define PV_RENDER_DEADLINE_PER_MPX  (12.0)
#define PV_RENDER_DEADLINE_MAX      (240.0)
#define PV_ALARM_MARGIN_SECONDS     (5.0)
#define PV_OPEN_DEADLINE_SECONDS    (30.0)
#define PV_OPEN_ALARM_SECONDS       (35u)

// Both ends compute the deadline from the same command, with the same code, so
// they cannot drift apart. A helper whose alarm was shorter than the viewer's
// deadline would kill itself doing legitimate work; one whose alarm was far
// longer would stop being a fail-safe.
static inline double PVRenderDeadlineSeconds(uint64_t width, uint64_t height)
{
    double megapixels = ((double)width * (double)height) / 1.0e6;
    double seconds = PV_RENDER_DEADLINE_BASE +
                     PV_RENDER_DEADLINE_PER_MPX * megapixels;
    if (!(seconds > PV_RENDER_DEADLINE_BASE)) seconds = PV_RENDER_DEADLINE_BASE;
    if (seconds > PV_RENDER_DEADLINE_MAX)     seconds = PV_RENDER_DEADLINE_MAX;
    return seconds;
}

static inline unsigned PVRenderAlarmSeconds(uint64_t width, uint64_t height)
{
    return (unsigned)(PVRenderDeadlineSeconds(width, height) +
                      PV_ALARM_MARGIN_SECONDS) + 1u;
}

// Which of the two things a helper is being started for.
//
// A lane source and the thumbnail source already have their geometry, copied
// from the source that opened the document first, so making every helper walk
// the page tree again would pay for the same parse three times over on a
// two-lane machine with the sidebar open.
#define PV_HELPER_MODE_META   "meta"     /* open reply, then geometry records */
#define PV_HELPER_MODE_RENDER "render"   /* open reply only */

// Why the helper could not present the document. Carried instead of an errno
// because these are the cases the viewer has distinct wording for, and because
// the interesting ones (encrypted, no pages) are not errno values at all.
enum {
    PVRenderOpenOK           = 0,
    PVRenderOpenUnreadable   = 1,   /* CGPDFDocumentCreateWithURL declined */
    PVRenderOpenEncrypted    = 2,   /* locked, and we do not ask for passwords */
    PVRenderOpenNoPages      = 3,
    PVRenderOpenTooManyPages = 4,   /* past PV_MAX_PDF_PAGES */
    PVRenderOpenOutOfMemory  = 5
};

// Sent once, immediately after the helper has opened the snapshot, before any
// command is read. Fixed size and self-delimiting: the parent reads exactly
// this many bytes under a deadline and never has to trust a length it has not
// already bounded.
typedef struct {
    uint32_t magic;
    uint32_t version;
    int32_t  status;         /* one of the PVRenderOpen* values above */
    uint32_t geometryCount;  /* records that follow; 0 in render mode */
    uint64_t pageCount;
} PVRenderOpenReply;

// One page, as the helper measured it. The crop box is already the validated
// crop/media intersection -- the same rectangle the helper will clip to when it
// draws -- so the viewer's layout and the helper's rasterisation cannot
// disagree about what the page is.
typedef struct {
    double   x, y, width, height;
    int32_t  rotation;       /* normalised to 0, 90, 180 or 270 */
    uint32_t reserved;
} PVRenderPageGeometry;

// What scheduling priority the helper should draw this page at.
//
// The helper backgrounds itself at startup, because that is what almost every
// render should be: prefetch and scroll-ahead exist to be cheap, and Darwin's
// background class is where the thermal and battery policy lives.
//
// But not every render. The express lane -- the one page the reader is looking
// at with nothing cached to show -- is the case the whole latency budget is
// spent on, and it stops existing if the process that does the drawing is
// pinned to background regardless. Measured on this machine: 266 ms at normal
// priority against 1401 ms backgrounded, for the same 1200x1550 page. Promoting
// the parent's dispatch block alone promotes the thread that WAITS.
//
// So the priority travels with the command and the helper adopts it for the
// duration of that one page, returning to background afterwards. Express
// renders are rare by construction; everything else stays cheap.
enum {
    PVRenderPriorityBackground  = 0,
    PVRenderPriorityInteractive = 1
};

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint64_t sequence;
    uint64_t page;             /* zero based */
    uint32_t width;
    uint32_t height;
    uint32_t priority;         /* one of the PVRenderPriority* values */
    uint32_t reserved;
    uint64_t bytesPerRow;
    double   naturalWidth;
    double   naturalHeight;
    char     sharedMemoryName[PV_RENDER_SHM_NAME_MAX];
} PVRenderCommand;

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint64_t sequence;
    int32_t  status;           /* zero on success */
    uint32_t reserved;
} PVRenderReply;

#endif
