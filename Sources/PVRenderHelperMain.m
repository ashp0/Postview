//  PVRenderHelperMain.m -- the render helper process.
//
//  Rasterising a PDF page means calling CGContextDrawPDFPage, which is an
//  uninterruptible C call into Quartz. A malformed document can make it parse
//  forever, deadlock, or fault; @catch sees none of those, because none of them
//  is an Objective-C exception. The only honest containment is a process
//  boundary, so the drawing happens here and the viewer keeps a deadline on it.
//
//  OPENING the document is contained here for the same reason and it is the
//  same reason. CGPDFDocumentCreateWithURL, CGPDFDocumentGetNumberOfPages and
//  the page-tree walk behind CGPDFDocumentGetPage are all Quartz parsing
//  attacker-controlled bytes, and a viewer that performed them itself would be
//  killable by a document before the helper it built was ever used. Nothing in
//  the viewer process touches CGPDF* any more: this process opens the snapshot,
//  measures every page, sends the measurements over the pipe, and is the only
//  thing that can die of the answer.
//
//  This process owns its own CGPDFDocumentRef and shares nothing with the
//  viewer but a page of bytes and two pipes. If it hangs or dies, the viewer
//  kills it, fails that one render, and starts a fresh one.
#import <Foundation/Foundation.h>
#import "PVRenderProtocol.h"
#import "PVRenderCore.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/event.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <string.h>
#include <pthread.h>

