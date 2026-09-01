#ifndef PV_RENDER_PROTOCOL_H
#define PV_RENDER_PROTOCOL_H

#include <stdint.h>

// Bumped from 1 when the helper took over opening the document, and from 2 when
// the bitmap stopped being addressed by name. A version-1 helper never sends the
// open reply the parent waits for; a version-2 helper expects a shared-memory
// NAME in the command and would read the field the descriptor replaced. Neither
// can be mixed with this one, so the number moves.
#define PV_RENDER_PROTOCOL_MAGIC   ((uint32_t)0x50565231) /* PVR1 */
#define PV_RENDER_PROTOCOL_VERSION ((uint32_t)3)

// How the bitmap reaches the helper: as a descriptor, over the command socket,
// in the SCM_RIGHTS control message attached to the command itself.
//
// It used to travel as a POSIX shared-memory NAME, and a name is a thing that
// outlives the processes that agreed on it. The viewer created the object,
// named it in the command, and the helper unlinked it once it had mapped it --
// which is correct on every path where both processes live long enough to run
// it, and on no other. A viewer killed between shm_open and the helper's unlink
// left the object with no owner and no name that anything would ever look up
// again, and a POSIX shared-memory object with no link survives until the
// machine is rebooted. Measured after a forced crash: one 12,800,000-byte
// object, permanently.
//
// A descriptor cannot leak that way. The viewer now unlinks the name
// immediately after sizing the object -- before it is ever mapped or sent -- so
// from that instant the object exists only as long as some descriptor or
// mapping refers to it. Every way either process can die, including SIGKILL,
// closes descriptors and drops mappings, so every crash path is kernel-clean by
// construction rather than by remembering to tidy up.
//
// This is why the command channel is a socketpair and not a pipe: SCM_RIGHTS
// needs an AF_UNIX socket. The reply channel is still an ordinary pipe.
#define PV_RENDER_COMMAND_CARRIES_FD 1

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

// Copying the source document into the snapshot, in a process of its own.
//
// This is the same argument as rasterising, applied to the other end. open()
// and read() on a network or removable volume are not interruptible calls: when
// an SMB or NFS mount goes away, or a USB disk is pulled mid-read, the thread
// making them blocks in the kernel and stays there. No timeout, no signal and
// no amount of care in the calling code brings it back -- the only thing that
// can be bounded is a process that can be killed.
//
// So the viewer no longer touches the source file at all. It creates the empty
// snapshot, hands the descriptor to a copier, and watches: the copier's exit
// wakes it immediately, and a copier that stops making progress is killed and
// its half-written snapshot unlinked. Nothing the source volume does can wedge
// the viewer, and nothing a wedged copier holds is waited for on a thread that
// matters.
#define PV_HELPER_MODE_COPY   "copy"     /* copy argv[1] into fd 1, then exit */

// The descriptor the copier writes the snapshot to. stdout, so that the file
// actions that set it up are the same two lines every other spawn uses.
#define PV_COPY_OUTPUT_FD 1

// How long the snapshot may fail to GROW before its copier is presumed wedged.
//
// Deliberately a stall bound and not a total one. A 2 GB document off a slow
// USB 2 disk is a legitimate multi-minute copy, and a flat deadline would kill
// it for being large rather than for being stuck. What distinguishes a hung
// mount is that nothing arrives at all.
#define PV_COPY_STALL_SECONDS (20.0)

// How often the supervisor wakes to check that growth, when the copier has not
// exited. Short enough that a wedge is noticed promptly, long enough that a
// normal copy is not measurably watched.
#define PV_COPY_POLL_SECONDS  (1)

// The largest source document this viewer will copy, and the free space it
// insists on having left over afterwards.
//
// Neither bound existed, and the copy loop reads until EOF. A sparse regular
// file is the cheap way to demonstrate the problem -- a hundred gigabytes of
// holes costs nothing to create and fills the boot volume when copied -- but
// any large regular file does it, and the temporary directory filling up takes
// the rest of the system with it, not just Postview. Two gigabytes is far past
// any PDF that can be presented on the target hardware.
//
// Shared with the copier rather than private to the viewer, because the copier
// is now the process that enforces both.
#define PV_MAX_PDF_BYTES     (2LL * 1024LL * 1024LL * 1024LL)
#define PV_SNAPSHOT_HEADROOM (256LL * 1024LL * 1024LL)
#define PV_COPY_CHUNK_BYTES  (128 * 1024)

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
    // No shared-memory name. The bitmap arrives as the descriptor in this
    // command's SCM_RIGHTS control message; see PV_RENDER_COMMAND_CARRIES_FD.
} PVRenderCommand;

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint64_t sequence;
    int32_t  status;           /* zero on success */
    uint32_t reserved;
} PVRenderReply;

#endif
