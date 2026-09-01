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
#include <sys/mount.h>        // fstatfs, for the copier's headroom check
#include <sys/socket.h>       // recvmsg, SCM_RIGHTS
#include <sys/stat.h>
#include <sys/event.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

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

// One command, and the descriptor of the bitmap it is about.
//
// The viewer attaches the shared-memory descriptor to the command's SCM_RIGHTS
// control message, so a command and its buffer arrive together or not at all.
// See PV_RENDER_COMMAND_CARRIES_FD for why the buffer stopped being a name.
//
// Returns NO on EOF or on anything malformed, which is the same answer this
// process gives to every unusable input: stop, and let the viewer start a fresh
// helper.
static BOOL PVReceiveCommand(int socket, PVRenderCommand *command, int *outFD)
{
    *outFD = -1;

    struct iovec item;
    item.iov_base = command;
    item.iov_len  = sizeof(*command);

    // Aligned as a cmsghdr, and sized by a constant.
    //
    // Two separate hazards, both invisible until they are not. The union gives
    // the storage cmsghdr alignment, which CMSG_FIRSTHDR needs and a bare char
    // array does not promise. The odd-looking length is because CMSG_SPACE is
    // NOT a constant expression on the 10.9 SDK -- __DARWIN_ALIGN32 casts
    // through a size_t -- so using it to size an array quietly produced a
    // variable-length array inside a union, which is a clang extension rather
    // than C. sizeof(struct cmsghdr) + sizeof(int) + 32 is a genuine constant
    // and is comfortably above CMSG_SPACE(sizeof(int)), which cannot exceed
    // sizeof(struct cmsghdr) + 3 + sizeof(int) + 3.
    union {
        struct cmsghdr align;
        char           bytes[sizeof(struct cmsghdr) + sizeof(int) + 32];
    } control;
    memset(&control, 0, sizeof(control));

    // Stated rather than trusted to the arithmetic above.
    if (sizeof(control.bytes) < CMSG_SPACE(sizeof(int))) return NO;

    struct msghdr message;
    memset(&message, 0, sizeof(message));
    message.msg_iov        = &item;
    message.msg_iovlen     = 1;
    message.msg_control    = control.bytes;
    message.msg_controllen = sizeof(control.bytes);

    ssize_t got;
    do { got = recvmsg(socket, &message, 0); }
    while (got < 0 && errno == EINTR);
    if (got <= 0) return NO;

    struct cmsghdr *header;
    for (header = CMSG_FIRSTHDR(&message); header != NULL;
         header = CMSG_NXTHDR(&message, header)) {
        if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS)
            continue;
        size_t payload = (size_t)header->cmsg_len - CMSG_LEN(0);
        size_t count = payload / sizeof(int);
        size_t i;
        for (i = 0; i < count; i++) {
            int received;
            memcpy(&received, CMSG_DATA(header) + i * sizeof(int),
                   sizeof(received));
            // Exactly one is expected. Anything past the first is closed rather
            // than kept: a sender that gets this wrong must not be able to fill
            // this process's descriptor table one render at a time.
            if (*outFD < 0) *outFD = received;
            else            close(received);
        }
    }

    // The kernel had to drop control data that did not fit, so a descriptor may
    // have been lost on the way in. A command whose buffer is unknown is not
    // one to guess at.
    if (message.msg_flags & MSG_CTRUNC) {
        if (*outFD >= 0) { close(*outFD); *outFD = -1; }
        return NO;
    }

    // A stream socket may deliver the command in pieces. The descriptor came
    // with the first of them; the remainder is ordinary bytes.
    size_t offset = (size_t)got;
    while (offset < sizeof(*command)) {
        ssize_t n = read(socket, (char *)command + offset,
                         sizeof(*command) - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) {
            if (*outFD >= 0) { close(*outFD); *outFD = -1; }
            return NO;
        }
        offset += (size_t)n;
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

// Start the watchdog, and say whether there is one.
//
// The return value is checked by both callers, and that is the whole change.
// pthread_attr_init and pthread_create were called for effect and their
// failures discarded, which meant the one case that actually matters -- no
// watchdog thread at all -- was indistinguishable from success. A helper
// without a watchdog is a process with no fail-safe: if its viewer dies while
// it is wedged inside Quartz it never notices, and it burns a core on a
// document nobody is looking at until the machine is restarted. That is
// precisely the outcome this thread exists to prevent, so failing to create it
// is not a degraded mode to carry on in.
//
// Note what is NOT fatal: kqueue being unavailable inside the thread. The
// polling fallback there is a real fail-safe -- it notices a dead parent within
// a second and exits -- and refusing to render because kqueue failed would
// trade a working guarantee for no renderer at all.
static BOOL PVStartParentWatchdog(void)
{
    pid_t parent = getppid();
    // Already an orphan: nothing spawned us that is still here to want the
    // answer, so there is nothing worth opening a document for.
    if (parent <= 1) _exit(0);

    pthread_t thread;
    pthread_attr_t attr;
    if (pthread_attr_init(&attr) != 0) return NO;
    (void)pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    int rc = pthread_create(&thread, &attr, PVParentWatchdog,
                            (void *)(intptr_t)parent);
    pthread_attr_destroy(&attr);
    return (rc == 0);
}

// Copy argv[1] into PV_COPY_OUTPUT_FD, and report by exit status.
//
// This runs before anything else in this process: no Quartz, no document, no
// background priority. The copy is what a reader is waiting on, so it is not
// throttled, and the process exits the moment it is done.
//
// The result travels as the exit status rather than over a pipe, because every
// value it can carry is an errno and every errno on Darwin fits in the eight
// bits an exit status has. That leaves nothing to frame, nothing to read under
// a deadline, and no channel that can itself wedge. The supervisor learns the
// answer from waitpid, and learns that there IS an answer from NOTE_EXIT.
//
// Every bound the viewer used to enforce inline is enforced here instead, on
// the far side of the process boundary, where a hung read cannot take the
// viewer with it.
static int PVCopySource(const char *sourcePath)
{
    void *buffer = NULL;
    int input = -1;
    int saved = 0;
    long long copied = 0;
    struct stat before, after;
    struct statfs space;

    memset(&before, 0, sizeof(before));
    memset(&after, 0, sizeof(after));

    buffer = malloc(PV_COPY_CHUNK_BYTES);
    if (!buffer) { saved = ENOMEM; goto done; }

    // The first call that can block forever, and the reason this is a separate
    // process at all: open() on a dead mount does not return.
    input = open(sourcePath, O_RDONLY);
    if (input < 0) { saved = errno; goto done; }

    // The two failures are separated because only one of them sets errno.
    // fstat succeeding on something that is not a regular file leaves errno
    // holding whatever the last unrelated call left there -- or nothing at all,
    // which is an undefined read -- and the error the user is then shown is a
    // strerror() of that.
    if (fstat(input, &before) != 0) { saved = errno; goto done; }
    if (!S_ISREG(before.st_mode))   { saved = EINVAL; goto done; }
    // Bounded before a single byte is read, not discovered partway through.
    if (before.st_size < 0 || (long long)before.st_size > PV_MAX_PDF_BYTES) {
        saved = EFBIG;
        goto done;
    }

    // Filling the volume is not Postview's failure to have alone: everything
    // else on the machine is writing to the same disk. Asked once, of the
    // volume the snapshot actually landed on rather than of the path it was
    // requested at.
    //
    // A failure to ASK is now fatal. It used to be ignored, which silently
    // turned the headroom rule off for exactly the filesystems whose statfs is
    // unusual -- so the one guard against filling the boot volume was absent
    // precisely where it was least predictable.
    if (fstatfs(PV_COPY_OUTPUT_FD, &space) != 0) { saved = errno; goto done; }
    {
        long long available = (long long)space.f_bavail *
                              (long long)space.f_bsize;
        if (available < (long long)before.st_size + PV_SNAPSHOT_HEADROOM) {
            saved = ENOSPC;
            goto done;
        }
    }

    for (;;) {
        ssize_t got;
        do { got = read(input, buffer, PV_COPY_CHUNK_BYTES); }
        while (got < 0 && errno == EINTR);
        if (got < 0) { saved = errno; goto done; }
        if (got == 0) break;

        // The bound again, this time against what is actually arriving. fstat
        // reported a size; a file being appended to, or one whose size the
        // filesystem misreports, can still deliver more than that, and the
        // ceiling has to hold against the bytes rather than against the claim.
        copied += (long long)got;
        if (copied > PV_MAX_PDF_BYTES) { saved = EFBIG; goto done; }

        ssize_t offset = 0;
        while (offset < got) {
            ssize_t put;
            do { put = write(PV_COPY_OUTPUT_FD, (char *)buffer + offset,
                             (size_t)(got - offset)); }
            while (put < 0 && errno == EINTR);
            if (put <= 0) { saved = errno ? errno : EIO; goto done; }
            offset += put;
        }
        // No progress report. The snapshot itself is the progress: the
        // supervisor watches it grow, so there is no second channel to keep in
        // step with the first.
    }

    if (fstat(input, &after) != 0) { saved = errno; goto done; }
    // st_ctimespec as well as st_mtimespec: a rename, a permission change or a
    // truncation-and-rewrite that lands on the same mtime still moves ctime,
    // and any of them means the bytes just copied are not one coherent file.
    if (before.st_dev != after.st_dev || before.st_ino != after.st_ino ||
        before.st_size != after.st_size ||
        before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec ||
        before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec ||
        before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec ||
        before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec) {
        saved = EBUSY;
        goto done;
    }
    // What was actually copied, against what was promised. The size comparison
    // above comes from two fstats of the same descriptor; this one is the only
    // check that the copy loop itself moved the whole file.
    if (copied != (long long)after.st_size) { saved = EBUSY; goto done; }

done:
    if (input >= 0) close(input);
    free(buffer);
    // Clamped so the status stays an errno the supervisor can read back. Every
    // Darwin errno is far below this; the clamp is here so that a future one
    // that is not cannot silently become a different error.
    if (saved < 0 || saved > 125) saved = EIO;
    return saved;
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

    // Copying is answered before anything else, and before this process has
    // done anything that could fail. It opens no document, links no Quartz
    // state and stays at ordinary priority: a reader is waiting on it.
    //
    // The watchdog still applies. A copier whose viewer died is a process
    // reading a network volume for nobody, which is precisely the thing that
    // must not be left running.
    if (strcmp(argv[2], PV_HELPER_MODE_COPY) == 0) {
        signal(SIGPIPE, SIG_IGN);
        // Especially here. An orphaned copier is a process reading a network
        // volume on behalf of nobody, which is the exact thing the supervisor
        // kills it for -- and the supervisor is the process that just died.
        if (!PVStartParentWatchdog()) return EAGAIN;
        return PVCopySource(argv[1]);
    }

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

    if (!PVStartParentWatchdog()) return 4;

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
            int sharedFD = -1;
            if (!PVReceiveCommand(STDIN_FILENO, &command, &sharedFD)) break;

            PVRenderReply reply;
            memset(&reply, 0, sizeof(reply));
            reply.magic = PV_RENDER_PROTOCOL_MAGIC;
            reply.version = PV_RENDER_PROTOCOL_VERSION;
            reply.sequence = command.sequence;
            reply.status = EPROTO;

            if (sharedFD >= 0 &&
                command.magic == PV_RENDER_PROTOCOL_MAGIC &&
                command.version == PV_RENDER_PROTOCOL_VERSION &&
                command.width > 0 && command.height > 0 &&
                command.bytesPerRow >= (uint64_t)command.width * 4 &&
                command.height <= SIZE_MAX / command.bytesPerRow &&
                command.page < open.pageCount) {
                size_t bytes = (size_t)command.bytesPerRow * command.height;
                {
                    // The segment has to be at least the size the command says.
                    //
                    // Mapping is not bounds-checked by anything else: a shorter
                    // segment maps successfully and then raises SIGBUS on the
                    // first write past its end, in the middle of Quartz, on
                    // whichever row of the page happens to cross the boundary.
                    // The descriptor comes from another process, so its size is
                    // not something this one gets to assume -- a descriptor is
                    // a safer rendezvous than a name was, but it is not a
                    // promise about length.
                    //
                    // At least, not exactly: the kernel rounds a shared-memory
                    // object up to a whole page, so the creator's ftruncate
                    // length and the length fstat reports here differ for every
                    // bitmap whose byte count is not page-aligned -- which is
                    // nearly all of them, and by a different amount on a 4 KB
                    // page than on a 16 KB one. Demanding equality rejected
                    // every render on both.
                    struct stat info;
                    BOOL sized = (fstat(sharedFD, &info) == 0 &&
                                  info.st_size >= 0 &&
                                  (uint64_t)info.st_size >= (uint64_t)bytes);
                    void *map = sized ? mmap(NULL, bytes, PROT_READ | PROT_WRITE,
                                             MAP_SHARED, sharedFD, 0)
                                      : MAP_FAILED;
                    int mapErrno = errno;
                    // Nothing to unlink. The viewer dropped the name before it
                    // ever sent this descriptor, so the object already lives
                    // only as long as the mappings and descriptors that refer
                    // to it -- which is what makes every crash path clean.
                    if (map != MAP_FAILED) {
                        // Raised only for the duration of this one page, and
                        // only when the viewer asked. See PVRenderPriority*.
                        BOOL raised = PVAdoptCommandPriority(command.priority);
                        alarm(PVRenderAlarmSeconds(command.width,
                                                   command.height));
                        PVRenderCoreResult result = PVRenderPDFPageToBuffer(document,
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
                            close(sharedFD);
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
                        // Each cause keeps its own errno across the pipe. The
                        // viewer's whole retry policy turns on the difference,
                        // and collapsing them here is what made a page that
                        // lost one allocation indistinguishable from a page
                        // Quartz will never draw.
                        switch (result) {
                            case PVRenderCoreOK:
                                reply.status = 0;      break;
                            case PVRenderCoreInvalidPage:
                                reply.status = EINVAL; break;
                            case PVRenderCoreTransientResource:
                                reply.status = ENOMEM; break;
                            case PVRenderCoreDrawFailure:
                            default:
                                reply.status = EILSEQ; break;
                        }
                    } else {
                        // A segment shorter than the command described is the
                        // two ends disagreeing about a structure they both
                        // computed -- a protocol fault, not a bad page. As
                        // EINVAL it retired the page permanently, blaming the
                        // document for the viewer's own arithmetic.
                        reply.status = sized ? mapErrno : EPROTO;
                    }
                }
            }

            // The helper's copy is finished with either way. The viewer closed
            // its own the moment it sent this, so once the mapping above is
            // gone the object is too.
            if (sharedFD >= 0) close(sharedFD);

            if (!PVWriteExact(STDOUT_FILENO, &reply, sizeof(reply))) break;
        }
    }
    CGPDFDocumentRelease(document);
    return 0;
}