static BOOL PVReadExact(int fd, void *bytes, size_t length)
{
    size_t offset = 0;
    while (offset < length) {
        ssize_t count = read(fd, (char *)bytes + offset, length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        offset += (size_t)count;
    }
    return YES;
}

static BOOL PVWriteExact(int fd, const void *bytes, size_t length)
{
    size_t offset = 0;
    while (offset < length) {
        ssize_t count = write(fd, (const char *)bytes + offset, length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        offset += (size_t)count;
    }
    return YES;
}

// Die when the viewer does.
//
// Pipe EOF is the ordinary way this process learns it is no longer wanted, and
// it is enough right up until it is not: a helper wedged inside Quartz is not
// at a read() and will not notice EOF until the call it is stuck in returns,
// which is the case where "stuck" means never. A viewer that crashed mid-render
// would then leave a process behind burning a core on a document nobody is
// looking at, for as long as the machine stays up.
//
// EVFILT_PROC/NOTE_EXIT fires from the kernel regardless of what this process
// is doing, so the wait costs nothing and works from inside a hung render.
static void *PVParentWatchdog(void *context)
{
    pid_t parent = (pid_t)(intptr_t)context;

    int queue = kqueue();
    if (queue >= 0) {
        struct kevent change;
        EV_SET(&change, (uintptr_t)parent, EVFILT_PROC, EV_ADD | EV_ENABLE,
               NOTE_EXIT, 0, NULL);
        if (kevent(queue, &change, 1, NULL, 0, NULL) == 0) {
            // Registration can lose a race with the parent's death, and a
            // kevent already registered against a dead process reports nothing.
            // Re-asking who our parent is settles it: an orphan has been
            // reparented and no longer names the process we just watched.
            if (getppid() != parent) _exit(0);
            for (;;) {
                struct kevent event;
                int n = kevent(queue, NULL, 0, &event, 1, NULL);
                if (n < 0 && errno == EINTR) continue;
                break;
            }
            _exit(0);
        }
        close(queue);
    }

    // kqueue could not be used. Polling is a poor second -- it notices a dead
    // parent up to a second late -- but a late exit is still an exit, and the
    // alternative is no fail-safe at all.
    for (;;) {
        if (getppid() != parent) _exit(0);
        sleep(1);
    }
    return NULL;
}

static void PVStartParentWatchdog(void)
{
    pid_t parent = getppid();
    // Already an orphan: nothing spawned us that is still here to want the
    // answer, so there is nothing worth opening a document for.
    if (parent <= 1) _exit(0);

    pthread_t thread;
    pthread_attr_t attr;
    if (pthread_attr_init(&attr) != 0) return;
    (void)pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    (void)pthread_create(&thread, &attr, PVParentWatchdog,
                         (void *)(intptr_t)parent);
    pthread_attr_destroy(&attr);
}

// Measure every page and send it. Returns NO if the viewer stopped listening.
static BOOL PVSendGeometry(CGPDFDocumentRef document, size_t pageCount)
{
    size_t i;
    for (i = 0; i < pageCount; i++) {
        PVRenderPageGeometry record;
        memset(&record, 0, sizeof(record));

        // Per page rather than once around the loop. A hundred thousand pages
        // is a legitimate document and each one is cheap; what the alarm is
        // bounding is the single page that never returns.
        alarm(PV_OPEN_ALARM_SECONDS);
        CGPDFPageRef page = CGPDFDocumentGetPage(document, i + 1);
        CGRect box = PVSafeCropBox(page);          // NULL-safe: US Letter
        int rotation = PVPageRotation(page);
        alarm(0);

        record.x        = (double)box.origin.x;
        record.y        = (double)box.origin.y;
        record.width    = (double)box.size.width;
        record.height   = (double)box.size.height;
        record.rotation = rotation;
        if (!PVWriteExact(STDOUT_FILENO, &record, sizeof(record))) return NO;
    }
    return YES;
}

// Adopt the priority one command asked for, and say whether it was changed.
//
// Entering and leaving Darwin's background class is a cheap, per-process,
// reversible state -- setpriority with PRIO_DARWIN_BG to enter, 0 to leave --
// so the express page can be drawn at ordinary priority and everything after it
// goes straight back to being cheap. A failure to LEAVE background is not fatal:
// the page is merely slow, which is the behaviour without this at all. A failure
// to RE-ENTER it is, because that is the thermal policy silently switching off.
static BOOL PVAdoptCommandPriority(uint32_t priority)
{
    if (priority != PVRenderPriorityInteractive) return NO;
    return (setpriority(PRIO_DARWIN_PROCESS, 0, 0) == 0);
}

int main(int argc, const char *argv[])
{
    if (argc != 3) return 2;

    // Before anything expensive, and before the document is even opened.
    //
    // The viewer's render queue targets the background global queue, but since
    // the rasterisation moved out of process that only backgrounds the thread
    // that WAITS for this one -- the Quartz call itself runs here, and a child
    // of posix_spawn inherits an ordinary foreground priority. Observed
    // directly: helper at nice 0 while the viewer's render thread sat at
    // background. That silently undid the thermal and battery policy the whole
    // scheduler is built around, which on the Haswell target is the difference
    // between ~84 mJ and ~684 mJ for the same page.
    //
    // A failure here is fatal rather than ignored. Running this work at
    // foreground priority is not a degraded mode of the design, it is the thing
    // the design exists to prevent, and doing it silently would be worse than
    // failing the render: the viewer starts a fresh helper and reports the
    // failure, which is visible.
    if (setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG) != 0) return 4;

    // A viewer that dies mid-command turns the next write into SIGPIPE. Ignored
    // so the write reports EPIPE and this process exits through its own loop.
    signal(SIGPIPE, SIG_IGN);
    // The alarms below are fail-safes, so the default action -- terminate -- is
    // exactly what is wanted. Stated rather than assumed, because a handler
    // inherited across exec would turn the fail-safe into a no-op.
    signal(SIGALRM, SIG_DFL);

    PVStartParentWatchdog();

    BOOL wantGeometry = (strcmp(argv[2], PV_HELPER_MODE_META) == 0);
    CGPDFDocumentRef document = NULL;
    PVRenderOpenReply open;

    @autoreleasepool {
        NSURL *url = [NSURL fileURLWithPath:
            [NSString stringWithUTF8String:argv[1]]];

        memset(&open, 0, sizeof(open));
        open.magic = PV_RENDER_PROTOCOL_MAGIC;
        open.version = PV_RENDER_PROTOCOL_VERSION;
        open.status = PVRenderOpenUnreadable;

        alarm(PV_OPEN_ALARM_SECONDS);
        document = url ? CGPDFDocumentCreateWithURL((CFURLRef)url) : NULL;
        alarm(0);

        if (document) {
            alarm(PV_OPEN_ALARM_SECONDS);
            BOOL locked = (CGPDFDocumentIsEncrypted(document) &&
                           !CGPDFDocumentIsUnlocked(document));
            size_t pageCount = locked ? 0 : CGPDFDocumentGetNumberOfPages(document);
            alarm(0);

            if (locked) {
                open.status = PVRenderOpenEncrypted;
            } else if (pageCount == 0) {
                open.status = PVRenderOpenNoPages;
            } else if ((uint64_t)pageCount > PV_MAX_PDF_PAGES) {
                open.status = PVRenderOpenTooManyPages;
            } else {
                open.status = PVRenderOpenOK;
                open.pageCount = (uint64_t)pageCount;
                if (wantGeometry) open.geometryCount = (uint32_t)pageCount;
            }
        }
    }

    if (!PVWriteExact(STDOUT_FILENO, &open, sizeof(open))) {
        if (document) CGPDFDocumentRelease(document);
        return 5;
    }
    if (open.status != PVRenderOpenOK) {
        if (document) CGPDFDocumentRelease(document);
        // Not an error exit: the viewer has been told exactly what is wrong and
        // will present it. Exiting non-zero here would only add a second,
        // less informative account of the same thing.
        return 0;
    }
    if (open.geometryCount &&
        !PVSendGeometry(document, (size_t)open.geometryCount)) {
        CGPDFDocumentRelease(document);
        return 5;
    }

    for (;;) {
        // One pool per command, not one for the process.
        //
        // Quartz autoreleases as it parses, and this loop used to run inside a
        // single pool that was drained when the process exited -- which is to
        // say never, for a helper the viewer keeps alive across a reading
        // session. Measured at 183-242 MB resident against a viewer using
        // 34-40 MB, and invisible to the soak gate, which only ever looked at
        // mach_task_self().
        @autoreleasepool {
            PVRenderCommand command;
            if (!PVReadExact(STDIN_FILENO, &command, sizeof(command))) break;

            PVRenderReply reply;
            memset(&reply, 0, sizeof(reply));
            reply.magic = PV_RENDER_PROTOCOL_MAGIC;
            reply.version = PV_RENDER_PROTOCOL_VERSION;
            reply.sequence = command.sequence;
            reply.status = EPROTO;

            if (command.magic == PV_RENDER_PROTOCOL_MAGIC &&
                command.version == PV_RENDER_PROTOCOL_VERSION &&
                command.width > 0 && command.height > 0 &&
                command.bytesPerRow >= (uint64_t)command.width * 4 &&
                command.height <= SIZE_MAX / command.bytesPerRow &&
                command.page < open.pageCount &&
                memchr(command.sharedMemoryName, '\0',
                       sizeof(command.sharedMemoryName)) != NULL) {
                size_t bytes = (size_t)command.bytesPerRow * command.height;
                int fd = shm_open(command.sharedMemoryName, O_RDWR, 0);
                if (fd >= 0) {
                    // The segment has to be at least the size the command says.
                    //
                    // Mapping is not bounds-checked by anything else: a shorter
                    // segment maps successfully and then raises SIGBUS on the
                    // first write past its end, in the middle of Quartz, on
                    // whichever row of the page happens to cross the boundary.
                    // The name is a rendezvous with another process, so its
                    // size is not something this one gets to assume.
                    //
                    // At least, not exactly: the kernel rounds a shared-memory
                    // object up to a whole page, so the creator's ftruncate
                    // length and the length fstat reports here differ for every
                    // bitmap whose byte count is not page-aligned -- which is
                    // nearly all of them, and by a different amount on a 4 KB
                    // page than on a 16 KB one. Demanding equality rejected
                    // every render on both.
                    struct stat info;
                    BOOL sized = (fstat(fd, &info) == 0 &&
                                  info.st_size >= 0 &&
                                  (uint64_t)info.st_size >= (uint64_t)bytes);
                    void *map = sized ? mmap(NULL, bytes, PROT_READ | PROT_WRITE,
                                             MAP_SHARED, fd, 0)
                                      : MAP_FAILED;
                    int mapErrno = errno;
                    close(fd);
                    // The name has done its job: both processes hold a mapping,
                    // and the segment now lives until the last of them unmaps
                    // it. Unlinking here rather than only in the viewer bounds
                    // what a SIGKILL can strand -- the viewer's own unlink is in
                    // a @finally, which a killed process never runs, and a
                    // leaked POSIX shared-memory segment survives until reboot.
                    if (map != MAP_FAILED)
                        (void)shm_unlink(command.sharedMemoryName);
                    if (map != MAP_FAILED) {
                        // Raised only for the duration of this one page, and
                        // only when the viewer asked. See PVRenderPriority*.
                        BOOL raised = PVAdoptCommandPriority(command.priority);
                        alarm(PVRenderAlarmSeconds(command.width,
                                                   command.height));
                        BOOL ok = PVRenderPDFPageToBuffer(document,
                            (NSUInteger)command.page,
                            CGSizeMake((CGFloat)command.naturalWidth,
                                       (CGFloat)command.naturalHeight),
                            command.width, command.height, map,
                            (size_t)command.bytesPerRow);
                        alarm(0);
                        // Back to background before the reply is even written,
                        // so no work after this page can inherit the promotion.
                        // If it cannot be restored the process is no longer
                        // honouring the policy it exists to honour, and the
                        // honest response is to stop being that process: the
                        // viewer starts a fresh one, which begins backgrounded.
                        if (raised &&
                            setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG) != 0) {
                            munmap(map, bytes);
                            // Released even though the process is about to end,
                            // because the exit paths of this loop are the ones
                            // the analyser reads to decide whether `document`
                            // is owned -- and an exit that quietly abandons it
                            // is indistinguishable, to a reader and to the
                            // analyser, from one that forgot.
                            CGPDFDocumentRelease(document);
                            return 4;
                        }
                        munmap(map, bytes);
                        reply.status = ok ? 0 : EINVAL;
                    } else {
                        reply.status = sized ? mapErrno : EINVAL;
                    }
                } else {
                    reply.status = errno;
                }
            }

            if (!PVWriteExact(STDOUT_FILENO, &reply, sizeof(reply))) break;
        }
    }
    CGPDFDocumentRelease(document);
    return 0;
}
