//  pvsuite.m — every automated check Postview has, in one program.
//
//  This used to be five executables built from five files: pvtest (unit),
//  pvuitest (a real controller, driven), pvsoak (long uptime), pvstress
//  (contention, under sanitizers) and pvband (the banding cost probe). They
//  shared four copies of the same OK()/Pump() harness, three copies of the
//  process-inspection code, and no way at all to compare a number one of them
//  measured against a number another one did.
//
//  One binary, one subcommand per suite:
//
//    pvsuite unit   <pdf> [rotation.pdf] [real.pdf]   make test
//    pvsuite ui     <pdf> <outdir>                    make uitest
//    pvsuite soak   <pdf> [cycles]                    make soak / make leakcheck
//    pvsuite stress <pdf> [scale]                     make stress
//    pvsuite band   <pdf> [pages] [reps]              make band
//    pvsuite power  <pdf> [idle-seconds]              make power
//    pvsuite all    <pdf> <outdir> [rotation.pdf]     unit, ui, soak and power
//
//  Each suite's arguments are unchanged from the executable it replaces: the
//  dispatcher hands argv on with the subcommand in argv[0], so every Run*
//  function below sees exactly the argv its main() used to see.
//
//  `power` is new, and is the reason the merge was worth doing. Postview's
//  entire design argument is about energy -- ENGINEERING.md section 1 -- and
//  until now nothing measured any. The suite could report 345 passing
//  assertions about a build that had quietly doubled its CPU cost, because no
//  assertion anywhere was about cost. See "The energy and CPU suite" below.

#import "PVCommon.h"
#import "PVAppDelegate.h"
#import "PVPDFSource.h"
#import "PVImageCache.h"
#import "PVRenderQueue.h"
#import "PVCostModel.h"
#import "PVPageView.h"
#import "PVStateStore.h"
#import "PVWindowController.h"
#import "PVWelcomeWindowController.h"
#import "PVDropView.h"

#import <objc/runtime.h>
#import <mach/mach.h>
#import <mach/mach_time.h>

#include <dlfcn.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <libproc.h>

// <dispatch/block.h> and <sys/qos.h> arrived in 10.10. On a real 10.9 SDK they
// are not there to include, so the tests that pin the express lane's hardcoded
// constants against the SDK's own cannot be compiled -- and requiring them
// would mean this suite could not be built on the machine it is meant to
// qualify. Where the SDK has them the constants are pinned; where it does not,
// what is checked instead is that the lane degrades to its documented fallback.
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 101000
#include <dispatch/block.h>
#include <sys/qos.h>
#define PV_TEST_HAS_QOS_SDK 1
#else
#define PV_TEST_HAS_QOS_SDK 0
#endif

// Whether this machine can report the QoS a block ran at. qos_class_self() is
// 10.10+; on 10.9 there is nothing to observe and no promotion to observe it
// on, which is a supported configuration rather than a failure.
static BOOL QoSObservable(void)
{
    static BOOL resolved, answer;
    if (!resolved) {
        answer = (dlsym(RTLD_DEFAULT, "qos_class_self") != NULL);
        resolved = YES;
    }
    return answer;
}

// The rasterisation census, on for the whole binary.
//
// PVStatsEnabled() resolves POSTVIEW_STATS once through dispatch_once, so it
// has to be set before anything at all touches it -- which means before main()
// runs rather than at the top of main(). A constructor is the only place early
// enough that is still inside this file.
//
// It used to be the UI suite's alone. Now every suite sees it, and that is the
// point rather than a side effect: `power` reads the same counters the UI suite
// asserts on, so "how many full renders did that scroll ask for" and "what did
// they cost in CPU" are finally two columns of one measurement instead of two
// programs' separate opinions. Turning the census on only adds counting -- no
// decision anywhere reads a counter, and PVStatAdd takes a mutex, so the
// ThreadSanitizer gate is measuring the same code either way.
__attribute__((constructor)) static void PVEnableStatsForTests(void)
{
    setenv("POSTVIEW_STATS", "1", 1);
}

#pragma mark - Shared harness

// One pass/fail tally for the whole program. `all` runs several suites into it
// and prints one total, which is what makes the composite exit status mean
// something.
static int gPass = 0, gFail = 0;

static void OK(int cond, const char *what)
{
    if (cond) { gPass++; printf("  ok    %s\n", what); }
    else      { gFail++; printf("  FAIL  %s\n", what); }
}

static void Pump(double seconds)
{
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

// Pump until the condition holds, or the deadline passes. Rendering runs at
// background QoS by design, so a fixed sleep has to be sized for the slowest
// plausible machine and then costs that long on every machine. Waiting on the
// condition takes as long as this machine actually needs, and a genuine
// regression still fails -- just at the deadline rather than at once.
static BOOL PumpUntil(BOOL (^cond)(void), double deadline)
{
    double waited = 0;
    while (waited < deadline) {
        if (cond()) return YES;
        @autoreleasepool { Pump(0.05); }
        waited += 0.05;
    }
    return cond();
}

static double NowMs(void) { return [NSDate timeIntervalSinceReferenceDate] * 1000.0; }

#pragma mark - Process inspection

// Physical footprint, or resident size where the kernel cannot report it.
//
// task_vm_info_data_t gained phys_footprint in the REV1 revision, which
// Mavericks' <mach/task_info.h> does not have -- the field simply is not in the
// struct there, so naming it is a compile error rather than a runtime fallback.
// The revision is therefore tested for at compile time, and the count is checked
// at run time as well: an older kernel can answer a TASK_VM_INFO request with a
// short struct, and reading phys_footprint out of it would be reading past what
// was filled in.
static double FootprintMB(void)
{
#if defined(TASK_VM_INFO_REV1_COUNT)
    task_vm_info_data_t info;
    mach_msg_type_number_t vmCount = TASK_VM_INFO_REV1_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO,
                  (task_info_t)&info, &vmCount) == KERN_SUCCESS &&
        vmCount >= TASK_VM_INFO_REV1_COUNT)
        return (double)info.phys_footprint / (1024.0 * 1024.0);
#endif

    mach_task_basic_info_data_t basic;
    mach_msg_type_number_t basicCount = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  (task_info_t)&basic, &basicCount) == KERN_SUCCESS)
        return (double)basic.resident_size / (1024.0 * 1024.0);
    return 0;
}

// Every direct child of this process, listed. One sysctl, so a caller that
// wants both the count and each child's statistics pays for the enumeration
// once -- the render helper is spawned and retired repeatedly during a long
// session, and the energy suite samples this on every render.
//
// sysctl(KERN_PROC_ALL) and proc_pidinfo, not task_for_pid: reading another
// task's port needs privileges this test does not have and should not need,
// while both of these work unprivileged on a process of the same user, and both
// have been present since well before 10.9.
static int ChildPids(pid_t *out, int max)
{
    int mib[3];
    mib[0] = CTL_KERN; mib[1] = KERN_PROC; mib[2] = KERN_PROC_ALL;

    size_t length = 0;
    if (sysctl(mib, 3, NULL, &length, NULL, 0) != 0 || length == 0) return 0;
    // Processes can appear between the sizing call and the fetch, so ask for
    // more room than was quoted rather than failing the whole measurement over
    // a helper that started in between.
    length += length / 8 + 4096;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(length);
    if (!procs) return 0;
    if (sysctl(mib, 3, procs, &length, NULL, 0) != 0) { free(procs); return 0; }

    pid_t self = getpid();
    int found = 0;
    size_t i, n = length / sizeof(struct kinfo_proc);
    for (i = 0; i < n && found < max; i++)
        if (procs[i].kp_eproc.e_ppid == self)
            out[found++] = procs[i].kp_proc.p_pid;
    free(procs);
    return found;
}

// Resident bytes in every direct child of this process, summed.
//
// The gate above measures mach_task_self() and nothing else, which was true of
// the whole program right up until rasterisation moved into a helper process.
// After that the largest single consumer in the system was invisible to it:
// measured at 183-242 MB of helper RSS against 34-40 MB in the parent, with the
// soak reporting a clean, flat 40 MB the entire time. A steady state that
// excludes most of the memory is not a steady state.
static double HelperResidentMB(void)
{
    pid_t kids[64];
    int i, n = ChildPids(kids, 64);
    unsigned long long total = 0;
    for (i = 0; i < n; i++) {
        struct proc_taskinfo info;
        int got = proc_pidinfo(kids[i], PROC_PIDTASKINFO, 0, &info, sizeof(info));
        // A helper that exited between the listing and this call reports
        // nothing, which is the correct contribution for a process that is gone.
        if (got == (int)sizeof(info)) total += info.pti_resident_size;
    }
    return (double)total / (1024.0 * 1024.0);
}

// The pid of a direct child, or 0. Used only to notice that the helper serving
// renders has CHANGED, which is what recycling looks like from outside.
static pid_t FirstChildPid(void)
{
    pid_t kids[1];
    return ChildPids(kids, 1) ? kids[0] : 0;
}

// Direct children that are still RUNNING, as opposed to exited and not yet
// reaped.
//
// The difference matters to exactly one question -- "did this program leave a
// rasteriser behind?" -- and it is the whole question there. A zombie is a
// process-table entry and nothing else: it holds no memory, burns no CPU and
// wakes nothing. PVReapEventually deliberately does not block on a child that
// will not die promptly, so a zombie outliving the source that killed it is the
// designed behaviour and not a leak. A child in any other state is a helper
// that is still alive, which on a portable is the most expensive bug this
// program could have.
static int LiveChildren(pid_t *out, int max)
{
    int mib[3];
    mib[0] = CTL_KERN; mib[1] = KERN_PROC; mib[2] = KERN_PROC_ALL;

    size_t length = 0;
    if (sysctl(mib, 3, NULL, &length, NULL, 0) != 0 || length == 0) return 0;
    length += length / 8 + 4096;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(length);
    if (!procs) return 0;
    if (sysctl(mib, 3, procs, &length, NULL, 0) != 0) { free(procs); return 0; }

    pid_t self = getpid();
    int found = 0;
    size_t i, n = length / sizeof(struct kinfo_proc);
    for (i = 0; i < n && found < max; i++) {
        if (procs[i].kp_eproc.e_ppid != self) continue;
        if (procs[i].kp_proc.p_stat == SZOMB) continue;
        out[found++] = procs[i].kp_proc.p_pid;
    }
    free(procs);
    return found;
}

static int CmpDouble(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x < y) ? -1 : (x > y) ? 1 : 0;
}

// Median of samples[lo..hi), computed on a copy so the caller's order survives.
static double Median(const double *v, int lo, int hi)
{
    int n = hi - lo;
    if (n <= 0) return 0;
    double *tmp = (double *)malloc((size_t)n * sizeof(double));
    if (!tmp) return 0;
    memcpy(tmp, v + lo, (size_t)n * sizeof(double));
    qsort(tmp, (size_t)n, sizeof(double), CmpDouble);
    double m = (n % 2) ? tmp[n / 2] : (tmp[n / 2 - 1] + tmp[n / 2]) / 2.0;
    free(tmp);
    return m;
}

#pragma mark - Energy and CPU instrumentation

// What "battery usage" can honestly be measured as, on the machines this ships
// to, and what it cannot.
//
// The target is a 2013 Mac Pro. It has no battery, so the direct measurement --
// watts out of a cell -- is unavailable there, and any suite that only knew how
// to do that would report nothing on the machine that decides. The development
// hosts are portables, where it IS available and is the ground truth.
//
// So three instruments, in decreasing order of directness, and every number
// below says which one it came from:
//
//   1. THE BATTERY. AppleSmartBattery publishes instantaneous amperage and
//      voltage in the IO registry, so power in watts is a multiplication and
//      energy over an interval is that integrated. This is the real quantity
//      and it exists only on a portable that is discharging.
//
//   2. CPU TIME, from getrusage() for this process and proc_pid_rusage() for
//      the render helpers. On any machine with a fixed operating point this is
//      very nearly proportional to energy, which is what makes it the metric
//      ENGINEERING.md's showdown compares against Preview. It is not
//      proportional across machines, or across power states on one machine,
//      which is why nothing here compares seconds measured on this host with
//      seconds measured on another.
//
//   3. WAKEUPS, from TASK_POWER_INFO. The part CPU time cannot see. A process
//      that wakes the CPU out of an idle state pays the transition whether or
//      not it then does any work, and a viewer displaying a static page should
//      be waking it a handful of times a second at most. Activity Monitor's
//      "Energy Impact" is a weighted sum of exactly these two families;
//      the weights are Apple's and undocumented, so this suite does not
//      pretend to reproduce them -- it reports the components and asserts on
//      them separately.
//
// Everything is sampled as a pair of snapshots with the workload between them,
// and reported as the difference. The absolute values are meaningless (they
// include the suite's own start-up); the differences are the measurement.

typedef struct {
    double   wall;              // PVMonotonicSeconds
    double   selfUser, selfSys; // this process, seconds
    double   childCPU;          // every helper, live and reaped, seconds
    uint64_t interruptWakeups;  // TASK_POWER_INFO, this process
    uint64_t idleWakeups;       // ...platform idle wakeups: the energy term
    uint64_t timerWakeups;      // ...both timer bins, summed
    uint64_t voluntarySwitches, involuntarySwitches;
    uint64_t childIdleWakeups;  // helpers, live and reaped
    double   footprintMB;       // this process
    double   helperMB;          // every helper, summed
    double   batteryCharge;     // mAh remaining, or -1 where there is no battery
    double   batteryWatts;      // instantaneous draw, or -1
    int      batteryExternal;   // 1 on mains, 0 on the cell, -1 where unknown
    double   renderSeconds;     // Postview's own view of the same interval
    double   renderMegapixels;
    double   fullRenders, previewRenders;
} PVResources;

// rusage_info's times, in seconds.
//
// Helper CPU -- which on this program is most of the CPU there is -- can only
// be read with proc_pid_rusage, and the times it returns are in the kernel's
// absolute-time unit. That unit is the nanosecond on an Intel Mac and 125/3 of
// one on Apple silicon, so getting it wrong is a factor of 41.67 on the single
// quantity this whole suite exists to measure, and it would be a silent factor:
// every number would still look like seconds.
//
// The obvious fix is mach_timebase_info(), and the obvious fix is wrong here.
// This binary is x86_64 -- it has to be, it is the shipping architecture -- so
// on an Apple silicon development host it runs under Rosetta, and Rosetta
// reports the timebase it EMULATES: 1/1, the Intel one. The kernel's rusage
// numbers are not translated and stay in the host's real units. Asking the
// timebase therefore gives the answer 1 on precisely the machine where the
// answer is 41.67, and a scheme that picks between "nanoseconds" and "what the
// timebase says" has two identical candidates to choose from. That is not a
// hypothetical: it under-reported the render helper by 41.67x. Over eight page
// renders the suite printed 0.121 s of helper CPU while `ps` showed that same
// helper had accumulated 7.5 s, and every energy figure downstream of it --
// the viewer/helper split, the cost per megapixel, the comparison against
// Postview's own census -- was wrong by that factor without ever looking it.
//
// So nothing is assumed and nothing is chosen. The ratio is measured directly,
// once, against getrusage(RUSAGE_SELF) -- microseconds by definition, and a
// description of this same process at the same instant. Fifty milliseconds of
// CPU are burned first if the process has not spent that much yet, so that the
// skew between the two calls is a rounding error against the quantity being
// divided.
static double RusageSeconds(uint64_t raw)
{
    static double scale = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        scale = 1.0e-9;   // the answer everywhere the measurement cannot be made

        struct rusage ru;
        struct rusage_info_v2 ri;
        double truth = 0;

        volatile double sink = 0;
        int spins = 0;
        while (spins++ < 2000) {
            if (getrusage(RUSAGE_SELF, &ru) != 0) return;
            truth = (double)ru.ru_utime.tv_sec + (double)ru.ru_utime.tv_usec / 1.0e6 +
                    (double)ru.ru_stime.tv_sec + (double)ru.ru_stime.tv_usec / 1.0e6;
            if (truth >= 0.050) break;
            int k;
            for (k = 0; k < 200000; k++) sink += (double)k * 0.5;
        }
        (void)sink;
        if (truth < 0.050) return;

        if (proc_pid_rusage(getpid(), RUSAGE_INFO_V2, (rusage_info_t *)&ri) != 0) return;
        double sample = (double)(ri.ri_user_time + ri.ri_system_time);
        if (sample <= 0) return;

        // Sanity bounds rather than a fit to the two units that exist today:
        // anything from a tenth of a nanosecond to a microsecond per count is
        // accepted, and anything outside that is a reading this code does not
        // understand, where the documented default is safer than a number
        // derived from it.
        double measured = truth / sample;
        if (measured > 1.0e-10 && measured < 1.0e-6) scale = measured;
    });
    return (double)raw * scale;
}

// CPU seconds spent by render helpers: the ones still running, plus every one
// that has already been reaped.
//
// Both halves are needed and neither alone is right. RUSAGE_CHILDREN counts
// only children that have been waited for, so a helper that is mid-render at
// the sample contributes nothing to it; proc_pid_rusage sees that helper but
// loses it the instant it exits. Summing them makes the total monotonic across
// a retirement: a helper with 1.0 s live at the first sample and 3.0 s reaped
// at the second contributes -1.0 to the live term and +3.0 to the reaped one,
// and the difference of the sum is the 2.0 s it actually spent.
static double ChildCPUSeconds(uint64_t *outIdleWakeups)
{
    double total = 0;
    uint64_t wakeups = 0;

    struct rusage ru;
    if (getrusage(RUSAGE_CHILDREN, &ru) == 0)
        total += (double)ru.ru_utime.tv_sec + (double)ru.ru_utime.tv_usec / 1.0e6 +
                 (double)ru.ru_stime.tv_sec + (double)ru.ru_stime.tv_usec / 1.0e6;

    // The reaped children's wakeups, from this process's own rusage_info: the
    // ri_child_* fields accumulate exactly the same way ru_*_CHILDREN does.
    struct rusage_info_v2 self;
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V2, (rusage_info_t *)&self) == 0)
        wakeups += self.ri_child_pkg_idle_wkups;

    pid_t kids[64];
    int i, n = ChildPids(kids, 64);
    for (i = 0; i < n; i++) {
        struct rusage_info_v2 ri;
        if (proc_pid_rusage(kids[i], RUSAGE_INFO_V2, (rusage_info_t *)&ri) != 0) continue;
        total   += RusageSeconds(ri.ri_user_time + ri.ri_system_time);
        wakeups += ri.ri_pkg_idle_wkups;
    }

    if (outIdleWakeups) *outIdleWakeups = wakeups;
    return total;
}

// IOKit, resolved at runtime rather than linked.
//
// The same reasoning PVCommon.m gives for the power-source lookup, and the same
// four-line idiom: reading the battery is not worth an LC_LOAD_DYLIB on a test
// binary that `make package` ships to the Mavericks machine alongside the app.
// The IO registry is also the only place instantaneous amperage appears -- the
// IOPS power-source dictionaries report capacity as a whole-number percentage,
// which over a ten-second workload is either 0% or 1% and therefore not a
// measurement of anything.
typedef CFMutableDictionaryRef (*PVIOServiceMatchingFn)(const char *);
typedef mach_port_t (*PVIOServiceGetMatchingServiceFn)(mach_port_t, CFDictionaryRef);
typedef kern_return_t (*PVIORegistryPropertiesFn)(mach_port_t, CFMutableDictionaryRef *,
                                                  CFAllocatorRef, uint32_t);
typedef kern_return_t (*PVIOObjectReleaseFn)(mach_port_t);

static double NumberForKey(CFDictionaryRef d, CFStringRef key, double fallback)
{
    CFTypeRef v = d ? CFDictionaryGetValue(d, key) : NULL;
    if (!v) return fallback;
    if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        double out = 0;
        if (CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, &out)) return out;
    }
    if (CFGetTypeID(v) == CFBooleanGetTypeID())
        return CFBooleanGetValue((CFBooleanRef)v) ? 1 : 0;
    return fallback;
}

// Charge in mAh and instantaneous draw in watts, or -1 for each where the
// machine cannot say. A desktop takes the -1 path on every call, which is the
// correct answer and not a failure: see the note above PVResources.
static void ReadBattery(double *outCharge, double *outWatts, int *outExternal)
{
    if (outCharge)   *outCharge   = -1;
    if (outWatts)    *outWatts    = -1;
    if (outExternal) *outExternal = -1;

    static PVIOServiceMatchingFn           matching;
    static PVIOServiceGetMatchingServiceFn getService;
    static PVIORegistryPropertiesFn        properties;
    static PVIOObjectReleaseFn             releaseObject;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (!h) return;
        matching      = (PVIOServiceMatchingFn)dlsym(h, "IOServiceMatching");
        getService    = (PVIOServiceGetMatchingServiceFn)dlsym(h, "IOServiceGetMatchingService");
        properties    = (PVIORegistryPropertiesFn)dlsym(h, "IORegistryEntryCreateCFProperties");
        releaseObject = (PVIOObjectReleaseFn)dlsym(h, "IOObjectRelease");
    });
    if (!matching || !getService || !properties || !releaseObject) return;

    CFMutableDictionaryRef match = matching("AppleSmartBattery");
    if (!match) return;
    // MACH_PORT_NULL for the master port: IOKit reads that as the default one,
    // which spares this from having to dlsym a global variable whose type it
    // would then have to assume.
    mach_port_t service = getService(MACH_PORT_NULL, match);   // consumes `match`
    if (!service) return;

    CFMutableDictionaryRef props = NULL;
    if (properties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
        // AppleRawCurrentCapacity is in mAh and moves continuously;
        // CurrentCapacity on newer systems is a percentage. Prefer the raw one
        // and fall back only if it is absent.
        double mAh = NumberForKey(props, CFSTR("AppleRawCurrentCapacity"), -1);
        if (mAh < 0) mAh = NumberForKey(props, CFSTR("CurrentCapacity"), -1);

        double mV = NumberForKey(props, CFSTR("Voltage"), -1);
        double mA = NumberForKey(props, CFSTR("InstantAmperage"),
                     NumberForKey(props, CFSTR("Amperage"), 0));
        double external = NumberForKey(props, CFSTR("ExternalConnected"), -1);

        if (outCharge) *outCharge = mAh;
        // Amperage is signed and negative while discharging. The magnitude is
        // the draw either way; whether it is coming out of the cell or going
        // into it is what ExternalConnected says.
        if (outWatts && mV > 0) *outWatts = (mV / 1000.0) * (fabs(mA) / 1000.0);
        if (outExternal) *outExternal = (int)external;
        CFRelease(props);
    }
    releaseObject(service);
}

static void SampleResources(PVResources *r)
{
    memset(r, 0, sizeof *r);
    r->wall = PVMonotonicSeconds();

    struct rusage ru;
    if (getrusage(RUSAGE_SELF, &ru) == 0) {
        r->selfUser = (double)ru.ru_utime.tv_sec + (double)ru.ru_utime.tv_usec / 1.0e6;
        r->selfSys  = (double)ru.ru_stime.tv_sec + (double)ru.ru_stime.tv_usec / 1.0e6;
        r->voluntarySwitches   = (uint64_t)ru.ru_nvcsw;
        r->involuntarySwitches = (uint64_t)ru.ru_nivcsw;
    }

    task_power_info_data_t power;
    mach_msg_type_number_t count = TASK_POWER_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_POWER_INFO,
                  (task_info_t)&power, &count) == KERN_SUCCESS) {
        r->interruptWakeups = power.task_interrupt_wakeups;
        r->idleWakeups      = power.task_platform_idle_wakeups;
        r->timerWakeups     = power.task_timer_wakeups_bin_1 +
                              power.task_timer_wakeups_bin_2;
    }

    r->childCPU    = ChildCPUSeconds(&r->childIdleWakeups);
    r->footprintMB = FootprintMB();
    r->helperMB    = HelperResidentMB();
    ReadBattery(&r->batteryCharge, &r->batteryWatts, &r->batteryExternal);

    // Postview's own account of the same interval, so a cost in CPU can be
    // divided by the work that was actually asked for rather than by wall time.
    r->renderSeconds    = PVStatValue(PVStatRenderSecondsFull) +
                          PVStatValue(PVStatRenderSecondsPreview);
    r->renderMegapixels = PVStatValue(PVStatPixelsFull) +
                          PVStatValue(PVStatPixelsPreview);
    r->fullRenders      = PVStatValue(PVStatRendersFull);
    r->previewRenders   = PVStatValue(PVStatRendersPreview);
}

// Total CPU across this process and every helper it has used. The single
// number the energy comparisons are made on: rasterisation is out of process,
// so a figure that counted only this task would report a viewer that had moved
// all its work next door as having become free.
static double TotalCPU(const PVResources *a, const PVResources *b)
{
    return (b->selfUser - a->selfUser) + (b->selfSys - a->selfSys) +
           (b->childCPU - a->childCPU);
}

static void ReportInterval(const char *label, const PVResources *a, const PVResources *b)
{
    double wall  = b->wall - a->wall;
    double self  = (b->selfUser - a->selfUser) + (b->selfSys - a->selfSys);
    double child = b->childCPU - a->childCPU;
    double total = self + child;
    double mpx   = b->renderMegapixels - a->renderMegapixels;

    printf("  %-26s %7.3f s wall\n", label, wall);
    printf("    CPU   viewer %6.3f s   helpers %6.3f s   total %6.3f s "
           "(%.1f%% of one core)\n",
           self, child, total, wall > 0 ? 100.0 * total / wall : 0.0);
    printf("    wake  idle %6llu   timer %6llu   interrupt %6llu   "
           "helper idle %6llu\n",
           (unsigned long long)(b->idleWakeups - a->idleWakeups),
           (unsigned long long)(b->timerWakeups - a->timerWakeups),
           (unsigned long long)(b->interruptWakeups - a->interruptWakeups),
           (unsigned long long)(b->childIdleWakeups - a->childIdleWakeups));
    printf("    work  %.0f full + %.0f preview renders, %.2f Mpx",
           b->fullRenders - a->fullRenders,
           b->previewRenders - a->previewRenders, mpx);
    if (mpx > 0.001) printf("   = %.1f ms CPU per Mpx", 1000.0 * total / mpx);
    printf("\n");

    if (a->batteryCharge >= 0 && b->batteryCharge >= 0) {
        double drained = a->batteryCharge - b->batteryCharge;
        printf("    power %.0f mAh -> %.0f mAh (%+.0f mAh)   draw now %.2f W\n",
               a->batteryCharge, b->batteryCharge, -drained,
               b->batteryWatts >= 0 ? b->batteryWatts : 0.0);
    }
}

#pragma mark ======================= unit =======================

#pragma mark - Render queue collector

@interface Collector : NSObject <PVRenderQueueDelegate> {
@public
    NSMutableArray *pages;
    NSMutableArray *failed;
    BOOL onMainThread;
    BOOL quiet;            // suppress the per-image assertion in bulk tests
}
@end
@implementation Collector
- (id)init
{
    self = [super init];
    if (self) {
        pages  = [[NSMutableArray alloc] init];
        failed = [[NSMutableArray alloc] init];
        onMainThread = YES;
    }
    return self;
}
- (void)dealloc { [pages release]; [failed release]; [super dealloc]; }
- (void)renderQueue:(PVRenderQueue *)q didRenderPage:(NSUInteger)page image:(CGImageRef)img
          pixelSize:(CGSize)px preview:(BOOL)preview
{
    if (![NSThread isMainThread]) onMainThread = NO;
    if (!quiet) OK(img != NULL, "render queue delivered a non-NULL image");
    [pages addObject:[NSNumber numberWithUnsignedLongLong:page]];
}
- (void)renderQueue:(PVRenderQueue *)q didFailPage:(NSUInteger)page
          pixelSize:(CGSize)px preview:(BOOL)preview
{
    if (![NSThread isMainThread]) onMainThread = NO;
    [failed addObject:[NSNumber numberWithUnsignedLongLong:page]];
}
@end

#pragma mark - Tests

// Returns the fraction of the bitmap's width and height actually covered by
// non-white pixels. Catches a page that renders correct-sized but with the
// content shrunk into the middle -- which is exactly what
// CGPDFPageGetDrawingTransform does if you let it scale a page up.
static void InkCoverage(CGImageRef img, double *outW, double *outH)
{
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    size_t stride = w * 4;
    unsigned char *buf = (unsigned char *)calloc(h, stride);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(buf, w, h, 8, stride, cs,
        (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(cs);
    CGContextDrawImage(c, CGRectMake(0, 0, w, h), img);

    size_t minX = w, maxX = 0, minY = h, maxY = 0;
    BOOL any = NO;
    for (size_t y = 0; y < h; y++) {
        for (size_t x = 0; x < w; x++) {
            unsigned char *p = buf + y * stride + x * 4;
            // bytes are B,G,R,<skipped alpha>; index 3 is padding, not colour
            if (p[0] < 235 || p[1] < 235 || p[2] < 235) {
                any = YES;
                if (x < minX) minX = x;  if (x > maxX) maxX = x;
                if (y < minY) minY = y;  if (y > maxY) maxY = y;
            }
        }
    }
    *outW = any ? (double)(maxX - minX + 1) / (double)w : 0.0;
    *outH = any ? (double)(maxY - minY + 1) / (double)h : 0.0;
    CGContextRelease(c);
    free(buf);
}

// Many renders from ONE source, which is what a reading session is.
//
// The helper protocol names a POSIX shared-memory segment per render, and
// shm_open refuses any name longer than 31 characters including the slash --
// PSHMNAMLEN, not PATH_MAX, and nothing in the API hints at it. The first
// scheme embedded the source pointer and a per-source counter and so grew by a
// character every power of ten: it fitted for 99 renders and then failed for
// every render afterwards, permanently, leaving blank pages behind.
//
// 250 is chosen to be past that cliff. Everything before it passed; the point
// of the number is what comes after 99.
static void TestSourceManyRenders(PVPDFSource *src)
{
    printf("\n[PVPDFSource: a long session's worth of renders from one source]\n");
    NSUInteger produced = 0, i;
    for (i = 0; i < 250; i++) {
        @autoreleasepool {
            CGImageRef im = [src createImageForPage:(i % [src pageCount])
                                          pixelSize:CGSizeMake(80, 104)];
            if (im) { produced++; CGImageRelease(im); }
        }
    }
    printf("  %lu of 250 renders produced a bitmap\n", (unsigned long)produced);
    OK(produced == 250,
       "render 100 and everything after it still succeeds (shm name stays legal)");
}

static void TestSource(PVPDFSource *src)
{
    printf("\n[PVPDFSource]\n");
    OK([src pageCount] == 60, "page count is 60");
    CGSize s = [src pointSizeOfPage:0];
    OK(fabs(s.width - 612) < 1 && fabs(s.height - 792) < 1, "page 0 is US Letter");
    OK(fabs([src maxPointSize].width - 612) < 1, "max page width is 612");
    CGSize oob = [src pointSizeOfPage:9999];
    OK(oob.width > 0 && oob.height > 0, "out-of-range page returns a safe fallback size");

    CGImageRef img = [src createImageForPage:0 pixelSize:CGSizeMake(612, 792)];
    OK(img != NULL, "rendered page 0");
    OK(img && CGImageGetWidth(img) == 612 && CGImageGetHeight(img) == 792, "bitmap has exact requested size");
    if (img) CGImageRelease(img);

    // Content must FILL the bitmap at every scale, including well above the
    // page's natural size (the fit-width / Retina case).
    double cw = 0, ch = 0;
    struct { const char *name; CGSize px; } scales[] = {
        { "natural size 612x792",   { 612,  792  } },
        { "2x upscale 1224x1584",   { 1224, 1584 } },
        { "fit-width-ish 1600x2071",{ 1600, 2071 } },
        { "preview 204x264",        { 204,  264  } },
    };
    for (unsigned i = 0; i < sizeof(scales)/sizeof(scales[0]); i++) {
        CGImageRef im = [src createImageForPage:0 pixelSize:scales[i].px];
        if (!im) { OK(NO, scales[i].name); continue; }
        InkCoverage(im, &cw, &ch);
        char msg[160];
        snprintf(msg, sizeof msg, "content fills the bitmap at %s (ink %.0f%% x %.0f%%)",
                 scales[i].name, cw * 100, ch * 100);
        OK(cw > 0.85 && ch > 0.85, msg);
        CGImageRelease(im);
    }

    OK([src createImageForPage:9999 pixelSize:CGSizeMake(10, 10)] == NULL, "out-of-range page renders NULL");

    // 40000x40000 would be 6.4 GB. The guard used to return NULL, which kept
    // the allocation safe but left the page permanently blank AND had the
    // render queue re-request it on every scroll event, since nothing ever
    // reached the cache to stop asking. It now scales the request down to the
    // ceiling instead: still bounded, but it produces a usable page.
    CGImageRef huge = [src createImageForPage:0 pixelSize:CGSizeMake(40000, 40000)];
    OK(huge != NULL, "absurd pixel size is scaled down, not refused");
    if (huge) {
        double px = (double)CGImageGetWidth(huge) * (double)CGImageGetHeight(huge);
        OK(px <= PVMaxRenderPixels() + 1, "scaled-down bitmap respects the pixel ceiling");
        OK(CGImageGetWidth(huge) == CGImageGetHeight(huge),
           "scaling down preserves the requested aspect ratio");
        CGImageRelease(huge);
    }

    // Non-finite geometry cannot be clamped meaningfully and is still refused.
    OK([src createImageForPage:0 pixelSize:CGSizeMake(NAN, 100)] == NULL, "NaN pixel size is refused");
    OK([src createImageForPage:0 pixelSize:CGSizeMake(INFINITY, 100)] == NULL, "infinite pixel size is refused");

    CGImageRef tiny = [src createImageForPage:0 pixelSize:CGSizeMake(0, 0)];
    OK(tiny != NULL, "zero pixel size is clamped, not crashed");
    if (tiny) CGImageRelease(tiny);
}

// The render queue hardcodes two libdispatch constants so it can compile
// against 10.9 headers while still using a 10.10+ entry point through dlsym.
// Getting one wrong is silent -- the express lane simply stops promoting and
// the only symptom is that opening a document feels slower -- so pin them here
// against the real SDK values.
static void TestDispatchConstants(void)
{
    printf("\n[dispatch constants used by the express lane]\n");
#if PV_TEST_HAS_QOS_SDK
    // Reading these enumerators is what the availability guard objects to, but
    // they are compile-time integers: no symbol is bound and nothing executes
    // on 10.9. Suppressed for this comparison only -- the guard stays armed
    // everywhere else, which is exactly what caught the mistake this test now
    // pins down.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
    uintptr_t sdkEnforce  = (uintptr_t)DISPATCH_BLOCK_ENFORCE_QOS_CLASS;
    uintptr_t sdkDetached = (uintptr_t)DISPATCH_BLOCK_DETACHED;
    unsigned  sdkUtility  = (unsigned)QOS_CLASS_UTILITY;
#pragma clang diagnostic pop

    OK(PV_BLOCK_ENFORCE_QOS_CLASS == sdkEnforce,
       "PV_BLOCK_ENFORCE_QOS_CLASS matches DISPATCH_BLOCK_ENFORCE_QOS_CLASS");
    OK(PV_QOS_CLASS_UTILITY == sdkUtility,
       "PV_QOS_CLASS_UTILITY matches QOS_CLASS_UTILITY");
    OK(PV_BLOCK_ENFORCE_QOS_CLASS != sdkDetached,
       "the enforce flag is not confused with DISPATCH_BLOCK_DETACHED");
#else
    printf("  skip  SDK has no <sys/qos.h>; constants cannot be pinned here\n");
#endif

    // The entry point is 10.10+, so on the target itself it is expected to be
    // absent. What must hold on every machine is that the two cases are
    // distinguishable and the queue has a path for each: present means the
    // promotion is available, absent means the ordinary lane is used.
    BOOL haveEntryPoint =
        (dlsym(RTLD_DEFAULT, "dispatch_block_create_with_qos_class") != NULL);
    if (QoSObservable()) {
        OK(haveEntryPoint,
           "dispatch_block_create_with_qos_class resolves where QoS exists");
    } else {
        OK(!haveEntryPoint,
           "no QoS on this OS, and no promotion entry point either");
    }
}

static void TestRenderSpeed(PVPDFSource *src)
{
    printf("\n[render cost — heavy vector pages, 1400 curves + 40 text lines each]\n");
    double t0 = NowMs();
    int n = 8;
    for (int i = 0; i < n; i++) {
        CGImageRef im = [src createImageForPage:i pixelSize:CGSizeMake(850, 1100)];
        if (im) CGImageRelease(im);
    }
    double full = (NowMs() - t0) / n;

    t0 = NowMs();
    for (int i = 0; i < n; i++) {
        CGImageRef im = [src createImageForPage:i pixelSize:CGSizeMake(284, 367)];
        if (im) CGImageRelease(im);
    }
    double prev = (NowMs() - t0) / n;

    printf("  full page @850x1100 : %6.1f ms/page\n", full);
    printf("  preview   @284x367  : %6.1f ms/page  (%.1fx cheaper)\n", prev, full / prev);
    OK(prev < full, "preview pass is cheaper than the full pass");
}

static void TestCache(void)
{
    printf("\n[PVImageCache]\n");
    // 4 MB budget; each 512x512 bitmap is 1 MB.
    PVImageCache *cache = [[PVImageCache alloc] initWithBudget:4 * 1024 * 1024];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();

    CGImageRef imgs[10];
    for (int i = 0; i < 10; i++) {
        CGContextRef c = CGBitmapContextCreate(NULL, 512, 512, 8, 0, cs,
            (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host);
        imgs[i] = CGBitmapContextCreateImage(c);
        CGContextRelease(c);
    }

    for (int i = 0; i < 10; i++)
        [cache setFullImage:imgs[i] pixelSize:CGSizeMake(512, 512) forPage:i];

    OK([cache fullImageForPage:9 pixelSize:CGSizeMake(512, 512)] != NULL,
       "most recently inserted page survives eviction");
    OK([cache fullImageForPage:0 pixelSize:CGSizeMake(512, 512)] == NULL,
       "oldest page was evicted under budget pressure");

    // Wrong-size lookup must miss, but still be usable as a placeholder.
    OK([cache fullImageForPage:9 pixelSize:CGSizeMake(256, 256)] == NULL,
       "exact-size lookup rejects a bitmap rendered at another zoom");
    OK([cache placeholderImageForPage:9] != NULL,
       "wrong-size bitmap is still offered as a placeholder");

    // Previews must outlive full bitmaps.
    PVImageCache *c2 = [[PVImageCache alloc] initWithBudget:3 * 1024 * 1024];
    for (int i = 0; i < 3; i++)
        [c2 setPreviewImage:imgs[i] pixelSize:CGSizeMake(512, 512) forPage:i];
    for (int i = 5; i < 8; i++)
        [c2 setFullImage:imgs[i] pixelSize:CGSizeMake(512, 512) forPage:i];
    int previewsLeft = 0;
    for (int i = 0; i < 3; i++) if ([c2 hasPreviewForPage:i]) previewsLeft++;
    OK(previewsLeft > 0, "previews survive while full bitmaps are evicted first");

    // Record exactly which previews exist, then assert the drop keeps all of
    // them. (Checking one fixed page would be wrong: some previews may already
    // have been evicted by budget pressure above.)
    BOOL before[3];
    for (int i = 0; i < 3; i++) before[i] = [c2 hasPreviewForPage:i];
    [c2 dropFullImages];
    OK([c2 fullImageForPage:7 pixelSize:CGSizeMake(512, 512)] == NULL,
       "memory-pressure drop releases full bitmaps");
    BOOL keptAll = YES;
    for (int i = 0; i < 3; i++) if (before[i] && ![c2 hasPreviewForPage:i]) keptAll = NO;
    OK(keptAll && previewsLeft > 0,
       "memory-pressure drop keeps every preview it had");

    [cache removeAll];
    OK([cache placeholderImageForPage:5] == NULL, "removeAll empties the cache");

    for (int i = 0; i < 10; i++) CGImageRelease(imgs[i]);
    CGColorSpaceRelease(cs);
    [c2 release];
    [cache release];
}

// The cache and the wanted-set have to agree about what must be resident, and
// the only proof that they do is that the loop between them stops.
//
// It did not. With two pages on screen whose full bitmaps did not both fit,
// storing the second evicted the first; the next draw found the first missing;
// the wanted-set asked for it again; storing it evicted the second. Nothing
// ever landed in the cache to break the cycle, so the render queue rasterised
// the same two heavy pages for as long as the window stayed open -- a
// background thread at full tilt on a document nobody is touching, and pages
// visibly flickering between sharp and soft. It began at 200% zoom on a Retina
// 2 GB machine.
//
// This drives the real loop -- ask what is missing, render it, store it -- and
// asserts it reaches a pass that renders nothing. Reverting either half of the
// fix (the pin, or the per-bitmap ceiling) fails it.
// The count cap, exercised where it is the binding constraint rather than the
// byte budget: small bitmaps at a generous budget, which is the case the cap
// exists for. A short document at a small zoom could otherwise hold every one
// of its pages live inside the same bytes.
static void TestCacheFullImageCountCap(void)
{
    printf("\n[PVImageCache: full-bitmap count cap]\n");

    // 64 MB budget against 64x64 bitmaps (16 KB each): hundreds fit by bytes,
    // so anything that limits them here is the count cap and nothing else.
    PVImageCache *cache = [[PVImageCache alloc] initWithBudget:64 * 1024 * 1024];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();

    NSUInteger i;
    for (i = 0; i < 40; i++) {
        CGContextRef c = CGBitmapContextCreate(NULL, 64, 64, 8, 0, cs,
            (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host);
        CGImageRef img = CGBitmapContextCreateImage(c);
        CGContextRelease(c);
        // Nothing pinned: the cap is free to act on every entry.
        [cache setPinnedPages:NSMakeRange(0, 0)];
        [cache setFullImage:img pixelSize:CGSizeMake(64, 64) forPage:i];
        CGImageRelease(img);
    }

    OK([cache byteCount] < 64 * 1024 * 1024,
       "forty small bitmaps never approach the byte budget");
    OK([cache fullImageCount] <= PV_MAX_FULL_IMAGES && [cache fullImageCount] < 40,
       "the count cap holds where the byte budget never would");

    // The cap must evict least-recently-used, so the most recent page stored
    // is still there. Anything else and the cap would be throwing away the
    // page the user is on.
    OK([cache fullImageForPage:39 pixelSize:CGSizeMake(64, 64)] != NULL,
       "the most recently stored bitmap survives the cap");

    // A pinned page is never evicted, cap or no cap: the layer above will ask
    // for it again immediately and evicting it buys nothing.
    [cache removeAll];
    [cache setPinnedPages:NSMakeRange(0, 2)];
    for (i = 0; i < 40; i++) {
        CGContextRef c = CGBitmapContextCreate(NULL, 64, 64, 8, 0, cs,
            (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host);
        CGImageRef img = CGBitmapContextCreateImage(c);
        CGContextRelease(c);
        [cache setFullImage:img pixelSize:CGSizeMake(64, 64) forPage:i];
        CGImageRelease(img);
    }
    OK([cache fullImageForPage:0 pixelSize:CGSizeMake(64, 64)] != NULL &&
       [cache fullImageForPage:1 pixelSize:CGSizeMake(64, 64)] != NULL,
       "pinned pages survive the count cap");

    CGColorSpaceRelease(cs);
    [cache release];
}

static void TestCacheConverges(void)
{
    printf("\n[cache reaches a steady state: no render/evict loop]\n");

    struct { const char *name; size_t budget; size_t w, h; int visible; } cases[] = {
        { "fit width, 2 pages on screen",      32u<<20,  830, 1075, 2 },
        { "retina fit width, 2 pages",         32u<<20, 1660, 2150, 2 },
        { "200% retina, 2 pages",              32u<<20, 2400, 3100, 2 },
        { "400% retina, 2 pages",              32u<<20, 3400, 4400, 2 },
        { "600% retina, 2 pages",              96u<<20, 5000, 6500, 2 },
        { "low zoom, 6 small pages on screen", 32u<<20,  420,  545, 6 },
        { "one enormous page alone",           32u<<20, 6000, 7800, 1 },
    };
    const int nc = (int)(sizeof(cases) / sizeof(cases[0]));
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();

    for (int ci = 0; ci < nc; ci++) {
        PVImageCache *c = [[PVImageCache alloc] initWithBudget:cases[ci].budget];
        // Exactly what -updateVisibleContent does before it asks for anything.
        [c setPinnedPages:NSMakeRange(0, (NSUInteger)cases[ci].visible)];

        // The renderer clamps every request, so the test has to ask for what it
        // would actually be given -- otherwise it measures a bitmap the app can
        // never produce.
        CGSize want = PVClampPixelSize(CGSizeMake((CGFloat)cases[ci].w, (CGFloat)cases[ci].h));
        size_t pw = (size_t)want.width, ph = (size_t)want.height;

        int rendersInLastPass = 0;
        for (int pass = 0; pass < 8; pass++) {
            rendersInLastPass = 0;
            for (int p = 0; p < cases[ci].visible; p++) {
                if ([c fullImageForPage:(NSUInteger)p pixelSize:want]) continue;
                CGContextRef bc = CGBitmapContextCreate(NULL, pw, ph, 8, 0, cs,
                    (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host);
                if (!bc) continue;
                CGImageRef im = CGBitmapContextCreateImage(bc);
                CGContextRelease(bc);
                if (!im) continue;
                [c setFullImage:im pixelSize:want forPage:(NSUInteger)p];
                CGImageRelease(im);
                rendersInLastPass++;
            }
        }
        char msg[160];
        snprintf(msg, sizeof msg, "%s: settles, no page re-rendered forever", cases[ci].name);
        OK(rendersInLastPass == 0, msg);
        [c release];
    }

    // The bound that makes the pin safe to hold: one bitmap can never be more
    // than a third of the budget, so the visible set cannot run away with the
    // cache however far the user zooms in.
    OK(PVMaxRenderPixels() * 4.0 <= (double)PVPageCacheBudget() / 3.0 + 1.0,
       "one bitmap can never exceed a third of the cache budget");
    OK(PVClampPixelSize(CGSizeMake(1e9, 1e9)).width * PVClampPixelSize(CGSizeMake(1e9, 1e9)).height
       <= PVMaxRenderPixels() + 1.0,
       "an absurd request is scaled down to the ceiling, not refused");
    OK(PVClampPixelSize(CGSizeMake(NAN, 100)).width == 0,
       "a non-finite request yields a zero size, which the renderer refuses");
    OK(PVClampPixelSize(CGSizeMake(0.2, 0.2)).width >= 1,
       "a degenerate request is floored at one pixel, not refused");

    CGColorSpaceRelease(cs);
}

static void TestLayout(PVPDFSource *src)
{
    printf("\n[PVPageView layout]\n");
    PVImageCache *cache = [[PVImageCache alloc] initWithBudget:PVPageCacheBudget()];
    PVPageView *v = [[PVPageView alloc] initWithSource:src cache:cache];
    [v setZoom:1.0 backingScale:1.0 containerWidth:900];

    NSUInteger n = [src pageCount];
    BOOL monotonic = YES, noOverlap = YES;
    for (NSUInteger i = 1; i < n; i++) {
        NSRect a = [v rectForPage:i - 1], b = [v rectForPage:i];
        if (NSMinY(b) <= NSMinY(a)) monotonic = NO;
        if (NSMinY(b) < NSMaxY(a))  noOverlap = NO;
    }
    OK(monotonic, "page rects increase down the document");
    OK(noOverlap, "page rects never overlap");
    OK(NSHeight([v frame]) > NSMaxY([v rectForPage:n - 1]), "document view is tall enough for the last page");

    // Exhaustive binary-search check: the search must agree with a linear scan
    // for every page, including the page-0 boundary where an unsigned underflow
    // would be easy to write.
    BOOL searchOK = YES;
    for (NSUInteger i = 0; i < n; i++) {
        NSRect r = [v rectForPage:i];
        NSRange got = [v pageRangeInRect:NSMakeRect(0, NSMinY(r) + 1, 900, 10)];
        if (got.location != i || got.length < 1) searchOK = NO;
    }
    OK(searchOK, "pageRangeInRect finds the right page for all 60 pages");

    NSRange top = [v pageRangeInRect:NSMakeRect(0, 0, 900, 5)];
    OK(top.location == 0, "rect above page 1 resolves to page 0 (no unsigned underflow)");
    NSRange all = [v pageRangeInRect:[v frame]];
    OK(all.location == 0 && all.length == n, "whole-document rect covers every page");
    NSRange past = [v pageRangeInRect:NSMakeRect(0, NSHeight([v frame]) + 500, 900, 50)];
    OK(past.location < n, "rect past the end stays in range");

    // Position round-trip: page + fraction -> scroll offset -> page + fraction.
    BOOL roundTrip = YES;
    for (NSUInteger i = 0; i < n; i += 7) {
        CGFloat frac = 0.37;
        NSRect r = [v rectForPage:i];
        CGFloat y = NSMinY(r) + frac * NSHeight(r);
        CGFloat outFrac = 0;
        NSUInteger back = [v pageAtTopOfRect:NSMakeRect(0, y, 900, 600) fraction:&outFrac];
        if (back != i || fabs(outFrac - frac) > 0.02) roundTrip = NO;
    }
    OK(roundTrip, "page+fraction survives a round trip through scroll coordinates");

    // Pixel alignment: this is what makes the common case a 1:1 blit.
    BOOL aligned = YES;
    [v setZoom:1.37 backingScale:2.0 containerWidth:900];
    for (NSUInteger i = 0; i < n; i += 5) {
        NSRect r = [v rectForPage:i];
        CGSize px = [v pixelSizeForPage:i];
        if (fabs(px.width - r.size.width * 2.0) > 0.001) aligned = NO;
        if (r.size.width != floor(r.size.width))  aligned = NO;
    }
    OK(aligned, "bitmap pixels map exactly onto device pixels at fractional zoom");

    [v setZoom:0.0001 backingScale:1.0 containerWidth:900];
    OK([v zoom] >= PV_MIN_ZOOM, "zoom is clamped at the low end");
    [v setZoom:999 backingScale:1.0 containerWidth:900];
    OK([v zoom] <= PV_MAX_ZOOM, "zoom is clamped at the high end");

    // ---- the two-page spread ------------------------------------------
    //
    // Everything above is asserted again with two pages to a row, because the
    // spread is not a second layout: it is the same one with a different
    // column count, and if the properties the rest of the app relies on hold
    // in one column and not in two then the app is only half written.
    [v setZoom:1.0 backingScale:1.0 containerWidth:900];
    CGFloat singleHeight = NSHeight([v frame]);
    NSRect  singlePage0  = [v rectForPage:0];

    [v setColumns:2];
    OK([v columns] == 2, "the column count is what it was set to");
    // The geometry the view was last laid out for is unchanged in every
    // argument -- same zoom, same scale, same width -- so this call is exactly
    // the one the early-out exists to swallow. It must not swallow this.
    [v setZoom:1.0 backingScale:1.0 containerWidth:900];
    OK(NSHeight([v frame]) < singleHeight,
       "turning the spread on relays out even though zoom, scale and width did not move");

    BOOL paired = YES, gutter = YES, rowsApart = YES, rowStart = YES;
    for (NSUInteger i = 0; i + 1 < n; i += 2) {
        NSRect a = [v rectForPage:i], b = [v rectForPage:i + 1];
        if (fabs(NSMinY(a) - NSMinY(b)) > 0.001) paired = NO;
        if (fabs(NSMinX(b) - (NSMaxX(a) + PV_PAGE_GAP)) > 0.001) gutter = NO;
        if ([v firstPageOfRowContainingPage:i]     != i) rowStart = NO;
        if ([v firstPageOfRowContainingPage:i + 1] != i) rowStart = NO;
        if (i + 2 < n) {
            NSRect next = [v rectForPage:i + 2];
            if (NSMinY(next) < NSMaxY(a) || NSMinY(next) < NSMaxY(b)) rowsApart = NO;
        }
    }
    OK(paired,    "facing pages share a top edge");
    OK(gutter,    "the second page of a row sits one gap to the right of the first");
    OK(rowsApart, "rows never overlap the row above them");
    OK(rowStart,  "both pages of a spread report the same first page of the row");
    OK(NSWidth([v rectForRowContainingPage:1]) >= NSWidth(singlePage0) * 2,
       "a row is as wide as the two pages in it");
    OK(fabs(NSMinY([v rectForRowContainingPage:0]) - NSMinY([v rectForPage:1])) < 0.001 &&
       fabs(NSMinY([v rectForRowContainingPage:1]) - NSMinY([v rectForPage:0])) < 0.001,
       "either page of a spread names the same row");

    // The search, again exhaustively. This is the property the row table
    // exists for: a search over page frames is not guaranteed to find the row
    // it is standing in once two pages share a band.
    BOOL spreadSearch = YES;
    for (NSUInteger i = 0; i < n; i++) {
        NSRect r = [v rectForRowContainingPage:i];
        NSRange got = [v pageRangeInRect:NSMakeRect(0, NSMinY(r) + 1, 900, 10)];
        NSUInteger first = [v firstPageOfRowContainingPage:i];
        NSUInteger want  = (first + 1 < n) ? 2 : 1;
        if (got.location != first || got.length != want) spreadSearch = NO;
    }
    OK(spreadSearch, "a thin rect inside a row resolves to both pages of that row");

    NSRange spreadAll = [v pageRangeInRect:[v frame]];
    OK(spreadAll.location == 0 && spreadAll.length == n,
       "whole-document rect still covers every page in the spread");
    NSRange spreadTop = [v pageRangeInRect:NSMakeRect(0, 0, 900, 5)];
    OK(spreadTop.location == 0, "rect above the first spread resolves to page 0");
    NSRange spreadPast = [v pageRangeInRect:NSMakeRect(0, NSHeight([v frame]) + 500, 900, 50)];
    OK(spreadPast.location < n, "rect past the end of the spread stays in range");

    // The round trip is what saved reading positions depend on, and it is
    // measured against the row: the fraction the controller stores is a
    // fraction into the band the two facing pages share.
    BOOL spreadRoundTrip = YES;
    for (NSUInteger i = 0; i < n; i += 7) {
        CGFloat frac = 0.37;
        NSRect r = [v rectForRowContainingPage:i];
        CGFloat y = NSMinY(r) + frac * NSHeight(r);
        CGFloat outFrac = 0;
        NSUInteger back = [v pageAtTopOfRect:NSMakeRect(0, y, 900, 600) fraction:&outFrac];
        if (back != [v firstPageOfRowContainingPage:i]) spreadRoundTrip = NO;
        if (fabs(outFrac - frac) > 0.02) spreadRoundTrip = NO;
    }
    OK(spreadRoundTrip, "page+fraction survives a round trip through the spread");

    // And back. Turning the mode off has to return the exact geometry it was
    // turned on from, or a reader who tried it once has a document that never
    // quite goes back to how it was.
    [v setColumns:1];
    [v setZoom:1.0 backingScale:1.0 containerWidth:900];
    OK(NSHeight([v frame]) == singleHeight &&
       NSEqualRects([v rectForPage:0], singlePage0),
       "turning the spread off restores the single-page geometry exactly");
    OK(NSEqualRects([v rectForRowContainingPage:3], [v rectForPage:3]),
       "a row is the page itself when there is one column");

    // ---- the count asked for, against the count laid out ----------------
    //
    // -setColumns: records an intent; the row table is not rebuilt until the
    // next layout pass. Everything that indexes that table has to answer from
    // the shape it actually has, and the failure if it does not is not a stale
    // answer but an out-of-range one: at two columns over a table still built
    // one row per page, `row * columns` runs past the end of the document and
    // the range built from it underflows to a length of billions -- which then
    // goes to -setPinnedPages: and to the draw loop.
    //
    // The app never opens this window, because the controller relayouts in the
    // same turn of the run loop that it sets the count. That is a property of
    // one call site, not of this class, so it is pinned here.
    [v setColumns:1];
    [v setZoom:1.0 backingScale:1.0 containerWidth:900];
    [v setColumns:2];                       // ... and deliberately no relayout
    OK([v columns] == 2 && [v laidOutColumns] == 1,
       "the requested column count moves ahead of the laid-out one");

    BOOL staleSafe = YES;
    for (NSUInteger i = 0; i < n; i++) {
        if ([v firstPageOfRowContainingPage:i] != i) staleSafe = NO;
    }
    OK(staleSafe, "row queries answer from the layout on screen, not the one asked for");

    NSRange stale = [v pageRangeInRect:[v frame]];
    OK(stale.location < n && stale.length <= n &&
       stale.location + stale.length <= n,
       "the visible range stays inside the document while the two counts disagree");

    NSRange staleThin = [v pageRangeInRect:NSMakeRect(0, NSMinY([v rectForPage:n - 1]) + 1,
                                                     900, 4)];
    OK(staleThin.location < n && staleThin.location + staleThin.length <= n,
       "and the last row of the document is still in range from the stale count");

    // The relayout that answers the request is what moves the other count.
    [v setZoom:1.0 backingScale:1.0 containerWidth:900];
    OK([v laidOutColumns] == 2, "the layout pass is what publishes the new count");
    [v setColumns:1];
    [v setZoom:1.0 backingScale:1.0 containerWidth:900];

    [v release];
    [cache release];
}

// A page is "in flight" from the moment the worker picks it up until its bitmap
// has been handed over on the main thread -- not merely until rasterisation
// finishes. Those two instants are one main-queue hop apart, and in between the
// bitmap exists but the cache does not have it, so a wanted-set rebuilt in that
// window used to name a page that had already been rendered. Under main-thread
// load that is a heavy page rasterised two or three times over.
//
// The window is reproduced exactly: render, let the worker finish WITHOUT
// running the run loop (so the delivery cannot be dequeued), then ask again.
static void TestRenderQueueDeduplication(NSURL *url, PVPDFSource *geom)
{
    PVPDFSource *own = [[PVPDFSource alloc] initWithURL:url geometryFrom:geom error:NULL];
    Collector *col = [[Collector alloc] init];
    col->quiet = YES;
    PVRenderQueue *q = [[PVRenderQueue alloc] initWithSource:own label:"test.dedup"];
    [q setDelegate:col];

    CGSize px = CGSizeMake(240, 310);
    [q setDesiredRequests:[NSArray arrayWithObject:
        [PVRenderRequest page:3 pixels:px priority:PVPriorityVisibleFull preview:NO]]];

    // Deliberately not PumpRunLoop: the main queue must stay unserviced so the
    // delivery is queued and nothing has reached the delegate yet. Background
    // QoS makes this slow, so the wait is generous.
    usleep(1200 * 1000);
    OK([col->pages count] == 0, "delivery really is still queued (test premise holds)");
    OK([q inFlightCount] == 1, "a rendered-but-undelivered page is still counted in flight");

    // The layer above has no way to know the bitmap exists yet, so it asks for
    // the same page again -- exactly what -updateVisibleContent would do.
    [q setDesiredRequests:[NSArray arrayWithObject:
        [PVRenderRequest page:3 pixels:px priority:PVPriorityVisibleFull preview:NO]]];
    Pump(2.0);

    OK([col->pages count] == 1, "a page already rendered and awaiting delivery is not rendered twice");
    OK([q inFlightCount] == 0, "the in-flight count returns to zero after delivery");
    OK([q isIdle], "the queue is idle once everything has been delivered");

    // A different pixel size for the same page is genuinely different work and
    // must NOT be suppressed, or a zoom during a render would never resolve.
    [col->pages removeAllObjects];
    [q setDesiredRequests:[NSArray arrayWithObject:
        [PVRenderRequest page:3 pixels:CGSizeMake(300, 388)
                     priority:PVPriorityVisibleFull preview:NO]]];
    Pump(2.0);
    OK([col->pages count] == 1, "the same page at a different size is still rendered");

    [q shutdown];
    [q release];
    [col release];
    [own release];
}

// A request CoreGraphics cannot satisfy must be reported, not silently dropped.
// Silently dropping it is what let the layer above ask for the same impossible
// page on every scroll event for the rest of the session.
static void TestRenderQueueFailureReporting(NSURL *url, PVPDFSource *geom)
{
    PVPDFSource *own = [[PVPDFSource alloc] initWithURL:url geometryFrom:geom error:NULL];
    Collector *col = [[Collector alloc] init];
    col->quiet = YES;
    PVRenderQueue *q = [[PVRenderQueue alloc] initWithSource:own label:"test.fail"];
    [q setDelegate:col];

    // A page index past the end of the document is the one failure that can be
    // provoked deterministically; -createImageForPage: returns NULL for it by
    // exactly the same route as a page object the document cannot hand back.
    NSUInteger bogus = [own pageCount] + 5;
    [q setDesiredRequests:[NSArray arrayWithObject:
        [PVRenderRequest page:bogus pixels:CGSizeMake(200, 260)
                     priority:PVPriorityVisibleFull preview:NO]]];
    Pump(2.0);

    OK([col->failed count] == 1, "a render that produced no bitmap is reported as a failure");
    OK([col->pages count] == 0, "a failed render is not reported as a success");
    OK([q inFlightCount] == 0, "a failed render still retires its in-flight marker");
    OK([q isIdle], "a failed render leaves the queue idle, not wedged");

    [q shutdown];
    [q release];
    [col release];
    [own release];
}

// The express lane exists so that the one page the user is visibly waiting on
// arrives in ~0.37 s instead of ~1.4 s. It is worth about eight times the
// energy of a background render, which is why it is spent on exactly one page.
//
// It has to be spent reliably, though, or the same action has two different
// latencies depending on nothing the user can see. -pump gives up when the
// worker is already running, so an express request arriving while a prefetched
// page was mid-rasterisation used to be drained by that ordinary block at
// background QoS and the promotion was simply lost. Jumping to a page within a
// second of stopping a scroll -- when prefetch is still working -- hit it every
// time.
//
// A PVPDFSource subclass records the QoS each render actually ran at, which is
// the only way to observe the promotion from outside.
@interface PVQoSRecordingSource : PVPDFSource {
@public
    NSMutableArray *qos;      // qos_class_t per render, in order
    NSLock         *lock;
}
@end

@implementation PVQoSRecordingSource
- (id)initWithURL:(NSURL *)u geometryFrom:(PVPDFSource *)g error:(NSError **)e
{
    self = [super initWithURL:u geometryFrom:g error:e];
    if (self) { qos = [[NSMutableArray alloc] init]; lock = [[NSLock alloc] init]; }
    return self;
}
- (void)dealloc { [qos release]; [lock release]; [super dealloc]; }
// PVPDFSource's designated override point, which is the only method
// PVRenderQueue calls. Overriding any of the convenience spellings instead
// leaves this instrumentation recording nothing while the suite still reports a
// pass -- which has happened twice, so the primitive is named in the header now
// and this comment says which one it is.
- (CGImageRef)createImageForPage:(NSUInteger)index pixelSize:(CGSize)px
                     interactive:(BOOL)interactive
                         failure:(PVRenderFailure *)failure
{
    // qos_class_self() is 10.10+, and this file is compiled at the app's own
    // 10.9 deployment target with -Werror=unguarded-availability. Resolved the
    // same way the express lane resolves its own entry point, so the guard
    // stays armed and a 10.9 run simply records nothing.
    static unsigned int (*qsel)(void);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        qsel = (unsigned int (*)(void))dlsym(RTLD_DEFAULT, "qos_class_self");
    });
    unsigned int q = qsel ? qsel() : 0;
    [lock lock];
    [qos addObject:[NSNumber numberWithUnsignedInt:q]];
    [lock unlock];
    return [super createImageForPage:index pixelSize:px
                          interactive:interactive failure:failure];
}
- (BOOL)sawQoSAtLeast:(unsigned int)want
{
    BOOL found = NO;
    [lock lock];
    NSUInteger i, n = [qos count];
    for (i = 0; i < n; i++)
        if ([[qos objectAtIndex:i] unsignedIntValue] >= want) { found = YES; break; }
    [lock unlock];
    return found;
}
- (void)resetQoS { [lock lock]; [qos removeAllObjects]; [lock unlock]; }
@end

// The promotion reaches the process that actually draws.
//
// The express lane raises the QoS of the dispatch block that issues a render.
// Since rasterisation moved into a helper, that block does nothing but write a
// pipe and wait on it -- the drawing happens in another process, which backs
// itself into Darwin's background class at startup and stays there unless the
// command says otherwise. Promoting the waiter while the worker stays
// backgrounded is a promotion of nothing, and it is invisible: every test of
// the express lane still passes, because they all check the QoS of the caller.
//
// Measured rather than inspected, because the state being asserted about is not
// readable from outside: getpriority(PRIO_DARWIN_PROCESS) answers only for the
// calling process, so another process's background flag cannot be queried. What
// can be observed is the consequence, and the consequence is large -- around 5x
// on this machine, which is the whole reason the background class is used at
// all.
// The snapshot sweep: what it reclaims, and what it must never touch.
//
// A snapshot is unlinked in -dealloc, which covers every ordinary exit and none
// of the others -- kill -9, a crash, a power cut. Measured on the development
// machine after a day of testing: 41 abandoned copies, about 100 MB. The sweep
// reclaims them.
//
// It also runs `unlink` on files this process did not create, which is the kind
// of thing that should be tested rather than reasoned about. The property that
// matters is the negative one: a snapshot belonging to a LIVE document is never
// swept, no matter how old the file looks.
static void TestSnapshotSweep(NSURL *url)
{
    printf("\n[abandoned snapshot sweep]\n");

    NSString *dir = NSTemporaryDirectory();
    NSFileManager *fm = [NSFileManager defaultManager];

    // An abandoned snapshot: right name, old enough, and nothing holding it.
    NSString *stale = [dir stringByAppendingPathComponent:
                          @"Postview-PDF-ZZstale"];
    [fm removeItemAtPath:stale error:NULL];
    OK([[NSData data] writeToFile:stale atomically:YES],
       "a stand-in for a snapshot left behind by a crash");
    // Backdated well past the staleness threshold.
    NSDictionary *old = [NSDictionary dictionaryWithObject:
        [NSDate dateWithTimeIntervalSinceNow:-(48 * 3600)]
        forKey:NSFileModificationDate];
    [fm setAttributes:old ofItemAtPath:stale error:NULL];

    // A file with the same age that is NOT ours. The sweep is keyed on the
    // name, and a sweep that ignored the name would be deleting other people's
    // temporary files.
    NSString *foreign = [dir stringByAppendingPathComponent:@"NotPostview-ZZ"];
    [fm removeItemAtPath:foreign error:NULL];
    [[NSData data] writeToFile:foreign atomically:YES];
    [fm setAttributes:old ofItemAtPath:foreign error:NULL];

    // And a LIVE document, whose snapshot is then backdated to look every bit
    // as abandoned as the first one. Only the lock distinguishes them.
    NSError *err = nil;
    PVPDFSource *live = [[PVPDFSource alloc] initWithURL:url error:&err];
    OK(live != nil, "a live document to protect");
    NSString *livePath = nil;
    if (live) {
        livePath = [[[live valueForKey:@"_snapshot"] path] copy];
        OK([livePath length] > 0, "the live document has a snapshot on disk");
        [fm setAttributes:old ofItemAtPath:livePath error:NULL];
    }

    PVSweepAbandonedSnapshotsNow();

    OK(![fm fileExistsAtPath:stale],
       "an old, unheld snapshot is reclaimed");
    OK([fm fileExistsAtPath:foreign],
       "a file that is not ours is left alone, however old");
    OK(livePath && [fm fileExistsAtPath:livePath],
       "the snapshot of an OPEN document survives, however old it looks");

    // And once the document closes, the same file is gone -- by -dealloc, not
    // by the sweep, which is the ordinary path.
    [live release];
    OK(livePath && ![fm fileExistsAtPath:livePath],
       "closing the document removes its snapshot without waiting for a sweep");

    [fm removeItemAtPath:foreign error:NULL];
    [livePath release];
}

static void TestHelperRenderPriority(NSURL *url, PVPDFSource *geom)
{
    printf("\n[render priority reaches the helper process]\n");

    NSError *err = nil;
    PVPDFSource *src = [[PVPDFSource alloc] initWithURL:url geometryFrom:geom error:&err];
    if (!src) { OK(NO, "could not open the fixture for the priority test"); return; }

    CGSize px = CGSizeMake(1100, 1420);
    // Warm: the first render of a document pays for parsing it, which belongs
    // to neither measurement.
    CGImageRef warm = [src createImageForPage:0 pixelSize:px];
    if (warm) CGImageRelease(warm);

    const int kRounds = 4;
    double background = 0, interactive = 0;
    int i, ok = 0;
    // Interleaved rather than run in two blocks, so a machine that gets busier
    // partway through the test loads both measurements equally instead of
    // whichever one happened to be second.
    for (i = 0; i < kRounds; i++) {
        double t0 = PVMonotonicSeconds();
        CGImageRef a = [src createImageForPage:(NSUInteger)(i % 8) pixelSize:px
                                   interactive:NO failure:NULL];
        background += PVMonotonicSeconds() - t0;
        if (a) { ok++; CGImageRelease(a); }

        double t1 = PVMonotonicSeconds();
        CGImageRef b = [src createImageForPage:(NSUInteger)(i % 8) pixelSize:px
                                   interactive:YES failure:NULL];
        interactive += PVMonotonicSeconds() - t1;
        if (b) { ok++; CGImageRelease(b); }
    }
    background  /= kRounds;
    interactive /= kRounds;

    OK(ok == kRounds * 2, "every render in the priority comparison succeeded");
    printf("  background  %.0f ms/page\n  interactive %.0f ms/page\n",
           background * 1000.0, interactive * 1000.0);

    // Asserted only when the background figure is big enough to have measured
    // anything. Below that the page is too cheap for the scheduling class to
    // show through the noise, and a ratio taken from two small numbers on a
    // loaded machine is not evidence of anything.
    if (background > 0.150) {
        char msg[200];
        snprintf(msg, sizeof msg,
                 "an express render is materially faster than a background one "
                 "(%.2fx: %.0f ms vs %.0f ms)",
                 background / (interactive > 0 ? interactive : 1e-9),
                 background * 1000.0, interactive * 1000.0);
        // 1.5x against a measured ~5x. The margin is deliberately loose: what
        // this has to catch is the promotion not arriving at all, which reads as
        // 1.0x, and a threshold set near the true ratio would fail on a busy
        // machine for no useful reason.
        OK(interactive * 1.5 < background, msg);
    } else {
        printf("  note  the background render took only %.0f ms; too fast to "
               "compare meaningfully on this machine\n", background * 1000.0);
    }

    [src release];
}

static void TestExpressLanePromotion(NSURL *url, PVPDFSource *geom)
{
    printf("\n[express lane: the promotion is not lost to a busy queue]\n");

    PVQoSRecordingSource *own =
        [[PVQoSRecordingSource alloc] initWithURL:url geometryFrom:geom error:NULL];
    Collector *col = [[Collector alloc] init];
    col->quiet = YES;
    PVRenderQueue *q = [[PVRenderQueue alloc] initWithSource:own label:"test.express"];
    [q setDelegate:col];

    // Baseline: an express request handed to an idle queue must be promoted.
    [q setDesiredRequests:[NSArray arrayWithObject:
        [PVRenderRequest page:0 pixels:CGSizeMake(700, 900)
                     priority:PVPriorityVisibleFull preview:NO express:YES]]];
    Pump(3.0);
    // On 10.9 there is no QoS to raise and no way to read one back. The lane's
    // documented behaviour there is to render the page on the ordinary queue,
    // so that is what is asserted -- requiring a symbol the target does not
    // have would fail the suite on the one machine it exists to qualify.
    if (QoSObservable())
        OK([own sawQoSAtLeast:PV_QOS_CLASS_UTILITY],
           "an express request on an idle queue runs at raised QoS");
    else
        OK([col->pages count] > 0,
           "with no QoS available an express request still renders");

    // The real case. Fill the queue with ordinary background work, let the
    // worker get into a page, and only then ask for the express one -- which
    // is what a page jump during prefetch does.
    [own resetQoS];
    [col->pages removeAllObjects];
    NSMutableArray *bulk = [NSMutableArray array];
    NSUInteger i;
    for (i = 1; i < 7; i++)
        [bulk addObject:[PVRenderRequest page:i pixels:CGSizeMake(700, 900)
                                     priority:PVPriorityNearFull preview:NO]];
    [q setDesiredRequests:bulk];
    Pump(0.05);                      // the worker is now inside a page

    NSMutableArray *withExpress = [NSMutableArray arrayWithArray:bulk];
    [withExpress insertObject:[PVRenderRequest page:9 pixels:CGSizeMake(700, 900)
                                           priority:PVPriorityVisibleFull preview:NO
                                            express:YES]
                      atIndex:0];
    [q setDesiredRequests:withExpress];
    Pump(4.0);

    if (QoSObservable())
        OK([own sawQoSAtLeast:PV_QOS_CLASS_UTILITY],
           "an express request arriving while the queue is busy is still promoted");
    else
        OK([col->pages count] > 0,
           "with no QoS available a busy queue still drains the express request");

    [q shutdown];
    Pump(0.5);
    [q release];
    [col release];
    [own release];
}

static void TestRenderQueue(PVPDFSource *src, NSURL *url)
{
    printf("\n[PVRenderQueue]\n");
    PVPDFSource *own = [[PVPDFSource alloc] initWithURL:url geometryFrom:src error:NULL];
    OK(own != nil, "second source shares geometry from the first");
    OK(own && [own pageCount] == [src pageCount], "shared-geometry source has the same page count");

    Collector *col = [[Collector alloc] init];
    PVRenderQueue *q = [[PVRenderQueue alloc] initWithSource:own label:"test.render"];
    [q setDelegate:col];

    NSMutableArray *reqs = [NSMutableArray array];
    for (int i = 0; i < 3; i++)
        [reqs addObject:[PVRenderRequest page:i pixels:CGSizeMake(200, 260)
                                     priority:PVPriorityVisibleFull preview:NO]];
    [q setDesiredRequests:reqs];
    Pump(4.0);

    OK([col->pages count] == 3, "all three requested pages were delivered");
    OK(col->onMainThread, "results are delivered on the main thread");

    // Replacing the desired set must drop work that is no longer wanted.
    [col->pages removeAllObjects];
    NSMutableArray *many = [NSMutableArray array];
    for (int i = 10; i < 40; i++)
        [many addObject:[PVRenderRequest page:i pixels:CGSizeMake(700, 900)
                                     priority:PVPriorityNearFull preview:NO]];
    [q setDesiredRequests:many];
    [q setDesiredRequests:[NSArray array]];      // user scrolled away
    Pump(1.5);
    OK([col->pages count] <= 1,
       "replacing the wanted set cancels queued work (at most the in-flight page lands)");

    [q shutdown];
    OK(YES, "shutdown drained without deadlocking");
    [q release];
    [col release];
    [own release];

    TestRenderQueueDeduplication(url, src);
    TestRenderQueueFailureReporting(url, src);
    TestExpressLanePromotion(url, src);
    TestHelperRenderPriority(url, src);
    TestSnapshotSweep(url);
}

// The file on disk is untrusted input: it can be hand-edited, restored from a
// backup written by another version, or left half-sane by a filesystem that
// lost a write. Every value used to be read with its type simply assumed, so a
// string where a number belonged reached -unsignedLongLongValue and took the
// app down -- at document-open time, on every open, until the user found and
// deleted the file. Run against a scratch file, never the user's own.
static void TestStateStoreCorruptFile(void)
{
    printf("\n[PVStateStore: hostile plist]\n");
    NSString *path = @"/tmp/postview-selftest-corrupt.plist";
    NSURL *good = [NSURL fileURLWithPath:@"/tmp/postview-corrupt-a.pdf"];
    NSURL *junk = [NSURL fileURLWithPath:@"/tmp/postview-corrupt-b.pdf"];

    NSDictionary *hostile = [NSDictionary dictionaryWithObjectsAndKeys:
        // Every field the wrong type, which is the shape that used to crash.
        [NSDictionary dictionaryWithObjectsAndKeys:
            @"not a number",              @"page",
            @"neither is this",           @"fraction",
            [NSArray array],              @"zoom",
            [NSDictionary dictionary],    @"zoomMode",
            @"yes please",                @"sidebar",
            [NSNumber numberWithInt:7],   @"windowFrame",
            nil],                                         [junk path],
        // An entry that is not a dictionary at all.
        @"I am not a state dictionary",                   @"/tmp/postview-corrupt-c.pdf",
        // A well-formed entry alongside them, which must survive intact.
        [NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithInt:11],   @"page",
            [NSNumber numberWithDouble:0.5], @"fraction",
            [NSNumber numberWithDouble:1.25], @"zoom",
            [NSNumber numberWithInt:2],    @"zoomMode",
            [NSNumber numberWithBool:YES], @"sidebar",
            @"10 10 700 500 0 0 1440 900", @"windowFrame",
            nil],                                         [good path],
        nil];
    OK([hostile writeToFile:path atomically:YES], "hostile fixture written");

    PVStateStore *s = [[PVStateStore alloc] initWithPath:path];
    OK(s != nil, "a store loads from a plist full of wrong types without crashing");

    NSUInteger page = 999; CGFloat frac = -5, zoom = -5;
    PVZoomMode mode = (PVZoomMode)99; BOOL sidebar = YES; NSString *frame = (NSString *)@"x";
    NSUInteger columns = 99;
    BOOL found = [s stateForURL:junk page:&page fraction:&frac zoomMode:&mode
                           zoom:&zoom sidebar:&sidebar columns:&columns
                    windowFrame:&frame];
    OK(found, "the wrong-typed entry is still found, not discarded wholesale");
    OK(page == 0,                      "a non-numeric page reads back as 0");
    OK(frac >= 0 && frac <= 1,         "a non-numeric fraction is clamped into range");
    OK(zoom == 1.0,                    "a non-numeric zoom falls back to 1.0");
    OK(mode == PVZoomModeFitWidth,     "a non-numeric zoom mode falls back to fit width");
    OK(sidebar == NO,                  "a non-numeric sidebar flag reads back as NO");
    OK(frame == nil,                   "a non-string window frame reads back as nil");
    OK(columns == 1,                   "a non-numeric column count falls back to one page across");

    // A value that is not a dictionary must not be reachable at all: -prune
    // reaches into every value it holds and would have gone down with it.
    OK(![s stateForURL:[NSURL fileURLWithPath:@"/tmp/postview-corrupt-c.pdf"]
                  page:NULL fraction:NULL zoomMode:NULL zoom:NULL sidebar:NULL
               columns:NULL windowFrame:NULL],
       "an entry that is not a dictionary is dropped on load");

    // The good entry must be untouched by any of that.
    page = 0; frac = 0; zoom = 0; mode = PVZoomModeCustom; sidebar = NO; frame = nil;
    OK([s stateForURL:good page:&page fraction:&frac zoomMode:&mode
                 zoom:&zoom sidebar:&sidebar columns:NULL windowFrame:&frame],
       "the sound entry survives");
    OK(page == 11 && fabs(zoom - 1.25) < 0.0001 && mode == PVZoomModeFitPage &&
       sidebar == YES && [frame length] > 0, "the sound entry round-trips unchanged");

    // Writing after loading a hostile file must not carry the junk back out,
    // and -prune must be able to walk what is left.
    [s recordForURL:good page:3 fraction:0.1 zoomMode:PVZoomModeActual
               zoom:1.0 sidebar:NO columns:1 windowFrame:@"0 0 10 10 0 0 100 100"];
    [s flush];
    OK(YES, "flush after loading a hostile file completes");
    [s release];

    // Truncated / not-a-plist-at-all.
    [@"this is not a plist" writeToFile:path atomically:YES
                              encoding:NSUTF8StringEncoding error:NULL];
    PVStateStore *s2 = [[PVStateStore alloc] initWithPath:path];
    OK(s2 != nil, "a store loads from a file that is not a plist at all");
    OK(![s2 stateForURL:good page:NULL fraction:NULL zoomMode:NULL
                   zoom:NULL sidebar:NULL columns:NULL windowFrame:NULL],
       "an unreadable file yields an empty store rather than a crash");
    [s2 release];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static void TestStateStore(void)
{
    printf("\n[PVStateStore]\n");
    NSURL *url = [NSURL fileURLWithPath:@"/tmp/postview-selftest-doc.pdf"];
    PVStateStore *s = [PVStateStore sharedStore];
    [s recordForURL:url page:42 fraction:0.25 zoomMode:PVZoomModeFitPage
               zoom:1.75 sidebar:YES columns:2
        windowFrame:@"100 100 800 600 0 0 1440 900"];
    [s flush];

    NSUInteger page = 0; CGFloat frac = 0, zoom = 0;
    PVZoomMode mode = PVZoomModeCustom; BOOL sidebar = NO; NSString *frame = nil;
    NSUInteger columns = 0;
    BOOL found = [s stateForURL:url page:&page fraction:&frac zoomMode:&mode
                           zoom:&zoom sidebar:&sidebar columns:&columns
                    windowFrame:&frame];
    OK(found, "state was recorded");
    OK(page == 42, "page number round-trips");
    OK(fabs(frac - 0.25) < 0.0001, "scroll fraction round-trips");
    OK(mode == PVZoomModeFitPage, "zoom mode round-trips");
    OK(fabs(zoom - 1.75) < 0.0001, "zoom round-trips");
    OK(sidebar == YES, "sidebar visibility round-trips");
    OK(columns == 2, "the two-page layout round-trips");
    OK([frame length] > 0, "window frame round-trips");

    // Survives a full reload from disk, which is the case that actually matters:
    // quit the app, relaunch, reopen the document.
    NSString *path = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
        NSUserDomainMask, YES) objectAtIndex:0]
        stringByAppendingPathComponent:@"Postview/DocumentState.plist"];
    NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:path];
    NSDictionary *entry = [onDisk objectForKey:[url path]];
    OK(entry != nil, "state is readable straight from the plist on disk");
    OK([[entry objectForKey:@"page"] intValue] == 42, "page survives a real disk round trip");

    NSUInteger p2 = 7;
    BOOL missing = [s stateForURL:[NSURL fileURLWithPath:@"/tmp/never-opened-xyz.pdf"]
                             page:&p2 fraction:NULL zoomMode:NULL zoom:NULL
                          sidebar:NULL columns:NULL windowFrame:NULL];
    OK(!missing, "unknown document reports no saved state");
}

// Locates the black square and reports which quadrant of the rendered image it
// landed in. /Rotate is applied clockwise on display, so the square drawn at the
// PDF-space bottom-left corner must move predictably as rotation increases.
static const char *DarkQuadrant(CGImageRef img)
{
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    size_t stride = w * 4;
    unsigned char *buf = (unsigned char *)calloc(h, stride);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(buf, w, h, 8, stride, cs,
        (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(cs);
    CGContextDrawImage(c, CGRectMake(0, 0, w, h), img);

    double sx = 0, sy = 0; long n = 0;
    for (size_t y = 0; y < h; y++)
        for (size_t x = 0; x < w; x++) {
            unsigned char *p = buf + y * stride + x * 4;
            if (p[0] < 60 && p[1] < 60 && p[2] < 60) { sx += x; sy += y; n++; }
        }
    CGContextRelease(c);
    free(buf);
    if (n == 0) return "none";
    double cx = sx / n / w, cy = sy / n / h;   // cy: 0 = top of the image
    if (cy < 0.5) return (cx < 0.5) ? "top-left" : "top-right";
    return (cx < 0.5) ? "bottom-left" : "bottom-right";
}

static void TestRotation(NSString *path)
{
    printf("\n[page rotation — /Rotate 0, 90, 180, 270]\n");
    NSError *err = nil;
    PVPDFSource *src = [[PVPDFSource alloc] initWithURL:[NSURL fileURLWithPath:path]
                                                  error:&err];
    if (!src) { OK(NO, "rotation fixture opened"); return; }
    OK([src pageCount] == 4, "rotation fixture has 4 pages");

    // Media box is 400x200 landscape; 90 and 270 must report it swapped.
    struct { int rot; CGSize size; const char *quadrant; } expect[] = {
        {   0, { 400, 200 }, "bottom-left"  },
        {  90, { 200, 400 }, "top-left"     },
        { 180, { 400, 200 }, "top-right"    },
        { 270, { 200, 400 }, "bottom-right" },
    };

    for (int i = 0; i < 4; i++) {
        CGSize got = [src pointSizeOfPage:i];
        char msg[160];
        snprintf(msg, sizeof msg, "/Rotate %d reports %.0fx%.0f", expect[i].rot,
                 got.width, got.height);
        OK(fabs(got.width - expect[i].size.width) < 1 &&
           fabs(got.height - expect[i].size.height) < 1, msg);

        // Render at 2x the reported size: exercises rotation and upscaling together.
        CGImageRef im = [src createImageForPage:i
                                      pixelSize:CGSizeMake(got.width * 2, got.height * 2)];
        if (!im) { OK(NO, "rotated page rendered"); continue; }

        double cw = 0, ch = 0;
        InkCoverage(im, &cw, &ch);
        snprintf(msg, sizeof msg, "/Rotate %d fills the bitmap (ink %.0f%% x %.0f%%)",
                 expect[i].rot, cw * 100, ch * 100);
        OK(cw > 0.9 && ch > 0.9, msg);

        const char *q = DarkQuadrant(im);
        snprintf(msg, sizeof msg, "/Rotate %d puts the corner mark %s (expected %s)",
                 expect[i].rot, q, expect[i].quadrant);
        OK(strcmp(q, expect[i].quadrant) == 0, msg);
        CGImageRelease(im);
    }
    [src release];
}

static void TestArbitrary(NSString *path)
{
    printf("\n[arbitrary real-world document: %s]\n",
           [[path lastPathComponent] UTF8String]);
    NSError *err = nil;
    PVPDFSource *src = [[PVPDFSource alloc] initWithURL:[NSURL fileURLWithPath:path]
                                                  error:&err];
    if (!src) { OK(NO, "document opened"); return; }
    OK([src pageCount] > 0, "document reports at least one page");

    CGSize nat = [src pointSizeOfPage:0];
    OK(nat.width > 1 && nat.height > 1, "page 0 has a sensible size");

    // The invariant that holds for ANY document: whatever fraction of the page
    // is inked, it must be the same fraction at every rendering scale. If the
    // content were being centred at 1:1 instead of scaled up, coverage would
    // shrink as the bitmap grew.
    double baseW = 0, baseH = 0, cw = 0, ch = 0;
    BOOL consistent = YES;
    double factors[] = { 0.5, 1.0, 2.0, 3.0 };
    for (int i = 0; i < 4; i++) {
        CGImageRef im = [src createImageForPage:0
            pixelSize:CGSizeMake(nat.width * factors[i], nat.height * factors[i])];
        if (!im) { consistent = NO; break; }
        InkCoverage(im, &cw, &ch);
        if (i == 0) { baseW = cw; baseH = ch; }
        else if (fabs(cw - baseW) > 0.06 || fabs(ch - baseH) > 0.06) consistent = NO;
        CGImageRelease(im);
    }
    char msg[160];
    snprintf(msg, sizeof msg,
             "ink coverage is scale independent (%.0f%% x %.0f%% at 0.5x through 3x)",
             baseW * 100, baseH * 100);
    OK(consistent && baseW > 0.05, msg);
    OK(baseW <= 1.0 && baseH <= 1.0, "ink stays inside the page");
    [src release];
}

#pragma mark - Where the app is running from

// The crash this guards against cannot be reproduced in a test: it needs the
// executable's own file to stop being readable while the process runs, and a
// process cannot survive that by construction. What is testable is the
// decision that keeps the app out of that situation, so that is what is
// pinned here -- the whole truth table, and the one volume every machine has.
// A page too large to lay out is presented smaller, not reshaped.
//
// PVPDFSource caps a page's point size so the layout arithmetic downstream --
// frame rectangles, pixel sizes, the render ceiling -- stays inside numbers it
// can carry. The cap used to be applied per axis, replacing whichever dimension
// was out of range with the corresponding US Letter one, which for a page that
// is oversized on ONE axis substitutes an aspect ratio the document does not
// The aspect ratio a page can actually reach, measured rather than assumed.
//
// PVClampPixelSize caps the pixel PRODUCT and then floors each axis back up to
// 1 independently, so a request whose ratio drives one axis below a single
// pixel re-inflates the product past the ceiling. Measured directly: a
// 1 x 1e9 request clamps to 1 x 129,526,892 -- 7.7x PVMaxRenderPixels(), and a
// ~7.9 GB mapping if -createImageForPage: were ever handed it.
//
// Nothing can ask for that, and this is the test of WHY rather than a restating
// of it. The protection is not in PVClampPixelSize at all; it is two properties
// of PVUsablePageSize -- both axes held inside PV_MAX_PAGE_POINTS, and any axis
// at or below 1 pt replaced outright -- which together bound the ratio a page
// can present. -pixelSizeForPage: then scales that rect by a UNIFORM factor, so
// a request's ratio is a page's ratio.
//
// Asserting `20000.0 < PVMaxRenderPixels()` would pin nothing: PV_MAX_PAGE_POINTS
// is #defined inside PVPDFSource.m, so a literal here goes on being true no
// matter what that constant becomes. So the ratio is read back through the real
// API, from a document built to be as thin as a PDF can ask for. Raise the cap,
// remove the 1 pt floor, or add a path that derives width and height
// independently, and these fail.
static NSString *PVWriteSliverFixture(void)
{
    // Deliberately past every guard, in both directions: a hair under the 1 pt
    // floor, a hair over it, and one absurdly large and thin.
    const char *boxes[3] = { "[0 0 25000 0.5]", "[0 0 25000 1.5]", "[0 0 1000000 2]" };
    NSMutableString *pdf = [NSMutableString string];
    NSUInteger offsets[6];
    int i;

    [pdf appendString:@"%PDF-1.4\n"];
    offsets[1] = [pdf length];
    [pdf appendString:@"1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"];
    offsets[2] = [pdf length];
    [pdf appendString:@"2 0 obj\n<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>\nendobj\n"];
    for (i = 0; i < 3; i++) {
        offsets[3 + i] = [pdf length];
        [pdf appendFormat:@"%d 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox %s >>\nendobj\n",
                          3 + i, boxes[i]];
    }
    NSUInteger xref = [pdf length];
    [pdf appendString:@"xref\n0 6\n0000000000 65535 f \n"];
    for (i = 1; i <= 5; i++)
        [pdf appendFormat:@"%010lu 00000 n \n", (unsigned long)offsets[i]];
    [pdf appendFormat:@"trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n%lu\n%%%%EOF\n",
                      (unsigned long)xref];

    NSString *path = @"/tmp/postview-selftest-sliver.pdf";
    if (![pdf writeToFile:path atomically:YES encoding:NSASCIIStringEncoding error:NULL])
        return nil;
    return path;
}

static void TestSliverPageRatioBound(void)
{
    printf("\n[the aspect ratio a page can reach, and the clamp that depends on it]\n");
    NSString *path = PVWriteSliverFixture();
    OK(path != nil, "sliver fixture written");
    if (!path) return;

    NSError *err = nil;
    PVPDFSource *src = [[PVPDFSource alloc] initWithURL:[NSURL fileURLWithPath:path]
                                                  error:&err];
    OK(src != nil, "a document of sliver pages still opens");
    if (!src) return;

    double ceiling = PVMaxRenderPixels();
    double worst = 0;
    NSUInteger i, n = [src pageCount];
    for (i = 0; i < n; i++) {
        CGSize s = [src pointSizeOfPage:i];
        if (!(s.width > 0) || !(s.height > 0)) continue;
        double lo = (double)(s.width < s.height ? s.width : s.height);
        double hi = (double)(s.width > s.height ? s.width : s.height);
        double ratio = hi / lo;
        if (ratio > worst) worst = ratio;

        // The clamp itself, at a magnification far past anything the zoom
        // offers, for this page's real shape. This is the property that keeps
        // -createImageForPage: from sizing an allocation it cannot afford.
        CGSize px = PVClampPixelSize(CGSizeMake((CGFloat)((double)s.width * 4096.0),
                                                (CGFloat)((double)s.height * 4096.0)));
        char msg[200];
        snprintf(msg, sizeof msg,
                 "page %lu (%.0f x %.0f pt) stays under the pixel ceiling when "
                 "magnified 4096x (%.0f px)", (unsigned long)i,
                 (double)s.width, (double)s.height,
                 (double)px.width * (double)px.height);
        OK((double)px.width * (double)px.height <= ceiling + 1.0, msg);
    }

    char msg[200];
    snprintf(msg, sizeof msg,
             "the thinnest page this document can present is %.0f:1, and the "
             "clamp needs worse than %.0f:1 to break", worst, ceiling);
    OK(worst > 1.0 && worst < ceiling, msg);

    [src release];
}

// have. The page is then drawn correctly proportioned inside a frame of the
// wrong shape, so it appears as a thin strip in a mostly blank page with
// nothing anywhere reporting a problem.
//
// The fixture is built here rather than shipped, because the geometry that
// triggers it is out of spec: PDF's own limit is 14400 pt, and no generator
// this project could reasonably keep around emits 25000.
static NSString *PVWriteOversizedFixture(void)
{
    // Three pages: oversized on width only, oversized on height only, and one
    // ordinary page, so the cap is exercised in both directions and the
    // untouched path is checked in the same document.
    const char *boxes[3] = { "[0 0 25000 300]", "[0 0 300 25000]", "[0 0 612 792]" };
    NSMutableString *pdf = [NSMutableString string];
    NSUInteger offsets[5];
    int i;

    [pdf appendString:@"%PDF-1.4\n"];
    offsets[1] = [pdf length];
    [pdf appendString:@"1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"];
    offsets[2] = [pdf length];
    [pdf appendString:@"2 0 obj\n<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>\nendobj\n"];
    for (i = 0; i < 3; i++) {
        offsets[3 + i] = [pdf length];
        [pdf appendFormat:@"%d 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox %s >>\nendobj\n",
                          3 + i, boxes[i]];
    }
    NSUInteger xref = [pdf length];
    [pdf appendString:@"xref\n0 6\n0000000000 65535 f \n"];
    for (i = 1; i <= 5; i++)
        [pdf appendFormat:@"%010lu 00000 n \n", (unsigned long)offsets[i]];
    [pdf appendFormat:@"trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n%lu\n%%%%EOF\n",
                      (unsigned long)xref];

    NSString *path = @"/tmp/postview-selftest-oversized.pdf";
    if (![pdf writeToFile:path atomically:YES encoding:NSASCIIStringEncoding error:NULL])
        return nil;
    return path;
}

static void TestOversizedPageGeometry(void)
{
    printf("\n[page geometry past the layout cap]\n");
    NSString *path = PVWriteOversizedFixture();
    OK(path != nil, "oversized fixture written");
    if (!path) return;

    NSError *err = nil;
    PVPDFSource *src = [[PVPDFSource alloc] initWithURL:[NSURL fileURLWithPath:path]
                                                  error:&err];
    OK(src != nil, "a document with out-of-spec page sizes still opens");
    if (!src) return;
    OK([src pageCount] == 3, "all three pages are present");

    // Both axes are inside what layout will carry.
    NSUInteger i;
    BOOL bounded = YES;
    for (i = 0; i < [src pageCount]; i++) {
        CGSize s = [src pointSizeOfPage:i];
        if (!(s.width > 1) || !(s.height > 1) || s.width > 20000.5 || s.height > 20000.5)
            bounded = NO;
    }
    OK(bounded, "every reported page size is inside the layout cap");

    // ...and the shape survives, which is the part that used to be lost. The
    // tolerance is a rounding allowance on a ratio of ~83, not a margin for a
    // different answer: the old behaviour reported 612 x 300, a ratio of 2.04.
    CGSize wide = [src pointSizeOfPage:0];
    CGSize tall = [src pointSizeOfPage:1];
    CGSize norm = [src pointSizeOfPage:2];

    double wantWide = 25000.0 / 300.0;
    double gotWide  = (double)wide.width / (double)wide.height;
    OK(fabs(gotWide - wantWide) < 0.01,
       "an over-wide page keeps its aspect ratio (25000:300)");

    double wantTall = 300.0 / 25000.0;
    double gotTall  = (double)tall.width / (double)tall.height;
    OK(fabs(gotTall - wantTall) < 0.0001,
       "an over-tall page keeps its aspect ratio (300:25000)");

    // The scale is the one that just fits, so the long axis lands on the cap
    // rather than somewhere arbitrary below it.
    OK(fabs((double)wide.width  - 20000.0) < 0.5, "the over-wide page is scaled to the cap");
    OK(fabs((double)tall.height - 20000.0) < 0.5, "the over-tall page is scaled to the cap");

    // A page that was never out of range is not touched at all.
    OK(fabs((double)norm.width - 612.0) < 0.5 && fabs((double)norm.height - 792.0) < 0.5,
       "an ordinary page beside them is reported exactly as it is");

    // The cap is a layout decision, and the renderer has to agree with it: a
    // bitmap asked for at the reported size must actually come back.
    CGImageRef img = [src createImageForPage:0 pixelSize:CGSizeMake(400, 5)];
    OK(img != NULL, "the capped page still rasterises");
    if (img) CGImageRelease(img);

    [src release];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

// The app delegate's private half, declared rather than added: these exist on
// the class already, and the test has no business reaching around them.
@interface PVAppDelegate (PVTestHooks)
- (void)saveOpenDocumentState;
- (void)stopObservingNotifications;
@end

// Counts the saves instead of performing them, so the test is about which
// notification centre the delegate listened to and not about the disk.
@interface PVSleepProbeDelegate : PVAppDelegate {
@public
    NSUInteger saves;
}
@end
@implementation PVSleepProbeDelegate
- (void)saveOpenDocumentState { saves++; }
@end

// Sleep is a save point. See ENGINEERING.md section 10.
//
// What this pins is not that a save is a good idea -- it is which centre the
// registration went to. NSWorkspace posts its notifications on its own centre,
// and a delegate that registers for NSWorkspaceWillSleepNotification on the
// default centre compiles, links, runs, raises nothing and is simply never
// called. There is no observable difference between that mistake and having
// written no hook at all, except on the machine where the crash happens, and
// the reader who loses their place is the one who finds out.
static void TestSleepSavesReadingPosition(void)
{
    printf("\n[sleep is a save point]\n");

    PVSleepProbeDelegate *d = [[PVSleepProbeDelegate alloc] init];
    [d applicationWillFinishLaunching:nil];

    NSNotificationCenter *workspace = [[NSWorkspace sharedWorkspace] notificationCenter];
    NSUInteger before = d->saves;
    [workspace postNotificationName:NSWorkspaceWillSleepNotification object:nil];
    OK(d->saves == before + 1, "the machine going to sleep writes the reading position");

    // The same name on the wrong centre reaches nothing, which is the whole
    // point: this is the mistake being guarded against, asserted directly.
    before = d->saves;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:NSWorkspaceWillSleepNotification object:nil];
    OK(d->saves == before,
       "the default centre is not where that notification lives");

    // And the way out. The workspace centre holds observers unsafely, so a
    // delegate that unregistered from only the default centre would leave a
    // freed pointer behind to be messaged at the next sleep.
    [d stopObservingNotifications];
    before = d->saves;
    [workspace postNotificationName:NSWorkspaceWillSleepNotification object:nil];
    OK(d->saves == before, "a torn-down delegate no longer hears about sleep");

    [d release];
}

static void TestRunningLocation(void)
{
    printf("\n[where the app is running from]\n");

    // removable, ejectable, local
    OK(PVVolumeKindFromFlags(NO,  NO,  YES) == PVVolumeFixed,
       "an internal disk is somewhere safe to run from");
    OK(PVVolumeKindFromFlags(YES, NO,  YES) == PVVolumeRemovable,
       "removable media is not");
    OK(PVVolumeKindFromFlags(NO,  YES, YES) == PVVolumeRemovable,
       "an ejectable device or mounted disk image is not");
    OK(PVVolumeKindFromFlags(YES, YES, YES) == PVVolumeRemovable,
       "removable and ejectable together is still one risk");

    // Not local outranks the other two: a share can be exported from a disk
    // that is itself removable, and the network is the part that will drop.
    OK(PVVolumeKindFromFlags(NO,  NO,  NO)  == PVVolumeNetwork,
       "a network mount is reported as a network mount");
    OK(PVVolumeKindFromFlags(YES, NO,  NO)  == PVVolumeNetwork,
       "and stays one when the far end is removable");
    OK(PVVolumeKindFromFlags(NO,  YES, NO)  == PVVolumeNetwork,
       "and when it is ejectable");
    OK(PVVolumeKindFromFlags(YES, YES, NO)  == PVVolumeNetwork,
       "and when it is both");

    // The boot volume is the case that must never produce a dialog, because
    // every correctly installed copy is on it.
    OK(PVVolumeKindForURL([NSURL fileURLWithPath:@"/"]) == PVVolumeFixed,
       "the boot volume never raises the warning");
    OK(PVVolumeKindForURL([NSURL fileURLWithPath:@"/Applications"]) == PVVolumeFixed,
       "nor does /Applications");

    // Anything unanswerable is answered "removable", which is the conservative
    // direction rather than the quiet one.
    //
    // This used to answer "fixed", so that a question the file system declined
    // put no dialog in front of anyone. But the only caller is the check that
    // warns about running from a disk that can vanish, and PVVolumeFixed is the
    // answer that suppresses that warning -- so "I could not tell" and "I
    // checked and it is safe" produced identical behaviour, and the warning was
    // silenced in precisely the case where safety could not be established.
    //
    // The two errors do not cost the same. A false "removable" is one dialog
    // the user can decline. A false "fixed" is Postview killed mid-session with
    // no warning ever shown, which is the outcome the check exists to prevent.
    OK(PVVolumeKindForURL(nil) == PVVolumeRemovable,
       "no URL is not evidence of safety");
    OK(PVVolumeKindForURL([NSURL URLWithString:@"http://example.com/"]) == PVVolumeRemovable,
       "nor is a non-file URL");
    OK(PVVolumeKindForURL([NSURL fileURLWithPath:@"/no/such/path/at/all"]) == PVVolumeRemovable,
       "nor is a path whose volume cannot be read");

    // And the common cases still resolve, so this is not a check that has
    // simply been made to say "removable" about everything.
    OK(PVVolumeKindForURL([NSURL fileURLWithPath:NSHomeDirectory()]) == PVVolumeFixed,
       "a real path on the boot volume is still fixed");
}

#pragma mark - Scheduler budget arithmetic

// The render scheduler's memory arithmetic, pinned so that changing one of the
// three numbers without the others cannot pass.
//
// PVMaxRenderPixels() is a third of the page-cache budget, chosen so that the
// two pages on screen come to two thirds and the previews fit in what is left.
// That derivation leaves NO room for a full-resolution prefetch, which is
// exactly the bug this guards: the wanted-set used to ask for three of them.
// Five full bitmaps against a budget sized for three meant that storing one
// evicted a page still on screen, which was then asked for again -- 51 full
// renders to display six pages of a document nobody was scrolling.
// ---------------------------------------------------------------------------
// The resident rendered-pixel census.
//
// Every memory claim about the render pipeline is now read off this counter, so
// the counter itself has to be shown correct first: balanced, clamped at both
// ends, and returning to zero. A census that drifts is worse than none, because
// the number it reports is still believed.
// ---------------------------------------------------------------------------
static void TestResidentCensus(void)
{
    printf("\nResident rendered-pixel census\n");

    PVResidentReset();
    OK(PVResidentTotal() == 0 && PVResidentHighWater() == 0,
       "reset clears both the totals and the high-water marks");

    PVResidentAdd(PVResidentCache, 100);
    PVResidentAdd(PVResidentUndelivered, 30);
    OK(PVResidentTotal() == 130, "the total is the sum of the buckets");
    OK(PVResidentBytes(PVResidentCache) == 100 &&
       PVResidentBytes(PVResidentUndelivered) == 30 &&
       PVResidentBytes(PVResidentRender) == 0,
       "each bucket holds only what was added to it");
    OK(PVResidentHighWater() == 130, "the high-water mark tracks the peak sum");

    PVResidentSub(PVResidentCache, 100);
    OK(PVResidentTotal() == 30, "subtracting removes exactly what was added");
    OK(PVResidentHighWater() == 130, "the high-water mark does not follow the total back down");
    OK(PVResidentHighWaterForBucket(PVResidentCache) == 100,
       "each bucket keeps its own peak");

    // An unbalanced subtraction has to clamp. Wrapping a size_t here would read
    // as a colossal resident total that then suppresses every subsequent peak
    // for the life of the process -- silent, and permanent.
    PVResidentSub(PVResidentUndelivered, 1000000);
    OK(PVResidentBytes(PVResidentUndelivered) == 0 && PVResidentTotal() == 0,
       "an over-subtraction clamps at zero rather than wrapping");

    // ...and the same at the other end.
    PVResidentAdd(PVResidentRender, SIZE_MAX);
    PVResidentAdd(PVResidentRender, SIZE_MAX);
    OK(PVResidentBytes(PVResidentRender) == SIZE_MAX,
       "an overflowing addition saturates rather than wrapping");
    PVResidentReset();

    // Out-of-range buckets are ignored, not written through the end of the
    // array. The enum is the only caller today; this is about the day it isn't.
    PVResidentAdd((PVResidentBucket)-1, 4096);
    PVResidentAdd((PVResidentBucket)PVResidentBucketCount, 4096);
    OK(PVResidentTotal() == 0, "an out-of-range bucket is ignored");
    OK(PVResidentBytes((PVResidentBucket)99) == 0,
       "reading an out-of-range bucket is zero, not a wild read");

    // The cache mirrors its own byte count into the census exactly.
    PVResidentReset();
    {
        PVImageCache *c = [[PVImageCache alloc] initWithBudget:64 * 1024 * 1024];
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        int i;
        for (i = 0; i < 3; i++) {
            CGContextRef bc = CGBitmapContextCreate(NULL, 200, 200, 8, 0, cs,
                (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host);
            if (!bc) continue;
            CGImageRef im = CGBitmapContextCreateImage(bc);
            CGContextRelease(bc);
            if (!im) continue;
            [c setFullImage:im pixelSize:CGSizeMake(200, 200) forPage:(NSUInteger)i];
            CGImageRelease(im);
        }
        CGColorSpaceRelease(cs);
        OK(PVResidentBytes(PVResidentCache) == [c byteCount],
           "the census agrees with the cache's own byte count");
        [c removeAll];
        OK(PVResidentBytes(PVResidentCache) == 0,
           "-removeAll takes the census back down with it");

        // A cache thrown away without -removeAll must not leave its bytes
        // counted. Across the soak's document cycles that would climb without
        // bound and read as a leak in the one figure that exists to disprove one.
        CGColorSpaceRef cs2 = CGColorSpaceCreateDeviceRGB();
        CGContextRef bc = CGBitmapContextCreate(NULL, 200, 200, 8, 0, cs2,
            (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host);
        CGColorSpaceRelease(cs2);
        if (bc) {
            CGImageRef im = CGBitmapContextCreateImage(bc);
            CGContextRelease(bc);
            if (im) {
                [c setFullImage:im pixelSize:CGSizeMake(200, 200) forPage:0];
                CGImageRelease(im);
            }
        }
        OK(PVResidentBytes(PVResidentCache) > 0, "the cache is holding bytes before release");
        [c release];
        OK(PVResidentBytes(PVResidentCache) == 0,
           "releasing a cache retires the bytes it was holding");
    }
    PVResidentReset();
}

// ---------------------------------------------------------------------------
// PV_MAX_INFLIGHT_FULL, enforced.
//
// The bug this closes is specific and is reproduced here rather than approximated:
// the worker rasterises a full page, hands the result to the main queue and
// starts the next one immediately. When the main thread is busy -- which during
// `page` and `scroll` it is, handling 20-50 key events a second -- the deliveries
// queue up behind those events and several ~28 MB bitmaps sit undelivered, where
// no cache budget can see them.
//
// "The main thread is busy" is not simulated with a sleep inside a delegate; it
// is produced exactly, by not running the run loop at all. No delivery block can
// execute until this function pumps, so the queue is left to rasterise against a
// main thread that never drains. Without the cap the undelivered count climbs to
// the size of the request set. With it, it stops at two, and the remaining work
// is still there to be finished the moment the main thread comes back.
// ---------------------------------------------------------------------------
static void TestInFlightFullCap(PVPDFSource *geom, NSURL *url)
{
    printf("\nIn-flight full-bitmap cap (PV_MAX_INFLIGHT_FULL = %d)\n", PV_MAX_INFLIGHT_FULL);

    NSError *err = nil;
    PVPDFSource *src = [[PVPDFSource alloc] initWithURL:url geometryFrom:geom error:&err];
    if (!src) { OK(NO, "could not open the fixture for the in-flight cap test"); return; }

    PVRenderQueue *q = [[PVRenderQueue alloc] initWithSource:src label:"pv.test.inflight"];
    Collector *c = [[Collector alloc] init];
    c->quiet = YES;
    [q setDelegate:c];

    const NSUInteger kRequests = 6;
    NSUInteger pages = [src pageCount];
    if (pages > kRequests) pages = kRequests;

    // Big enough that a render takes long enough to observe, small enough that
    // six of them do not dominate the suite's runtime.
    CGSize px = CGSizeMake(700, 900);

    // ---- full-resolution requests, with the main thread never draining ----
    PVResidentReset();
    {
        NSMutableArray *reqs = [NSMutableArray array];
        NSUInteger i;
        for (i = 0; i < pages; i++)
            [reqs addObject:[PVRenderRequest page:i pixels:px
                                         priority:PVPriorityVisibleFull preview:NO]];
        [q setDesiredRequests:reqs];

        // usleep, deliberately, not PumpRunLoop: pumping would let the delivery
        // blocks run, which is the very thing the cap exists to survive without.
        // Renders run at background QoS, so give the worker real time to get as
        // far as it is ever going to get.
        NSUInteger observedMax = 0;
        double waited = 0;
        while (waited < 20.0) {
            NSUInteger n = [q undeliveredFullCount];
            if (n > observedMax) observedMax = n;
            // Once it has sat at the cap through several samples, the worker has
            // demonstrably stopped rather than merely not started.
            if (observedMax >= PV_MAX_INFLIGHT_FULL && waited > 2.0) break;
            usleep(50000);
            waited += 0.05;
        }

        char msg[200];
        snprintf(msg, sizeof msg,
                 "undelivered full bitmaps never exceeded %d (observed max %lu of %lu asked for)",
                 PV_MAX_INFLIGHT_FULL, (unsigned long)observedMax, (unsigned long)pages);
        OK(observedMax <= PV_MAX_INFLIGHT_FULL, msg);
        OK(observedMax == PV_MAX_INFLIGHT_FULL,
           "...and the cap is what stopped it, not the machine being slow");
        OK([q inFlightCount] <= PV_MAX_INFLIGHT_FULL,
           "nothing extra is held in flight behind the cap");

        // The bytes, which is the point of the exercise: at most two page
        // bitmaps are resident where no budget can see them.
        double undeliveredMB = (double)PVResidentBytes(PVResidentUndelivered) / (1024.0 * 1024.0);
        double onePageMB     = (double)(700 * 900 * 4) / (1024.0 * 1024.0);
        snprintf(msg, sizeof msg,
                 "undelivered bytes bounded at %.2f MB (%.2f MB per bitmap, cap %d)",
                 undeliveredMB, onePageMB, PV_MAX_INFLIGHT_FULL);
        OK(undeliveredMB <= onePageMB * PV_MAX_INFLIGHT_FULL + 0.5, msg);

        // Nothing was lost: the skipped requests are still pending and are
        // picked up as soon as deliveries start landing again. This is the half
        // that a naive "drop the request" implementation would fail.
        BOOL drained = PumpUntil(^{ return (BOOL)([q isIdle] && [c->pages count] >= pages); }, 90.0);
        snprintf(msg, sizeof msg,
                 "every deferred request still completed once the main thread drained (%lu of %lu)",
                 (unsigned long)[c->pages count], (unsigned long)pages);
        OK(drained, msg);
        OK([q undeliveredFullCount] == 0, "the undelivered count returns to zero");
        OK(PVResidentBytes(PVResidentUndelivered) == 0,
           "and so do the undelivered bytes");
    }

    // ---- previews are NOT gated: they are the responsiveness path ----
    {
        [c->pages removeAllObjects];
        NSMutableArray *reqs = [NSMutableArray array];
        NSUInteger i;
        CGSize small = CGSizeMake(px.width / PV_PREVIEW_DIVISOR, px.height / PV_PREVIEW_DIVISOR);
        for (i = 0; i < pages; i++)
            [reqs addObject:[PVRenderRequest page:i pixels:small
                                         priority:PVPriorityVisiblePreview preview:YES]];
        [q setDesiredRequests:reqs];

        NSUInteger observedInFlight = 0;
        double waited = 0;
        while (waited < 20.0) {
            NSUInteger n = [q inFlightCount];
            if (n > observedInFlight) observedInFlight = n;
            if (observedInFlight > PV_MAX_INFLIGHT_FULL) break;
            usleep(50000);
            waited += 0.05;
        }
        char msg[200];
        snprintf(msg, sizeof msg,
                 "previews drain past the full-bitmap cap (%lu in flight, cap is %d)",
                 (unsigned long)observedInFlight, PV_MAX_INFLIGHT_FULL);
        OK(observedInFlight > PV_MAX_INFLIGHT_FULL, msg);
        OK([q undeliveredFullCount] == 0, "previews are not counted against the cap");
        PumpUntil(^{ return [q isIdle]; }, 90.0);
    }

    // ---- shutdown with work outstanding leaves nothing counted ----
    {
        NSMutableArray *reqs = [NSMutableArray array];
        NSUInteger i;
        for (i = 0; i < pages; i++)
            [reqs addObject:[PVRenderRequest page:i pixels:px
                                         priority:PVPriorityVisibleFull preview:NO]];
        [q setDesiredRequests:reqs];
        usleep(200000);
        [q shutdown];
        BOOL quiet = PumpUntil(^{ return (BOOL)([q inFlightCount] == 0); }, 90.0);
        OK(quiet, "a shutdown mid-render retires every in-flight marker");
        OK([q undeliveredFullCount] == 0,
           "shutdown leaves no bitmap counted against the cap");
        OK(PVResidentBytes(PVResidentUndelivered) == 0,
           "shutdown leaves no undelivered bytes counted");
    }

    [q release];
    [c release];
    [src release];
    PVResidentReset();
}

// ---------------------------------------------------------------------------
// The same cap, on two lanes, which is where it was not holding.
//
// PV_MAX_INFLIGHT_FULL bounds the full-page bitmaps that exist at once, and the
// scheduler used to enforce it by counting only the ones already RASTERISED and
// waiting for the main thread. That is a check with no reservation behind it.
// Two lanes read the same count in the same instant and both proceed; worse, a
// lane that had just finished a bitmap could start another before the first was
// delivered. Three ~28 MB bitmaps against a declared limit of two.
//
// It cannot be reproduced on one lane, and it cannot be reproduced on a laptop,
// because a machine with a battery is given one lane by policy. So the machine
// is forced: AC, no internal battery -- a 2013 Mac Pro, which is the hardware
// the second lane exists for and the hardware this was reported on.
//
// The costs are made asymmetric on purpose. Pages are sharded across lanes by
// page number, so giving the even pages a large bitmap and the odd pages a
// small one guarantees the two lanes finish at different times, which is the
// interleaving that opens the gap. Equal costs make the lanes finish together
// and the bug hides.
// ---------------------------------------------------------------------------
static void TestTwoLaneFullCap(PVPDFSource *geom, NSURL *url)
{
    printf("\nTwo-lane in-flight cap (forced Mac Pro configuration)\n");

    NSUInteger cores = [[NSProcessInfo processInfo] activeProcessorCount];
    if (cores < 6) {
        printf("  skip  this machine has %lu cores; the second lane needs 6\n",
               (unsigned long)cores);
        return;
    }

    PVSetPowerSourceOverride(PVPowerAC, YES);
    PVSetInternalBatteryOverride(NO, YES);

    NSError *err = nil;
    PVPDFSource *src = [[PVPDFSource alloc] initWithURL:url geometryFrom:geom error:&err];
    PVRenderQueue *q = src ? [[PVRenderQueue alloc] initWithSource:src
                                                             label:"pv.test.twolane"] : nil;
    Collector *c = [[Collector alloc] init];
    c->quiet = YES;
    [q setDelegate:c];

    // The configuration is asserted, not assumed. A queue that quietly built
    // one lane would pass every assertion below without testing anything.
    OK(q != nil && [q laneCount] == 2,
       "the forced configuration really did build two lanes");

    if (q && [q laneCount] == 2) {
        const NSUInteger kRequests = 12;
        NSUInteger pages = [src pageCount];
        if (pages > kRequests) pages = kRequests;

        // Sampled from another thread, as tightly as it will go. The peak this
        // is looking for lasts exactly as long as one lane's head start, and a
        // sampler sharing the main thread with the polling loop would step over
        // it. Plain loads and stores under the queue's own lock, published
        // through it: -fullCapacityInUse takes that lock for the whole read.
        __block volatile int32_t stop = 0;
        __block NSUInteger observedMax = 0;
        NSLock *seen = [[NSLock alloc] init];
        dispatch_queue_t sampler =
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
        dispatch_async(sampler, ^{
            while (!stop) {
                NSUInteger n = [q fullCapacityInUse];
                [seen lock];
                if (n > observedMax) observedMax = n;
                [seen unlock];
            }
        });

        NSMutableArray *reqs = [NSMutableArray array];
        NSUInteger i;
        for (i = 0; i < pages; i++) {
            // Even pages are ~4x the pixels of odd ones, and the lanes are
            // sharded by page parity: lane 0 gets the slow work, lane 1 the fast.
            CGSize px = (i % 2 == 0) ? CGSizeMake(900, 1160)
                                     : CGSizeMake(450, 580);
            [reqs addObject:[PVRenderRequest page:i pixels:px
                                         priority:PVPriorityVisibleFull preview:NO]];
        }
        [q setDesiredRequests:reqs];

        // usleep, not PumpRunLoop, for the same reason as the one-lane test: no
        // delivery may run, so the bitmaps have nowhere to go and the cap is the
        // only thing that can stop the lanes.
        double waited = 0;
        while (waited < 20.0) {
            usleep(50000);
            waited += 0.05;
            [seen lock];
            NSUInteger peak = observedMax;
            [seen unlock];
            if (peak >= PV_MAX_INFLIGHT_FULL && waited > 3.0) break;
        }

        stop = 1;
        [seen lock];
        NSUInteger peak = observedMax;
        [seen unlock];

        char msg[220];
        snprintf(msg, sizeof msg,
                 "two lanes never held more than %d full bitmaps at once "
                 "(rasterising + undelivered, observed peak %lu)",
                 PV_MAX_INFLIGHT_FULL, (unsigned long)peak);
        OK(peak <= PV_MAX_INFLIGHT_FULL, msg);
        OK(peak == PV_MAX_INFLIGHT_FULL,
           "...and the cap is what stopped them, not the machine being slow");

        // Nothing was dropped to achieve it. A cap that loses work is not a cap,
        // and with two lanes the requeue path has two ways to go wrong.
        BOOL drained = PumpUntil(^{
            return (BOOL)([q isIdle] && [c->pages count] >= pages); }, 120.0);
        snprintf(msg, sizeof msg,
                 "every deferred request completed on two lanes (%lu of %lu)",
                 (unsigned long)[c->pages count], (unsigned long)pages);
        OK(drained, msg);
        OK([q fullCapacityInUse] == 0,
           "the two-lane capacity returns to zero when the queue is idle");
        [seen release];
    }

    [q shutdown];
    PumpUntil(^{ return (BOOL)([q inFlightCount] == 0); }, 60.0);
    [q release];
    [c release];
    [src release];

    PVSetInternalBatteryOverride(NO, NO);
    PVSetPowerSourceOverride(PVPowerUnknown, NO);
    PVResidentReset();
}

// The eviction budget and the render ceiling are two numbers now, not one
// expression, so the property that used to hold by construction has to be
// asserted. It is asserted on every tier rather than on whichever tier this
// machine happens to be: the failure being guarded against is someone cutting a
// budget for the 2 GB tier while developing on an 8 GB one, which no test that
// only reads PVPageCacheBudget() can ever see.
static void TestRamTierInvariants(void)
{
    printf("\nRAM tiers: eviction budget vs render ceiling\n");

    // The tier boundaries themselves, as a pure function of a byte count.
    const unsigned long long GB = 1024ULL * 1024ULL * 1024ULL;
    OK(PVRamTierForBytes(0)            == PVRamTierSmall,  "an implausible RAM reading takes the smallest tier");
    OK(PVRamTierForBytes(1 * GB)       == PVRamTierSmall,  "1 GB is the small tier");
    OK(PVRamTierForBytes(2 * GB)       == PVRamTierSmall,  "2 GB is the small tier (boundary is inclusive)");
    OK(PVRamTierForBytes(2 * GB + 1)   == PVRamTierMedium, "just over 2 GB moves up a tier");
    OK(PVRamTierForBytes(4 * GB)       == PVRamTierMedium, "4 GB is the medium tier (boundary is inclusive)");
    OK(PVRamTierForBytes(4 * GB + 1)   == PVRamTierLarge,  "just over 4 GB is the large tier");
    OK(PVRamTierForBytes(8 * GB)       == PVRamTierLarge,  "8 GB is the large tier (boundary is inclusive)");
    OK(PVRamTierForBytes(8 * GB + 1)   == PVRamTierHuge,   "just over 8 GB is the huge tier");
    OK(PVRamTierForBytes(16 * GB)      == PVRamTierHuge,   "16 GB is the huge tier");
    OK(PVRamTierForBytes(64 * GB)      == PVRamTierHuge,   "64 GB is the huge tier");
    OK(PVRamTierForBytes(1024 * GB)    == PVRamTierHuge,   "a machine larger than any Mavericks Mac does not overflow past the top tier");
    OK(PVRamTierOfThisMachine() == PVRamTierForBytes(
           [[NSProcessInfo processInfo] physicalMemory]),
       "this machine's tier agrees with the pure function");

    // The anti-thrash invariant, on every tier. Two full-resolution pages are on
    // screen at any ordinary zoom; the previews are what make scrolling back
    // instant and must not be the thing evicted to make room for a page.
    //
    // This is what the old `ceiling = budget / 3 / 4` bought by construction.
    // Stated as an inequality it survives either number being tuned, and fails
    // loudly on the tier that was tuned rather than silently rendering that
    // tier's pages soft.
    int t;
    for (t = 0; t < PVRamTierCount; t++) {
        double ceiling = PVMaxRenderPixelsForTier((PVRamTier)t);
        double budget  = (double)PVPageCacheBudgetForTier((PVRamTier)t);
        double pageBytes    = ceiling * 4.0;
        double previewBytes = pageBytes / (PV_PREVIEW_DIVISOR * PV_PREVIEW_DIVISOR);
        double needed = 2.0 * pageBytes + PV_CACHE_SLACK_PREVIEWS * previewBytes;

        char msg[200];
        snprintf(msg, sizeof msg,
                 "tier %d: two full pages + %d previews (%.1f MB) fit the %.0f MB budget",
                 t, PV_CACHE_SLACK_PREVIEWS, needed / (1024.0 * 1024.0),
                 budget / (1024.0 * 1024.0));
        OK(needed <= budget, msg);

        snprintf(msg, sizeof msg, "tier %d: ceiling and budget are both positive", t);
        OK(ceiling > 0 && budget > 0, msg);

        snprintf(msg, sizeof msg, "tier %d: one bitmap is at most a third of the budget", t);
        OK(pageBytes * 3.0 <= budget + 1.0, msg);
    }

    // No machine may render a softer page than it did before the split. These
    // are the values the old derivation produced; they are pinned so that a
    // later cut to PVPageCacheBudgetForTier() cannot quietly drag them down --
    // which is the exact trap ENGINEERING.md §4.1 documents.
    OK(fabs(PVMaxRenderPixelsForTier(PVRamTierLarge)  - 8388608.0) < 1.0,
       "the >4 GB render ceiling has not moved from 8.39 Mpx");
    OK(fabs(PVMaxRenderPixelsForTier(PVRamTierMedium) - 5592405.3333) < 1.0,
       "the 4 GB render ceiling has not moved from 5.59 Mpx");
    OK(PVMaxRenderPixelsForTier(PVRamTierHuge) > PVMaxRenderPixelsForTier(PVRamTierLarge) &&
       PVMaxRenderPixelsForTier(PVRamTierLarge) > PVMaxRenderPixelsForTier(PVRamTierMedium) &&
       PVMaxRenderPixelsForTier(PVRamTierMedium) > PVMaxRenderPixelsForTier(PVRamTierSmall),
       "a bigger machine never gets a smaller ceiling");
    OK(PVPageCacheBudgetForTier(PVRamTierHuge) > PVPageCacheBudgetForTier(PVRamTierLarge) &&
       PVPageCacheBudgetForTier(PVRamTierLarge) > PVPageCacheBudgetForTier(PVRamTierMedium) &&
       PVPageCacheBudgetForTier(PVRamTierMedium) > PVPageCacheBudgetForTier(PVRamTierSmall),
       "a bigger machine never gets a smaller budget");

    // The three tiers that existed before the split are pinned to the byte.
    // Every Mavericks-capable Mac with 8 GB or less lands in one of them, so
    // this is the assertion that says the fourth tier changed nothing for the
    // machines that were already supported -- a 2 GB 2007 iMac and an 8 GB 2013
    // MacBook Pro must get exactly the budgets they got before it existed.
    OK(PVPageCacheBudgetForTier(PVRamTierSmall)  ==  32 * 1024 * 1024 &&
       PVPageCacheBudgetForTier(PVRamTierMedium) ==  64 * 1024 * 1024 &&
       PVPageCacheBudgetForTier(PVRamTierLarge)  ==  96 * 1024 * 1024,
       "the three original tiers' budgets are unchanged by the fourth");
    OK(PVThumbCacheBudgetForTier(PVRamTierSmall)  ==  6 * 1024 * 1024 &&
       PVThumbCacheBudgetForTier(PVRamTierMedium) == 10 * 1024 * 1024 &&
       PVThumbCacheBudgetForTier(PVRamTierLarge)  == 16 * 1024 * 1024,
       "the three original tiers' thumbnail budgets are unchanged by the fourth");

    // The zoom headroom cliff, stated as a number instead of left to be
    // discovered. A US Letter page fit to the width of the 1200x800 showdown
    // window on a 2x display is ~7.1 Mpx against an 8.39 Mpx ceiling -- so the
    // ceiling is crossed by zooming in less than a tenth. Past that point
    // PVClampPixelSize() scales the request down and -drawRect: stretches it
    // back up: the page is soft, silently, and stays soft for as long as the
    // zoom does.
    //
    // Not raised here. Raising it means raising the eviction budget to keep the
    // inequality above, which is the opposite of what this round of work is
    // for. Recorded, pinned, and left as a known limit.
    {
        double colWidthPt = 1200.0 - 2.0 * PV_EDGE_GAP;
        double pagePt     = 792.0 / 612.0;             // US Letter aspect
        double wPx = colWidthPt * 2.0;                 // backingScaleFactor 2
        double hPx = wPx * pagePt;
        double fitPixels = wPx * hPx;
        double crossing  = sqrt(PVMaxRenderPixelsForTier(PVRamTierLarge) / fitPixels);
        printf("  note  fit-width Letter at 2x is %.2f Mpx; the >4 GB ceiling is\n"
               "        crossed at %.2fx zoom, above which every page is rendered\n"
               "        downscaled and stretched back up\n",
               fitPixels / 1.0e6, crossing);
        OK(fitPixels < PVMaxRenderPixelsForTier(PVRamTierLarge),
           "fit-width itself is under the ceiling: the default view is sharp");
        OK(crossing > 1.05 && crossing < 1.15,
           "the ceiling is crossed between 1.05x and 1.15x zoom (pinned, known limit)");

        // The huge tier exists to move that cliff, and this is the number it
        // moves it to. A machine with more than 8 GB gets its ceiling doubled,
        // which is sqrt(2) on the zoom axis because the ceiling is in pixels
        // and zoom is linear -- so 1.09x becomes 1.54x, not 2.18x. Stated here
        // because "we doubled the ceiling" and "we doubled the usable zoom" are
        // different claims and only the first one is true.
        double crossingHuge = sqrt(PVMaxRenderPixelsForTier(PVRamTierHuge) / fitPixels);
        printf("  note  the > 8 GB ceiling is crossed at %.2fx zoom\n", crossingHuge);
        OK(crossingHuge > 1.50 && crossingHuge < 1.58,
           "the huge tier moves the cliff to between 1.50x and 1.58x zoom");
        OK(fabs(PVMaxRenderPixelsForTier(PVRamTierHuge)
                / PVMaxRenderPixelsForTier(PVRamTierLarge) - 2.0) < 1e-9,
           "the huge tier's ceiling is exactly twice the large tier's");
    }
}

static void TestSchedulerBudgetArithmetic(void)
{
    printf("\nScheduler budget arithmetic\n");

    double maxPx    = PVMaxRenderPixels();
    double maxBytes = maxPx * 4.0;
    double budget   = (double)PVPageCacheBudget();

    OK(maxBytes > 0 && budget > 0, "budget and per-bitmap ceiling are positive");
    // An inequality, where this used to assert equality with budget/3.
    //
    // The equality was a restatement of `ceiling = budget / 3 / 4`, which is
    // precisely the coupling task 3 existed to break: written as a derivation,
    // any cut to the budget silently cut the ceiling too and every page in every
    // scenario came out soft with no diagnostic. Re-asserting it here put the
    // coupling back in the test suite after it had been removed from the code,
    // and it is what the huge tier's fourth-page budget trips over. The property
    // actually being protected is that one bitmap cannot monopolise the cache,
    // and that is a bound, not an identity.
    OK(maxBytes * 3.0 <= budget + 1.0,
       "one full bitmap is at most a third of the page-cache budget");

    // Two pages are on screen at any ordinary zoom. Everything the wanted-set
    // may ask for at full resolution has to fit what the cache can hold, or
    // the last one stored evicts one that is still wanted.
    double fullsRequested = 2.0 + (double)PV_FULL_PREFETCH_PAGES;
    OK(fullsRequested * maxBytes <= budget + 1.0,
       "visible pages plus full prefetch fit the cache budget");

    // Stated separately so the failure message says which number moved.
    OK(PV_FULL_PREFETCH_PAGES <= 1,
       "full-resolution prefetch depth stays within what the budget allows");
    OK(PV_MAX_FULL_IMAGES >= 3,
       "the count cap is looser than the byte budget, not a second ceiling");

    // Previews are what make scrolling back instant, so the budget has to hold
    // several of them alongside the visible pages.
    double previewBytes = maxBytes / (PV_PREVIEW_DIVISOR * PV_PREVIEW_DIVISOR);
    OK(previewBytes * 4.0 < budget,
       "four previews still fit beside the full bitmaps");
}

#pragma mark - Scenario replay

// The profiler's three workloads, replayed through the same speed model the
// controller uses, so the throttle's behaviour on each is pinned without a
// window, a clock or a PDF.
//
// This exists because the profile is easy to misread. `read` reports zero
// suppressed requests, which looks like a broken throttle and is in fact the
// correct answer: a reader sitting on a page for two and a half seconds wants
// it sharp. Only `page` and `scroll` move fast enough for suppression to be
// right, and the test says so in those terms.
static double ReplaySpeed(int presses, double delay, double travel)
{
    double speed = 0, lastT = 0, now = 0;
    int i;
    for (i = 0; i < presses; i++) {
        now += delay;
        double dt = now - lastT;
        // Mirrors -[PVWindowController boundsDidChange:].
        if (lastT > 0 && dt >= 0.002 && dt < 0.5) {
            double v = travel / dt;
            if (v <= PV_MAX_SCROLL_SPEED)
                speed = (speed > 0) ? (speed * 0.7 + v * 0.3) : v;
        } else if (lastT > 0 && dt >= 0.5) {
            speed = 0;                      // half a second of stillness ends a scroll
        }
        lastT = now;
    }
    return speed;
}

// How far one arrow press scrolls.
//
// Pinned here because it is a number the showdown's fairness gate compares
// against Preview, and the comparison is only meaningful if the number is
// stable. The recorded failure: 200 arrow presses moved Preview 13 pages and
// Postview 6, so the two apps were not doing the same work and the run could
// not name a winner. See ENGINEERING.md section 9.
static void TestArrowScrollStep(void)
{
    printf("\nArrow-key scroll step\n");

    // The showdown's window: 1200x800, viewport about 770 pt after the chrome.
    // A page of the measured document is 1847.5 pt tall at that width and a
    // page pitch is 1859.5 with the gap, so 200 presses must land nearer to
    // Preview's 13 pages than the old 60 pt did.
    const double kPitch = 1847.5 + PV_PAGE_GAP;
    CGFloat step = PVArrowScrollForViewportHeight(770.0);
    OK(fabs(step - 770.0 / 8.0) < 0.001,
       "a 770 pt viewport gives one eighth of itself per press");
    double pages = 200.0 * step / kPitch;
    OK(pages > 13.0 / 2.0,
       "200 presses travel more than half of Preview's 13 pages (the gate)");
    OK(pages < 13.0 * 2.0,
       "...and less than twice it, from the other side");
    OK(200.0 * 60.0 / kPitch <= 13.0 / 2.0,
       "the 60 pt step this replaced does NOT clear that gate");

    // Monotonic in the viewport, so a taller window scrolls further per press,
    // and clamped at both ends so neither extreme is unusable.
    OK(PVArrowScrollForViewportHeight(1000.0) > PVArrowScrollForViewportHeight(600.0),
       "a taller viewport scrolls further per press");
    OK(PVArrowScrollForViewportHeight(100.0) == PV_ARROW_SCROLL_MIN,
       "a very short viewport is held at the floor");
    OK(PVArrowScrollForViewportHeight(4000.0) == PV_ARROW_SCROLL_MAX,
       "a very tall viewport is held at the ceiling");

    // Degenerate geometry reaches -scrollToPoint: as a number, never a NaN.
    OK(PVArrowScrollForViewportHeight(0.0) == PV_ARROW_SCROLL_MIN,
       "a zero viewport returns the floor");
    OK(PVArrowScrollForViewportHeight(-50.0) == PV_ARROW_SCROLL_MIN,
       "a negative viewport returns the floor");
    OK(PVArrowScrollForViewportHeight((CGFloat)NAN) == PV_ARROW_SCROLL_MIN,
       "a non-finite viewport returns the floor, not NaN");
    OK(isfinite(PVArrowScrollForViewportHeight((CGFloat)INFINITY)),
       "an infinite viewport returns a finite step");

    // The arrow stays smaller than Page Down at every size, or the two keys
    // would have swapped roles somewhere in the middle of the range.
    int i; BOOL ordered = YES;
    for (i = 200; i <= 2000; i += 50) {
        CGFloat vp = (CGFloat)i;
        CGFloat pageStep = (vp - 40.0 < 40.0) ? vp : vp - 40.0;
        if (PVArrowScrollForViewportHeight(vp) >= pageStep) ordered = NO;
    }
    OK(ordered, "an arrow press is smaller than a Page Down at every window size");
}

static void TestScenarioReplay(void)
{
    printf("\nScenario replay (profiler workloads)\n");

    const double kPageTravel = 760.0;   // roughly one viewport per Page Down
    // One arrow press in the showdown's 800 pt window. Taken from the function
    // the app calls rather than written down again, so this replay cannot go
    // on modelling a step the app has stopped using -- which is what it was
    // doing at 24 pt against the app's 60.
    const double kLineTravel = (double)PVArrowScrollForViewportHeight(770.0);

    // read: 12 Page Downs, 2.5 s apart. Every gap exceeds half a second, so
    // each one ends the previous scroll and the speed returns to rest.
    double readSpeed = ReplaySpeed(12, 2.5, kPageTravel);
    OK(readSpeed == 0.0, "read: 2.5 s gaps leave the document at rest");
    OK(PVShouldRenderWhileMoving(readSpeed, 0.0, 0.1),
       "read: a page being read is rendered, however short its dwell looks");

    // page: 80 Page Downs at 20/s. This is a flick.
    double pageSpeed = ReplaySpeed(80, 0.05, kPageTravel);
    OK(pageSpeed > PV_MIN_SCROLL_SPEED, "page: 20 presses/s registers as motion");
    OK(!PVShouldRenderWhileMoving(pageSpeed, 0.0, kPageTravel / pageSpeed),
       "page: pages flying past are skipped");

    // scroll: 200 arrow keys at 50/s. Slower travel, but still real motion.
    double scrollSpeed = ReplaySpeed(200, 0.02, kLineTravel);
    OK(scrollSpeed > PV_MIN_SCROLL_SPEED, "scroll: 50 presses/s registers as motion");
    OK(!PVShouldRenderWhileMoving(scrollSpeed, 0.0, kLineTravel / scrollSpeed),
       "scroll: continuous motion suppresses too");

    // The ordering that makes the throttle device-independent. A keyboard
    // scroll posts no live-scroll notification, so anything keyed off those
    // flags alone would treat these two as different -- which is precisely the
    // bug that let full-resolution renders past the throttle while previews
    // beside them were correctly suppressed.
    OK(pageSpeed > scrollSpeed,
       "paging travels faster than line scrolling, as the geometry says");
    OK(!PVShouldRenderWhileMoving(pageSpeed, 0.0, 0.1) ==
       !PVShouldRenderWhileMoving(scrollSpeed, 0.0, 0.1),
       "both keyboard motions reach the same decision for the same dwell");

    // The safety property, restated at the scenario level: whatever the speed,
    // a measurement that has gone stale renders. A document that stops moving
    // cannot stay soft.
    OK(PVShouldRenderWhileMoving(pageSpeed, PV_SPEED_FRESH_SECONDS * 1.01, 0.0),
       "a flick that ended leaves nothing suppressed behind it");
}

#pragma mark - Render-suppression policy

// PVShouldRenderWhileMoving is the whole of the throttle. It is a pure
// function precisely so it can be pinned here: no window, no run loop, no PDF,
// and no dependence on how fast this machine happens to be.
//
// The property that matters most is the last group. Suppression must be
// impossible to get stuck in, because the only thing that recomputes speed is
// movement -- so if a stale measurement could still suppress, a document that
// stopped moving would stay soft with no event coming that would fix it.
static void TestRenderSuppressionPolicy(void)
{
    printf("\nRender-suppression policy\n");

    const double kFresh = 0.0;                     // measured just now
    const double kSlow  = 0.5 * PV_MIN_VISIBLE_SECONDS;   // page gone too soon
    const double kLong  = 2.0 * PV_MIN_VISIBLE_SECONDS;   // page stays put

    // Ordering the design depends on: the settle timer must normally fire
    // before staleness would have ended the suppression on its own, or the
    // backstop becomes the mechanism and the sharp pass gets slower.
    OK(PV_SETTLE_SECONDS < PV_SPEED_FRESH_SECONDS,
       "settle fires before a measurement goes stale");
    OK(PV_SETTLE_SECONDS > 0.0 && PV_SPEED_FRESH_SECONDS > 0.0,
       "settle and freshness windows are positive");

    // At rest: always render, however briefly the geometry says a page lasts.
    OK(PVShouldRenderWhileMoving(0.0, kFresh, kSlow),
       "at rest, renders");
    OK(PVShouldRenderWhileMoving(PV_MIN_SCROLL_SPEED, kFresh, kSlow),
       "at the speed floor, renders");
    OK(PVShouldRenderWhileMoving(PV_MIN_SCROLL_SPEED * 0.99, kFresh, 0.0),
       "below the speed floor, renders even for a page with no dwell");

    // Moving fast, fresh measurement: this is the only case that suppresses.
    OK(!PVShouldRenderWhileMoving(20000.0, kFresh, kSlow),
       "fast and fresh, a page that will be gone is skipped");
    OK(PVShouldRenderWhileMoving(20000.0, kFresh, kLong),
       "fast and fresh, a page that stays is still rendered");
    OK(!PVShouldRenderWhileMoving(20000.0, PV_SPEED_FRESH_SECONDS * 0.99, kSlow),
       "just inside the freshness window, still suppressing");

    // The stuck-suppression guard. Past the freshness window the measurement
    // is disregarded no matter how fast it said the document was going.
    OK(PVShouldRenderWhileMoving(20000.0, PV_SPEED_FRESH_SECONDS, kSlow),
       "exactly at the freshness limit, renders");
    OK(PVShouldRenderWhileMoving(20000.0, PV_SPEED_FRESH_SECONDS * 1.01, kSlow),
       "a stale measurement cannot suppress");
    OK(PVShouldRenderWhileMoving(1.0e9, 3600.0, 0.0),
       "an hour-old measurement of any speed cannot suppress");
    OK(PVShouldRenderWhileMoving(20000.0, HUGE_VAL, kSlow),
       "no measurement yet cannot suppress");
    OK(PVShouldRenderWhileMoving(20000.0, -1.0, kSlow),
       "a clock that moved backwards cannot suppress");

    // Non-finite inputs render rather than falling through comparisons that
    // are all false for a NaN.
    OK(PVShouldRenderWhileMoving(NAN, kFresh, kSlow),
       "NaN speed renders");
    OK(PVShouldRenderWhileMoving(20000.0, kFresh, NAN),
       "NaN dwell renders");
    OK(PVShouldRenderWhileMoving(HUGE_VAL, kFresh, kSlow),
       "infinite speed renders");
    OK(PVShouldRenderWhileMoving(20000.0, NAN, kSlow),
       "NaN age renders");

    // Exhaustive sweep: the ONLY combination that may return NO is fresh
    // evidence of real speed with a page that will not survive it. Anything
    // else returning NO is a document that could be left permanently soft.
    int violations = 0, suppressions = 0;
    double speeds[] = { 0.0, 1.0, 1.5, 100.0, 20000.0, 99999.0, 1.0e9 };
    double ages[]   = { 0.0, 0.01, 0.1, 0.24, 0.25, 0.26, 1.0, 60.0 };
    double dwells[] = { 0.0, 0.01, 0.24, 0.25, 0.26, 1.0, 1.0e6 };
    size_t si, ai, di;
    for (si = 0; si < sizeof(speeds) / sizeof(speeds[0]); si++)
    for (ai = 0; ai < sizeof(ages)   / sizeof(ages[0]);   ai++)
    for (di = 0; di < sizeof(dwells) / sizeof(dwells[0]); di++) {
        BOOL render = PVShouldRenderWhileMoving(speeds[si], ages[ai], dwells[di]);
        if (render) continue;
        suppressions++;
        BOOL legitimate = (speeds[si] > PV_MIN_SCROLL_SPEED) &&
                          (ages[ai]   < PV_SPEED_FRESH_SECONDS) &&
                          (dwells[di] <= PV_MIN_VISIBLE_SECONDS);
        if (!legitimate) {
            violations++;
            printf("        speed=%g age=%g dwell=%g suppressed without cause\n",
                   speeds[si], ages[ai], dwells[di]);
        }
    }
    OK(violations == 0, "no combination suppresses without fresh evidence");
    OK(suppressions > 0, "the sweep actually exercised suppression");

    // Determinism: identical inputs, identical answer, every time. The policy
    // reads no clock and holds no state of its own, and this says so.
    int i, stable = 1;
    BOOL first = PVShouldRenderWhileMoving(20000.0, 0.05, kSlow);
    for (i = 0; i < 10000; i++)
        if (PVShouldRenderWhileMoving(20000.0, 0.05, kSlow) != first) stable = 0;
    OK(stable, "same inputs give the same answer across 10000 calls");
}


#pragma mark - Power source

static void TestPowerSource(void)
{
    printf("\nPower source\n");

    // The classifier, which is the only part of this that a machine cannot
    // change underneath the test. Both IOKit's own spellings and the ones a
    // person types at a shell have to work, because -PVPowerState is meant to
    // be usable by hand and Tools/showdown.sh passes it programmatically.
    OK(PVPowerSourceFromString(@"AC Power")      == PVPowerAC,      "IOKit's \"AC Power\" is AC");
    OK(PVPowerSourceFromString(@"ACPower")       == PVPowerAC,      "\"ACPower\" is AC");
    OK(PVPowerSourceFromString(@"ac")            == PVPowerAC,      "\"ac\" is AC");
    OK(PVPowerSourceFromString(@"  AC  ")        == PVPowerAC,      "surrounding space is trimmed");
    OK(PVPowerSourceFromString(@"Battery Power") == PVPowerBattery, "IOKit's \"Battery Power\" is battery");
    OK(PVPowerSourceFromString(@"battery")       == PVPowerBattery, "\"battery\" is battery");

    // Everything else is Unknown, and Unknown is never AC. This is the whole
    // safety property of the classifier: a string nobody anticipated must not
    // be able to turn on the branch that spends energy.
    OK(PVPowerSourceFromString(nil)              == PVPowerUnknown, "nil is unknown");
    OK(PVPowerSourceFromString(@"")              == PVPowerUnknown, "empty is unknown");
    OK(PVPowerSourceFromString(@"AC Powerrr")    == PVPowerUnknown, "a near miss is unknown, not AC");
    OK(PVPowerSourceFromString(@"UPS Power")     == PVPowerUnknown, "an unhandled source is unknown");
    OK(PVPowerSourceFromString((NSString *)@42)  == PVPowerUnknown, "a non-string is unknown");

    // The override, which is what lets every test below run the same on a
    // laptop, a desktop and a machine with the charger being pulled in and out.
    PVPowerSource actual = PVCurrentPowerSource();
    OK(actual == PVPowerAC || actual == PVPowerBattery || actual == PVPowerUnknown,
       "this machine reports one of the three states");
    printf("  note  this machine reports %s\n",
           actual == PVPowerAC ? "AC" : actual == PVPowerBattery ? "battery" : "unknown");

    PVSetPowerSourceOverride(PVPowerBattery, YES);
    OK(PVCurrentPowerSource() == PVPowerBattery, "the override pins battery");
    PVSetPowerSourceOverride(PVPowerAC, YES);
    OK(PVCurrentPowerSource() == PVPowerAC, "the override pins AC");
    PVSetPowerSourceOverride(PVPowerUnknown, NO);
    OK(PVCurrentPowerSource() == actual, "clearing the override restores the machine's own answer");
}

#pragma mark - The render policy

static void TestRenderPolicy(void)
{
    printf("\nRender policy (power x tier x pressure)\n");

    const PVPowerSource powers[3] = { PVPowerUnknown, PVPowerBattery, PVPowerAC };
    int pi, t, pr;

    // Exhaustive. Three power states, four tiers, and pressure from none to
    // past the point where only previews are allowed -- 36 combinations, every
    // one of which some machine somewhere will actually be in.
    int checked = 0, violations = 0;
    for (pi = 0; pi < 3; pi++)
    for (t = 0; t < PVRamTierCount; t++)
    for (pr = 0; pr < 3; pr++) {
        PVRenderPolicy p = PVRenderPolicyFor(powers[pi], (PVRamTier)t, (NSUInteger)pr);
        checked++;
        // The invariant that matters: no policy may ask for more full-resolution
        // bitmaps than that tier's cache can hold. Violating it is the loop that
        // produced 51 full renders to display 6 pages, and it is invisible from
        // outside the process.
        if (!PVRenderPolicyFitsCache(p, (PVRamTier)t)) {
            violations++;
            printf("        power=%d tier=%d pressure=%d prefetch=%lu does not fit\n",
                   (int)powers[pi], t, pr, (unsigned long)p.fullPrefetchPages);
        }
        // Every field has to be usable as a number. A NaN safety factor would
        // make PVShouldRenderWhileMovingCost ignore the prediction silently,
        // which is a policy nobody chose.
        if (!(p.dwellSafetyFactor > 0) || !isfinite(p.dwellSafetyFactor)) violations++;
        if (!(p.minDwellSeconds   > 0) || !isfinite(p.minDwellSeconds))   violations++;
    }
    OK(checked == 36, "every power x tier x pressure combination was walked");
    OK(violations == 0, "no combination asks for more full bitmaps than its cache holds");

    // Battery is today's behaviour, to the field. This is the assertion that
    // says adding a power-aware policy did not change the case the project
    // exists to optimise -- if any of these four moves, every recorded battery
    // number in ENGINEERING.md stops describing the program.
    for (t = 0; t < PVRamTierCount; t++) {
        PVRenderPolicy b = PVRenderPolicyFor(PVPowerBattery, (PVRamTier)t, 0);
        char msg[160];
        snprintf(msg, sizeof msg, "tier %d on battery: prefetch is still PV_FULL_PREFETCH_PAGES", t);
        OK(b.fullPrefetchPages == PV_FULL_PREFETCH_PAGES, msg);
        snprintf(msg, sizeof msg, "tier %d on battery: the motion gate is still closed", t);
        OK(b.fullRendersWhileMoving == NO, msg);
        snprintf(msg, sizeof msg, "tier %d on battery: the dwell floor is still PV_MIN_VISIBLE_SECONDS", t);
        OK(fabs(b.minDwellSeconds - PV_MIN_VISIBLE_SECONDS) < 1e-12, msg);
    }

    // Unknown is battery, not AC. A machine that cannot answer must get the
    // conservative branch, and this is the test that stops a later refactor
    // from folding Unknown in with AC because "most Macs are plugged in".
    for (t = 0; t < PVRamTierCount; t++) {
        PVRenderPolicy u = PVRenderPolicyFor(PVPowerUnknown, (PVRamTier)t, 0);
        PVRenderPolicy b = PVRenderPolicyFor(PVPowerBattery, (PVRamTier)t, 0);
        char msg[160];
        snprintf(msg, sizeof msg, "tier %d: an unknown power source behaves exactly as battery", t);
        OK(u.fullPrefetchPages == b.fullPrefetchPages &&
           u.fullRendersWhileMoving == b.fullRendersWhileMoving &&
           fabs(u.dwellSafetyFactor - b.dwellSafetyFactor) < 1e-12 &&
           fabs(u.minDwellSeconds   - b.minDwellSeconds)   < 1e-12, msg);
    }

    // AC does something, and does it only where the cache can take it. On the
    // three tiers that existed before, the budget holds exactly three ceiling
    // sized pages -- two visible and one ahead -- so the deeper prefetch is
    // clamped away and only the motion gate opens. The huge tier is sized for
    // the fourth page and is the one place the deeper prefetch survives.
    OK(PVRenderPolicyFor(PVPowerAC, PVRamTierLarge, 0).fullRendersWhileMoving == YES,
       "AC opens the motion gate on the large tier");
    OK(PVRenderPolicyFor(PVPowerAC, PVRamTierLarge, 0).fullPrefetchPages == PV_FULL_PREFETCH_PAGES,
       "AC does not deepen prefetch on the large tier: the budget cannot hold it");
    OK(PVRenderPolicyFor(PVPowerAC, PVRamTierHuge, 0).fullPrefetchPages == PV_AC_FULL_PREFETCH_PAGES,
       "AC deepens prefetch on the huge tier, which is sized for it");
    OK(PVRenderPolicyFor(PVPowerAC, PVRamTierSmall, 0).fullPrefetchPages <= PV_FULL_PREFETCH_PAGES,
       "AC never deepens prefetch on a 2 GB machine");

    // Pressure outranks power, in both directions and at both thresholds.
    OK(PVRenderPolicyFor(PVPowerAC, PVRamTierHuge, 1).fullPrefetchPages == 0,
       "one pressure report stops full prefetch even on AC");
    OK(PVRenderPolicyFor(PVPowerAC, PVRamTierHuge, 1).fullRendersWhileMoving == NO,
       "one pressure report closes the motion gate even on AC");
    OK(PVRenderPolicyFor(PVPowerAC, PVRamTierHuge, 2).fullPrefetchPages == 0 &&
       fabs(PVRenderPolicyFor(PVPowerAC, PVRamTierHuge, 2).dwellSafetyFactor
            - PV_DWELL_SAFETY_BATTERY) < 1e-12,
       "a second pressure report puts an AC machine fully back on the cautious policy");
    OK(PVRenderPolicyFor(PVPowerAC, PVRamTierHuge, 99).fullPrefetchPages == 0,
       "sustained pressure does not wrap around into permission");
}

#pragma mark - The cost model

static void TestCostModel(void)
{
    printf("\nCost model\n");

    PVCostModel *m = [[PVCostModel alloc] init];
    CGSize page = CGSizeMake(2344, 3033);          // 7.11 Mpx, the showdown page
    double mpx  = (page.width * page.height) / 1.0e6;

    // Nothing is claimed until there is evidence. This is what makes the whole
    // feature safe to add: while it holds, every gate is running the constant
    // it ran before the cost model existed.
    OK([m predictedSecondsForPixels:page preview:NO] == 0,
       "an empty model offers no prediction");
    OK([m sampleCountForPreview:NO] == 0, "an empty model has no samples");

    int i;
    for (i = 0; i < PV_COST_MIN_SAMPLES - 1; i++)
        [m recordSeconds:0.657 pixels:page preview:NO];
    OK([m predictedSecondsForPixels:page preview:NO] == 0,
       "below PV_COST_MIN_SAMPLES there is still no prediction");
    [m recordSeconds:0.657 pixels:page preview:NO];
    OK([m predictedSecondsForPixels:page preview:NO] > 0,
       "at PV_COST_MIN_SAMPLES a prediction appears");

    // The measured heavy.pdf figure, fed in and read back. A model that cannot
    // reproduce a constant input is not measuring anything.
    double pred = [m predictedSecondsForPixels:page preview:NO];
    OK(fabs(pred - 0.657) < 0.01, "a constant 657 ms input predicts 657 ms");
    OK(fabs([m msPerMegapixelForPreview:NO] - (657.0 / mpx)) < 0.5,
       "the stored rate is the input in ms per megapixel");

    // Prediction scales with area, which is the one thing the rate is for.
    CGSize half = CGSizeMake(page.width / 2, page.height / 2);   // a quarter the pixels
    OK(fabs([m predictedSecondsForPixels:half preview:NO] - pred / 4.0) < 0.01,
       "a quarter of the pixels is predicted at a quarter of the time");

    // The two populations are independent. This is failure 2 from PVCostModel.h,
    // and it is the one that made two earlier attempts at this unusable: a
    // preview is 1/9 the pixels but re-walks the whole content stream, so its
    // rate per megapixel is nothing like a full page's and mixing them moved
    // the crossover by a factor of six.
    OK([m predictedSecondsForPixels:page preview:YES] == 0,
       "full-resolution samples say nothing about previews");
    CGSize prev = CGSizeMake(ceil(page.width / 3.0), ceil(page.height / 3.0));
    for (i = 0; i < PV_COST_MIN_SAMPLES; i++) [m recordSeconds:0.011 pixels:prev preview:YES];
    OK([m predictedSecondsForPixels:prev preview:YES] > 0, "previews get their own prediction");
    OK(fabs([m predictedSecondsForPixels:page preview:NO] - pred) < 1e-9,
       "recording previews does not move the full-resolution rate");
    // The two rates hold genuinely different values, and that is all that is
    // asserted. Which of them is larger is a property of the document, not of
    // this code: a text page pays the same content-stream interpretation over a
    // ninth of the pixels and comes out dearer per megapixel, while a vector
    // page's smaller destination fits a cache the whole page does not and comes
    // out cheaper -- `make band` measures both directions on the two fixtures.
    // A test that pinned the direction would be pinning heavy.pdf.
    OK(fabs([m msPerMegapixelForPreview:YES] - [m msPerMegapixelForPreview:NO]) > 1.0,
       "the two populations hold materially different rates");
    OK([m sampleCountForPreview:YES] == PV_COST_MIN_SAMPLES &&
       [m sampleCountForPreview:NO]  == PV_COST_MIN_SAMPLES,
       "each population counts only its own samples");

    // Convergence. The EWMA has to actually reach a step change, or a document
    // whose character shifts partway through is modelled by its first page
    // forever.
    for (i = 0; i < 60; i++) [m recordSeconds:0.011 pixels:page preview:NO];
    OK(fabs([m predictedSecondsForPixels:page preview:NO] - 0.011) < 0.002,
       "the rate converges on a sustained step change");

    // Rubbish in does not become policy. Every one of these is a real way for a
    // measurement to be wrong -- a clock that stepped, a zero-size bitmap, a
    // NaN out of a failed clamp -- and none of them may move a rate that decays
    // over a dozen samples.
    double before = [m msPerMegapixelForPreview:NO];
    [m recordSeconds:-1.0    pixels:page preview:NO];
    [m recordSeconds:0.0     pixels:page preview:NO];
    [m recordSeconds:NAN     pixels:page preview:NO];
    [m recordSeconds:INFINITY pixels:page preview:NO];
    [m recordSeconds:0.5     pixels:CGSizeMake(0, 0) preview:NO];
    [m recordSeconds:0.5     pixels:CGSizeMake(NAN, 100) preview:NO];
    OK(fabs([m msPerMegapixelForPreview:NO] - before) < 1e-12,
       "negative, zero, NaN, infinite and zero-area samples are all discarded");

    // The clamps, which exist so one absurd sample cannot put the scheduler
    // somewhere it will not come back from.
    [m reset];
    for (i = 0; i < 20; i++) [m recordSeconds:1.0e9 pixels:page preview:NO];
    OK([m msPerMegapixelForPreview:NO] <= PV_COST_MAX_MS_PER_MPX + 1e-6,
       "an absurdly slow sample is clamped rather than believed");
    [m reset];
    OK([m sampleCountForPreview:NO] == 0 && [m predictedSecondsForPixels:page preview:NO] == 0,
       "reset clears both populations");

    [m release];
}

#pragma mark - The cost-aware gate

static void TestCostAwareGate(void)
{
    printf("\nCost-aware suppression gate\n");

    const double kFresh = 0.0;
    const double kFast  = 20000.0;

    // Absence is the old policy, asserted across the same sweep the three
    // argument form is checked with rather than at a handful of points. This is
    // the property the whole design leans on: a machine where the cost model
    // never gathers enough samples runs exactly the scheduler it ran before.
    double speeds[] = { 0.0, PV_MIN_SCROLL_SPEED, 500.0, 3000.0, 60000.0 };
    double ages[]   = { 0.0, 0.1, PV_SPEED_FRESH_SECONDS, 1.0, HUGE_VAL, -1.0 };
    double dwells[] = { 0.0, 0.1, PV_MIN_VISIBLE_SECONDS, 0.3, 2.0, HUGE_VAL };
    int si, ai, di, mismatches = 0, compared = 0;
    for (si = 0; si < 5; si++)
    for (ai = 0; ai < 6; ai++)
    for (di = 0; di < 6; di++) {
        BOOL oldWay = PVShouldRenderWhileMoving(speeds[si], ages[ai], dwells[di]);
        BOOL newWay = PVShouldRenderWhileMovingCost(speeds[si], ages[ai], dwells[di],
                                                    0.0, PV_DWELL_SAFETY_BATTERY,
                                                    PV_MIN_VISIBLE_SECONDS);
        compared++;
        if (oldWay != newWay) mismatches++;
    }
    OK(compared == 180, "the equivalence sweep covered every combination");
    OK(mismatches == 0, "with no prediction the cost-aware gate is the old gate exactly");

    // The expensive direction. 657 ms is heavy.pdf, measured. A page with 0.4 s
    // of dwell passes the old constant comfortably and cannot possibly be
    // finished in time, which is the case one constant could not express.
    OK(PVShouldRenderWhileMoving(kFast, kFresh, 0.4),
       "the old gate admits a 0.4 s dwell without asking what it costs");
    OK(!PVShouldRenderWhileMovingCost(kFast, kFresh, 0.4, 0.657,
                                      PV_DWELL_SAFETY_BATTERY, PV_MIN_VISIBLE_SECONDS),
       "a 657 ms render is refused a 0.4 s window");
    OK(PVShouldRenderWhileMovingCost(kFast, kFresh, 2.0, 0.657,
                                     PV_DWELL_SAFETY_BATTERY, PV_MIN_VISIBLE_SECONDS),
       "the same render is allowed a 2 s window");

    // The floor is never lowered. 11 ms is text.pdf, also measured: even a
    // render the machine could do twenty times over does not license a page
    // that nobody can look at. PV_MIN_VISIBLE_SECONDS is a claim about eyes and
    // the cost model has no standing to overrule it.
    OK(!PVShouldRenderWhileMovingCost(kFast, kFresh, 0.05, 0.011,
                                      PV_DWELL_SAFETY_AC, PV_MIN_VISIBLE_SECONDS),
       "a cheap render still cannot rescue a 50 ms glimpse");
    OK(PVShouldRenderWhileMovingCost(kFast, kFresh, 0.3, 0.011,
                                     PV_DWELL_SAFETY_AC, PV_MIN_VISIBLE_SECONDS),
       "a cheap render is allowed anything above the floor");

    // The safety factor is a margin and points the right way.
    OK(!PVShouldRenderWhileMovingCost(kFast, kFresh, 0.60, 0.50, 1.5, PV_MIN_VISIBLE_SECONDS),
       "a 0.5 s render is refused a 0.6 s window at a 1.5x margin");
    OK(PVShouldRenderWhileMovingCost(kFast, kFresh, 0.60, 0.50, 1.0, PV_MIN_VISIBLE_SECONDS),
       "the same case passes with no margin, so the margin is what decided it");
    OK(PV_DWELL_SAFETY_BATTERY > PV_DWELL_SAFETY_AC,
       "battery is the more cautious of the two margins");

    // A prediction that is not a number must mean "no prediction", never
    // "threshold zero" -- which would render everything, during a flick, at
    // full resolution.
    int j;
    double junk[] = { NAN, INFINITY, -1.0, -0.0 };
    int junkRendered = 0;
    for (j = 0; j < 4; j++)
        if (PVShouldRenderWhileMovingCost(kFast, kFresh, 0.05, junk[j],
                                          PV_DWELL_SAFETY_BATTERY, PV_MIN_VISIBLE_SECONDS))
            junkRendered++;
    OK(junkRendered == 0, "a non-finite or negative prediction falls back to the floor");
    OK(!PVShouldRenderWhileMovingCost(kFast, kFresh, 0.05, 0.011, NAN, PV_MIN_VISIBLE_SECONDS) &&
       !PVShouldRenderWhileMovingCost(kFast, kFresh, 0.05, 0.011, PV_DWELL_SAFETY_AC, NAN),
       "a non-finite margin or floor falls back to PV_MIN_VISIBLE_SECONDS");

    // At rest nothing is ever suppressed, whatever it costs. A reader sitting
    // on a page gets a sharp page even if it takes a second and a half.
    OK(PVShouldRenderWhileMovingCost(0.0, kFresh, 0.001, 1.5,
                                     PV_DWELL_SAFETY_BATTERY, PV_MIN_VISIBLE_SECONDS),
       "at rest, an expensive page still renders");
    OK(PVShouldRenderWhileMovingCost(kFast, HUGE_VAL, 0.001, 1.5,
                                     PV_DWELL_SAFETY_BATTERY, PV_MIN_VISIBLE_SECONDS),
       "with no fresh speed measurement, an expensive page still renders");

    // Determinism, for the same reason the three-argument form is checked for
    // it: this function reads no clock and holds no state.
    int stable = 1;
    BOOL first = PVShouldRenderWhileMovingCost(kFast, kFresh, 0.4, 0.657, 1.5, 0.25);
    for (j = 0; j < 10000; j++)
        if (PVShouldRenderWhileMovingCost(kFast, kFresh, 0.4, 0.657, 1.5, 0.25) != first)
            stable = 0;
    OK(stable, "same inputs give the same answer across 10000 calls");
}

#pragma mark - Cost-aware eviction

// A bitmap of a given size, so the cache tests can control bytes exactly.
static CGImageRef MakeTestImage(size_t w, size_t h)
{
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs,
        (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return img;
}

static void TestCostAwareEviction(void)
{
    printf("\nCost-aware eviction\n");

    // Four bitmaps of identical size, so bytes cannot be what decides. Budget
    // holds three of them, so storing the fourth must evict exactly one.
    CGImageRef img = MakeTestImage(600, 800);
    OK(img != NULL, "test bitmap was created");
    if (!img) return;
    size_t each = PVImageBytes(img);
    CGSize px = CGSizeMake(600, 800);

    {
        PVImageCache *c = [[PVImageCache alloc] initWithBudget:each * 3 + each / 2];
        // Page 0 is expensive to rebuild, pages 1 and 2 are cheap. Stored oldest
        // first, so a pure LRU would throw page 0 away.
        [c setFullImage:img pixelSize:px forPage:0 renderSeconds:0.657];
        [c setFullImage:img pixelSize:px forPage:1 renderSeconds:0.011];
        [c setFullImage:img pixelSize:px forPage:2 renderSeconds:0.011];
        [c setFullImage:img pixelSize:px forPage:3 renderSeconds:0.011];
        OK([c fullImageCount] == 3, "the budget still holds exactly three full bitmaps");
        OK([c hasFullImageForPage:0 pixelSize:px],
           "the expensive page survived, though it was the least recently stored");
        OK(![c hasFullImageForPage:1 pixelSize:px],
           "the cheapest and oldest page is the one that went");
        [c release];
    }

    // The same sequence with no cost information anywhere degrades to the LRU
    // it replaced. This is what lets the two-argument setters stay truthful and
    // every test written against the old ordering keep describing the code.
    {
        PVImageCache *c = [[PVImageCache alloc] initWithBudget:each * 3 + each / 2];
        [c setFullImage:img pixelSize:px forPage:0];
        [c setFullImage:img pixelSize:px forPage:1];
        [c setFullImage:img pixelSize:px forPage:2];
        [c setFullImage:img pixelSize:px forPage:3];
        OK([c fullImageCount] == 3, "unmeasured: the budget still holds three");
        OK(![c hasFullImageForPage:0 pixelSize:px],
           "unmeasured: the least recently stored page is evicted, exactly as before");
        OK([c hasFullImageForPage:3 pixelSize:px], "unmeasured: the newest page is kept");
        [c release];
    }

    // Cost is per byte, not per render. A page that took twice as long but
    // occupies four times the bytes is worse value and must not win.
    {
        CGImageRef big = MakeTestImage(1200, 1600);
        if (big) {
            size_t bigBytes = PVImageBytes(big);
            PVImageCache *c = [[PVImageCache alloc] initWithBudget:bigBytes + each];
            [c setFullImage:big pixelSize:CGSizeMake(1200, 1600) forPage:0 renderSeconds:0.20];
            [c setFullImage:img pixelSize:px forPage:1 renderSeconds:0.10];
            // 0.20/4B vs 0.10/1B: the small one is twice the value per byte.
            [c setFullImage:img pixelSize:px forPage:2 renderSeconds:0.10];
            OK(![c hasFullImageForPage:0 pixelSize:CGSizeMake(1200, 1600)],
               "a big slow bitmap loses to a small quick one with better value per byte");
            [c release];
            CGImageRelease(big);
        }
    }

    // Aging. An expensive page that is never returned to must not be immortal:
    // the inflation term has to catch up with it, or one 657 ms page outlives
    // the document that contained it.
    {
        PVImageCache *c = [[PVImageCache alloc] initWithBudget:each * 3 + each / 2];
        [c setFullImage:img pixelSize:px forPage:0 renderSeconds:0.657];
        int k;
        for (k = 1; k < 40; k++)
            [c setFullImage:img pixelSize:px forPage:(NSUInteger)k renderSeconds:0.657];
        OK(![c hasFullImageForPage:0 pixelSize:px],
           "an expensive page nobody returns to is eventually evicted anyway");
        OK([c fullImageCount] == 3, "the budget is still respected after 40 stores");
        [c release];
    }

    // Pinning still outranks cost. A page on screen is one the layer above will
    // ask for again immediately, so evicting it frees nothing -- that has to
    // remain true whatever the cost model says about it.
    {
        PVImageCache *c = [[PVImageCache alloc] initWithBudget:each * 2];
        [c setPinnedPages:NSMakeRange(0, 2)];
        [c setFullImage:img pixelSize:px forPage:0 renderSeconds:0.001];
        [c setFullImage:img pixelSize:px forPage:1 renderSeconds:0.001];
        [c setFullImage:img pixelSize:px forPage:2 renderSeconds:9.999];
        OK([c hasFullImageForPage:0 pixelSize:px] && [c hasFullImageForPage:1 pixelSize:px],
           "cheap pinned pages survive an expensive unpinned one");
        [c release];
    }

    CGImageRelease(img);
}

static int RunUnit(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: pvsuite unit <test.pdf> [rotation.pdf] [real.pdf]\n"); return 2; }
        [NSApplication sharedApplication];   // AppKit needs this before views exist

        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        NSError *err = nil;
        PVPDFSource *src = [[PVPDFSource alloc] initWithURL:url error:&err];
        if (!src) { fprintf(stderr, "cannot open %s: %s\n", argv[1],
                            [[err localizedDescription] UTF8String]); return 2; }

        TestSource(src);
        TestSourceManyRenders(src);
        TestDispatchConstants();
        TestRenderSpeed(src);
        TestCache();
        TestCacheFullImageCountCap();
        TestCacheConverges();
        TestLayout(src);
        TestRenderQueue(src, url);
        TestStateStore();
        TestStateStoreCorruptFile();
        TestOversizedPageGeometry();
        TestSliverPageRatioBound();
        TestRunningLocation();
        TestSleepSavesReadingPosition();
        TestRenderSuppressionPolicy();
        TestRamTierInvariants();
        TestResidentCensus();
        TestSchedulerBudgetArithmetic();
        TestPowerSource();
        TestRenderPolicy();
        TestCostModel();
        TestCostAwareGate();
        TestCostAwareEviction();
        TestInFlightFullCap(src, url);
        TestTwoLaneFullCap(src, url);
        TestArrowScrollStep();
        TestScenarioReplay();
        if (argc > 2) TestRotation([NSString stringWithUTF8String:argv[2]]);
        if (argc > 3) TestArbitrary([NSString stringWithUTF8String:argv[3]]);

        printf("\n%d passed, %d failed\n", gPass, gFail);
        // The fixture source, handed back. A leak in the harness is small, but
        // this harness is one of the things that argues the app does not leak,
        // and `leaks` cannot tell whose object it is looking at.
        int result = gFail ? 1 : 0;
        [src release];
        return result;
    }
}

#pragma mark ======================== ui ========================

// Declared, not added: every one of these already exists on the class. The
// controller has no reason to advertise them, and the test has no reason to
// reach around them.
// Counts what -updateVisibleContent hands to the render queue.
//
// -setDesiredRequests: is the only way work reaches the queue, so intercepting
// it counts requests as the scheduler issued them -- before the queue's own
// coalescing drops duplicates, which is what we want here: the question is what
// the scheduler asked for, not what survived.
static BOOL       PVCountRequests = NO;
static NSUInteger PVFullRequestCount = 0;
static NSUInteger PVPreviewRequestCount = 0;
// Which pages were named, not just how many. A count answers "how much work",
// and the horizontal cull needs the other question: "work on WHICH page".
static NSMutableIndexSet *PVRequestedPages = nil;

@interface PVRenderQueue (PVTestCounting)
- (void)pvCountingSetDesiredRequests:(NSArray *)requests;
@end

@implementation PVRenderQueue (PVTestCounting)
- (void)pvCountingSetDesiredRequests:(NSArray *)requests
{
    if (PVCountRequests) {
        NSUInteger i, n = [requests count];
        for (i = 0; i < n; i++) {
            PVRenderRequest *r = [requests objectAtIndex:i];
            if (![r isKindOfClass:[PVRenderRequest class]]) continue;
            if (r->preview) PVPreviewRequestCount++; else PVFullRequestCount++;
            [PVRequestedPages addIndex:r->page];
        }
    }
    // Swapped, so this name now reaches the original implementation.
    [self pvCountingSetDesiredRequests:requests];
}
@end

// Idempotent, and it has to be: method_exchangeImplementations is an
// involution, so calling this twice puts the original implementation back and
// silently stops the counting -- which does not fail, it just makes every
// count zero. That is exactly what happened the first time two suites in one
// binary both asked for the hook: four assertions about what the scheduler
// requested failed, reporting the swizzle's absence as the scheduler's silence.
static void PVInstallRequestCounter(void)
{
    static BOOL installed = NO;
    if (installed) return;
    Method a = class_getInstanceMethod([PVRenderQueue class], @selector(setDesiredRequests:));
    Method b = class_getInstanceMethod([PVRenderQueue class], @selector(pvCountingSetDesiredRequests:));
    if (a && b) { method_exchangeImplementations(a, b); installed = YES; }
}

// Mirrors PV_MAX_RENDER_ATTEMPTS, which is private to PVWindowController.m.
// Deliberately larger, so a loop that means "exhaust the attempts" keeps
// meaning that if the real limit is ever raised.
#define PV_UITEST_MAX_ATTEMPTS 8

@interface PVWindowController (PVTestHooks)
- (BOOL)pageIsUnrenderable:(NSUInteger)page;
- (BOOL)pageIsUnrenderable:(NSUInteger)page preview:(BOOL)preview;
- (BOOL)thumbIsUnrenderable:(NSUInteger)page;
- (void)notePageFailed:(NSUInteger)page preview:(BOOL)preview;
- (void)resetRenderFailures;
- (void)updateVisibleContent;
- (void)memoryPressure:(NSNotification *)note;
- (void)showSidebar;
- (void)hideSidebar;
- (void)renderQueue:(PVRenderQueue *)queue didFailPage:(NSUInteger)page
          pixelSize:(CGSize)px preview:(BOOL)preview;
- (BOOL)worthRenderingDuringScroll:(NSUInteger)page;
- (NSUInteger)currentPageWithFraction:(CGFloat *)outFraction;
- (double)secondsPageStaysVisible:(NSUInteger)page;
- (void)willStartLiveScroll:(NSNotification *)note;
- (void)didEndLiveScroll:(NSNotification *)note;
// The bounds-change handler, which is where the wanted-set rebuild early-out
// lives. Missing here it still dispatched -- the selector exists -- but the
// compiler inferred a return type of id for a void method and said so on every
// build, and a warning that is always present is a warning nobody reads.
- (void)clipBoundsChanged:(NSNotification *)note;
- (void)scrollToPage:(NSUInteger)page fraction:(CGFloat)fraction;
- (void)scrollClipTo:(NSPoint)p;
- (void)pageViewWillMagnify:(PVPageView *)v atPoint:(NSPoint)p;
- (void)pageView:(PVPageView *)v magnifyBy:(CGFloat)factor;
- (void)pageViewDidMagnify:(PVPageView *)v;
- (void)pageViewSmartMagnify:(PVPageView *)v atPoint:(NSPoint)p;
- (void)scrollViewFrameChanged:(NSNotification *)note;
- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar *)tb;
- (NSApplicationPresentationOptions)window:(NSWindow *)window
     willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)proposedOptions;
// Reached only by the stress suite, which used to declare a second category of
// its own that re-stated eight of the selectors above. One list, so a change to
// the controller has one place here to disagree with.
- (void)windowOcclusionChanged:(NSNotification *)note;
- (void)backingPropertiesChanged:(NSNotification *)note;
@end

// Stands in for a real drag. Only -draggingPasteboard is consulted by the drop
// view, so this is all the protocol surface the test needs.
@interface PVFakeDrag : NSObject { NSPasteboard *_pb; }
- (id)initWithPaths:(NSArray *)paths;
- (NSPasteboard *)draggingPasteboard;
@end

@implementation PVFakeDrag
- (id)initWithPaths:(NSArray *)paths
{
    self = [super init];
    if (self) {
        _pb = [[NSPasteboard pasteboardWithUniqueName] retain];
        [_pb declareTypes:[NSArray arrayWithObject:NSFilenamesPboardType] owner:nil];
        [_pb setPropertyList:paths forType:NSFilenamesPboardType];
    }
    return self;
}
- (NSPasteboard *)draggingPasteboard { return _pb; }
- (void)dealloc { [_pb releaseGlobally]; [_pb release]; [super dealloc]; }
@end

// A memory-pressure notification carrying a level, exactly as PVAppDelegate
// posts one. The level matters: the controller's response to CRITICAL is not
// its response to WARN, and a notification with no level at all is read as WARN.
static NSNotification *PressureNote(unsigned long flags)
{
    NSDictionary *info = [NSDictionary dictionaryWithObject:
        [NSNumber numberWithUnsignedLong:flags] forKey:@"PVMemoryPressureFlags"];
    return [NSNotification notificationWithName:PVMemoryPressureNotification
                                         object:nil
                                       userInfo:info];
}

// Drive the viewport the way an input device does, and count what the scheduler
// asks for.
//
// Both devices reach the scheduler through exactly one door. -keyDown: calls
// -[PVPageView scrollByPoints:], which calls -[NSClipView scrollToPoint:]; the
// trackpad and wheel are handled by NSScrollView itself, because PVPageView
// deliberately does NOT override -scrollWheel: (that is the precondition for
// +isCompatibleWithResponsiveScrolling). Both end at the same clip-view bounds
// change and therefore at -clipBoundsChanged:.
//
// So moving the clip view directly is not an approximation of either device --
// it is the code both of them run. The ONLY thing that differs between them is
// the pair of live-scroll notifications AppKit posts for gestures and not for
// keys, and `gesture` adds exactly those.
//
// usleep rather than the run loop, so both variants present the same elapsed
// time between bounds changes and are therefore judged at the same speed. The
// bounds notification is posted synchronously by -scrollToPoint:, so nothing
// here needs the run loop to run.
static void DriveScroll(PVWindowController *wc, NSScrollView *sv,
                        BOOL gesture, CGFloat step, useconds_t gapUs, int steps,
                        int warmup, NSUInteger *outFulls, NSUInteger *outPreviews)
{
    NSClipView *clip = [sv contentView];

    // Both variants start from rest with no speed history, which is what
    // -willStartLiveScroll: does for a gesture. Stated for the keyboard variant
    // too, or the comparison would be between a fresh gesture and whatever the
    // previous phase of the test left behind.
    [wc setValue:[NSNumber numberWithDouble:0.0] forKey:@"_scrollSpeed"];
    [wc setValue:[NSNumber numberWithDouble:0.0] forKey:@"_lastScrollTime"];

    if (gesture)
        [[NSNotificationCenter defaultCenter]
            postNotificationName:NSScrollViewWillStartLiveScrollNotification object:sv];

    // `warmup` moves happen before the counters are armed.
    //
    // Speed is computed from the gap between two bounds changes, so the FIRST
    // change of any movement carries no speed measurement at all, and the policy
    // renders when it has no evidence -- deliberately, and documented in
    // PVShouldRenderWhileMoving. A gesture is exempt from that one event because
    // AppKit says a scroll is beginning before it begins; the keyboard has no
    // such announcement, and nothing can invent one from a single key press that
    // is genuinely indistinguishable from a deliberate page-down.
    //
    // That one event is the whole of the difference between the devices. With
    // warmup 0 it is included and the counts differ by it; with warmup 1 the
    // comparison is between two movements that both have a speed, which is where
    // the claim "one path, one policy" is either true or false.
    PVFullRequestCount = 0; PVPreviewRequestCount = 0;

    int i;
    for (i = 0; i < steps; i++) {
        if (i == warmup) {
            PVFullRequestCount = 0; PVPreviewRequestCount = 0;
            PVCountRequests = YES;
        }
        NSRect vis = [clip documentVisibleRect];
        CGFloat maxY = NSHeight([[sv documentView] frame]) - NSHeight(vis);
        CGFloat y = NSMinY(vis) + step;
        if (y > maxY) y = maxY;
        if (y < 0) y = 0;
        [clip scrollToPoint:NSMakePoint(NSMinX(vis), y)];
        [sv reflectScrolledClipView:clip];
        if (gapUs) usleep(gapUs);
    }

    PVCountRequests = NO;
    if (outFulls)    *outFulls    = PVFullRequestCount;
    if (outPreviews) *outPreviews = PVPreviewRequestCount;

    if (gesture)
        [[NSNotificationCenter defaultCenter]
            postNotificationName:NSScrollViewDidEndLiveScrollNotification object:sv];
}

static void Snap(NSWindow *win, NSString *path)
{
    NSView *v = [win contentView];
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:[v bounds]];
    [v cacheDisplayInRect:[v bounds] toBitmapImageRep:rep];
    NSData *png = [rep representationUsingType:NSPNGFileType properties:
                   [NSDictionary dictionary]];
    [png writeToFile:path atomically:YES];
    printf("  snapshot -> %s\n", [path UTF8String]);
}

static int RunUI(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: pvsuite ui <pdf> <outdir>\n"); return 2; }
        NSString *pdf = [NSString stringWithUTF8String:argv[1]];
        NSString *out = [NSString stringWithUTF8String:argv[2]];
        [[NSFileManager defaultManager] createDirectoryAtPath:out
                                 withIntermediateDirectories:YES attributes:nil error:NULL];

        [NSApplication sharedApplication];
        PVInstallRequestCounter();
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        // Pinned to battery for the whole suite, and this is load-bearing
        // rather than tidy.
        //
        // Almost everything below asserts the scheduler's cautious behaviour --
        // no full-resolution bitmaps while the document moves, prefetch of one
        // page, the motion gate reporting what it withheld. That is the battery
        // policy. On mains power PVRenderPolicyFor deliberately opens the motion
        // gate, so on a desktop, or on a laptop that happens to be charging,
        // those assertions would fail for a reason that is not a regression --
        // and, far worse, would pass or fail depending on where the machine was
        // plugged in when the suite ran. A gate whose verdict depends on that is
        // not a gate.
        //
        // The AC branch is not skipped: TestPowerAwareScheduling below turns it
        // on explicitly, asserts what it changes, and turns it back off. This is
        // the same reason Tools/showdown.sh pins -PVPowerState battery.
        PVSetPowerSourceOverride(PVPowerBattery, YES);

        NSURL *url = [NSURL fileURLWithPath:pdf];

        // Start from a known reading state. Without this the run inherits
        // whatever the previous run saved, so the zoom ratchets upwards on
        // every invocation until it pins at PV_MAX_ZOOM and the [4] snapshot
        // stops meaning anything. Only this fixture's entry is touched.
        [[PVStateStore sharedStore] recordForURL:url
                                            page:0
                                        fraction:0.0
                                        zoomMode:PVZoomModeFitWidth
                                            zoom:1.0
                                         sidebar:NO
                                         columns:1
                                     windowFrame:nil];

        NSError *err = nil;
        PVPDFSource *src = [[PVPDFSource alloc] initWithURL:url error:&err];
        if (!src) { fprintf(stderr, "open failed\n"); return 2; }

        PVWindowController *wc = [[PVWindowController alloc] initWithSource:src url:url];
        [wc showWindow:nil];
        [[wc window] setFrame:NSMakeRect(120, 120, 900, 760) display:YES];
        Pump(2.5);

        printf("\n[1] default view, fit width\n");
        Snap([wc window], [out stringByAppendingPathComponent:@"01-default.png"]);

        // Toolbar centring, checked at two very different window widths. This
        // is the regression that showed up as "the toolbar is not centred on an
        // iMac": with a plain trailing flexible space the controls drifted
        // further right the wider the window got.
        printf("\n[1b] the toolbar keeps its shape as the window widens\n");
        {
            // Checked on the LIVE toolbar rather than on freshly built items,
            // because what is being pinned is how AppKit lays them out -- which
            // is the part that has changed repeatedly between 10.9 and now, and
            // the part that produced the clipped zoom control on Mavericks.
            CGFloat widths[] = { 700, 900, 1900 };
            unsigned wi;
            for (wi = 0; wi < sizeof(widths)/sizeof(*widths); wi++) {
                NSRect f = [[wc window] frame];
                f.size.width = widths[wi];
                [[wc window] setFrame:f display:YES];
                Pump(0.4);

                NSArray *items = [[[wc window] toolbar] items];
                NSView *sidebar = nil, *zoom = nil;
                NSUInteger k;
                for (k = 0; k < [items count]; k++) {
                    NSToolbarItem *it = [items objectAtIndex:k];
                    if ([[it itemIdentifier] isEqualToString:@"PVToolbarSidebar"]) sidebar = [it view];
                    if ([[it itemIdentifier] isEqualToString:@"PVToolbarZoom"])    zoom    = [it view];
                }
                char msg[160];
                if (!sidebar || !zoom || ![sidebar window] || ![zoom window]) {
                    snprintf(msg, sizeof msg,
                             "both toolbar controls are on screen at %.0f pt wide", widths[wi]);
                    OK(NO, msg);
                    continue;
                }

                NSRect sr = [sidebar convertRect:[sidebar bounds] toView:nil];
                NSRect zr = [zoom    convertRect:[zoom    bounds] toView:nil];
                CGFloat windowW = NSWidth([[[wc window] contentView] bounds]);

                // Both fully inside the window, and not on top of each other.
                //
                // Deliberately not "leading" or "trailing": which edge they sit
                // at is the system's own convention and differs by release --
                // 10.9 packs them left with the title on its own row, macOS 11
                // and later reserve the leading region for the title and lay
                // them out trailing. Asserting one of those would be asserting
                // against the platform on the other. What must hold on every
                // release is that they are on screen, whole, and separate.
                snprintf(msg, sizeof msg,
                         "both controls are wholly inside the window at %.0f pt wide "
                         "(sidebar %.0f..%.0f, zoom %.0f..%.0f, window %.0f)",
                         widths[wi], NSMinX(sr), NSMaxX(sr), NSMinX(zr), NSMaxX(zr), windowW);
                // The couple of points of slack between the two is AppKit's own
                // item spacing: the boxes abut and the bezels sit inset within
                // them, so their frames touch by a point or two without the
                // controls ever overlapping on screen.
                OK(NSMinX(sr) >= -0.5 && NSMaxX(zr) <= windowW + 0.5 &&
                   NSMinX(zr) >= NSMaxX(sr) - 4.0, msg);

                // Same height, same vertical centre: they have to read as one
                // group, which they did not when they were built from
                // unrelated numbers.
                snprintf(msg, sizeof msg,
                         "the two controls share a height and a baseline at %.0f pt wide",
                         widths[wi]);
                OK(fabs(NSHeight(sr) - NSHeight(zr)) < 1.0 &&
                   fabs(NSMidY(sr) - NSMidY(zr)) < 1.0, msg);

                // Equal wrapper views are not enough.  Mavericks gives a
                // textured NSButton and a textured NSSegmentedControl
                // different native bezel heights inside those wrappers.  The
                // thumbnail control intentionally uses the same one-segment
                // segmented control as +/- so the pixels, not just the boxes,
                // stay aligned on that release.
                NSArray *ssubs = [sidebar subviews];
                NSArray *zsubs = [zoom subviews];
                NSView *scontrol = ([ssubs count] > 0) ? [ssubs objectAtIndex:0] : nil;
                NSView *zcontrol = ([zsubs count] > 0) ? [zsubs objectAtIndex:0] : nil;
                snprintf(msg, sizeof msg,
                         "the thumbnail and +/- use equal-height segmented controls at %.0f pt wide",
                         widths[wi]);
                OK([scontrol isKindOfClass:[NSSegmentedControl class]] &&
                   [zcontrol isKindOfClass:[NSSegmentedControl class]] &&
                   fabs(NSHeight([scontrol frame]) - NSHeight([zcontrol frame])) < 0.01,
                   msg);

                // And neither is clipped by the item that holds it: the zoom
                // control used to be given 74 points for two 36-point segments,
                // leaving nothing for the bezel and cutting the outer edge off
                // both magnifiers.  (zsubs is the one fetched above.)
                snprintf(msg, sizeof msg, "the zoom control is not clipped at %.0f pt wide",
                         widths[wi]);
                OK([zsubs count] > 0 &&
                   NSMaxX([(NSView *)[zsubs objectAtIndex:0] frame]) <= NSWidth([zoom bounds]) + 0.01,
                   msg);
            }
        }
        [[wc window] setFrame:NSMakeRect(120, 120, 900, 760) display:YES];
        Pump(0.4);

        // Both windows accept a dropped PDF over their whole surface, so the
        // accept/reject decision is worth pinning down -- and so is the fact
        // that it is the content view doing it, which is what makes the drop
        // work over the page, the sidebar and the margins rather than over one
        // panel in the empty state.
        printf("\n[1c] both windows accept a dropped PDF and refuse anything else\n");
        {
            PVWelcomeWindowController *welcome = [PVWelcomeWindowController sharedController];
            id drop = [[welcome window] contentView];

            PVFakeDrag *pdfDrag = [[PVFakeDrag alloc]
                initWithPaths:[NSArray arrayWithObject:pdf]];
            PVFakeDrag *txtDrag = [[PVFakeDrag alloc]
                initWithPaths:[NSArray arrayWithObject:@"/tmp/not-a-document.txt"]];
            PVFakeDrag *mixDrag = [[PVFakeDrag alloc]
                initWithPaths:[NSArray arrayWithObjects:@"/tmp/x.txt", pdf, nil]];

            OK([drop draggingEntered:(id)pdfDrag] == NSDragOperationCopy,
               "a dragged PDF is accepted");
            OK([drop draggingEntered:(id)txtDrag] == NSDragOperationNone,
               "a dragged non-PDF is refused");
            OK([drop draggingEntered:(id)mixDrag] == NSDragOperationCopy,
               "a mixed drag containing a PDF is accepted");
            OK([drop prepareForDragOperation:(id)txtDrag] == NO,
               "a non-PDF drop is rejected before it is performed");

            // The document window takes drops too, over its whole surface.
            id docDrop = [[wc window] contentView];
            OK([docDrop isKindOfClass:[PVDropView class]],
               "the document window's content view is the drop target");
            OK([docDrop draggingEntered:(id)pdfDrag] == NSDragOperationCopy,
               "a PDF dropped on an open document window is accepted");
            OK([docDrop draggingEntered:(id)txtDrag] == NSDragOperationNone,
               "a non-PDF dropped on a document window is refused");
            OK([docDrop isDropHighlighted],
               "a pending drop is registered as pending");
            [docDrop draggingExited:(id)txtDrag];
            OK(![docDrop isDropHighlighted], "and stops being pending when the drag leaves");

            // The page view sits on top of it and claims no drag types of its
            // own, which is what lets AppKit walk up to the content view. A
            // drag registered on the page view instead would be the old bug in
            // a new place: a drop target the size of one control.
            NSView *pv = [wc valueForKey:@"_pageView"];
            OK([[pv registeredDraggedTypes] count] == 0,
               "the page view claims no drags, so they reach the window's own target");

            [pdfDrag release]; [txtDrag release]; [mixDrag release];
        }

        // Recent documents come from NSDocumentController, which is already
        // keeping that list for the Open Recent menu and for the system's own
        // document history. A second list here would be a second thing to get
        // out of step, so what is checked is that the window mirrors that one
        // exactly -- not that some private copy has the right contents.
        //
        // The list itself cannot be written from here: NSDocumentController
        // matches a noted URL against the app's CFBundleDocumentTypes, and a
        // bare test executable has no Info.plist to declare any. It is the
        // bundle that makes recents work, and `make verify` is what checks the
        // bundle. So this drives -reloadRecents against whatever the system
        // does return, including nothing, and pins the behaviour either way.
        printf("\n[1d] the empty state offers the documents you had open\n");
        {
            PVWelcomeWindowController *welcome = [PVWelcomeWindowController sharedController];
            [welcome reloadRecents];

            NSTableView  *table  = [welcome valueForKey:@"_recentTable"];
            NSScrollView *scroll = [welcome valueForKey:@"_recentScroll"];
            NSArray      *recents = [welcome valueForKey:@"_recents"];
            OK(table != nil && scroll != nil, "the empty state has a recent-documents list");
            OK([table numberOfRows] == (NSInteger)[recents count],
               "the table agrees with the list behind it");

            // Whatever the system offers, every entry shown must be a file that
            // is still there: a row that opens an error panel is worse than no
            // row. Nothing is offered that -recentDocumentURLs did not name.
            NSArray *system = [[NSDocumentController sharedDocumentController] recentDocumentURLs];
            BOOL allReal = YES, allFromSystem = YES;
            NSUInteger ri;
            for (ri = 0; ri < [recents count]; ri++) {
                NSURL *u = [recents objectAtIndex:ri];
                if (![[NSFileManager defaultManager] fileExistsAtPath:[u path]]) allReal = NO;
                if (![system containsObject:u]) allFromSystem = NO;
            }
            OK(allReal, "every recent offered is a file that still exists");
            OK(allFromSystem, "nothing is offered that the document history did not name");
            OK([recents count] <= [system count],
               "the list is a filtered view of the history, never an addition to it");

            // The empty state has to be handled, and on this run it is the
            // state under test: with nothing to show, the list goes away and
            // the window says what to do instead of showing an empty box.
            OK([scroll isHidden] == ([recents count] == 0),
               "the list is on screen when there is something to show, and not when there is not");

            // A row has to be buildable and has to name its file, or it is a
            // row that cannot be clicked. Built directly so this is checked
            // even when the history is empty.
            NSTableCellView *row = (NSTableCellView *)[welcome tableView:table
                                        viewForTableColumn:[[table tableColumns] objectAtIndex:0]
                                                       row:0];
            if ([recents count] > 0) {
                OK(row != nil, "a row view is produced for the first recent");
                OK([[[row textField] stringValue] length] > 0, "the row names the document");
                OK([[row imageView] image] != nil, "the row shows the file's own icon");
            } else {
                OK(row == nil, "no row is produced when there is nothing to show");
                printf("  (document history is empty in a bare test binary; the bundle's\n");
                printf("   CFBundleDocumentTypes is what populates it -- see Info.plist)\n");
            }
        }

        printf("\n[2] thumbnails shown on request\n");
        [wc toggleSidebar:nil];
        Pump(3.0);
        Snap([wc window], [out stringByAppendingPathComponent:@"02-thumbnails.png"]);

        printf("\n[3] jump to page 37\n");
        [wc goToPageNumber:37];
        Pump(2.5);
        Snap([wc window], [out stringByAppendingPathComponent:@"03-page37.png"]);

        printf("\n[4] zoom in twice\n");
        [wc zoomIn:nil];
        [wc zoomIn:nil];
        Pump(2.5);
        Snap([wc window], [out stringByAppendingPathComponent:@"04-zoomed.png"]);

        printf("\n[5] thumbnails hidden again\n");
        [wc toggleSidebar:nil];
        Pump(1.0);
        Snap([wc window], [out stringByAppendingPathComponent:@"05-nothumbs.png"]);

        // The on-demand sidebar makes exactly one promise: it costs nothing
        // once it is put away. A thumbnail rasterised just before the sidebar
        // closed used to arrive afterwards and quietly re-fill the cache
        // -hideSidebar had emptied, where it then sat until the sidebar was
        // next opened. Re-opening and immediately closing reproduces that
        // ordering: renders are certainly in flight at the moment of the hide.
        printf("\n[5b] closing the sidebar releases everything behind it\n");
        {
            [wc showSidebar];
            Pump(0.25);                       // long enough to start, not to finish

            // Retained across the hide on purpose. -hideSidebar releases the
            // controller's references, and the point of the next few lines is
            // that they are gone -- so the only way to keep asking questions
            // about them is to hold them here.
            PVImageCache  *tc = [[wc valueForKey:@"_thumbCache"]  retain];
            PVRenderQueue *tq = [[wc valueForKey:@"_thumbQueue"]  retain];
            PVPDFSource   *ts = [[wc valueForKey:@"_thumbSource"] retain];
            OK(tc && tq && ts,
               "the sidebar builds its own source, queue and cache");

            [wc hideSidebar];

            // The promise the on-demand sidebar makes is that it costs nothing
            // once it is put away -- not "nothing except a second PVPDFSource
            // with its own snapshot and helper process, a render queue with its
            // own worker, a cache, a strip view and a bounds observer", which is
            // what it used to keep until the document closed.
            OK([wc valueForKey:@"_thumbCache"]  == nil, "hiding it releases the cache");
            OK([wc valueForKey:@"_thumbQueue"]  == nil, "...and the render queue");
            OK([wc valueForKey:@"_thumbSource"] == nil, "...and the second PDF source");
            OK([wc valueForKey:@"_thumbView"]   == nil, "...and the strip view");

            OK([tc entryCount] == 0, "the thumbnail cache is emptied on the way out");
            // Everything in flight at the moment of the hide has now been
            // delivered -- the queue only reports idle once its results have
            // reached the main thread. The queue outlives the controller's
            // reference because its worker block retains it, which is what makes
            // releasing it mid-render safe.
            OK(PumpUntil(^{ return [tq isIdle]; }, 20.0),
               "the thumbnail queue drains after the sidebar is hidden");
            OK([tc entryCount] == 0,
               "a thumbnail delivered after the sidebar closed is not stored");
            OK([tc byteCount] == 0, "no thumbnail bytes are held once the sidebar is away");

            [tc release];
            [tq release];
            [ts release];
        }

        // The strip rebuilds its wanted set only when the visible range changes
        // -- the same early-out -clipBoundsChanged: has for the page view, and
        // worth it for the same reason: dragging the strip posts a bounds
        // notification per frame, and an identical range gives an identical
        // answer.
        //
        // The failure it can cause is the one pinned here. -hideSidebar empties
        // the thumbnail cache, and reopening the strip at the page it was closed
        // on produces the identical visible range -- so an early-out that
        // remembered that range across the hide would recognise it, decline to
        // ask, and leave a sidebar of empty boxes until something else moved it.
        // Driven through the real show/hide rather than by reading the flag,
        // because the flag being right is not the claim; the thumbnails coming
        // back is.
        printf("\n[5c] the thumbnail early-out is reset when the cache is emptied\n");
        {
            // Re-read after each -showSidebar: the cache is built by the show
            // and released by the hide, so it is a different object each time
            // rather than one long-lived cache being emptied and refilled.
            [wc showSidebar];
            PVImageCache *tc = [[wc valueForKey:@"_thumbCache"] retain];
            OK(PumpUntil(^{ return (BOOL)([tc entryCount] > 0); }, 20.0),
               "reopening the sidebar renders thumbnails");
            NSUInteger firstFill = [tc entryCount];
            [wc hideSidebar];
            OK([tc entryCount] == 0, "hiding it empties the cache again");
            [tc release];

            [wc showSidebar];
            PVImageCache *tc2 = [[wc valueForKey:@"_thumbCache"] retain];
            OK(PumpUntil(^{ return (BOOL)([tc2 entryCount] >= firstFill); }, 20.0),
               "reopening at the same page refills it: the early-out is not sticky");
            [tc2 release];
            [wc hideSidebar];
        }

        // A page CoreGraphics will not rasterise never reaches the cache, so
        // the wanted-set names it again on the very next scroll event and the
        // queue tries it again -- for as long as the document stays open. The
        // attempt limit is what makes that terminate.
        printf("\n[5c] a page that cannot be rendered stops being asked for\n");
        {
            PVRenderQueue *pq = [wc valueForKey:@"_pageQueue"];
            [wc resetRenderFailures];
            OK(![wc pageIsUnrenderable:5 preview:NO], "a page starts out renderable");
            [wc renderQueue:pq didFailPage:5 pixelSize:CGSizeMake(10, 10) preview:NO];
            OK(![wc pageIsUnrenderable:5 preview:NO], "one failure is not enough to give up");
            [wc renderQueue:pq didFailPage:5 pixelSize:CGSizeMake(10, 10) preview:NO];
            OK(![wc pageIsUnrenderable:5 preview:NO], "two failures are not enough either");
            [wc renderQueue:pq didFailPage:5 pixelSize:CGSizeMake(10, 10) preview:NO];
            OK([wc pageIsUnrenderable:5 preview:NO], "the third failure retires the full bitmap");
            OK(![wc pageIsUnrenderable:6 preview:NO],
               "retiring one page does not retire its neighbour");

            // The counters are per bitmap, not per page. A 28 MB full render
            // can fail for want of contiguous memory while the 3 MB preview of
            // the same page succeeds every time -- and when one counter served
            // both, the expensive failure retired the cheap bitmap with it, so
            // a page that could have shown something showed nothing at all.
            OK(![wc pageIsUnrenderable:5 preview:YES],
               "a retired full bitmap does not retire the page's preview");
            OK(![wc pageIsUnrenderable:5],
               "...so the page as a whole is still worth asking about");
            OK(![wc thumbIsUnrenderable:5],
               "...and its thumbnail is a third, separate question");

            NSUInteger attempt;
            for (attempt = 0; attempt < PV_UITEST_MAX_ATTEMPTS; attempt++)
                [wc renderQueue:pq didFailPage:5
                      pixelSize:CGSizeMake(10, 10) preview:YES];
            OK([wc pageIsUnrenderable:5],
               "only once both bitmaps are retired is the page itself given up on");

            // Asking again after nothing has changed must not restart the
            // cycle; asking again after the pixel size changes must.
            [wc updateVisibleContent];
            OK([wc pageIsUnrenderable:5], "a plain refresh does not un-retire the page");
            [wc zoomIn:nil];
            Pump(0.3);
            OK(![wc pageIsUnrenderable:5],
               "a zoom asks CoreGraphics a different question, so the page is retried");
            [wc zoomOut:nil];
            Pump(0.5);
        }

        // The same question asked of the failures that are NOT about the page.
        //
        // Every failure used to arrive as a bare NULL, so a page starved of
        // shared memory for one instant was counted exactly like a page
        // CoreGraphics will never draw: three of them and the page was blank for
        // the session. Now the renderer says which kind it was, and only the
        // deterministic kind spends an attempt.
        printf("\n[5c2] transient failures are retried; a missing renderer is not\n");
        {
            PVRenderQueue *pq = [wc valueForKey:@"_pageQueue"];
            CGSize px = CGSizeMake(10, 10);
            [wc resetRenderFailures];

            // Three transient failures -- the number that permanently retires a
            // page when the reason is not carried -- must not retire this one.
            //
            // "Not retired" is not the same as "ask again immediately", and the
            // two assertions below are that distinction. Straight after a
            // transient failure the page reports unrenderable, because a backoff
            // is outstanding and re-requesting inside it would be the spin this
            // is replacing. What matters is that the backoff EXPIRES.
            int i;
            for (i = 0; i < 3; i++)
                [wc renderQueue:pq didFailPage:7 pixelSize:px preview:NO
                        failure:PVRenderFailureTransientResource];
            OK([wc pageIsUnrenderable:7 preview:NO],
               "a transient failure holds the page off rather than re-asking at once");
            OK(PumpUntil(^BOOL{
                   return (BOOL)![wc pageIsUnrenderable:7 preview:NO]; }, 5.0),
               "...and three of them still leave it renderable once the backoff expires");

            // The bound. A machine that never recovers must not be asked
            // forever, so the transient budget runs out too -- but into a state
            // a reset can lift, unlike the permanent one.
            [wc resetRenderFailures];
            for (i = 0; i < 40; i++)
                [wc renderQueue:pq didFailPage:8 pixelSize:px preview:NO
                        failure:PVRenderFailureTimeout];
            OK([wc pageIsUnrenderable:8 preview:NO],
               "transient retries are bounded, so a broken machine is not asked forever");
            [wc resetRenderFailures];
            OK(![wc pageIsUnrenderable:8 preview:NO],
               "...and a reset lifts it, which it must not do for a real refusal");

            // Deterministic failures still retire, and still take three.
            for (i = 0; i < 3; i++)
                [wc renderQueue:pq didFailPage:9 pixelSize:px preview:NO
                        failure:PVRenderFailureInvalidPage];
            OK([wc pageIsUnrenderable:9 preview:NO],
               "a page CoreGraphics refuses is still retired after three tries");

            // Two pages whose backoffs expire at DIFFERENT times.
            //
            // One timer serves every outstanding backoff, and -scheduleRetryAt:
            // keeps only the earliest deadline on the reasoning that a later
            // one is covered because the fire re-examines every slot. It is
            // not. Re-examining a slot whose wait has not expired reports it
            // unrenderable and returns -- no failure is recorded for it, so
            // nothing calls -scheduleRetryAt: again. The timer only survived as
            // long as the pages coming due kept FAILING; the first time one
            // succeeded, every page with a longer backoff was left waiting on a
            // scroll or a zoom that need never come, and stayed blank.
            //
            // Two failures give page 21 a 0.50 s deadline and one gives page 20
            // a 0.25 s deadline, so 20's timer supersedes 21's. What is asserted
            // is what happens at 20's fire: the timer must be re-armed for 21,
            // not simply consumed.
            //
            // Note that -pageIsUnrenderable: alone cannot see this bug -- it
            // compares the deadline against the clock, so page 21 reports
            // renderable the moment its deadline passes whether or not anything
            // ever asks for it again. The timer is the thing that does the
            // asking, so the timer is what this checks.
            [wc resetRenderFailures];
            for (i = 0; i < 2; i++)
                [wc renderQueue:pq didFailPage:21 pixelSize:px preview:NO
                        failure:PVRenderFailureTransientResource];
            [wc renderQueue:pq didFailPage:20 pixelSize:px preview:NO
                    failure:PVRenderFailureTransientResource];

            double armedFirst = [[wc valueForKey:@"_retryTimerAt"] doubleValue];
            OK(armedFirst > 0,
               "a staggered pair arms a retry timer for the earlier deadline");

            OK(PumpUntil(^BOOL{
                   return (BOOL)([[wc valueForKey:@"_retryTimerAt"] doubleValue]
                                 != armedFirst); }, 5.0),
               "...the earlier deadline fires");
            OK([[wc valueForKey:@"_retryTimerAt"] doubleValue] > 0,
               "...and re-arms for the page still waiting, rather than "
               "abandoning it");

            OK(PumpUntil(^BOOL{
                   return (BOOL)![wc pageIsUnrenderable:21 preview:NO]; }, 5.0),
               "...so the later page comes back too");
            [wc resetRenderFailures];

            // A failure recorded at one bitmap size must not retire another.
            [wc resetRenderFailures];
            for (i = 0; i < 2; i++)
                [wc renderQueue:pq didFailPage:10 pixelSize:CGSizeMake(100, 130)
                        preview:NO failure:PVRenderFailureInvalidPage];
            [wc renderQueue:pq didFailPage:10 pixelSize:CGSizeMake(900, 1170)
                    preview:NO failure:PVRenderFailureInvalidPage];
            OK(![wc pageIsUnrenderable:10 preview:NO],
               "a failure at a new pixel size starts the count over, not finishes it");

            // And the one that is not about any page at all. A missing renderer
            // has no per-page counter to run out, so without a document-level
            // answer the failure handler rebuilt the wanted set, the wanted set
            // named the same pages, and nothing converged.
            [wc resetRenderFailures];
            OK(![wc pageIsUnrenderable:11 preview:NO], "page 11 starts renderable");
            [wc renderQueue:pq didFailPage:11 pixelSize:px preview:NO
                    failure:PVRenderFailureHelperUnavailable];
            OK([wc pageIsUnrenderable:11 preview:NO],
               "one helper-unavailable failure stops that page being asked for");
            OK([wc pageIsUnrenderable:12 preview:NO],
               "...and every other page too: it is one fact about the installation");
            OK([wc thumbIsUnrenderable:3],
               "...thumbnails included");
            [wc resetRenderFailures];
            OK([wc pageIsUnrenderable:12 preview:NO],
               "a reset does not put a renderer back in the bundle");

            // The alert this raised is a real sheet on a real window, and a
            // window with a sheet attached does not close: leaving it up made
            // -performClose: at the end of the run a no-op, so [6] read a
            // reading position that had never been written. Dismissed here.
            OK([[wc window] attachedSheet] != nil,
               "the missing renderer is reported to the user, once, as a sheet");
            if ([[wc window] attachedSheet]) {
                [NSApp endSheet:[[wc window] attachedSheet]];
                [[[wc window] attachedSheet] orderOut:nil];
            }
            // Waited for, not slept through. AppKit tears a sheet down over an
            // indeterminate number of run-loop turns, so a fixed Pump is a bet
            // on how loaded the machine is -- and this suite runs straight after
            // the static analyser, which is exactly when it is loaded. Observed
            // failing once in four runs at 0.2 s and never since as a wait.
            OK(PumpUntil(^BOOL{
                   return (BOOL)([[wc window] attachedSheet] == nil); }, 10.0),
               "the sheet is dismissed");

            // Undone for the rest of the run: every later section expects a
            // working renderer.
            [wc setValue:[NSNumber numberWithBool:NO]
                  forKey:@"_reportedRendererMissing"];
            [wc resetRenderFailures];
            OK(![wc pageIsUnrenderable:12 preview:NO],
               "the document recovers once the renderer is accounted for again");
            [wc updateVisibleContent];
            Pump(0.5);
        }

        // Under memory pressure the full-resolution bitmaps are dropped and the
        // previews kept. What must not happen is the prefetch that follows
        // asking for those same full bitmaps straight back: on a machine that
        // stays under pressure that is a render loop, which is the opposite of
        // shrinking.
        printf("\n[5d] memory pressure shrinks the cache and stays shrunk\n");
        {
            PVImageCache *pc = [wc valueForKey:@"_pageCache"];
            PVRenderQueue *pq = [wc valueForKey:@"_pageQueue"];
            // Counted from a clean cache, so the baseline is what one settled
            // pass actually asks for -- visible pages plus prefetch -- and not
            // a high-water mark left behind by everything above.
            [pc removeAll];
            [wc updateVisibleContent];
            OK(PumpUntil(^{ return [pq isIdle]; }, 60.0), "the first pass settles");
            NSUInteger normal = [pc fullImageCount];
            printf("  full bitmaps after a settled pass: %lu\n", (unsigned long)normal);
            OK(normal >= 2, "a settled pass renders the visible pages and prefetches ahead");

            [wc memoryPressure:PressureNote(DISPATCH_MEMORYPRESSURE_WARN)];
            OK([pc fullImageCount] == 0, "a warning drops every full bitmap immediately");
            OK(PumpUntil(^{ return [pq isIdle]; }, 60.0), "the pass after pressure settles");
            NSUInteger after = [pc fullImageCount];
            printf("  full bitmaps after a warning settled: %lu\n", (unsigned long)after);
            OK(after > 0, "the pages actually on screen still go sharp again");
            OK(after < normal,
               "prefetch does not put back the full bitmaps pressure just dropped");

            // CRITICAL is the kernel saying it is nearly out, and it is answered
            // directly rather than by counting how many times it has spoken.
            // The old code derived its response from the NUMBER of reports, so a
            // machine that went straight to critical -- one coalesced event --
            // read as a first warning, and the first-warning response is to
            // re-render every visible page at full resolution. That is the
            // largest allocation this app can make, made in reply to being told
            // memory is nearly gone.
            [wc memoryPressure:PressureNote(DISPATCH_MEMORYPRESSURE_CRITICAL)];
            OK([pc fullImageCount] == 0, "a critical report drops the bitmaps too");
            OK(PumpUntil(^{ return [pq isIdle]; }, 60.0), "the pass after it settles");
            OK([pc fullImageCount] == 0,
               "a machine at critical pressure is not asked to render again");
            OK([pc entryCount] > 0,
               "the previews are kept, so the document stays readable");

            // A single CRITICAL is enough on its own: it does not have to be
            // seen twice, and it must not be reachable by counting warnings.
            [wc memoryPressure:PressureNote(DISPATCH_MEMORYPRESSURE_NORMAL)];
            [wc memoryPressure:PressureNote(DISPATCH_MEMORYPRESSURE_CRITICAL)];
            OK([[wc valueForKey:@"_pressureReports"] unsignedIntegerValue] == 2,
               "one critical event reaches the strict tier by itself");

            // User activity must NOT end the backoff. Scrolling says nothing
            // about whether the kernel still has memory, and scrolling is
            // exactly what someone does while waiting for a stalled machine --
            // so clearing it here re-armed full-resolution rendering at the
            // worst possible moment.
            [wc goToPageNumber:2];
            Pump(0.6);
            OK([[wc valueForKey:@"_pressureReports"] unsignedIntegerValue] == 2,
               "a user action does not overrule the kernel");
            OK([pc fullImageCount] == 0,
               "...and no full bitmap is rendered while it still says critical");

            // Only the kernel's own all-clear does.
            [wc memoryPressure:PressureNote(DISPATCH_MEMORYPRESSURE_NORMAL)];
            OK([[wc valueForKey:@"_pressureReports"] unsignedIntegerValue] == 0,
               "a NORMAL event from the kernel ends the backoff");
            OK(PumpUntil(^BOOL{ return (BOOL)([pc fullImageCount] > 0); }, 60.0),
               "...and the pages go sharp again");
            // Put the document back where the rest of the run expects to find
            // it: [6] reads the position this leaves behind off the disk.
            [wc goToPageNumber:37];
            PumpUntil(^{ return [pq isIdle]; }, 60.0);
        }

        // The half of pressure handling that the block above cannot reach: a
        // render that was ALREADY RUNNING when the kernel said critical.
        //
        // Dropping the cache is only half a response. Rasterisation happens in
        // a helper process and cannot be recalled; the bitmap is coming whether
        // or not the machine is still short of memory, and delivery used to put
        // it straight into the cache that had just been emptied. On two lanes
        // that is ~56 MB restored within milliseconds of the release, on a
        // machine the kernel had just called critical, and nothing would take
        // it out again until the next pressure event.
        //
        // The pressure is therefore posted DURING the renders rather than
        // between them, which is the only arrangement that exercises the
        // delivery path at all.
        printf("\n[5d2] a render in flight when pressure arrives is not stored\n");
        {
            PVImageCache *pc = [wc valueForKey:@"_pageCache"];
            PVRenderQueue *pq = [wc valueForKey:@"_pageQueue"];

            [wc memoryPressure:PressureNote(DISPATCH_MEMORYPRESSURE_NORMAL)];
            [pc removeAll];
            [wc updateVisibleContent];

            // Caught mid-pass, deliberately not settled. -inFlightCount holds a
            // request from the moment a lane picks it up until its result has
            // been handed over, so a non-zero count here is exactly the
            // "bitmap already on its way" the assertion is about.
            BOOL caught = PumpUntil(^BOOL{
                return (BOOL)([pq inFlightCount] > 0); }, 30.0);
            OK(caught, "a render was in flight to post the pressure event into");
            printf("  in flight when critical was posted: %lu\n",
                   (unsigned long)[pq inFlightCount]);

            [wc memoryPressure:PressureNote(DISPATCH_MEMORYPRESSURE_CRITICAL)];
            OK([pc fullImageCount] == 0,
               "the drop empties the cache of full bitmaps as before");

            // Now let everything that was outstanding arrive.
            OK(PumpUntil(^{ return [pq isIdle]; }, 90.0),
               "every outstanding render drains");
            OK([pc fullImageCount] == 0,
               "...and not one of them was put back into the cache");
            OK([pc entryCount] > 0,
               "the previews still arrive, so the document stays readable");

            // And the same thing again, deterministically.
            //
            // The drain above is a real race and racing is all it can do: which
            // bitmaps happen to be outstanding when the event lands depends on
            // the machine, and on one lane it is usually a preview, which is
            // kept by design. A test that only sometimes exercises the path it
            // is named after passes just as loudly when the guard is gone --
            // observed, on this machine, with the guard deleted.
            //
            // So the late arrival is performed rather than waited for. This is
            // exactly what the delivery block does when a rasterisation that
            // began before the pressure event finishes after it, minus the
            // timing. The page is the one on screen, so the viewport-window
            // check further down cannot be what drops the bitmap and let this
            // pass for the wrong reason.
            {
                NSUInteger page =
                    [[wc valueForKey:@"_displayedPage"] unsignedIntegerValue];
                CGSize px = CGSizeMake(240, 320);
                CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
                CGContextRef ctx = CGBitmapContextCreate(NULL, (size_t)px.width,
                    (size_t)px.height, 8, 0, cs,
                    (CGBitmapInfo)kCGImageAlphaNoneSkipFirst |
                        kCGBitmapByteOrder32Host);
                CGColorSpaceRelease(cs);
                CGImageRef late = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
                if (ctx) CGContextRelease(ctx);
                OK(late != NULL, "a stand-in bitmap for the late arrival");

                NSUInteger before = [pc fullImageCount];
                [wc renderQueue:pq didRenderPage:page image:late pixelSize:px
                        preview:NO renderSeconds:0.1];
                OK([pc fullImageCount] == before,
                   "a full bitmap delivered during critical pressure is dropped, "
                   "not cached");

                // The counterpart: with the kernel's all-clear given, the very
                // same delivery is accepted. Without this the assertion above
                // would also pass if delivery had simply stopped working.
                [wc memoryPressure:PressureNote(DISPATCH_MEMORYPRESSURE_NORMAL)];
                [wc renderQueue:pq didRenderPage:page image:late pixelSize:px
                        preview:NO renderSeconds:0.1];
                OK([pc fullImageCount] > before,
                   "...and is accepted once the kernel says the pressure is over");
                if (late) CGImageRelease(late);
            }

            // The state the rest of the run expects.
            [wc memoryPressure:PressureNote(DISPATCH_MEMORYPRESSURE_NORMAL)];
            OK(PumpUntil(^BOOL{ return (BOOL)([pc fullImageCount] > 0); }, 60.0),
               "the all-clear brings the sharp pages back");
            [wc goToPageNumber:37];
            PumpUntil(^{ return [pq isIdle]; }, 60.0);
        }

        // -scrollViewFrameChanged: deliberately skips the exact pass while the
        // user is dragging the window edge, and AppKit does not necessarily
        // post another frame change once they let go. Without a handler for
        // the end of the resize the document stayed soft until the next scroll.
        printf("\n[5e] the end of a live resize asks for sharp bitmaps\n");
        {
            // Checked synchronously, with no run loop in between: a notification
            // is delivered on the posting thread, so if the controller handles
            // this one the flag is already down by the time the post returns.
            // Waiting on a rendered bitmap instead would prove nothing -- any
            // of several notifications arriving during the wait triggers the
            // same pass. The handler is reached through NSWindow's delegate
            // registration, so this also pins the window delegate being set.
            // Observed through the render-failure table rather than through
            // the pressure state. The end of a live resize means "the geometry
            // is final, ask again": it resets retired pages, because a page
            // that would not rasterise at the old size is a different question
            // at the new one. It does NOT clear memory pressure -- only the
            // kernel does that -- so the pressure flag can no longer serve as
            // the observable here.
            PVRenderQueue *rq = [wc valueForKey:@"_pageQueue"];
            [wc resetRenderFailures];
            NSUInteger attempt;
            for (attempt = 0; attempt < PV_UITEST_MAX_ATTEMPTS; attempt++) {
                [wc renderQueue:rq didFailPage:5
                      pixelSize:CGSizeMake(10, 10) preview:NO];
                [wc renderQueue:rq didFailPage:5
                      pixelSize:CGSizeMake(10, 10) preview:YES];
            }
            OK([wc pageIsUnrenderable:5],
               "a retired page is retired (test premise holds)");
            [[NSNotificationCenter defaultCenter]
                postNotificationName:NSWindowDidEndLiveResizeNotification
                              object:[wc window]];
            OK(![wc pageIsUnrenderable:5],
               "the end of a live resize is observed and starts a fresh exact pass");
            PumpUntil(^{ return [(PVRenderQueue *)[wc valueForKey:@"_pageQueue"] isIdle]; }, 60.0);
        }

        // A page that will be gone before its bitmap could arrive is not worth
        // rasterising. Without this the render queue saturated a core during
        // any fast scroll, producing previews for pages that had left the
        // screen long before they were delivered: measured at 128% of a core
        // flicking through a heavy document against 26% after, with what the
        // user sees unchanged, because what stopped being rendered was
        // precisely what was arriving too late to be seen.
        printf("\n[5f] pages flying past faster than they can be seen are not rendered\n");
        {
            PVImageCache  *pc = [wc valueForKey:@"_pageCache"];
            PVRenderQueue *pq = [wc valueForKey:@"_pageQueue"];
            [wc goToPageNumber:10];
            PumpUntil(^{ return [pq isIdle]; }, 60.0);
            // The page the viewport is actually sitting on, travelling
            // forwards. Stated rather than inherited, so the rule is measured
            // against a geometry the test knows and not whichever direction
            // the previous section happened to leave behind.
            NSUInteger onScreen = [wc currentPageWithFraction:NULL];
            [wc setValue:[NSNumber numberWithInt:1] forKey:@"_lastDirection"];

            // Standing still, everything is worth rendering however the rest
            // of the state is set: the rule only ever applies to a live scroll.
            [wc setValue:[NSNumber numberWithDouble:50000.0] forKey:@"_scrollSpeed"];
            OK([wc worthRenderingDuringScroll:onScreen],
               "not scrolling: the speed rule does not apply at all");

            [wc willStartLiveScroll:nil];
            OK([[wc valueForKey:@"_scrollSpeed"] doubleValue] == 0,
               "a new gesture starts from rest, not from the last one's speed");

            // A speed and the instant it was measured always move together:
            // -clipBoundsChanged: writes both, and the throttle disregards a
            // speed it cannot date (see PV_SPEED_FRESH_SECONDS, which is what
            // stops a document that has stopped moving from staying soft
            // forever). Setting the speed alone below therefore builds a state
            // the app cannot actually reach -- fast, but measured never -- and
            // the honest answer to it is the safe one: render.
            //
            // The gesture has just zeroed the clock, so the timestamp is
            // restated here to stand for the first bounds change of the
            // scroll. Without it these assertions test the staleness rule
            // rather than the speed rule they are written for.
            // PVMonotonicSeconds, because that is the clock -clipBoundsChanged:
            // stamps this ivar with. Written in wall-clock seconds it is not a
            // stale timestamp, it is a timestamp from a different time base --
            // roughly 8x10^8 seconds ahead of the clock it is compared against.
            [wc setValue:[NSNumber numberWithDouble:PVMonotonicSeconds()]
                  forKey:@"_lastScrollTime"];

            // The threshold is a constant, so these hold on every machine: a
            // page held on screen for many seconds is rendered, and one gone
            // within a glance is not.
            [wc setValue:[NSNumber numberWithDouble:50.0] forKey:@"_scrollSpeed"];
            OK([wc worthRenderingDuringScroll:onScreen],
               "a page held on screen for many seconds is always rendered");

            [wc setValue:[NSNumber numberWithDouble:50000.0] forKey:@"_scrollSpeed"];
            OK(![wc worthRenderingDuringScroll:onScreen],
               "a flick does not render pages that will be gone first");
            OK([wc secondsPageStaysVisible:onScreen] < PV_MIN_VISIBLE_SECONDS,
               "...because each page is on screen for less than a glance");

            // The two properties that make the rule safe on hardware nobody
            // here has measured: visible time falls as the scroll speeds up,
            // and the decision follows it. There is one crossover, so no
            // faster scroll ever renders something a slower one declined --
            // which is what stops the CPU cost swinging with the machine's
            // mood rather than with what the user is doing.
            BOOL monotoneTime = YES, monotoneDecision = YES;
            double prev = HUGE_VAL;
            BOOL prevDecision = YES;
            double sp;
            for (sp = 50; sp <= 128000; sp *= 2) {
                [wc setValue:[NSNumber numberWithDouble:sp] forKey:@"_scrollSpeed"];
                double t = [wc secondsPageStaysVisible:onScreen];
                BOOL d = [wc worthRenderingDuringScroll:onScreen];
                if (t > prev + 1e-9) monotoneTime = NO;
                if (d && !prevDecision) monotoneDecision = NO;
                prev = t; prevDecision = d;
            }
            OK(monotoneTime, "visible time falls monotonically as the scroll speeds up");
            OK(monotoneDecision, "and the decision follows it: one crossover, never a flip back");

            // A jump is not a speed. A page jump, a thumbnail click or the snap
            // at the end of a rubber-band moves the document thousands of
            // points between two events; folding that into the average reports
            // a scroll that never happened and stops rendering until it decays.
            [wc setValue:[NSNumber numberWithDouble:0.0] forKey:@"_scrollSpeed"];
            [wc setValue:[NSNumber numberWithDouble:0.0] forKey:@"_lastScrollTime"];
            [wc willStartLiveScroll:nil];
            [wc scrollToPage:2 fraction:0];
            [wc clipBoundsChanged:nil];
            [wc scrollToPage:900 fraction:0];      // a jump of most of a document
            [wc clipBoundsChanged:nil];
            OK([[wc valueForKey:@"_scrollSpeed"] doubleValue] <= PV_MAX_SCROLL_SPEED,
               "a jump across the document does not register as a scroll speed");
            // Leave a scroll in flight, which is the state the next check needs.
            [wc willStartLiveScroll:nil];

            // And the guarantee that makes all of it safe: stopping asks for
            // everything, at once. A flick that skipped every page on the way
            // past must still land on a sharp one.
            [pc removeAll];
            [wc setValue:[NSNumber numberWithDouble:50000.0] forKey:@"_scrollSpeed"];
            [wc updateVisibleContent];
            PumpUntil(^{ return [pq isIdle]; }, 10.0);
            OK([pc fullImageCount] == 0, "mid-flick, nothing was rendered at all");

            [wc didEndLiveScroll:nil];
            OK([[wc valueForKey:@"_scrollSpeed"] doubleValue] == 0,
               "the end of the scroll clears the speed");
            OK(PumpUntil(^BOOL{ return (BOOL)([pc fullImageCount] > 0); }, 60.0),
               "the moment it stops, the page the user landed on goes sharp");
            PumpUntil(^{ return [pq isIdle]; }, 60.0);
            [wc goToPageNumber:37];          // restore what [6] expects to read
            PumpUntil(^{ return [pq isIdle]; }, 60.0);
        }

        // The page column is centred inside a document view that is at least as
        // wide as the viewport. That makes the viewport width an input to where
        // the pages sit, even in the zoom modes that do not recompute their
        // zoom when the window changes size -- and those two used to return
        // early from -scrollViewFrameChanged: without laying out again. The
        // document view then kept its old, narrower width, and a narrower
        // document view is placed at the LEFT of its clip view: zoom in, go
        // full screen, and the page sat against the left edge with all the
        // gained width empty beside it.
        // The scheduler, end to end through the real controller: not "does the
        // policy function return NO" but "does -updateVisibleContent actually
        // stop asking for full-resolution bitmaps while the document moves".
        //
        // That distinction is the whole bug. The policy was correct and was
        // being consulted for previews; the full-resolution branch beside it
        // was gated on the live-scroll flags instead, which AppKit posts only
        // for gestures. Every keyboard scroll therefore asked for a whole-page
        // bitmap per visible page per key press, while the counter beside it
        // reported a healthy suppression rate for the cheap half of the work.
        //
        // Counted by intercepting the one call the controller uses to hand
        // work over, so this measures what was asked for rather than what
        // happened to survive the queue's own coalescing.
        printf("\n[5g2] the scheduler asks for no full bitmaps while the document moves\n");
        {
            PVRenderQueue *pq = [wc valueForKey:@"_pageQueue"];
            [wc goToPageNumber:20];
            PumpUntil(^{ return [pq isIdle]; }, 60.0);

            // Both measurements start from an empty cache. A page already
            // sharp is not asked for again, so measuring at rest against a
            // warm cache would compare "nothing left to want" with
            // "suppressed" and call them the same thing.
            PVImageCache *pcache = [wc valueForKey:@"_pageCache"];

            [pcache removeAll];
            PVFullRequestCount = 0; PVPreviewRequestCount = 0; PVCountRequests = YES;

            // At rest. The settle path states this outright, so state it here
            // the same way rather than waiting for a timer.
            [wc setValue:[NSNumber numberWithDouble:0.0] forKey:@"_scrollSpeed"];
            [wc setValue:[NSNumber numberWithDouble:0.0] forKey:@"_lastScrollTime"];
            [wc updateVisibleContent];
            NSUInteger fullsAtRest = PVFullRequestCount;

            // Moving fast, freshly measured: the flick case, same empty cache.
            [pcache removeAll];
            PVFullRequestCount = 0; PVPreviewRequestCount = 0;
            [wc setValue:[NSNumber numberWithDouble:20000.0] forKey:@"_scrollSpeed"];
            // PVMonotonicSeconds, because that is the clock -clipBoundsChanged:
            // stamps this ivar with. Written in wall-clock seconds it is not a
            // stale timestamp, it is a timestamp from a different time base --
            // roughly 8x10^8 seconds ahead of the clock it is compared against.
            [wc setValue:[NSNumber numberWithDouble:PVMonotonicSeconds()]
                  forKey:@"_lastScrollTime"];
            [wc updateVisibleContent];
            NSUInteger fullsMoving = PVFullRequestCount;

            PVCountRequests = NO;

            OK(fullsMoving == 0,
               "moving: not one full-resolution bitmap is asked for");
            OK(fullsAtRest > 0,
               "at rest: full-resolution bitmaps are asked for again");

            // The keyboard is the case that was broken, and it never sets the
            // live-scroll flags. Assert the decision does not depend on them.
            OK(![[wc valueForKey:@"_liveScrolling"] boolValue],
               "...and none of that involved a live-scroll notification");
        }

        // The keep-test applied to an arriving bitmap, which is the other half
        // of what the wanted-set asked for and until now did not match it.
        //
        // Prefetch only ever looks forward along _lastDirection. The keep-test
        // was symmetric, so a full bitmap arriving for the page one BEHIND a
        // moving viewport was stored -- ~28 MB in the profiling window, for a
        // page nothing had asked about and that already has a preview. The two
        // now agree: PV_FULL_PREFETCH_PAGES ahead, nothing behind.
        //
        // Driven by handing the controller a delivery directly, because that is
        // the decision under test. Waiting for the real queue to produce a
        // bitmap for a page outside the visible range would be testing the
        // prefetch policy instead, and would be timing-dependent.
        printf("\n[5g3] an arriving full bitmap is kept ahead of the viewport, not behind it\n");
        {
            PVRenderQueue *pq     = [wc valueForKey:@"_pageQueue"];
            PVImageCache  *pcache = [wc valueForKey:@"_pageCache"];

            [wc goToPageNumber:20];
            PumpUntil(^{ return [pq isIdle]; }, 60.0);
            [wc updateVisibleContent];          // establishes _lastRequestRange

            NSRange vis = [[wc valueForKey:@"_lastRequestRange"] rangeValue];
            NSInteger behind = (NSInteger)vis.location - 1;
            NSInteger ahead  = (NSInteger)NSMaxRange(vis);
            OK(behind >= 0 && ahead < (NSInteger)[[wc valueForKey:@"_source"] pageCount],
               "the probe has a page on each side of the visible range to test with");

            // One small synthetic bitmap, delivered as though it were a full
            // page. Size does not matter to the keep-test; only the page index
            // and the direction of travel do.
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGContextRef bc = CGBitmapContextCreate(NULL, 32, 32, 8, 0, cs,
                (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host);
            CGColorSpaceRelease(cs);
            CGImageRef img = bc ? CGBitmapContextCreateImage(bc) : NULL;
            if (bc) CGContextRelease(bc);
            CGSize px = CGSizeMake(32, 32);

            if (!img) {
                OK(NO, "could not build the synthetic bitmap for the delivery probe");
            } else {
                // Travelling forwards.
                [wc setValue:[NSNumber numberWithBool:YES] forKey:@"_hasMovedViewport"];
                [wc setValue:[NSNumber numberWithInt:1]    forKey:@"_lastDirection"];

                [pcache removeAll];
                [wc renderQueue:pq didRenderPage:(NSUInteger)ahead image:img
                      pixelSize:px preview:NO];
                OK([pcache fullImageForPage:(NSUInteger)ahead pixelSize:px] != NULL,
                   "forwards: the page ahead of the viewport is kept");

                [pcache removeAll];
                [wc renderQueue:pq didRenderPage:(NSUInteger)behind image:img
                      pixelSize:px preview:NO];
                OK([pcache fullImageForPage:(NSUInteger)behind pixelSize:px] == NULL,
                   "forwards: the page behind it is dropped, not stored");

                // A preview for the same trailing page is still kept. This is
                // the thing that makes scrolling back instant, and it is ~1/9
                // the pixels, so it is not what the memory work is aimed at.
                [pcache removeAll];
                [wc renderQueue:pq didRenderPage:(NSUInteger)behind image:img
                      pixelSize:px preview:YES];
                OK([pcache hasPreviewForPage:(NSUInteger)behind],
                   "...but its preview is kept: preview retention stays symmetric");

                // Travelling backwards: the window flips with the direction.
                [wc setValue:[NSNumber numberWithInt:-1] forKey:@"_lastDirection"];

                [pcache removeAll];
                [wc renderQueue:pq didRenderPage:(NSUInteger)behind image:img
                      pixelSize:px preview:NO];
                OK([pcache fullImageForPage:(NSUInteger)behind pixelSize:px] != NULL,
                   "backwards: the window flips and the page above is kept");

                [pcache removeAll];
                [wc renderQueue:pq didRenderPage:(NSUInteger)ahead image:img
                      pixelSize:px preview:NO];
                OK([pcache fullImageForPage:(NSUInteger)ahead pixelSize:px] == NULL,
                   "backwards: the page below is now the trailing one and is dropped");

                // Before the viewport has ever moved there is no direction to
                // widen along, and none is invented: the window is the visible
                // range exactly, which is also all the wanted-set asks for.
                [wc setValue:[NSNumber numberWithBool:NO] forKey:@"_hasMovedViewport"];
                [wc setValue:[NSNumber numberWithInt:1]   forKey:@"_lastDirection"];
                [pcache removeAll];
                [wc renderQueue:pq didRenderPage:(NSUInteger)ahead image:img
                      pixelSize:px preview:NO];
                OK([pcache fullImageForPage:(NSUInteger)ahead pixelSize:px] == NULL,
                   "before the first movement the window is the visible range and nothing more");

                [pcache removeAll];
                [wc renderQueue:pq didRenderPage:vis.location image:img
                      pixelSize:px preview:NO];
                OK([pcache fullImageForPage:vis.location pixelSize:px] != NULL,
                   "...and a visible page is always kept, in every direction");

                CGImageRelease(img);
                [wc setValue:[NSNumber numberWithBool:YES] forKey:@"_hasMovedViewport"];
            }
        }

        // The cost of the change above, measured rather than assumed.
        //
        // Dropping the trailing page's full bitmap means a scroll-back
        // re-renders it. ENGINEERING.md section 4.3 says that is the price
        // and says to measure it; this is the measurement. Page forward N, page
        // back over the same N, and report what the scheduler asked for and what
        // the process actually spent on each leg.
        //
        // The bound asserted is the theoretical worst case of the change: at
        // most one extra full-resolution render per page revisited. Anything
        // above that is not the trailing page being re-rendered, it is the cache
        // thrashing, which is a different and much more expensive failure.
        printf("\n[5g4] scroll-back probe: what the directional keep-window costs\n");
        {
            PVRenderQueue *pq     = [wc valueForKey:@"_pageQueue"];
            PVImageCache  *pcache = [wc valueForKey:@"_pageCache"];
            const NSInteger kSteps = 8;
            const NSInteger kStart = 10;

            [pcache removeAll];
            [wc goToPageNumber:kStart];
            PumpUntil(^{ return [pq isIdle]; }, 60.0);

            struct rusage ru;
            double cpu0 = 0, cpu1 = 0, cpu2 = 0;
            if (getrusage(RUSAGE_SELF, &ru) == 0)
                cpu0 = (double)ru.ru_utime.tv_sec + (double)ru.ru_utime.tv_usec / 1.0e6 +
                       (double)ru.ru_stime.tv_sec + (double)ru.ru_stime.tv_usec / 1.0e6;

            PVFullRequestCount = 0; PVPreviewRequestCount = 0; PVCountRequests = YES;

            // A settle after every jump, not just an idle queue. A page jump
            // moves the viewport, which registers as motion, which closes the
            // full-resolution gate -- so the queue goes idle at once having
            // asked for nothing, and a probe that only waited for idle would
            // measure a scroll rather than a reader. PV_SETTLE_SECONDS past the
            // last movement the sharp pass is asked for, and that pass is the
            // work this probe exists to count.
            NSInteger step;
            for (step = 1; step <= kSteps; step++) {
                [wc goToPageNumber:kStart + step];
                Pump(PV_SETTLE_SECONDS + PV_SPEED_FRESH_SECONDS);
                PumpUntil(^{ return [pq isIdle]; }, 60.0);
            }
            NSUInteger fullsForward = PVFullRequestCount;
            if (getrusage(RUSAGE_SELF, &ru) == 0)
                cpu1 = (double)ru.ru_utime.tv_sec + (double)ru.ru_utime.tv_usec / 1.0e6 +
                       (double)ru.ru_stime.tv_sec + (double)ru.ru_stime.tv_usec / 1.0e6;

            PVFullRequestCount = 0;
            for (step = kSteps - 1; step >= 0; step--) {
                [wc goToPageNumber:kStart + step];
                Pump(PV_SETTLE_SECONDS + PV_SPEED_FRESH_SECONDS);
                PumpUntil(^{ return [pq isIdle]; }, 60.0);
            }
            NSUInteger fullsBack = PVFullRequestCount;
            PVCountRequests = NO;
            if (getrusage(RUSAGE_SELF, &ru) == 0)
                cpu2 = (double)ru.ru_utime.tv_sec + (double)ru.ru_utime.tv_usec / 1.0e6 +
                       (double)ru.ru_stime.tv_sec + (double)ru.ru_stime.tv_usec / 1.0e6;

            printf("  forward %ld pages : %lu full requests, %.2f s CPU\n",
                   (long)kSteps, (unsigned long)fullsForward, cpu1 - cpu0);
            printf("  back    %ld pages : %lu full requests, %.2f s CPU\n",
                   (long)kSteps, (unsigned long)fullsBack, cpu2 - cpu1);
            printf("  scroll-back cost : %+ld full requests, %+.2f s CPU\n",
                   (long)fullsBack - (long)fullsForward, (cpu2 - cpu1) - (cpu1 - cpu0));
            printf("  (this host is not the arbiter; the ratio is the point, not the seconds)\n");

            OK(fullsForward > 0, "the forward leg asked for full-resolution bitmaps at all");
            char msg[200];
            snprintf(msg, sizeof msg,
                     "the return leg costs at most one extra full render per page "
                     "(%lu back vs %lu forward, bound %ld)",
                     (unsigned long)fullsBack, (unsigned long)fullsForward,
                     (long)fullsForward + kSteps);
            OK((NSInteger)fullsBack <= (NSInteger)fullsForward + kSteps, msg);
        }

        // Device parity, measured rather than argued.
        //
        // The claim under test is that trackpad/wheel scrolling and keyboard
        // scrolling reach the render scheduler through one path and are decided
        // by one policy. [5g2] shows the policy is device-independent; this
        // shows the two devices actually produce the same requests, by driving
        // the same viewport at the same speed with and without the live-scroll
        // notifications that are the only thing AppKit does differently for a
        // gesture.
        //
        // Written to fail if anyone reintroduces a device test. The original bug
        // was exactly that -- `!_liveScrolling && !_liveZooming` guarding the
        // expensive half of the work -- and it would show up here as a keyboard
        // count that is not the gesture count.
        printf("\n[5g5] trackpad and keyboard reach the scheduler through one path\n");
        {
            PVRenderQueue *pq     = [wc valueForKey:@"_pageQueue"];
            PVImageCache  *pcache = [wc valueForKey:@"_pageCache"];
            NSScrollView  *sv     = [wc valueForKey:@"_scrollView"];

            [wc goToPageNumber:8];
            PumpUntil(^{ return [pq isIdle]; }, 60.0);
            Pump(PV_SETTLE_SECONDS + PV_SPEED_FRESH_SECONDS);
            PumpUntil(^{ return [pq isIdle]; }, 60.0);

            // Fast: 300 pt every 5 ms is 60,000 pt/s, a hard flick. Once either
            // device is moving at a measured speed, neither may ask for a
            // full-resolution bitmap and neither may ask for a preview of a page
            // that will be gone before it arrives.
            NSUInteger kbFull = 0, kbPrev = 0, tpFull = 0, tpPrev = 0;

            [pcache removeAll];
            DriveScroll(wc, sv, NO,  300, 5000, 12, 1, &kbFull, &kbPrev);
            [pcache removeAll];
            DriveScroll(wc, sv, YES, 300, 5000, 12, 1, &tpFull, &tpPrev);

            printf("  flick (~60,000 pt/s), once moving: keyboard %lu full / %lu preview,"
                   "  trackpad %lu full / %lu preview\n",
                   (unsigned long)kbFull, (unsigned long)kbPrev,
                   (unsigned long)tpFull, (unsigned long)tpPrev);

            OK(kbFull == 0, "flick, keyboard: no full-resolution bitmap is asked for");
            OK(tpFull == 0, "flick, trackpad: no full-resolution bitmap is asked for");
            OK(kbFull == tpFull && kbPrev == tpPrev,
               "flick: the two devices ask for exactly the same set");

            // The first bounds change of a movement, which is the one place the
            // two devices genuinely differ and the reason the comparison above
            // skips it.
            //
            // A gesture is announced before it starts, so its first event is
            // already known to be a scroll. A key press is not announced and the
            // first one is indistinguishable from a deliberate single page-down,
            // so the policy does what it does everywhere else with no evidence:
            // it renders. That costs one wanted-set rebuild per scroll episode --
            // per episode, not per key, because a gap under half a second keeps
            // the speed measurement alive across the whole of a held key.
            //
            // Recorded rather than removed. Removing it means either rendering
            // nothing on a single deliberate page-down, which is the case
            // `read` is made of and where sharp pages are the whole point, or
            // inferring a scroll from key auto-repeat -- a behaviour change that
            // moves CPU and must be judged on the Mavericks machine, not here.
            NSUInteger kbFirst = 0, tpFirst = 0, kbFirstPrev = 0, tpFirstPrev = 0;
            [pcache removeAll];
            DriveScroll(wc, sv, NO,  300, 5000, 12, 0, &kbFirst, &kbFirstPrev);
            [pcache removeAll];
            DriveScroll(wc, sv, YES, 300, 5000, 12, 0, &tpFirst, &tpFirstPrev);
            printf("  flick including its first event : keyboard %lu full,"
                   "  trackpad %lu full  (difference is the announced-gesture bit)\n",
                   (unsigned long)kbFirst, (unsigned long)tpFirst);
            OK(tpFirst == 0,
               "an announced gesture asks for nothing even on its first event");
            OK(kbFirst <= 2,
               "an unannounced scroll costs at most one rebuild's worth of full requests");

            // The motion gate's own counter. Before this key existed the gate
            // appeared in no column of any profile: `scroll` reported zero
            // suppressed requests while the gate was suppressing everything,
            // because the PVStatAdd it would have run sits inside the branch the
            // gate closes. Both flicks above ran with the gate shut, so the
            // counter must have moved -- and the dwell counter must not have,
            // since at 60,000 pt/s the gate closes before any page is dwell-tested.
            double motion = PVStatValue(PVStatMotionSuppressed);
            printf("  motion-gate suppressions counted so far: %.0f "
                   "(dwell: %.0f)\n", motion, PVStatValue(PVStatRequestsSuppressed));
            OK(PVStatsEnabled(), "the census is enabled for this suite");
            OK(motion > 0,
               "the motion gate now reports the full renders it withheld");

            // The paired RSS reading: this process's footprint at the instant
            // the bitmap census peaked, taken by the app itself so that the two
            // numbers describe one moment rather than two maxima found on
            // different schedules.
            //
            // What is asserted is that the reading was TAKEN. What is
            // deliberately not asserted is rssAtPeak >= residentPeak, which
            // used to sit here reading like a sanity check.
            //
            // It was a claim about page-fault behaviour in another process. The
            // census counts bitmap bytes from the moment they are MAPPED, and
            // since rasterisation moved out of process those pixels are written
            // by the render helper into shared memory and mapped read-only
            // here -- so their physical pages are charged to the helper, and
            // land in this process's RSS only for the ones it happened to touch
            // by drawing them before they were evicted. Both orderings occur on
            // the same build: 178.4 MB of census against 78.0 MB of RSS on one
            // host, and 178.4 MB against 206.9 MB on another. An inequality
            // that holds or fails for reasons unrelated to the code under test
            // is not a gate, and the two quantities are not two measurements of
            // one thing.
            double rssAtPeak = (double)PVResidentRSSAtHighWater();
            double liveBitmaps = (double)PVResidentHighWater();
            printf("  rss at the bitmap peak: %.1f MB, live bitmaps %.1f MB\n",
                   rssAtPeak / (1024.0 * 1024.0),
                   liveBitmaps / (1024.0 * 1024.0));
            OK(rssAtPeak > 0,
               "RSS is sampled at the instant the bitmap census peaks");
            OK(liveBitmaps > 0,
               "the bitmap census recorded a peak to pair it with");

            // Slow: 8 pt every 40 ms is 200 pt/s, a deliberate read-along drag.
            // Every page survives the dwell test at that speed, so the per-page
            // policy says "render" for both devices -- and here the two DO
            // diverge, because -viewportIsMoving short-circuits on the gesture
            // flag before it ever consults the speed.
            //
            // Reported, not asserted equal, because it is a deliberate trade and
            // not the bug: the flag covers the first bounds change of a flick,
            // where no speed has been measured yet and the alternative is
            // rasterising whole pages at 60,000 pt/s. What it costs is that a
            // slow trackpad drag holds the sharp pass until the fingers lift,
            // where a slow keyboard scroll gets it PV_SETTLE_SECONDS after the
            // last key. Both end in the same call; only the trigger differs.
            // Counted over the whole episode, first event included, because the
            // question here is what a slow movement costs in total on each
            // device rather than whether the two agree once under way.
            [pcache removeAll];
            DriveScroll(wc, sv, NO,  8, 40000, 6, 0, &kbFull, &kbPrev);
            [pcache removeAll];
            DriveScroll(wc, sv, YES, 8, 40000, 6, 0, &tpFull, &tpPrev);

            printf("  drag  (~200 pt/s), whole episode : keyboard %lu full / %lu preview,"
                   "  trackpad %lu full / %lu preview\n",
                   (unsigned long)kbFull, (unsigned long)kbPrev,
                   (unsigned long)tpFull, (unsigned long)tpPrev);
            printf("  (the announced gesture makes the trackpad the more conservative\n"
                   "   of the two at every speed; it never makes it the less)\n");
            OK(tpFull <= kbFull,
               "a gesture never asks for MORE full bitmaps than the keyboard at the same speed");

            // The end of the gesture is the settle, and it is the same settle.
            // -didEndLiveScroll: and -settleFired: both zero the speed, clear
            // _haveRequestState and call -updateVisibleContent; this asserts the
            // outcome rather than the identity of the two methods.
            [pcache removeAll];
            PVFullRequestCount = 0; PVCountRequests = YES;
            [[NSNotificationCenter defaultCenter]
                postNotificationName:NSScrollViewDidEndLiveScrollNotification object:sv];
            NSUInteger afterGestureEnd = PVFullRequestCount;

            [pcache removeAll];
            PVFullRequestCount = 0;
            [wc setValue:[NSNumber numberWithDouble:0.0] forKey:@"_scrollSpeed"];
            [wc setValue:[NSNumber numberWithDouble:0.0] forKey:@"_lastScrollTime"];
            [wc setValue:[NSNumber numberWithBool:NO]    forKey:@"_haveRequestState"];
            [wc updateVisibleContent];
            NSUInteger afterKeyboardSettle = PVFullRequestCount;
            PVCountRequests = NO;

            printf("  settle: gesture end asks for %lu full, keyboard settle asks for %lu\n",
                   (unsigned long)afterGestureEnd, (unsigned long)afterKeyboardSettle);
            OK(afterGestureEnd > 0 && afterGestureEnd == afterKeyboardSettle,
               "both devices end their movement in the same sharp pass");
            OK(![[wc valueForKey:@"_liveScrolling"] boolValue],
               "the gesture flag is clear once the gesture has ended");

            PumpUntil(^{ return [pq isIdle]; }, 90.0);
        }

        // The AC branch, driven through the same real controller as everything
        // above, because a policy that is only ever exercised as a pure function
        // is a policy nobody has run.
        //
        // Two claims, and the second matters more than the first. On mains power
        // the blanket motion gate is replaced by a per-page cost question, so a
        // slow deliberate drag does ask for sharp pages where on battery it asks
        // for none. But the cost question still has to refuse a genuine flick --
        // if plugging in a laptop turned the flick pathology back on, this whole
        // branch would be a regression wearing a feature's clothes.
        printf("\n[5g6] on mains power the motion gate becomes a per-page cost question\n");
        {
            PVRenderQueue *pq     = [wc valueForKey:@"_pageQueue"];
            PVImageCache  *pcache = [wc valueForKey:@"_pageCache"];
            NSScrollView  *sv     = [wc valueForKey:@"_scrollView"];
            PVCostModel   *cost   = [pq costModel];

            [wc goToPageNumber:8];
            PumpUntil(^{ return [pq isIdle]; }, 60.0);
            Pump(PV_SETTLE_SECONDS + PV_SPEED_FRESH_SECONDS);
            PumpUntil(^{ return [pq isIdle]; }, 60.0);

            // The model has to have something to say before its effect can be
            // asserted, and by this point in the suite the document has been
            // rendered many times over. Checked rather than assumed: if it were
            // empty the AC branch would fall back to the constant and the test
            // below would be measuring nothing.
            printf("  cost model: %lu full samples at %.1f ms/Mpx, "
                   "%lu preview samples at %.1f ms/Mpx\n",
                   (unsigned long)[cost sampleCountForPreview:NO],
                   [cost msPerMegapixelForPreview:NO],
                   (unsigned long)[cost sampleCountForPreview:YES],
                   [cost msPerMegapixelForPreview:YES]);
            OK([cost sampleCountForPreview:NO] >= PV_COST_MIN_SAMPLES,
               "the cost model has measured this document by now");

            NSUInteger acFull = 0, acPrev = 0, batFull = 0, batPrev = 0;

            // A slow deliberate drag, the same one [5g5] uses, on each branch.
            //
            // Counted over the whole episode -- warmup 0 -- and that is not a
            // detail. Six 8 pt steps move the viewport 48 pt, which does not
            // change the visible page range, so -clipBoundsChanged:'s early-out
            // correctly declines to rebuild the wanted set for every event after
            // the first. Skipping the first event would leave nothing to count
            // on either branch and the test would pass by measuring silence.
            // A gesture is announced before it starts, so `moving` is already
            // true on that first event and the battery branch is still being
            // asked the question it refuses.
            // _haveRequestState is cleared before each drag, symmetrically.
            //
            // Without it the second of the two runs measures the early-out
            // rather than the policy: -clipBoundsChanged: rebuilds the wanted
            // set only when the page range, the direction or the motion state
            // has changed, and two consecutive slow drags over 48 pt change none
            // of the three -- so the second one would record zero requests on
            // whichever branch happened to go second and the comparison would be
            // between a policy and an optimisation. This is the same thing
            // -settleFired: does, for the same stated reason.
            PVSetPowerSourceOverride(PVPowerBattery, YES);
            [pcache removeAll];
            [wc setValue:[NSNumber numberWithBool:NO] forKey:@"_haveRequestState"];
            DriveScroll(wc, sv, YES, 8, 40000, 6, 0, &batFull, &batPrev);
            PumpUntil(^{ return [pq isIdle]; }, 90.0);

            PVSetPowerSourceOverride(PVPowerAC, YES);
            [pcache removeAll];
            [wc setValue:[NSNumber numberWithBool:NO] forKey:@"_haveRequestState"];
            DriveScroll(wc, sv, YES, 8, 40000, 6, 0, &acFull, &acPrev);
            PumpUntil(^{ return [pq isIdle]; }, 90.0);

            printf("  slow drag (~200 pt/s): battery %lu full / %lu preview,"
                   "  AC %lu full / %lu preview\n",
                   (unsigned long)batFull, (unsigned long)batPrev,
                   (unsigned long)acFull,  (unsigned long)acPrev);
            OK(batFull == 0, "battery: a slow gesture drag asks for no sharp pages");
            OK(acFull > 0,   "AC: the same drag does ask for sharp pages");

            // And the safety property, which must hold on every power source
            // and on every machine. At 60,000 pt/s a page is on screen for
            // roughly 20 ms, so no prediction and no power source can make
            // rasterising it worth anything -- the dwell floor refuses it before
            // the cost model is even consulted.
            NSUInteger acFlick = 0, acFlickPrev = 0;
            [pcache removeAll];
            DriveScroll(wc, sv, YES, 300, 5000, 12, 1, &acFlick, &acFlickPrev);
            PumpUntil(^{ return [pq isIdle]; }, 90.0);
            printf("  flick (~60,000 pt/s) on AC: %lu full / %lu preview\n",
                   (unsigned long)acFlick, (unsigned long)acFlickPrev);
            OK(acFlick == 0,
               "AC: a genuine flick still asks for no full-resolution bitmaps");

            // Prefetch depth follows the policy, and the delivery keep-window
            // has to agree with it. These two numbers describe one window from
            // opposite ends; if they disagree the extra page is rasterised,
            // dropped on delivery, and asked for again on the next event.
            PVRenderPolicy acPolicy  = PVRenderPolicyFor(PVPowerAC, PVRamTierOfThisMachine(), 0);
            PVRenderPolicy batPolicy = PVRenderPolicyFor(PVPowerBattery, PVRamTierOfThisMachine(), 0);
            printf("  prefetch depth on this machine (tier %d): battery %lu, AC %lu\n",
                   (int)PVRamTierOfThisMachine(),
                   (unsigned long)batPolicy.fullPrefetchPages,
                   (unsigned long)acPolicy.fullPrefetchPages);
            OK(acPolicy.fullPrefetchPages >= batPolicy.fullPrefetchPages,
               "AC never prefetches less than battery");
            OK(PVRenderPolicyFitsCache(acPolicy, PVRamTierOfThisMachine()),
               "this machine's AC prefetch depth fits its own cache budget");

            // Back to battery for everything that follows, so the rest of the
            // suite keeps asserting the policy it was written against.
            PVSetPowerSourceOverride(PVPowerBattery, YES);
            [pcache removeAll];
            PumpUntil(^{ return [pq isIdle]; }, 90.0);
        }

        printf("\n[5g7] an arrow press moves the viewport by one eighth of itself\n");
        {
            // PVArrowScrollForViewportHeight is pinned by the unit suite as a pure
            // function. What that cannot show is that -keyDown: actually calls
            // it, which is the half the showdown measures: the recorded failure
            // was 200 presses moving Postview 6 pages against Preview's 13, and
            // it was a real NSEvent that produced it. So this drives a real
            // NSEvent through the real view and reads the clip view afterwards.
            PVPageView   *pv   = [wc valueForKey:@"_pageView"];
            NSScrollView *sv   = [wc valueForKey:@"_scrollView"];
            NSClipView   *clip = [sv contentView];

            [wc goToPageNumber:8];
            Pump(0.05);

            NSString *down = [NSString stringWithFormat:@"%C",
                                  (unichar)NSDownArrowFunctionKey];
            NSString *up   = [NSString stringWithFormat:@"%C",
                                  (unichar)NSUpArrowFunctionKey];
            NSEvent *downEvent =
                [NSEvent keyEventWithType:NSKeyDown
                                 location:NSZeroPoint
                            modifierFlags:0
                                timestamp:0
                             windowNumber:[[wc window] windowNumber]
                                  context:nil
                               characters:down
              charactersIgnoringModifiers:down
                                isARepeat:NO
                                  keyCode:125];
            NSEvent *upEvent =
                [NSEvent keyEventWithType:NSKeyDown
                                 location:NSZeroPoint
                            modifierFlags:0
                                timestamp:0
                             windowNumber:[[wc window] windowNumber]
                                  context:nil
                               characters:up
              charactersIgnoringModifiers:up
                                isARepeat:NO
                                  keyCode:126];

            CGFloat viewport = NSHeight([clip documentVisibleRect]);
            CGFloat expected = PVArrowScrollForViewportHeight(viewport);

            CGFloat before = NSMinY([clip documentVisibleRect]);
            [pv keyDown:downEvent];
            CGFloat afterDown = NSMinY([clip documentVisibleRect]);
            [pv keyDown:upEvent];
            CGFloat afterUp = NSMinY([clip documentVisibleRect]);

            OK(fabs((afterDown - before) - expected) < 1.0,
               "a Down press moves the viewport by the computed step");
            OK(fabs(afterUp - before) < 1.0,
               "an Up press puts it back");
            OK(expected > 60.0,
               "the step is larger than the flat 60 pt that failed the showdown");

            // Ten presses travel ten steps, so the showdown's 200 are not
            // being eaten by rounding inside -scrollByPoints:.
            CGFloat start = NSMinY([clip documentVisibleRect]);
            int kp;
            for (kp = 0; kp < 10; kp++) [pv keyDown:downEvent];
            CGFloat travelled = NSMinY([clip documentVisibleRect]) - start;
            OK(fabs(travelled - 10.0 * expected) < 2.0,
               "ten presses travel ten steps, with no drift");

            [wc goToPageNumber:8];
            Pump(0.05);
        }

        printf("\n[5g8] a programmatic scroll records where it actually landed\n");
        {
            // _lastScrollY is the controller's memory of where the viewport was,
            // and -clipBoundsChanged: measures both direction and speed as the
            // difference between it and what the clip view reports next.
            //
            // Every programmatic scroll rounds its target to a whole point, and
            // AppKit constrains the result again to the document's bounds. The
            // two scrolling paths used to record the number they had ASKED for,
            // so the very next bounds notification measured up to half a point
            // of travel that never happened. Half a point sits exactly on the
            // direction threshold (`y > _lastScrollY + 0.5`), and divided by the
            // 2 ms floor on a sample interval it is ~250 pt/s of scrolling
            // reported for a viewport that was standing still -- into an
            // estimator that is deliberately seeded from its first sample.
            //
            // Asserted as an exact equality on purpose. This is not a tolerance
            // question: the recorded position either is where the viewport is or
            // it is a number about nothing.
            NSScrollView *sv   = [wc valueForKey:@"_scrollView"];
            NSClipView   *clip = [sv contentView];

            NSUInteger probes[4] = { 0, 3, 12, 37 };
            BOOL exact = YES, exactAfterFraction = YES;
            unsigned k;
            for (k = 0; k < 4; k++) {
                [wc scrollToPage:probes[k] fraction:0];
                Pump(0.05);
                double recorded = [[wc valueForKey:@"_lastScrollY"] doubleValue];
                double actual   = (double)NSMinY([clip documentVisibleRect]);
                if (recorded != actual) exact = NO;

                // A fractional offset is where the rounding actually bites: the
                // target is page origin + fraction * height, which is rarely a
                // whole number.
                [wc scrollToPage:probes[k] fraction:0.37f];
                Pump(0.05);
                recorded = [[wc valueForKey:@"_lastScrollY"] doubleValue];
                actual   = (double)NSMinY([clip documentVisibleRect]);
                if (recorded != actual) exactAfterFraction = NO;
            }
            OK(exact, "after a page jump the recorded position is the real one");
            OK(exactAfterFraction,
               "...and after a jump to a fractional offset, where rounding bites");

            // A target past the end is clamped by AppKit, not by the caller's
            // arithmetic, which is the other way the two used to disagree.
            [wc scrollClipTo:NSMakePoint(0, 1.0e9)];
            Pump(0.05);
            OK([[wc valueForKey:@"_lastScrollY"] doubleValue] ==
                   (double)NSMinY([clip documentVisibleRect]),
               "a scroll clamped by the document's own bounds is recorded as clamped");

            // The property all of that exists for: the notification a
            // programmatic scroll causes must measure no travel at all.
            [wc setValue:[NSNumber numberWithDouble:0.0] forKey:@"_scrollSpeed"];
            [wc setValue:[NSNumber numberWithDouble:
                             PVMonotonicSeconds() - 0.003]
                  forKey:@"_lastScrollTime"];
            [wc scrollToPage:20 fraction:0.61f];
            [wc clipBoundsChanged:nil];
            OK([[wc valueForKey:@"_scrollSpeed"] doubleValue] == 0.0,
               "so the notification it causes reports no speed, because there was none");
        }

        printf("\n[5g9] a viewport with nothing in it forgets the set it just dropped\n");
        {
            // -updateVisibleContent's degenerate branch clears the cache's pin
            // and the queue's pending set, because neither describes anything
            // any more. _lastRequestRange / _haveRequestState are the record OF
            // that set, and -clipBoundsChanged: skips the whole rebuild whenever
            // the range it computes matches them.
            //
            // Leaving the record standing while emptying the two things it is a
            // record of is the one combination that cannot be right: a viewport
            // that goes empty and comes back to the same page range is then
            // recognised as unchanged, and the rebuild that would have re-pinned
            // the visible pages and re-requested their bitmaps never runs.
            //
            // Reached here by handing the controller a page view that has not
            // been laid out, which is exactly what -pageRangeInRect: answers
            // with an empty range for.
            PVPageView *real  = [[wc valueForKey:@"_pageView"] retain];
            PVImageCache *pc  = [wc valueForKey:@"_pageCache"];
            PVPDFSource  *psrc = [wc valueForKey:@"_source"];
            PVPageView *blank = [[PVPageView alloc] initWithSource:psrc cache:pc];

            [wc updateVisibleContent];
            OK([[wc valueForKey:@"_haveRequestState"] boolValue],
               "a laid-out viewport records the set it asked for");

            [wc setValue:blank forKey:@"_pageView"];
            [wc updateVisibleContent];
            OK(![blank isLaidOut], "the stand-in page view really has no layout");
            OK(![[wc valueForKey:@"_haveRequestState"] boolValue],
               "an empty viewport drops the record along with the set it describes");

            [wc setValue:real forKey:@"_pageView"];
            [blank release];
            [real release];
            // Put the controller back to a state the sections after this one can
            // rely on, rather than leaving them to inherit a torn-down one.
            [wc updateVisibleContent];
            PumpUntil(^{ return [(PVRenderQueue *)[wc valueForKey:@"_pageQueue"] isIdle]; }, 60.0);
        }

        printf("\n[5g] the page stays centred at every width, in every zoom mode\n");
        {
            PVPageView   *pv = [wc valueForKey:@"_pageView"];
            NSScrollView *sv = [wc valueForKey:@"_scrollView"];
            NSWindow     *w  = [wc window];

            struct { const char *name; SEL sel; } modes[] = {
                { "fit width",   @selector(zoomFitWidth:)   },
                { "fit page",    @selector(zoomFitPage:)    },
                { "actual size", @selector(zoomActualSize:) },
                { "custom zoom", @selector(zoomIn:)         },
            };
            CGFloat widths[] = { 700, 1100, 1900, 900 };   // ...including full-screen wide

            BOOL centred = YES, fills = YES;
            const char *worstMode = ""; CGFloat worstW = 0, worstLeft = 0, worstRight = 0;
            int mi, wi;
            for (mi = 0; mi < 4; mi++) {
                [wc performSelector:modes[mi].sel withObject:nil];
                for (wi = 0; wi < 4; wi++) {
                    NSRect fr = [w frame];
                    fr.size.width = widths[wi];
                    [w setFrame:fr display:YES];
                    [[NSNotificationCenter defaultCenter]
                        postNotificationName:NSViewFrameDidChangeNotification object:sv];
                    Pump(0.02);

                    CGFloat viewport = NSWidth([[sv contentView] bounds]);
                    CGFloat docW     = NSWidth([pv frame]);
                    NSRect  page     = [pv rectForPage:0];
                    CGFloat left  = NSMinX(page);
                    CGFloat right = docW - NSMaxX(page);

                    // The document view must never be narrower than the
                    // viewport, or AppKit pins it to the left and no amount of
                    // centring inside it can help.
                    if (docW < viewport - 0.5) fills = NO;
                    // And within it the page must sit in the middle, unless it
                    // is wider than the space and the margins are the minimum.
                    if (fabs(left - right) > 1.5 && left > PV_EDGE_GAP + 0.5) {
                        centred = NO;
                        worstMode = modes[mi].name; worstW = viewport;
                        worstLeft = left; worstRight = right;
                    }
                }
            }
            OK(fills, "the document view is never narrower than the viewport");
            if (!centred)
                printf("  worst: %s at %.0f pt wide -- left %.1f, right %.1f\n",
                       worstMode, worstW, worstLeft, worstRight);
            OK(centred, "the page is horizontally centred at every width and zoom mode");

            // Restore a sane window and mode for what follows.
            NSRect fr = [w frame]; fr.size.width = 900; [w setFrame:fr display:YES];
            [wc zoomFitWidth:nil];
            Pump(0.05);
        }

        // Pinch to zoom. It never worked on Mavericks because it was never
        // implemented: nothing answered -magnifyWithEvent:. Knowing when the
        // gesture has ENDED is the part that differs across the systems this
        // has to run on -- Mavericks does not populate NSEvent's phase for
        // gestures and signals the end with -endGestureWithEvent:, which
        // current systems no longer send. Both routes are handled, and both
        // are checked here, because a gesture that never ends leaves the
        // document permanently stretched and never re-rendered.
        printf("\n[5h] pinch to zoom, ending the way either system ends it\n");
        {
            PVPageView *pv = [wc valueForKey:@"_pageView"];
            [wc zoomFitWidth:nil];
            Pump(0.05);
            CGFloat before = [pv zoom];

            [wc pageViewWillMagnify:pv atPoint:NSMakePoint(300, 400)];
            OK([[wc valueForKey:@"_liveZooming"] boolValue],
               "the gesture is recognised as in progress");
            [wc pageView:pv magnifyBy:1.10];
            [wc pageView:pv magnifyBy:1.10];
            OK([pv zoom] > before, "the document zooms while the fingers move");
            OK(fabs([pv zoom] - before * 1.21) < 0.02,
               "successive steps multiply, so the gesture tracks the fingers");
            OK([[wc valueForKey:@"_zoomMode"] intValue] == PVZoomModeCustom,
               "a pinch leaves the zoom under the user's control, not snapped to a mode");

            [wc pageViewDidMagnify:pv];
            OK(![[wc valueForKey:@"_liveZooming"] boolValue], "and it ends");
            OK(PumpUntil(^{ return [(PVRenderQueue *)[wc valueForKey:@"_pageQueue"] isIdle]; }, 60.0),
               "the sharp pass is asked for once, when the fingers come off");

            // Limits: a pinch cannot drive the document outside the zoom range.
            int i;
            for (i = 0; i < 60; i++) [wc pageView:pv magnifyBy:1.3];
            OK([pv zoom] <= PV_MAX_ZOOM + 0.001, "a long pinch cannot exceed the maximum zoom");
            for (i = 0; i < 120; i++) [wc pageView:pv magnifyBy:0.8];
            OK([pv zoom] >= PV_MIN_ZOOM - 0.001, "or go below the minimum");

            // Nonsense from a misbehaving driver must not reach the layout.
            CGFloat sane = [pv zoom];
            [wc pageView:pv magnifyBy:(CGFloat)NAN];
            OK([pv zoom] == sane, "a non-finite magnification is ignored");

            // How the gesture ENDS is the part that differs by system, and the
            // view owns that decision, so it is driven through the view.
            // Gesture NSEvents have no public constructor, so the recognised
            // state is set the way -magnifyWithEvent: would have set it.
            [pv setDelegate:(id <PVPageViewDelegate>)wc];
            [pv setValue:[NSNumber numberWithBool:YES] forKey:@"_magnifying"];
            [wc pageViewWillMagnify:pv atPoint:NSMakePoint(300, 400)];
            OK([[wc valueForKey:@"_liveZooming"] boolValue], "a gesture is in progress");

            // Deliberately no event: -endGestureWithEvent: must not read one,
            // because the only way to reach it in a test is without one. The
            // current SDK annotates the parameter nonnull, so passing a literal
            // nil warns; a variable says the same thing without the diagnostic,
            // and the point of the check is that the implementation copes.
            NSEvent *noEvent = nil;

            [pv endGestureWithEvent:noEvent];      // the Mavericks route
            OK(![[wc valueForKey:@"_liveZooming"] boolValue],
               "-endGestureWithEvent: ends the gesture, which is how Mavericks ends it");
            OK(![[pv valueForKey:@"_magnifying"] boolValue],
               "and the view stops considering itself mid-gesture");

            // A second end -- a system that sends both a phase and a bracket --
            // must not report the gesture twice.
            [wc setValue:[NSNumber numberWithBool:YES] forKey:@"_liveZooming"];
            [pv endGestureWithEvent:noEvent];
            OK([[wc valueForKey:@"_liveZooming"] boolValue],
               "a second end is ignored rather than reported again");
            [wc setValue:[NSNumber numberWithBool:NO] forKey:@"_liveZooming"];

            // Two-finger double tap toggles, and comes back.
            [wc zoomFitWidth:nil];
            [wc pageViewSmartMagnify:pv atPoint:NSMakePoint(300, 400)];
            OK([[wc valueForKey:@"_zoomMode"] intValue] == PVZoomModeActual,
               "a two-finger double tap goes to actual size");
            [wc pageViewSmartMagnify:pv atPoint:NSMakePoint(300, 400)];
            OK([[wc valueForKey:@"_zoomMode"] intValue] == PVZoomModeFitWidth,
               "and back to fit width");

            [wc zoomFitWidth:nil];
            [wc goToPageNumber:37];
            PumpUntil(^{ return [(PVRenderQueue *)[wc valueForKey:@"_pageQueue"] isIdle]; }, 60.0);
        }

        printf("\n[5i] two pages side by side, through the real controller\n");
        {
            // The unit suite asserts the spread's geometry against PVPageView
            // directly. This asserts the things only the controller can be
            // wrong about: that the mode reaches the view at all, that the
            // reader keeps their place across it, that the wanted set and the
            // pins follow, and that turning it off puts everything back.
            [wc zoomFitWidth:nil];
            [wc goToPageNumber:37];
            PumpUntil(^{ return [(PVRenderQueue *)[wc valueForKey:@"_pageQueue"] isIdle]; }, 60.0);

            PVPageView   *pgv = [wc valueForKey:@"_pageView"];
            PVImageCache *pc  = [wc valueForKey:@"_pageCache"];
            NSScrollView *sv  = [wc valueForKey:@"_scrollView"];

            CGFloat singleZoom = [[wc valueForKey:@"_zoom"] doubleValue];
            NSUInteger before  = [wc currentPageWithFraction:NULL];
            OK([pgv laidOutColumns] == 1, "a document opens in the single-page column");

            [wc toggleTwoPageView:nil];
            Pump(0.5);
            OK([pgv laidOutColumns] == 2,
               "the menu action reaches the view's laid-out geometry, not just the ivar");
            OK([[wc valueForKey:@"_columns"] unsignedLongValue] == 2,
               "and the controller agrees with it");

            // The place in the document is kept. In the spread page 36 shares
            // its row with 37, so the row the reader is on begins at 36 --
            // which is the page they were on, not a page they have never seen.
            OK([wc currentPageWithFraction:NULL] ==
                   [pgv firstPageOfRowContainingPage:before],
               "the reader stays on the row holding the page they were reading");

            // Fit-width now has to fit two pages plus the gutter across the
            // same window, so the zoom must come down. This is the whole power
            // argument for the spread: the pixels stay bounded by the viewport.
            CGFloat spreadZoom = [[wc valueForKey:@"_zoom"] doubleValue];
            OK(spreadZoom < singleZoom,
               "fit-width in the spread zooms out rather than widening the document");

            // Both pages of the row are on screen, wanted, and pinned. A
            // spread that renders only its left half is the failure this pins.
            NSRect vis = [[sv contentView] documentVisibleRect];
            NSRange visible = [pgv pageRangeInRect:vis];
            OK(visible.length >= 2, "both pages of a spread are in the visible range");

            PumpUntil(^{ return [(PVRenderQueue *)[wc valueForKey:@"_pageQueue"] isIdle]; }, 60.0);
            NSUInteger firstOfRow = [pgv firstPageOfRowContainingPage:
                                        [wc currentPageWithFraction:NULL]];
            OK([pc hasAnyImageForPage:firstOfRow] &&
               [pc hasAnyImageForPage:firstOfRow + 1],
               "both pages of the spread get a bitmap");

            // The title is the only page indicator this app has.
            NSString *title = [[wc window] title];
            OK([title rangeOfString:@"pages "].location != NSNotFound &&
               [title rangeOfString:@"-"].location != NSNotFound,
               "the title names both pages of the spread");

            // Next and previous turn a whole spread. Stepping one page would
            // land on a page already on screen and move nothing.
            NSUInteger rowBefore = firstOfRow;
            [wc goToNextPage:nil];
            Pump(0.3);
            OK([pgv firstPageOfRowContainingPage:[wc currentPageWithFraction:NULL]] ==
                   rowBefore + 2,
               "next page turns both pages at once");
            [wc goToPreviousPage:nil];
            Pump(0.3);
            OK([pgv firstPageOfRowContainingPage:[wc currentPageWithFraction:NULL]] ==
                   rowBefore,
               "and previous comes back to the same spread");

            // The menu item reports the mode rather than renaming itself.
            NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:@"Two Pages"
                                                          action:@selector(toggleTwoPageView:)
                                                   keyEquivalent:@""] autorelease];
            OK([wc validateMenuItem:item], "the spread item is enabled on a multi-page document");
            OK([item state] == NSOnState, "and is checked while the spread is on");

            // And back out. The zoom, the layout and the reading position all
            // have to return to what they were, or a reader who tried the mode
            // once is left with a document that never quite goes back.
            [wc toggleTwoPageView:nil];
            Pump(0.5);
            OK([pgv laidOutColumns] == 1, "turning it off returns to one column");
            OK(fabs([[wc valueForKey:@"_zoom"] doubleValue] - singleZoom) < 0.0001,
               "and to the zoom it had before");
            OK([wc currentPageWithFraction:NULL] == rowBefore,
               "and to the page the reader was on");
            OK([wc validateMenuItem:item] && [item state] == NSOffState,
               "and the menu item is unchecked again");

            PumpUntil(^{ return [(PVRenderQueue *)[wc valueForKey:@"_pageQueue"] isIdle]; }, 60.0);
        }

        printf("\n[5j] a spread zoomed past the window renders only the page you can see\n");
        {
            // The saving this pins is invisible in every fitted layout, which
            // is why it survived review: at fit-width and fit-page the whole
            // spread is inside the window, so both pages always overlap it and
            // the cull never fires. Zoom in far enough and a row is wider than
            // the glass -- and until the cull existed, the scheduler went on
            // asking for a preview AND a full-resolution bitmap for the half of
            // the pair that had no pixels on screen at all.
            PVPageView   *pgv = [wc valueForKey:@"_pageView"];
            PVImageCache *pc  = [wc valueForKey:@"_pageCache"];
            NSScrollView *sv  = [wc valueForKey:@"_scrollView"];

            [wc zoomFitWidth:nil];
            if ([pgv laidOutColumns] != 2) [wc toggleTwoPageView:nil];
            Pump(0.4);

            // Zoom until one page on its own is wider than the window, which is
            // what makes the far page of the spread reachable-but-invisible.
            int guard = 0;
            while (guard++ < 40 &&
                   NSWidth([pgv rectForPage:0]) <=
                       NSWidth([[sv contentView] documentVisibleRect]))
                [wc zoomIn:nil];
            Pump(0.4);

            NSRect vp = [[sv contentView] documentVisibleRect];
            OK(NSWidth([pgv rectForPage:0]) > NSWidth(vp),
               "the spread is now wider than the window, so one page can be off screen");

            NSUInteger left  = [pgv firstPageOfRowContainingPage:
                                   [wc currentPageWithFraction:NULL]];
            NSUInteger right = left + 1;
            CGFloat    maxX  = NSWidth([pgv frame]) - NSWidth(vp);

            // Hard left: the right-hand page has no pixels on screen.
            [wc scrollClipTo:NSMakePoint(0, NSMinY(vp))];
            [pc removeAll];
            [wc setValue:[NSNumber numberWithDouble:0.0] forKey:@"_scrollSpeed"];
            [wc setValue:[NSNumber numberWithDouble:0.0] forKey:@"_lastScrollTime"];
            PVFullRequestCount = 0; PVPreviewRequestCount = 0;
            PVRequestedPages = [NSMutableIndexSet indexSet];
            PVCountRequests = YES;
            [wc setValue:[NSNumber numberWithBool:NO] forKey:@"_haveRequestState"];
            [wc updateVisibleContent];
            PVCountRequests = NO;
            NSMutableIndexSet *atLeft = PVRequestedPages;

            OK(![atLeft containsIndex:right],
               "scrolled hard left, the right-hand page is not asked for at all");
            OK([atLeft containsIndex:left],
               "...and the page actually on screen still is");

            // Hard right: the mirror image, which rules out an off-by-one that
            // would merely have moved the waste to the other page.
            [wc scrollClipTo:NSMakePoint(maxX, NSMinY(vp))];
            [pc removeAll];
            [wc setValue:[NSNumber numberWithDouble:0.0] forKey:@"_scrollSpeed"];
            [wc setValue:[NSNumber numberWithDouble:0.0] forKey:@"_lastScrollTime"];
            PVRequestedPages = [NSMutableIndexSet indexSet];
            PVCountRequests = YES;
            [wc setValue:[NSNumber numberWithBool:NO] forKey:@"_haveRequestState"];
            [wc updateVisibleContent];
            PVCountRequests = NO;
            NSMutableIndexSet *atRight = PVRequestedPages;

            OK(![atRight containsIndex:left],
               "scrolled hard right, the left-hand page is not asked for either");
            OK([atRight containsIndex:right],
               "...and the one now on screen is");

            // The rebuild has to actually happen on a sideways move. Culling
            // without this would drop the far page correctly on the way out and
            // never ask for it again on the way back in, because the early-out
            // keys on the visible page RANGE -- which does not change when you
            // scroll across a spread.
            [wc scrollClipTo:NSMakePoint(0, NSMinY(vp))];
            [pc removeAll];
            [wc updateVisibleContent];
            PVRequestedPages = [NSMutableIndexSet indexSet];
            PVCountRequests = YES;
            [wc scrollClipTo:NSMakePoint(maxX, NSMinY(vp))];
            [wc clipBoundsChanged:nil];
            PVCountRequests = NO;
            OK([PVRequestedPages containsIndex:right],
               "scrolling across the spread asks for the page that came into view");
            PVRequestedPages = nil;

            // And none of this may leak into the single-page column, where a
            // page always overlaps the window horizontally whatever x is.
            [wc toggleTwoPageView:nil];
            [wc zoomFitWidth:nil];
            Pump(0.4);
            [pc removeAll];
            [wc setValue:[NSNumber numberWithDouble:0.0] forKey:@"_scrollSpeed"];
            [wc setValue:[NSNumber numberWithDouble:0.0] forKey:@"_lastScrollTime"];
            PVRequestedPages = [NSMutableIndexSet indexSet];
            PVCountRequests = YES;
            [wc setValue:[NSNumber numberWithBool:NO] forKey:@"_haveRequestState"];
            [wc updateVisibleContent];
            PVCountRequests = NO;
            OK([PVRequestedPages count] > 0,
               "the single-page column still asks for the page it is showing");
            PVRequestedPages = nil;

            [wc zoomFitWidth:nil];
            [wc goToPageNumber:37];
            PumpUntil(^{ return [(PVRenderQueue *)[wc valueForKey:@"_pageQueue"] isIdle]; }, 60.0);
        }

        // Close the window the way the user would, then read back what was saved.
        [[wc window] performClose:nil];
        Pump(1.0);

        NSUInteger page = 0; CGFloat frac = 0, zoom = 0;
        PVZoomMode mode = PVZoomModeCustom; BOOL sidebar = YES;
        BOOL found = [[PVStateStore sharedStore] stateForURL:url page:&page fraction:&frac
                        zoomMode:&mode zoom:&zoom sidebar:&sidebar columns:NULL
                     windowFrame:NULL];
        printf("\n[6] position saved on close: found=%d page=%lu (expect 36, i.e. page 37)"
               " sidebar=%d zoom=%.2f\n", (int)found, (unsigned long)page, (int)sidebar, zoom);
        int bad = 0;
        if (!found)       { printf("  FAIL no state saved\n"); bad = 1; }
        if (page != 36)   { printf("  FAIL expected page index 36\n"); bad = 1; }
        if (sidebar)      { printf("  FAIL sidebar should be recorded as hidden\n"); bad = 1; }
        // Two steps up from fit-width, which at this window size is ~1.2.
        // Pinned now that the run starts from a known state.
        OK(zoom > 1.0 && zoom < 3.0, "zoom lands on a sane step, not saturated at the limit");
        if (!bad) printf("  ok reading position and sidebar state persisted correctly\n");

        // Reopening is the other half of persistence, and the title bar has to
        // agree with it. The page number lives there now rather than in a
        // toolbar field, which is what let the toolbar lose the page field, the
        // count label, the two flexible spaces and the counterweight that used
        // to hold them in the middle of the window.
        //
        // The old failure this pins is unchanged in shape: the title is
        // rewritten only when the page CHANGES, so a document restored to page
        // 37 has to say 37 from the moment the window exists, not from the
        // first time the user scrolls.
        printf("\n[7] reopening restores the page, and the title bar says so\n");
        {
            PVWindowController *wc2 = [[PVWindowController alloc] initWithSource:src url:url];
            NSString *before = [[wc2 window] title];
            // Read BEFORE -showWindow:, which is the first thing that would
            // update the indicator.
            OK([before rangeOfString:@"page 37 of"].location != NSNotFound,
               "the title is correct from the moment the window is built");
            [wc2 showWindow:nil];
            NSString *after = [[wc2 window] title];
            printf("  title reads \"%s\" (expect page 37 of 60)\n", [after UTF8String]);
            OK([after rangeOfString:@"page 37 of 60"].location != NSNotFound,
               "the title shows the restored page and the page count");
            OK([after rangeOfString:@"heavy.pdf"].location != NSNotFound,
               "...and names the document, as a document window should");
            OK([[wc2 window] representedURL] != nil,
               "the window has a represented URL, so it gets a proxy icon");

            // The toolbar is two items now, and both draw from the bundled
            // artwork rather than from text. A missing asset is a blank
            // button, which is not something a build should be able to ship.
            OK(PVToolbarImageNamed(@"TB_contentAndThumbs") != nil, "the sidebar icon is in the bundle");
            OK(PVToolbarImageNamed(@"TB_zoomIn")  != nil, "the zoom-in icon is in the bundle");
            OK(PVToolbarImageNamed(@"TB_zoomOut") != nil, "the zoom-out icon is in the bundle");
            OK([PVToolbarImageNamed(@"TB_zoomIn") isTemplate],
               "icons are template images, so they tint instead of staying black");
            OK(PVToolbarImageNamed(@"TB_doesNotExist") == nil,
               "a missing asset reports itself rather than returning a blank image");

            NSApplicationPresentationOptions proposed =
                NSApplicationPresentationFullScreen | NSApplicationPresentationAutoHideMenuBar;
            NSApplicationPresentationOptions actual = [wc2 window:[wc2 window]
                willUseFullScreenPresentationOptions:proposed];
            OK((actual & proposed) == proposed &&
               (actual & NSApplicationPresentationAutoHideToolbar) != 0,
               "full screen detaches and hides the toolbar until the top-edge reveal");

            NSArray *ids = [wc2 toolbarDefaultItemIdentifiers:[[wc2 window] toolbar]];
            OK([ids count] == 2, "the toolbar is down to two items");

            // Every item the same height, and none of them clipped: the zoom
            // control used to be pinned to 74 points for two 36-point segments,
            // which left nothing for the bezel and cut the outer edge off both
            // magnifiers on Mavericks.
            BOOL sameHeight = YES, fits = YES, matchingControls = YES;
            CGFloat firstH = -1;
            CGFloat firstControlH = -1;
            NSUInteger ii;
            for (ii = 0; ii < [ids count]; ii++) {
                NSToolbarItem *it = [wc2 toolbar:[[wc2 window] toolbar]
                           itemForItemIdentifier:[ids objectAtIndex:ii]
                       willBeInsertedIntoToolbar:YES];
                NSView *v = [it view];
                if (!v) continue;          // the flexible space has no view
                if (fabs([v frame].size.height - [it minSize].height) > 0.01) sameHeight = NO;
                if (firstH < 0) firstH = [v frame].size.height;
                else if (fabs([v frame].size.height - firstH) > 0.01) sameHeight = NO;
                // The control inside must fit the box it was given, or it is
                // being clipped.
                NSArray *subs = [v subviews];
                if ([subs count] > 0) {
                    NSRect cf = [(NSView *)[subs objectAtIndex:0] frame];
                    if (![(NSView *)[subs objectAtIndex:0] isKindOfClass:[NSSegmentedControl class]])
                        matchingControls = NO;
                    if (firstControlH < 0) firstControlH = cf.size.height;
                    else if (fabs(cf.size.height - firstControlH) > 0.01) matchingControls = NO;
                    if (NSMaxX(cf) > NSWidth([v frame]) + 0.01 ||
                        NSMaxY(cf) > NSHeight([v frame]) + 0.01 ||
                        NSMinX(cf) < -0.01 || NSMinY(cf) < -0.01) fits = NO;
                }
            }
            OK(sameHeight, "every toolbar item is the same height");
            OK(matchingControls, "toolbar children are equal-height segmented controls on Mavericks");
            OK(fits, "no toolbar control is clipped by the item that holds it");

            [[wc2 window] performClose:nil];
            Pump(0.5);
            [wc2 release];
        }

        // The one invariant that AppKit will not maintain on Postview's behalf.
        // A window that has ever been ordered on screen is retained by AppKit
        // for the life of the process -- verified independently against a bare
        // NSWindow with none of this code in it: closed, ordered out, tabbing
        // disallowed, releasedWhenClosed either way, a shown window is simply
        // never deallocated. So the window cannot be trusted to release what it
        // owns, and what it owns is the entire page view, its bitmap cache and
        // the CGPDFDocument behind them. Closing a document has to hand that
        // back regardless, or a day of opening files leaves every one of them
        // resident until the app quits.
        // The primary controller and its source, handed back before the
        // lifecycle baseline is taken.
        //
        // [8] below counts live PVPageView, PVImageCache and PVPDFSource
        // objects before and after one document cycle. This controller and its
        // source were still owned by this frame at that point -- alloc'd at the
        // top of main and never released -- so they sat inside every one of
        // those counts. The deltas the section asserts on still worked, which
        // is exactly why it went unnoticed: the baseline was inflated by two
        // objects the test itself was leaking, and a suite that leaks cannot
        // then be the evidence that nothing leaks.
        [wc release];  wc = nil;
        [src release]; src = nil;

        printf("\n[8] closing a document releases its content even though AppKit\n"
               "    keeps the window alive forever\n");
        {
            long viewsBefore   = PVLiveCount("PVPageView");
            long cachesBefore  = PVLiveCount("PVImageCache");
            long sourcesBefore = PVLiveCount("PVPDFSource");
            NSWindow *heldWindow = nil;

            // Scoped: -valueForKey: hands back an autoreleased reference, and
            // the pool it would otherwise land in is main's, which does not
            // drain until the process exits. Without this the test itself keeps
            // the view tree alive and then reports the app for it.
            @autoreleasepool {
                NSError *e2 = nil;
                PVPDFSource *s3 = [[PVPDFSource alloc] initWithURL:url error:&e2];
                PVWindowController *wc3 = [[PVWindowController alloc] initWithSource:s3 url:url];
                [wc3 showWindow:nil];
                Pump(0.4);
                OK(PVLiveCount("PVPageView") == viewsBefore + 1,
                   "the new document has a page view");

                heldWindow = [[wc3 window] retain];
                [[wc3 window] performClose:nil];
                Pump(0.3);
                OK([[wc3 valueForKey:@"_splitView"] superview] == nil,
                   "closing detaches the view tree from the window");
                OK([heldWindow toolbar] == nil, "and takes the toolbar with it");

                [wc3 release];
                [s3 release];
            }

            OK(PumpUntil(^{ return (BOOL)(PVLiveCount("PVPageView") == viewsBefore); }, 20.0),
               "releasing the controller frees the page view");
            // The page view is what holds the cache and the document, so these
            // are the numbers that say the memory actually came back.
            //
            // Waited for, not sampled once. These two used to be bare
            // comparisons taken the instant the page view count reached zero,
            // on the assumption that whatever the page view held died with it.
            // It does not have to: the render queue's worker block holds its own
            // reference to the source until it next looks at the stop flags, and
            // a delivery already queued holds the cache until it runs on the
            // main thread -- the same asynchronous unwind pvstress's
            // SettlesToZero exists for. So the assertion was racing, and it lost
            // roughly one run in three on this host: `and the parsed PDF behind
            // it` failed while `and the bitmap cache it held` passed, and both
            // passed on the immediately following run.
            //
            // A deadline keeps the assertion honest -- an object that never
            // comes back still fails, twenty seconds later -- while a single
            // sample was only ever asserting that this machine happened to be
            // quick enough. A flaky gate is worse than a missing one: it teaches
            // you to re-run until green, which is exactly how the ASan failure
            // in ENGINEERING.md section 9.6 survived for as long as it did.
            OK(PumpUntil(^{ return (BOOL)(PVLiveCount("PVImageCache") == cachesBefore); }, 20.0),
               "and the bitmap cache it held");
            OK(PumpUntil(^{ return (BOOL)(PVLiveCount("PVPDFSource") == sourcesBefore); }, 20.0),
               "and the parsed PDF behind it");
            printf("  (AppKit is still holding that window: isVisible=%d, never deallocated)\n",
                   (int)[heldWindow isVisible]);
            [heldWindow release];
        }

        printf("\n%d passed, %d failed\n", gPass, gFail);
        return (bad || gFail) ? 1 : 0;
    }
}

#pragma mark ======================= soak =======================

// One full open/use/close cycle, exactly as the app performs it.
static void Cycle(NSURL *url, int i)
{
    @autoreleasepool {
        NSError *err = nil;
        PVPDFSource *src = [[PVPDFSource alloc] initWithURL:url error:&err];
        if (!src) { fprintf(stderr, "open failed\n"); exit(2); }

        PVWindowController *wc = [[PVWindowController alloc] initWithSource:src url:url];
        [wc showWindow:nil];
        Pump(0.05);

        [wc goToPageNumber:(i % 40) + 1];      // jump somewhere new each time
        Pump(0.03);
        [wc zoomIn:nil];
        [wc zoomIn:nil];
        Pump(0.03);
        [wc toggleSidebar:nil];                // builds the second source+queue+cache
        Pump(0.06);
        [wc toggleSidebar:nil];                // and tears the bitmaps back down
        [wc zoomFitWidth:nil];
        [wc goToPageNumber:1];
        Pump(0.03);

        [[wc window] performClose:nil];        // the real teardown path
        Pump(0.03);
        [wc release];
        [src release];
    }
    // Let any in-flight render finish and release its queue.
    Pump(0.05);
}

static int RunSoak(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: pvsuite soak <pdf> [cycles]\n"); return 2; }
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        int cycles = (argc > 2) ? atoi(argv[2]) : 60;
        if (cycles < 20) cycles = 20;

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        printf("[cache accounting]\n");
        {
            // The byte counter must track what CoreGraphics really allocated,
            // including the row padding CG adds, and must never be driven
            // negative by unbalanced bookkeeping.
            PVImageCache *c = [[PVImageCache alloc] initWithBudget:4 * 1024 * 1024];
            NSError *e = nil;
            PVPDFSource *s = [[PVPDFSource alloc] initWithURL:url error:&e];
            size_t expect = 0;
            int i;
            for (i = 0; i < 12; i++) {
                CGSize px = CGSizeMake(301, 407);   // deliberately not row-aligned
                CGImageRef im = [s createImageForPage:(NSUInteger)i pixelSize:px];
                if (!im) continue;
                [c setFullImage:im pixelSize:px forPage:(NSUInteger)i];
                expect = PVImageBytes(im);
                CGImageRelease(im);
            }
            OK(expect > (size_t)(301 * 407 * 4),
               "byte accounting uses the real row-padded size, not width*height*4");
            OK([c byteCount] <= 4 * 1024 * 1024, "cache stays inside its byte budget");
            [c dropFullImages];
            OK([c byteCount] == 0, "dropping every full image returns the counter to zero");
            OK([c entryCount] == 0, "emptied entries are removed, not left behind");
            [c removeAll];
            OK([c byteCount] == 0, "removeAll leaves a zero byte count");
            [s release];
            [c release];
        }

        printf("\n[render queue lifecycle]\n");
        {
            NSError *e = nil;
            PVPDFSource *s = [[PVPDFSource alloc] initWithURL:url error:&e];
            PVRenderQueue *q = [[PVRenderQueue alloc] initWithSource:s label:"soak"];
            [q setDesiredRequests:[NSArray arrayWithObject:
                [PVRenderRequest page:0 pixels:CGSizeMake(400, 520)
                             priority:PVPriorityVisibleFull preview:NO]]];
            // Shut down while work is very likely still in flight. This must
            // not block the caller and must not deadlock.
            NSDate *t0 = [NSDate date];
            [q shutdown];
            double blocked = -[t0 timeIntervalSinceNow];
            OK(blocked < 0.050, "shutdown does not block the caller on an in-flight page");
            Pump(0.4);
            OK([q isIdle], "queue reports idle once the drain has unwound");
            // The marker that keeps a rendered-but-undelivered page from being
            // rendered again. If it could ever be left behind, that page would
            // be permanently unrequestable for the life of the document -- a
            // page that never goes sharp, which is exactly the class of fault
            // that only shows up after a long session.
            OK([q inFlightCount] == 0, "no work is left marked in flight after a shutdown");
            [q release];
            Pump(0.4);
            OK(PVLiveCount("PVRenderQueue") == 0,
               "a queue released while draining is still deallocated");
            [s release];
        }

        {
            const char * const *tr = PVLiveTrackedClasses();
            int t2, dirty = 0;
            for (t2 = 0; tr[t2]; t2++) if (PVLiveCount(tr[t2]) != 0) dirty = 1;
            OK(!dirty, "census is clean before the soak begins");
        }

        printf("\n[soak: %d open/use/close cycles]\n", cycles);
        // The allocator returns pages to the OS in large irregular steps, so a
        // single before/after reading of the footprint is close to meaningless:
        // across a flat run it swings tens of megabytes either way. The trend
        // is taken from the MEDIAN of each half instead, which is insensitive
        // to that sawtooth while still exposing any genuine monotonic climb.
        int warm = 25;
        int i;
        for (i = 0; i < warm; i++) Cycle(url, i);
        double base = FootprintMB();
        printf("  footprint after %d warm-up cycles: %.1f MB\n", warm, base);

        double *samples = (double *)calloc((size_t)cycles, sizeof(double));
        if (!samples) { fprintf(stderr, "out of memory\n"); return 2; }
        // The warm-up's peaks say nothing about the steady state, and the
        // high-water mark is a maximum: without a reset here it would report
        // whatever the first twenty-five cycles happened to touch, forever.
        PVResidentReset();
        double peak = base;
        for (i = 0; i < cycles; i++) {
            Cycle(url, warm + i);
            samples[i] = FootprintMB();
            if (samples[i] > peak) peak = samples[i];
            if ((i + 1) % 25 == 0)
                printf("  after %3d more cycles: %6.1f MB\n", i + 1, samples[i]);
        }

        // The direct invariant. Process footprint is a noisy proxy dominated by
        // the frameworks' own caches; this is the thing actually under our
        // control, and it must go to exactly zero.
        //
        // AppKit defers the last window's release by an indeterminate number of
        // runloop turns, so the most recently closed document is legitimately
        // still alive for a moment after -performClose: returns. Waiting a
        // fixed interval made this test flaky on a busy machine. Instead, wait
        // for the census to clear with a deadline: a genuine leak never clears
        // and still fails, while normal teardown latency no longer decides the
        // result. How long it took is reported, so a regression that slows
        // teardown down is visible rather than silently absorbed.
        printf("\n[live objects after %d cycles]\n", warm + cycles);
        const char * const *tracked = PVLiveTrackedClasses();
        int t;
        double waited = 0.0;
        // A passing run breaks out the instant the census clears and pays none
        // of this, so the deadline only needs to be past any plausible teardown
        // latency. Rendering runs at background QoS by design, so a queue shut
        // down mid-page can legitimately take a moment to retire; what must
        // never happen is the count sitting still, which is what a genuine leak
        // -- or a starved render queue -- looks like. How long it actually took
        // is printed either way, so a regression that slows teardown is visible
        // rather than absorbed.
        const double kDeadline = 30.0;
        for (;;) {
            int outstanding = 0;
            for (t = 0; tracked[t]; t++)
                if (PVLiveCount(tracked[t]) != 0) outstanding++;
            if (!outstanding || waited >= kDeadline) break;
            @autoreleasepool { Pump(0.05); }
            waited += 0.05;
        }
        printf("  (all documents retired %.2f s after the last close)\n", waited);
        OK(waited < kDeadline, "teardown completes well inside the deadline");
        for (t = 0; tracked[t]; t++) {
            long n = PVLiveCount(tracked[t]);
            char msg[160];
            snprintf(msg, sizeof msg, "%-20s live=%ld (expected 0)", tracked[t], n);
            OK(n == 0, msg);
        }

        // ------------------------------------------------------------------
        // Resident rendered pixels.
        //
        // The footprint trend below is a proxy: it is dominated by AppKit,
        // CoreText and CoreGraphics filling their own caches, and by an
        // allocator that returns pages in irregular steps. This section is the
        // part of the footprint Postview actually decides, measured directly.
        //
        // Two claims, and the second is the one that matters. The high-water
        // marks say how much was resident at the worst instant of the run --
        // the number every memory change in the render pipeline is aimed at.
        // The totals say what is resident now, after every document has been
        // closed and every queue shut down, and that must be exactly zero: a
        // census that does not return to zero is not measuring what it claims
        // to, and any peak it reports is a number about nothing.
        // ------------------------------------------------------------------
        printf("\n[resident rendered pixels]\n");
        const double kMB = 1024.0 * 1024.0;
        printf("  high water, all buckets      : %.1f MB\n",
               (double)PVResidentHighWater() / kMB);
        printf("    of which cache             : %.1f MB\n",
               (double)PVResidentHighWaterForBucket(PVResidentCache) / kMB);
        printf("    of which undelivered       : %.1f MB  (cap %d full bitmaps)\n",
               (double)PVResidentHighWaterForBucket(PVResidentUndelivered) / kMB,
               PV_MAX_INFLIGHT_FULL);
        printf("    of which mid-rasterisation : %.1f MB\n",
               (double)PVResidentHighWaterForBucket(PVResidentRender) / kMB);
        {
            size_t leftRender      = PVResidentBytes(PVResidentRender);
            size_t leftUndelivered = PVResidentBytes(PVResidentUndelivered);
            size_t leftCache       = PVResidentBytes(PVResidentCache);
            size_t leftTotal       = PVResidentTotal();
            char msg[200];
            printf("  still resident after teardown: %.3f MB "
                   "(render %.3f, undelivered %.3f, cache %.3f)\n",
                   (double)leftTotal / kMB, (double)leftRender / kMB,
                   (double)leftUndelivered / kMB, (double)leftCache / kMB);
            snprintf(msg, sizeof msg,
                     "resident bitmap census returns to zero (%lu bytes left)",
                     (unsigned long)leftTotal);
            OK(leftTotal == 0, msg);
        }

        // The memory the old gate could not see.
        //
        // Everything above measures mach_task_self(), which stopped describing
        // this program when rasterisation moved into a child process. The
        // helper holds one CGPDFDocumentRef for its whole life and Quartz never
        // gives back what it caches behind that -- fonts, shadings, decoded
        // images -- so the footprint that matters is the parent's plus every
        // helper's, and it is the helper's that grows.
        //
        // Hundreds of renders of ONE document, which is the shape of a reading
        // session and the shape the old single-pool helper grew under. The
        // large frames are included deliberately: they are the other trigger
        // for retiring a helper, and a zoomed page is where the parse cache is
        // biggest.
        printf("\n[helper process footprint]\n");
        {
            NSError *e = nil;
            PVPDFSource *s = [[PVPDFSource alloc] initWithURL:url error:&e];
            OK(s != nil, "a source for the helper footprint run");

            const int kRenders = 200;
            double helperPeak = 0, aggregatePeak = 0;
            double *helperSamples = (double *)calloc(kRenders, sizeof(double));
            NSMutableSet *pidsSeen = [NSMutableSet set];
            int r, rendered = 0;

            for (r = 0; s && r < kRenders; r++) {
                // Mostly ordinary reading sizes, with every sixteenth render a
                // deliberately enormous one. PVClampPixelSize holds it to the
                // machine's ceiling, which on a large-memory tier is past
                // PV_HELPER_LARGE_FRAME -- so this exercises the size trigger
                // as well as the count trigger.
                CGSize px = (r % 64 == 63) ? CGSizeMake(6000, 7800)
                                           : CGSizeMake(900 + (r % 5) * 60,
                                                        1160 + (r % 5) * 78);
                CGImageRef im = [s createImageForPage:(NSUInteger)(r % [s pageCount])
                                            pixelSize:px];
                if (im) { rendered++; CGImageRelease(im); }

                double h = HelperResidentMB();
                helperSamples[r] = h;
                if (h > helperPeak) helperPeak = h;
                double aggregate = FootprintMB() + h;
                if (aggregate > aggregatePeak) aggregatePeak = aggregate;

                // Which helper served it. A helper that is never retired keeps
                // one pid for the whole run; recycling shows up here as several.
                pid_t child = FirstChildPid();
                if (child > 0)
                    [pidsSeen addObject:[NSNumber numberWithInt:(int)child]];
            }

            char msg[240];
            snprintf(msg, sizeof msg, "%d of %d renders succeeded", rendered, kRenders);
            OK(rendered >= kRenders - 2, msg);

            // The gate can see the helper at all. This is the actual defect:
            // not that the number was too large, but that it was not in the
            // measurement, so no threshold anywhere could have caught it.
            snprintf(msg, sizeof msg,
                     "helper memory is visible to the gate (peak %.1f MB in children)",
                     helperPeak);
            OK(helperPeak > 0.5, msg);

            double h1 = Median(helperSamples, kRenders / 2, kRenders * 3 / 4);
            double h2 = Median(helperSamples, kRenders * 3 / 4, kRenders);
            printf("  helper resident, median    : %.1f -> %.1f MB "
                   "(second half of the run)\n", h1, h2);
            printf("  helper resident, peak      : %.1f MB\n", helperPeak);
            printf("  parent + helpers, peak     : %.1f MB\n", aggregatePeak);
            printf("  distinct helpers over %d renders: %lu\n",
                   kRenders, (unsigned long)[pidsSeen count]);

            // Recycling happened. Without it one process serves all four
            // hundred renders and its parse cache only ever grows.
            snprintf(msg, sizeof msg,
                     "the helper is retired and replaced during a long session "
                     "(%lu distinct helpers)", (unsigned long)[pidsSeen count]);
            OK([pidsSeen count] >= 2, msg);

            // And the footprint is flat across the back half rather than
            // climbing. Generous, because a helper's resident set steps up and
            // down as documents are parsed and processes are replaced; what is
            // being excluded is a monotonic climb, which over four hundred
            // renders would be unmistakable.
            snprintf(msg, sizeof msg,
                     "helper memory does not climb across a long session "
                     "(%+.1f MB over the last %d renders)", h2 - h1, kRenders / 4);
            OK(h2 - h1 < 60.0, msg);

            free(helperSamples);
            [s release];
            // Releasing the source kills and reaps its helper, so nothing is
            // left behind for the cycle trend below to attribute to itself.
            OK(HelperResidentMB() < 0.001,
               "releasing the source leaves no helper process behind");
        }

        printf("\n[footprint trend]\n");
        // Measured over the LAST half of the run, not the whole of it.
        //
        // The question this has to answer is whether the process is still
        // growing once it has settled, because that is what decides whether a
        // document can be left open for days. Comparing the first half against
        // the second answers a different question -- it includes the frameworks
        // filling their own caches, which is a fixed cost paid once and looks
        // exactly like a slow leak while it is being paid.
        //
        // It is not a small effect. A 400-cycle run climbs 169 -> 180 -> 197 MB
        // and then stops, flat to within a megabyte for the last hundred
        // cycles; measured across the whole run that reads as +0.06 MB/cycle,
        // and measured across only the first 150 it reads as +0.26, purely
        // because the fill is still in progress there. Two quarters at the end
        // of the run see none of it.
        int q = cycles / 4;
        if (q < 2) q = 2;
        double m1 = Median(samples, cycles - 2 * q, cycles - q);
        double m2 = Median(samples, cycles - q, cycles);
        double climb = m2 - m1;
        double perCycle = climb / q;

        // Reported as well, because the difference between the two is the size
        // of the one-off fill and is worth being able to see.
        double whole1 = Median(samples, 0, cycles / 2);
        double whole2 = Median(samples, cycles / 2, cycles);

        printf("\n  median footprint, whole run  : %.1f -> %.1f MB (includes cache warm-up)\n",
               whole1, whole2);
        printf("  median footprint, settled    : %.1f -> %.1f MB (last %d cycles)\n",
               m1, m2, 2 * q);
        printf("  climb once settled %+.2f MB across %d cycles = %+.4f MB per cycle, peak %.1f MB\n",
               climb, q, perCycle, peak);

        // Secondary, and only asserted when there are enough samples to mean
        // anything. Postview's own accounting is pinned exactly by the census
        // above; what is left in this number is AppKit, CoreText and
        // CoreGraphics filling their internal caches, plus an allocator that
        // returns pages to the OS in large irregular steps. Across three
        // identical 50-cycle runs this figure came out at +0.02, +0.20 and
        // +0.98 MB/cycle -- it is simply too noisy to assert on at that sample
        // size, and a test that fails at random is worse than no test. Given
        // enough cycles it settles, so it is asserted there and reported
        // otherwise. A real runaway shows up in the census first regardless:
        // one leaked page bitmap per cycle is ~4 MB, fifty times this limit.
        //
        // The threshold is set well clear of the noise band rather than just
        // above it. What it needs to catch is memory growing outside the
        // census -- a CGImage that never reaches the cache, say -- and that is
        // megabytes per cycle, not kilobytes.
        const int kMinSamplesToAssert = 150;
        if (cycles >= kMinSamplesToAssert) {
            OK(perCycle < 0.250, "footprint shows no runaway growth per cycle");
        } else {
            printf("  note  footprint trend not asserted below %d cycles "
                   "(too noisy); run `make soak SOAKCYCLES=%d`\n",
                   kMinSamplesToAssert, kMinSamplesToAssert);
        }
        OK(peak - m1 < 80.0, "no unbounded peak across the run");
        free(samples);

        printf("\n%d passed, %d failed\n", gPass, gFail);
        return gFail ? 1 : 0;
    }
}

#pragma mark ====================== stress ======================

// Every teardown here is asynchronous by design: the worker holds its own
// reference until it next looks at the stop flags, and the delivery it may
// already have queued holds one until it runs on the main thread. So the
// assertion is "settles to zero", not "is zero the instant we ask" -- with a
// deadline, because "eventually" is exactly the bug this is looking for.
// Under ThreadSanitizer a page render is an order of magnitude slower, so the
// deadline is generous; a real leak still fails, it just fails at the end.
// Multiplier on every deadline below, from PVSTRESS_DEADLINE_SCALE.
//
// The deadlines are a claim about how long an unwind should take, and that is a
// property of the code. What they were being compared against is wall-clock
// time, which is a property of the build: a page render under a sanitizer is
// an order of magnitude slower than in the shipping configuration, and
// address+undefined is slower again than thread. One constant across all three
// is a constant that means three different things.
//
// Recorded 2026-08-31: the address+undefined build failed the two 60-round
// unwinds on this host -- 18 and 10 objects still live at the deadline -- while
// the plain and thread builds passed the same assertions, and `leakcheck`
// reported nothing leaked. Everything unwound; it did not unwind inside a
// number chosen for a faster build. The failure was invisible for as long as it
// was because `verify-all` piped each gate through `tail` and read the
// pipeline's status instead of the gate's, so it printed "every gate passed"
// two lines after printing the error.
//
// Deliberately a multiplier and not a longer constant: a real leak has to keep
// failing, and it does -- it just takes proportionally longer to say so.
static double DeadlineScale(void)
{
    static double scale = 0;
    if (scale > 0) return scale;
    const char *env = getenv("PVSTRESS_DEADLINE_SCALE");
    double v = env ? atof(env) : 1.0;
    if (!(v >= 1.0) || !isfinite(v)) v = 1.0;
    scale = v;
    return scale;
}

static BOOL SettlesToZero(const char *cls, double deadline)
{
    deadline *= DeadlineScale();
    double waited = 0;
    while (waited < deadline) {
        if (PVLiveCount(cls) == 0) return YES;
        @autoreleasepool { Pump(0.05); }
        waited += 0.05;
    }
    return PVLiveCount(cls) == 0;
}

// Wait for a queue to go quiet, with a deadline, instead of guessing at a
// duration.
//
// Shutdown is asynchronous: the worker sees the flag on its next iteration and
// the delivery it may already have queued runs on the main thread after that.
// The old form was a flat Pump(0.40) followed immediately by the assertion,
// which makes the test a claim about how long a page render takes on the host
// that happens to be running it -- and a page render varies by an order of
// magnitude between the plain, address and thread builds, and again between
// this laptop and the Mac Pro. Two of the plain runs recorded on 2026-08-31
// failed here for that reason and nothing else.
//
// The deadline is generous and the exit is a condition, so a queue that
// genuinely never settles still fails -- it just takes longer to say so.
static BOOL QueueSettles(PVRenderQueue *q, double deadline)
{
    double waited = 0;
    deadline *= DeadlineScale();
    while (waited < deadline) {
        if ([q isIdle] && [q inFlightCount] == 0) return YES;
        @autoreleasepool { Pump(0.05); }
        waited += 0.05;
    }
    return ([q isIdle] && [q inFlightCount] == 0);
}

// Reports the count it actually saw, so a failure says how far off it was
// rather than only that it was not zero.
static void CensusIsZero(const char *cls, const char *what, double deadline)
{
    BOOL ok = SettlesToZero(cls, deadline);
    if (ok) { gPass++; printf("  ok    %s\n", what); }
    else    { gFail++; printf("  FAIL  %s (live=%ld)\n", what, PVLiveCount(cls)); }
}

// A deterministic PRNG, so a failure found here is a failure that can be
// reproduced. rand() is seeded per-process and would make every run a
// different test.
static unsigned int gSeed = 0x5eed1234u;
static unsigned int Rnd(void)
{
    gSeed = gSeed * 1103515245u + 12345u;
    return (gSeed >> 16) & 0x7fffu;
}

#pragma mark - Queue-level contention

// Hammer -setDesiredRequests: from the main thread while the worker is picking
// requests off the other end. This is the app's hottest lock by a wide margin:
// during a live scroll it is taken on every bounds notification, and the worker
// takes it once per page and once per delivery.
// Somewhere to notice that renders happened at all.
//
// Every assertion in this harness is about TEARDOWN -- queues settle, objects
// reach a zero census, nothing survives a close. Every one of them is equally
// true of a build in which no page ever rendered: a queue that fails all sixty
// requests settles just as cleanly as one that served them, and the census is
// just as zero. So the sanitizer runs that this file is the gate for could have
// been reporting on a viewer that rasterised nothing, and would have passed.
//
// It counts failures too, and separately. A failure is not a crash and this
// harness is not a correctness suite -- what would be wrong is silence.
static int gDelivered = 0;
static int gFailed = 0;

@interface PVStressCollector : NSObject <PVRenderQueueDelegate>
@end

@implementation PVStressCollector
- (void)renderQueue:(PVRenderQueue *)queue
      didRenderPage:(NSUInteger)page
              image:(CGImageRef)image
          pixelSize:(CGSize)px
            preview:(BOOL)preview
{
    (void)queue; (void)page; (void)px; (void)preview;
    if (image) gDelivered++;
}
- (void)renderQueue:(PVRenderQueue *)queue
        didFailPage:(NSUInteger)page
          pixelSize:(CGSize)px
            preview:(BOOL)preview
{
    (void)queue; (void)page; (void)px; (void)preview;
    gFailed++;
}
@end

static void StressQueueChurn(NSURL *url, int rounds)
{
    printf("\n[queue churn: %d rounds of wanted-set replacement under load]\n", rounds);
    NSError *err = nil;
    PVPDFSource *src = [[PVPDFSource alloc] initWithURL:url error:&err];
    if (!src) { printf("  FAIL  could not open fixture\n"); gFail++; return; }

    NSUInteger pages = [src pageCount];
    @autoreleasepool {
    PVRenderQueue *q = [[PVRenderQueue alloc] initWithSource:src label:"com.postview.stress"];
    PVStressCollector *collector = [[PVStressCollector alloc] init];
    [q setDelegate:collector];
    int i;
    for (i = 0; i < rounds; i++) {
        NSMutableArray *reqs = [NSMutableArray array];
        NSUInteger base = (NSUInteger)(Rnd() % (unsigned)pages);
        int k;
        for (k = 0; k < 6; k++) {
            NSUInteger p = (base + (NSUInteger)k) % pages;
            // Vary the size so some requests match work already in flight and
            // some deliberately do not.
            CGFloat scale = 1.0 + (CGFloat)(i % 3) * 0.25;
            [reqs addObject:[PVRenderRequest page:p
                                           pixels:CGSizeMake(220 * scale, 300 * scale)
                                         priority:(k & 1) ? PVPriorityNearFull
                                                          : PVPriorityVisiblePreview
                                          preview:(k & 1) ? NO : YES
                                          express:(i % 17 == 0 && k == 0)]];
        }
        [q setDesiredRequests:reqs];
        // Interleave the two state flips that can race the worker's own
        // check-and-clear of the running slot.
        if (i % 5 == 0)  [q setSuspended:YES];
        if (i % 5 == 1)  [q setSuspended:NO];
        if (i % 23 == 0) Pump(0.002);
    }
    [q setSuspended:NO];
    Pump(0.30);

    // Waited for, not raced against.
    //
    // The churn above is deliberately hostile to completion -- it replaces the
    // wanted set 400 times without letting the queue breathe -- so whether any
    // bitmap survives to delivery in a flat 0.30 s is a statement about how
    // fast the host is, not about whether the renderer works. Measured before
    // this wait existed: exactly ONE bitmap delivered across the whole phase,
    // and zero as soon as anything shifted the timing slightly. That is the
    // same mistake the flat teardown deadlines made, and it gets the same fix.
    //
    // The queue is idle here and the last wanted set is still outstanding, so
    // this returns as soon as the first page lands and only spends the full
    // deadline when nothing is going to.
    {
        double waited = 0, limit = 30.0 * DeadlineScale();
        while (gDelivered == 0 && waited < limit) {
            Pump(0.05);
            waited += 0.05;
        }
    }

    [q shutdown];
    // Waited for, not guessed at: see QueueSettles.
    BOOL settled = QueueSettles(q, 30.0);
    OK(settled, "queue settles after churn and shutdown");
    OK([q isIdle], "queue is idle after churn and shutdown");
    OK([q inFlightCount] == 0, "nothing is left marked in flight after churn");
    // The assertion this file existed without. Without it every sanitizer run
    // below is a statement about a viewer that may have drawn nothing.
    OK(gDelivered > 0, "the renderer actually produced bitmaps during churn");
    if (gDelivered == 0)
        printf("        (delivered=%d failed=%d -- no page rendered at all)\n",
               gDelivered, gFailed);
    [q setDelegate:nil];
    [collector release];
    [q release];
    }
    [src release];
    CensusIsZero("PVRenderQueue", "every churned queue was deallocated", 20.0);
}

// Release the queue while it is mid-render and never call -shutdown first. The
// worker block holds its own reference, so this must still unwind cleanly.
static void StressAbandonMidRender(NSURL *url, int rounds)
{
    printf("\n[abandon: %d queues released while rasterising]\n", rounds);
    NSError *err = nil;
    PVPDFSource *src = [[PVPDFSource alloc] initWithURL:url error:&err];
    if (!src) { printf("  FAIL  could not open fixture\n"); gFail++; return; }
    int i;
    for (i = 0; i < rounds; i++) {
        @autoreleasepool {
            // Its own source, not the shared one.
            //
            // These queues are abandoned mid-render and are therefore all alive
            // and rasterising at the same time. Handing every one of them the
            // same PVPDFSource had sixty render lanes driving one source
            // concurrently -- which is exactly what PVPDFSource.h says must
            // never happen, so the harness was violating the contract it exists
            // to test rather than testing it. Geometry is copied from `src` and
            // the snapshot underneath is shared, so this costs one
            // CGPDFDocumentCreate per round and not one file copy.
            PVPDFSource *own = [[PVPDFSource alloc] initWithURL:url
                                                  geometryFrom:src
                                                         error:NULL];
            if (!own) { printf("  FAIL  could not open a per-queue source\n"); gFail++; break; }
            PVRenderQueue *q = [[PVRenderQueue alloc] initWithSource:own
                                                               label:"com.postview.stress.abandon"];
            [own release];
            NSMutableArray *reqs = [NSMutableArray array];
            int k;
            for (k = 0; k < 4; k++)
                [reqs addObject:[PVRenderRequest page:(NSUInteger)k
                                               pixels:CGSizeMake(700, 950)
                                             priority:PVPriorityVisibleFull preview:NO]];
            [q setDesiredRequests:reqs];
            Pump(0.001);              // let the worker get its teeth into a page
            [q release];              // no -shutdown: the abandoned-object path
        }
    }
    // Every abandoned queue's worker has to unwind and drop its own reference.
    // An abandoned queue is not cancelled -- nobody called -shutdown -- so it
    // finishes the whole set it was given before its last reference goes. That
    // is the point of the check: the unwinding has to complete, not be quick.
    // Under ThreadSanitizer a full-resolution page is an order of magnitude
    // slower, so the deadline is sized for that; a queue that never unwinds
    // still fails.
    CensusIsZero("PVRenderQueue", "abandoned queues all deallocated", 120.0);
    [src release];
}

#pragma mark - Controller-level contention

// The real thing: a live controller with a busy queue, taking the whole set of
// asynchronous events the app can receive, in an order no user would produce
// but the system can.
static void StressControllerEvents(NSURL *url, int rounds)
{
    printf("\n[controller: %d rounds of interleaved events under render load]\n", rounds);
    NSError *err = nil;
    PVPDFSource *src = [[PVPDFSource alloc] initWithURL:url error:&err];
    if (!src) { printf("  FAIL  could not open fixture\n"); gFail++; return; }

    NSUInteger pages = [src pageCount];

    // The controller's entire life is inside a pool. AppKit retains and
    // autoreleases a delegate around its own callbacks, so a controller left
    // in the enclosing pool's scope is still referenced when the census runs,
    // and the census reads it as a leak that is not one.
    @autoreleasepool {
    PVWindowController *wc = [[PVWindowController alloc] initWithSource:src url:url];
    [wc showWindow:nil];
    Pump(0.05);

    int i;
    for (i = 0; i < rounds; i++) {
        @autoreleasepool {
            switch (Rnd() % 10) {
                case 0: [wc goToPageNumber:(NSInteger)(Rnd() % (unsigned)pages) + 1]; break;
                case 1: [wc zoomIn:nil];  break;
                case 2: [wc zoomOut:nil]; break;
                case 3: [wc zoomFitWidth:nil]; break;
                // Memory pressure while pages are mid-flight: the delivery
                // that lands afterwards writes into a cache that was emptied
                // between its render starting and its bitmap arriving.
                case 4: [wc memoryPressure:nil]; break;
                // Occlusion suspends the queue mid-page.
                case 5: [wc windowOcclusionChanged:nil]; break;
                // A display change empties the cache under queued deliveries.
                case 6: [wc backingPropertiesChanged:nil]; break;
                case 7: [wc willStartLiveScroll:nil];
                        [wc scrollToPage:(NSUInteger)(Rnd() % (unsigned)pages) fraction:0.5];
                        [wc clipBoundsChanged:nil];
                        [wc didEndLiveScroll:nil]; break;
                case 8: [wc showSidebar]; break;
                case 9: [wc hideSidebar]; break;
            }
            // Most rounds do not pump at all, so events pile onto a queue that
            // is still working through the previous round's set.
            if ((Rnd() % 8) == 0) Pump(0.004);
        }
    }
    Pump(0.40);

    [[wc window] performClose:nil];
    Pump(0.05);
    [wc release];
    }
    [src release];

    CensusIsZero("PVWindowController", "controller deallocated after event storm", 20.0);
    CensusIsZero("PVRenderQueue",      "both render queues deallocated",           20.0);
    CensusIsZero("PVImageCache",       "both caches deallocated",                  20.0);
    CensusIsZero("PVPDFSource",        "both PDF sources deallocated",             20.0);
    CensusIsZero("PVPageView",         "page view deallocated",                    20.0);
    CensusIsZero("PVThumbStripView",   "thumb strip deallocated",                  20.0);
}

// Close the document while the queue is at its busiest and nothing has been
// delivered yet. Repeated, because the window that matters is one main-queue
// hop wide.
static void StressCloseUnderLoad(NSURL *url, int rounds)
{
    printf("\n[close-under-load: %d documents closed mid-render]\n", rounds);
    int i;
    for (i = 0; i < rounds; i++) {
        @autoreleasepool {
            NSError *err = nil;
            PVPDFSource *src = [[PVPDFSource alloc] initWithURL:url error:&err];
            if (!src) continue;
            PVWindowController *wc = [[PVWindowController alloc] initWithSource:src url:url];
            [wc showWindow:nil];
            [wc goToPageNumber:(i % 30) + 1];
            [wc showSidebar];
            // Deliberately short: the renders are still in flight.
            Pump(0.002 + 0.001 * (double)(i % 5));
            [[wc window] performClose:nil];
            [wc release];
            [src release];
        }
    }
    CensusIsZero("PVWindowController", "no controller survives a mid-render close", 30.0);
    CensusIsZero("PVRenderQueue",      "no render queue survives a mid-render close", 30.0);
    CensusIsZero("PVPDFSource",        "no PDF source survives a mid-render close",   30.0);
    CensusIsZero("PVImageCache",       "no cache survives a mid-render close",        30.0);
}

static int RunStress(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: pvsuite stress <pdf> [scale]\n"); return 2; }
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        int scale = (argc > 2) ? atoi(argv[2]) : 1;
        if (scale < 1) scale = 1;

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        // Reading positions are written through the shared store, so this has
        // to run with HOME pointed at a scratch directory rather than over the
        // user's real DocumentState.plist.
        //
        // Checked rather than asserted in a comment. The comment said the
        // makefile provided one and the makefile did not, so every run of this
        // harness read and rewrote the developer's own reading positions --
        // hundreds of state writes per run, against the file the app treats as
        // authoritative. A claim about the environment that nothing verifies is
        // a claim that stops being true silently.
        const char *home = getenv("HOME");
        if (!home || !strstr(home, "postview-stress-home")) {
            fprintf(stderr,
                "pvsuite stress: refusing to run without a scratch HOME.\n"
                "  HOME is currently %s\n"
                "  Run it through `make stress`, which creates one.\n",
                home ? home : "(unset)");
            return 2;
        }

        // The same argument as the scratch HOME above, for the same reason.
        //
        // A render helper is spawned with its stderr on /dev/null and an empty
        // environment unless PV_HELPER_DIAGNOSTICS says otherwise, which is
        // correct for a shipping viewer and useless for this harness: a
        // sanitized helper writes its findings to stderr and configures itself
        // from the environment, so a run without them is a run in which the
        // renderer -- the process holding the shared mapping and doing the
        // drawing -- was never actually being watched. Every "sanitizer stress
        // passed" collected that way only ever meant the parent passed.
        if (!getenv("PV_HELPER_DIAGNOSTICS")) {
            fprintf(stderr,
                "pvsuite stress: refusing to run without PV_HELPER_DIAGNOSTICS.\n"
                "  Helper stderr would go to /dev/null and its environment\n"
                "  would be empty, so nothing the render helper reports could\n"
                "  be seen. Run it through `make stress`, which sets it.\n");
            return 2;
        }

        StressQueueChurn(url, 400 * scale);
        StressAbandonMidRender(url, 60 * scale);
        StressControllerEvents(url, 600 * scale);
        StressCloseUnderLoad(url, 40 * scale);

        printf("\n%d passed, %d failed\n", gPass, gFail);
        return gFail ? 1 : 0;
    }
}

#pragma mark ======================= band =======================

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

static int RunBand(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: pvsuite band <test.pdf> [pages] [reps]\n"); return 2; }
        [NSApplication sharedApplication];

        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        NSError *err = nil;
        PVPDFSource *src = [[PVPDFSource alloc] initWithURL:url error:&err];
        if (!src) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }
        CGPDFDocumentRef doc = CGPDFDocumentCreateWithURL((CFURLRef)url);
        if (!doc) {
            fprintf(stderr, "cannot re-open %s for banding\n", argv[1]);
            [src release];
            return 2;
        }

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

#pragma mark ====================== power ======================

// The energy and CPU suite.
//
// ENGINEERING.md section 1: "the program optimises for energy". Every other
// suite in this file checks that Postview does the right THING -- the layout is
// right, the cache converges, nothing leaks, the scheduler withholds the
// bitmaps it says it withholds. Not one of them checked what any of it COST.
// A build that had doubled its CPU per page, or started waking the processor a
// thousand times a second while displaying a static page, passed every one of
// them.
//
// That gap was not academic. The showdown against Preview is the only place
// energy was ever measured, it runs on one machine that is not this one, and
// section 9.4 found four of its instruments reporting quantities that were not
// what their column headings said. An in-tree measurement that runs on every
// developer's machine, on every change, is a different kind of instrument from
// a periodic head-to-head, and the two answer different questions.
//
// What is asserted here, and what is only reported, is chosen by one rule:
// assert on RATIOS and on ZEROES, report the seconds.
//
//   * A ratio between two workloads measured back to back on one machine is a
//     property of the code. "The mains policy asks for sharp bitmaps while the
//     document is moving and the battery policy asks for none" is true on a
//     2013 Mac Pro and on a 2024 laptop, and 99.7% of a render's CPU is spent
//     in the helper process on both.
//   * A near-zero is a property of the code too. An open document that nobody
//     is touching must cost approximately nothing, and "approximately nothing"
//     is a statement about idleness rather than about clock speed.
//   * Seconds are a property of the machine. Nothing here fails a build for
//     being slow, because the machine that decides is a Mac Pro from 2013 and
//     this is not it.

// How long the at-rest measurement watches for. Overridable from the command
// line so a slow or busy machine can be given a longer look without any of the
// thresholds below changing meaning: everything asserted is a rate.
#define PV_POWER_IDLE_SECONDS   3.0

// Repetitions of each policy in [E4], alternated and compared on medians.
#define PV_POWER_SCROLL_REPS    3

// The scrolled workload: 1600 pt at 500 pt/s, a little over one page of the
// fixture. Two things about it are load-bearing and both were arrived at by
// getting them wrong first.
//
// THE SPEED. The first version flicked the viewport at 60,000 pt/s and the two
// policies came out identical to two decimal places -- correctly, because at
// that speed no page stays on screen long enough to be worth rasterising and
// both branches refuse the same work for the same reason. Two policies have to
// be compared where they disagree, and they disagree over a document being
// READ: slow enough that a page will still be there when its bitmap arrives,
// which is the case the mains branch opens the motion gate for and the battery
// branch does not.
//
// THE DISTANCE. The second version used the UI suite's [5g] drag exactly --
// twenty-four 10 pt steps -- and got nothing at all. 240 pt does not change the
// visible page range, so -clipBoundsChanged: rebuilds the wanted set for the
// first event and correctly declines for the rest, and both arms then measured
// a scheduler nobody had asked for anything. That suite compensates by emptying
// the cache and clearing _haveRequestState before each drag, which is right for
// a test of what the policy DECIDES and wrong for a measurement of what it
// COSTS: it would be timing a rebuild no reading session ever triggers. So this
// covers real ground instead, and the two suites meet in the middle -- [5g]
// counts what the scheduler asked for, this counts what answering cost.
#define PV_POWER_SCROLL_STEP    20.0
#define PV_POWER_SCROLL_GAP_US  40000
#define PV_POWER_SCROLL_STEPS   80

// A document at rest may not cost more than this. Generous by a factor of
// thirty against what Postview actually does -- 0.15% of one core, measured
// here -- because what it exists to catch is a spin, a timer that re-arms
// itself immediately, or a render loop that never concludes it is finished.
// Those are not 2% regressions; they are 100% ones, and a threshold set just
// above the current reading would fail on a busy build machine instead.
#define PV_POWER_IDLE_CPU_FRACTION 0.05

// ...and may not wake the processor more than this many times a second. The
// number that matters for a portable: a task that uses no measurable CPU but
// wakes the package two hundred times a second is a task that stops the machine
// from ever reaching a deep idle state, and it costs battery the whole time.
// Measured at 0.0 on this host over three seconds -- an idle Postview does not
// wake the package at all -- so the allowance is not a budget anything is
// spending, it is a ceiling far enough above zero that a timer somewhere in
// AppKit cannot fail the build while a rearming render loop still would.
#define PV_POWER_IDLE_WAKEUPS_PER_SECOND 60.0

// Repetitions whose document did not finish tearing down inside the deadline.
// See the pool note in ScrollOnce: a non-zero count here means every reading
// after that repetition was taken on a machine with another document's render
// helper still resident on it.
static int gScrollTeardownTimeouts = 0;

// One scroll of a freshly opened document, measured from open to quiet.
//
// A fresh controller per repetition rather than re-scrolling one, because the
// second scroll of a document finds its pages in the cache and costs almost
// nothing: comparing a warm run against a cold one would report whichever
// policy happened to go second as the cheap one. Everything either policy does
// differently is in here -- the requests it issues, the renders that result,
// and the drain afterwards, because work that is merely DEFERRED by a policy is
// not work that policy saved.
static void ScrollOnce(NSURL *url, PVPowerSource power, PVResources *before,
                       PVResources *after, NSUInteger *outFull, NSUInteger *outPreview)
{
    PVSetPowerSourceOverride(power, YES);

    // Every run starts at the top of the document, at fit-width, with the
    // sidebar closed.
    //
    // Without this the comparison silently destroys itself, and it does so in a
    // way that still prints plausible numbers. Closing a window records the
    // reading position, so run 2 opens where run 1 stopped and run 3 where run
    // 2 stopped; four runs in, the document is at its last page, the clip view
    // has nowhere left to scroll to, and every subsequent run measures a policy
    // doing nothing at all. Measured before this was added: the mains arm came
    // out at 0.206 s against battery's 0.470 s -- the exact reverse of the
    // truth, produced entirely by which arm happened to run out of document
    // first.
    [[PVStateStore sharedStore] recordForURL:url page:0 fraction:0.0
                                    zoomMode:PVZoomModeFitWidth zoom:1.0
                                     sidebar:NO columns:1 windowFrame:nil];

    // Scoped, and this is the difference between measuring the viewer and
    // measuring the harness.
    //
    // -valueForKey: hands back an AUTORELEASED reference, and the pool it would
    // otherwise land in is RunPower's, which does not drain until the whole
    // suite has finished. The render queue fetched below would therefore stay
    // alive for the rest of the run, holding its PVPDFSource, which holds a
    // render helper -- one per repetition, seven by the end, each with a parsed
    // copy of the document mapped and each appearing in every subsequent
    // reading. It also cost thirty seconds a repetition waiting for a teardown
    // that could not happen. The UI suite's [8] documents the same trap for the
    // same reason; this is the measurement version of it, where the price is
    // not a failed assertion but a quietly wrong number.
    @autoreleasepool {

    NSError *err = nil;
    PVPDFSource *src = [[PVPDFSource alloc] initWithURL:url error:&err];
    if (!src) { memset(before, 0, sizeof *before); memset(after, 0, sizeof *after); return; }

    PVWindowController *wc = [[PVWindowController alloc] initWithSource:src url:url];
    [wc showWindow:nil];
    [[wc window] setFrame:NSMakeRect(80, 80, 1200, 800) display:YES];

    NSScrollView *sv = [wc valueForKey:@"_scrollView"];
    PVRenderQueue *pq = [wc valueForKey:@"_pageQueue"];

    // Settled before the clock starts: opening a window is a fixed cost both
    // policies pay, and including it would dilute the difference being measured
    // with several hundred milliseconds of AppKit and a first page render. A
    // condition rather than a duration, because a page of this fixture takes
    // most of a second to draw and a fixed wait sized for one machine is a
    // different amount of settling on the next.
    PumpUntil(^{ return (BOOL)([pq isIdle] && [pq inFlightCount] == 0); }, 30.0);
    Pump(0.2);

    SampleResources(before);
    // warmup 0, deliberately: every event of the drag counts, including the
    // first. A gesture is announced before it begins, so the scheduler already
    // knows the document is moving on that first bounds change and the battery
    // branch is being asked the question it refuses -- which is exactly the
    // event the comparison is about.
    DriveScroll(wc, sv, YES, PV_POWER_SCROLL_STEP, PV_POWER_SCROLL_GAP_US,
                PV_POWER_SCROLL_STEPS, 0, outFull, outPreview);
    // Whatever the scroll asked for, finished. A policy that only postpones
    // work has not saved any, and stopping the clock at the last bounds change
    // would credit it as though it had.
    PumpUntil(^{ return (BOOL)([pq isIdle] && [pq inFlightCount] == 0); }, 20.0);
    SampleResources(after);

    [[wc window] performClose:nil];
    Pump(0.2);
    [wc release];
    [src release];

    }   // the pool, drained before anything waits on the census below

    // Waited for, not slept through. Each document holds one render helper per
    // lane, and a helper only dies when the source that owns it is deallocated
    // -- which AppKit defers by an indeterminate number of run-loop turns, and
    // which the render queue's worker delays further by holding its own
    // reference until it next looks at the stop flags. A fixed pump here left
    // one helper per repetition alive, so by the end of the suite seven of them
    // were running and every reading after the first was of a machine with
    // other people's rasterisers on it.
    if (!PumpUntil(^{ return (BOOL)(PVLiveCount("PVPDFSource") == 0); }, 30.0))
        gScrollTeardownTimeouts++;

    PVSetPowerSourceOverride(PVPowerUnknown, NO);
}

static int RunPower(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: pvsuite power <pdf> [idle-seconds]\n");
            return 2;
        }
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        double idleSeconds = (argc > 2) ? atof(argv[2]) : PV_POWER_IDLE_SECONDS;
        if (!(idleSeconds >= 0.5)) idleSeconds = PV_POWER_IDLE_SECONDS;

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        // Whatever a previously-run suite left pinned, unpinned. `pvsuite all`
        // runs the UI suite first, and that one pins the power source to
        // battery for its whole length -- so without this, [E1] would report
        // the pin as though it were the machine's answer, which is the one
        // thing [E1] exists to establish.
        PVSetPowerSourceOverride(PVPowerUnknown, NO);

        PVResources runStart;
        SampleResources(&runStart);

        // ------------------------------------------------------------------
        printf("\n[E1] the instruments\n");
        // Every measurement below is a difference of two readings from one of
        // three counters. A counter that does not move is not a measurement of
        // zero, it is an instrument that is not working -- which is exactly the
        // failure mode section 9.4 catalogued four times over, and the reason
        // this suite checks its own instruments before it reports anything.
        {
            int cores = (int)[[NSProcessInfo processInfo] processorCount];
            unsigned long long ram =
                (unsigned long long)[[NSProcessInfo processInfo] physicalMemory];
            PVPowerSource live = PVCurrentPowerSource();
            printf("  host          : %d logical cores, %.1f GB, RAM tier %d\n",
                   cores, (double)ram / (1024.0 * 1024.0 * 1024.0),
                   (int)PVRamTierOfThisMachine());
            printf("  power source  : %s, internal battery %s\n",
                   live == PVPowerAC ? "ac" : live == PVPowerBattery ? "battery" : "unknown",
                   PVMachineHasInternalBattery() ? "present" : "absent");

            PVResources a, b;
            SampleResources(&a);
            // Deliberately CPU, and deliberately not a sleep: this has to move
            // the CPU counter and the wakeup counter by different mechanisms,
            // so that a suite reporting zero for one of them afterwards is
            // reporting a real zero.
            volatile double sink = 0;
            int i;
            for (i = 0; i < 4000000; i++) sink += (double)i * 0.25;
            (void)sink;
            Pump(0.30);
            SampleResources(&b);

            OK(TotalCPU(&a, &b) > 0.005,
               "the CPU clock advances across a busy interval");
            OK(b.wall - a.wall > 0.25, "the monotonic clock advances");

            // The one calibration in this file, checked against the one clock
            // whose units are not in doubt.
            //
            // Helper CPU is read with proc_pid_rusage, whose times are in the
            // kernel's absolute-time unit -- which is the nanosecond on every
            // Intel Mac and 125/3 of one on an Apple silicon development host.
            // Choosing wrong is a factor of 41.67 on the single quantity this
            // whole suite is about, and it would be a quiet factor: every
            // number would still look like seconds. RusageSeconds() decides by
            // measurement rather than by assumption; this is the assertion that
            // the measurement came out right, made against getrusage(), which
            // is microseconds by definition and describes this same process.
            {
                struct rusage ru;
                struct rusage_info_v2 ri;
                if (getrusage(RUSAGE_SELF, &ru) == 0 &&
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V2,
                                    (rusage_info_t *)&ri) == 0) {
                    double truth =
                        (double)ru.ru_utime.tv_sec + (double)ru.ru_utime.tv_usec / 1.0e6 +
                        (double)ru.ru_stime.tv_sec + (double)ru.ru_stime.tv_usec / 1.0e6;
                    double calibrated = RusageSeconds(ri.ri_user_time + ri.ri_system_time);
                    double err = truth > 0 ? fabs(calibrated - truth) / truth : 1.0;
                    char msg[200];
                    printf("  cpu clocks    : getrusage %.3f s, proc_pid_rusage %.3f s "
                           "after calibration\n", truth, calibrated);
                    snprintf(msg, sizeof msg,
                             "the helper CPU clock is calibrated to within 5%% of "
                             "getrusage (%.1f%% off)", 100.0 * err);
                    OK(err < 0.05, msg);
                } else {
                    OK(0, "both CPU clocks can be read");
                }
            }

            OK(b.idleWakeups + b.timerWakeups + b.interruptWakeups >
               a.idleWakeups + a.timerWakeups + a.interruptWakeups,
               "TASK_POWER_INFO reports wakeups (the energy term CPU time cannot see)");

            if (a.batteryCharge >= 0) {
                printf("  battery       : %.0f mAh, drawing %.2f W right now%s\n",
                       a.batteryCharge, a.batteryWatts,
                       a.batteryExternal == 1 ? " (on mains)" :
                       a.batteryExternal == 0 ? " (on the cell)" : "");
                // A cell that EXISTS is not a cell that is moving current, and
                // this assertion conflated the two.
                //
                // AppleSmartBattery reports InstantAmperage 0 for a charged
                // machine sitting on mains: nothing is going into the cell and
                // nothing is coming out of it, so ReadBattery's mV x |mA| is a
                // true 0.00 W. Requiring a draw above 0.1 W therefore failed on
                // every run on such a machine -- which is the ordinary state of
                // a plugged-in developer laptop, and of this one. Measured
                // before changing anything: six consecutive runs on a quiet
                // machine, 22 assertions passing and this one failing every
                // time, at 100 mAh and 0.00 W. It is not flaky; it is wrong.
                //
                // That matters more than one red line, because `power` is a
                // verify-all stage: a gate that cannot pass on mains is a gate
                // whose failures stop being read.
                //
                // So the instrument is checked where there is something for it
                // to measure and reported where there is not, which is exactly
                // the distinction the desktop branch below already draws. The
                // check is NOT loosened: a machine running on the cell while
                // claiming to draw nothing is still a broken instrument, and
                // still fails here.
                if (a.batteryWatts > 0.1) {
                    OK(a.batteryWatts < 200.0,
                       "the battery reports a plausible instantaneous draw");
                } else if (a.batteryExternal == 1) {
                    printf("                  charged and on mains: no current in or out of\n"
                           "                  the cell, so 0.00 W is the true reading and there\n"
                           "                  is no draw for this run to check. CPU seconds and\n"
                           "                  wakeups carry the measurement instead.\n");
                } else {
                    OK(0, "the battery reports a plausible instantaneous draw "
                          "(on the cell, yet reporting no draw at all)");
                }
            } else {
                printf("  battery       : no cell to read (a desktop). Watts are\n"
                       "                  unavailable here; CPU seconds and wakeups\n"
                       "                  are the whole measurement on this machine.\n");
            }
        }

        // From here to [E4], pinned to the portable's policy.
        //
        // Not tidiness: PVRenderPolicyFor opens the motion gate on mains, so a
        // measurement taken without a pin is a measurement of where the laptop
        // running it happened to be plugged in. [E4] overrides this explicitly
        // for each of its two arms, which is the one place the AC branch is
        // supposed to be exercised.
        PVSetPowerSourceOverride(PVPowerBattery, YES);

        // ------------------------------------------------------------------
        printf("\n[E2] an open document at rest\n");
        // The single most important energy property of a document viewer, and
        // the one a scrolling benchmark can never show: what does it cost to
        // have the thing OPEN? A reader spends most of a session not touching
        // the trackpad, and a viewer that busies itself during that time is
        // spending battery on nothing at all.
        @autoreleasepool {
            NSError *err = nil;
            PVPDFSource *src = [[PVPDFSource alloc] initWithURL:url error:&err];
            OK(src != nil, "the fixture opens");
            if (!src) return 2;

            PVWindowController *wc = [[PVWindowController alloc] initWithSource:src url:url];
            // See ScrollOnce for why this matters more here than in a test.
            [wc showWindow:nil];
            [[wc window] setFrame:NSMakeRect(80, 80, 1200, 800) display:YES];
            PVRenderQueue *pq = [wc valueForKey:@"_pageQueue"];

            // At rest means at rest: the first page rendered, the queue empty,
            // nothing outstanding. Measuring before that would be measuring the
            // open, which is a cost the reader asked for.
            PumpUntil(^{ return (BOOL)([pq isIdle] && [pq inFlightCount] == 0); }, 20.0);
            Pump(0.5);

            PVResources a, b;
            SampleResources(&a);
            // ONE runUntilDate for the whole interval rather than a loop of
            // short ones. A polling loop is itself a timer firing twenty times
            // a second, and it would appear in the wakeup count as though the
            // application had done it.
            Pump(idleSeconds);
            SampleResources(&b);

            double wall     = b.wall - a.wall;
            double cpu      = TotalCPU(&a, &b);
            double fraction = wall > 0 ? cpu / wall : 0;
            double wakes    = wall > 0 ? (double)(b.idleWakeups - a.idleWakeups) / wall : 0;

            ReportInterval("at rest", &a, &b);

            char msg[200];
            snprintf(msg, sizeof msg,
                     "an idle document costs %.2f%% of one core (limit %.0f%%)",
                     100.0 * fraction, 100.0 * PV_POWER_IDLE_CPU_FRACTION);
            OK(fraction < PV_POWER_IDLE_CPU_FRACTION, msg);

            snprintf(msg, sizeof msg,
                     "an idle document wakes the package %.1f times a second (limit %.0f)",
                     wakes, PV_POWER_IDLE_WAKEUPS_PER_SECOND);
            OK(wakes < PV_POWER_IDLE_WAKEUPS_PER_SECOND, msg);

            OK(b.fullRenders - a.fullRenders == 0,
               "and rasterises nothing at all while nobody is reading");

            [[wc window] performClose:nil];
            Pump(0.2);
            [wc release];
            [src release];
            // See ScrollOnce: a helper outlives its source's release by
            // however long AppKit and the render queue take to let go, and a
            // helper still running is a helper in the next section's readings.
            PumpUntil(^{ return (BOOL)(PVLiveCount("PVPDFSource") == 0); }, 30.0);
        }

        // ------------------------------------------------------------------
        printf("\n[E3] where the work happens\n");
        // Rasterisation moved into a helper process, and the whole point of
        // that move was to put the expensive, killable part somewhere it cannot
        // wedge the viewer. This is the check that it actually WENT there: if
        // the parent is doing the drawing, every timeout and every kill in the
        // design is protecting nothing.
        //
        // It also validates the instrument the two comparisons below depend
        // on. A measurement of this program that stopped at mach_task_self()
        // would report the viewer as having become nearly free the day the
        // helper was introduced.
        @autoreleasepool {
            NSError *err = nil;
            PVPDFSource *src = [[PVPDFSource alloc] initWithURL:url error:&err];
            OK(src != nil, "a source for the render census");

            char msg[240];
            const CGSize kPx = CGSizeMake(900, 1165);
            const int kRenders = 8;
            const double kMpxEach = (kPx.width * kPx.height) / 1.0e6;

            PVResources a, b;
            NSMutableSet *helperPids = [NSMutableSet set];
            SampleResources(&a);
            int r, produced = 0;
            for (r = 0; r < kRenders && src; r++) {
                @autoreleasepool {
                    CGImageRef im = [src createImageForPage:(NSUInteger)(r % [src pageCount])
                                                  pixelSize:kPx];
                    if (im) { produced++; CGImageRelease(im); }
                    pid_t child = FirstChildPid();
                    if (child > 0)
                        [helperPids addObject:[NSNumber numberWithInt:(int)child]];
                }
            }
            SampleResources(&b);

            double parent = (b.selfUser - a.selfUser) + (b.selfSys - a.selfSys);
            double helper = b.childCPU - a.childCPU;
            double wall   = b.wall - a.wall;
            double megapixels = kMpxEach * (double)produced;

            snprintf(msg, sizeof msg, "%d page renders, %.2f Mpx each", kRenders, kMpxEach);
            ReportInterval(msg, &a, &b);
            printf("    split viewer %.1f%% / helpers %.1f%% of the CPU spent, "
                   "%lu distinct helpers\n",
                   100.0 * parent / (parent + helper > 0 ? parent + helper : 1),
                   100.0 * helper / (parent + helper > 0 ? parent + helper : 1),
                   (unsigned long)[helperPids count]);
            // Wall against CPU, which for a synchronous render round trip is
            // the duty cycle of the pipeline rather than a property of
            // rasterisation. A page that takes far longer to arrive than it
            // takes to draw is spending the difference somewhere -- spawning a
            // helper, opening the document again, or waiting on a pipe -- and
            // that difference is latency the reader sees and energy nobody
            // spent drawing anything.
            printf("    round trip %.0f ms per page, of which %.0f ms is CPU "
                   "(%.0f%% duty cycle)\n",
                   produced ? 1000.0 * wall / produced : 0,
                   produced ? 1000.0 * (parent + helper) / produced : 0,
                   wall > 0 ? 100.0 * (parent + helper) / wall : 0);

            snprintf(msg, sizeof msg, "%d of %d renders produced a bitmap",
                     produced, kRenders);
            OK(produced == kRenders, msg);

            snprintf(msg, sizeof msg,
                     "rasterisation is charged to the helper, not the viewer "
                     "(%.3f s helper vs %.3f s viewer)", helper, parent);
            OK(helper > parent, msg);

            snprintf(msg, sizeof msg,
                     "the helper's CPU is visible to this suite at all (%.3f s)", helper);
            OK(helper > 0.010, msg);

            double kernelMsPerMpx = megapixels > 0
                ? 1000.0 * (parent + helper) / megapixels : 0;
            printf("    cost  %.1f ms of CPU per megapixel, across both processes\n",
                   kernelMsPerMpx);

            // The same work again, through the render queue this time, so that
            // Postview's own census records it and can be checked against the
            // kernel's account of the same seconds.
            //
            // Not a detail: PVCostModel decides whether a page is worth
            // rasterising by predicting how long it will take, and section 9.4
            // caught that prediction being computed from a population it did
            // not describe. Nothing outside the program had ever looked at the
            // number it was predicting from. The two instruments measure
            // different things -- the census times a render inside the viewer,
            // this times CPU across two processes -- so they are not expected
            // to agree exactly. An order of magnitude apart means one of them
            // has stopped describing rendering, which is the failure mode, and
            // it is the one that cannot be seen from inside.
            //
            // -createImageForPage: above deliberately does NOT feed the census:
            // the counters live in PVRenderQueue, which is the path the
            // application actually uses. Measuring the direct call and then
            // reading the queue's counters would have compared this interval
            // against work done in some other one, and would have reported
            // whatever the previous suite happened to leave behind.
            @autoreleasepool {
                PVRenderQueue *q = [[PVRenderQueue alloc] initWithSource:src label:"power"];
                Collector *sink = [[Collector alloc] init];
                sink->quiet = YES;
                [q setDelegate:sink];

                NSMutableArray *reqs = [NSMutableArray array];
                int i;
                for (i = 0; i < 6; i++)
                    [reqs addObject:[PVRenderRequest page:(NSUInteger)i pixels:kPx
                                                 priority:PVPriorityVisibleFull preview:NO]];

                PVResources c, d;
                SampleResources(&c);
                [q setDesiredRequests:reqs];
                PumpUntil(^{ return (BOOL)([sink->pages count] + [sink->failed count] >= 6); }, 60.0);
                SampleResources(&d);

                double queueCPU = TotalCPU(&c, &d);
                double ownSeconds = d.renderSeconds - c.renderSeconds;
                double ownMpx     = d.renderMegapixels - c.renderMegapixels;
                double ownMsPerMpx    = ownMpx > 0 ? 1000.0 * ownSeconds / ownMpx : 0;
                double queueMsPerMpx  = ownMpx > 0 ? 1000.0 * queueCPU / ownMpx : 0;

                ReportInterval("6 renders via the queue", &c, &d);
                printf("    cost  kernel %.1f ms CPU per Mpx   Postview's own census "
                       "%.1f ms per Mpx\n", queueMsPerMpx, ownMsPerMpx);

                snprintf(msg, sizeof msg,
                         "the queue delivered %lu of 6 pages",
                         (unsigned long)[sink->pages count]);
                OK([sink->pages count] == 6, msg);

                if (ownMsPerMpx > 0 && queueMsPerMpx > 0) {
                    double ratio = ownMsPerMpx / queueMsPerMpx;
                    if (ratio < 1) ratio = 1.0 / ratio;
                    snprintf(msg, sizeof msg,
                             "Postview's cost census and the kernel agree to within "
                             "10x (%.1fx apart)", ratio);
                    OK(ratio < 10.0, msg);
                } else {
                    OK(0, "Postview's own render census recorded this work");
                }

                [q shutdown];
                [q release];
                [sink release];
            }

            [src release];
            PumpUntil(^{ return (BOOL)(PVLiveCount("PVPDFSource") == 0); }, 30.0);
        }

        // ------------------------------------------------------------------
        printf("\n[E4] the battery policy against the mains policy\n");
        // Section 4.2's claim, measured rather than argued. On battery the
        // motion gate refuses full-resolution bitmaps for pages that will not
        // stay on screen long enough to be seen; on mains it opens, because the
        // energy is arriving down a wall socket and latency is the thing worth
        // buying with it.
        //
        // What is asserted is what the two policies DECIDE -- the requests each
        // issues while the document is moving, which the policy determines
        // outright and which no amount of scheduling noise can move. The
        // seconds and the megapixels are reported beside them.
        //
        // That is a narrower claim than the one this section was first written
        // to make, and the narrowing is the finding. See the note further down:
        // over a scroll that ENDS, both policies rasterise the same pixels,
        // because the battery branch renders after the motion stops what the
        // mains branch rendered during it. A gate on total work would have been
        // asserting something that is not true, and a gate on seconds would
        // have been a claim about this machine's scheduler on the day it ran.
        //
        // Alternated B, A, B, A, ... and compared on medians. Three runs of
        // each in one order would attribute anything that drifts across the
        // suite -- thermal state, another process starting -- to whichever
        // policy went last.
        {
            double batteryCPU[PV_POWER_SCROLL_REPS], acCPU[PV_POWER_SCROLL_REPS];
            double batteryMpx[PV_POWER_SCROLL_REPS], acMpx[PV_POWER_SCROLL_REPS];
            NSUInteger batteryFull = 0, acFull = 0, batteryPrev = 0, acPrev = 0;
            int rep;

            for (rep = 0; rep < PV_POWER_SCROLL_REPS; rep++) {
                PVResources a, b;
                NSUInteger f = 0, p = 0;

                ScrollOnce(url, PVPowerBattery, &a, &b, &f, &p);
                batteryCPU[rep] = TotalCPU(&a, &b);
                batteryMpx[rep] = b.renderMegapixels - a.renderMegapixels;
                batteryFull += f; batteryPrev += p;
                printf("    run %d battery: %6.3f s CPU  %6.2f Mpx  "
                       "%lu full + %lu preview requests\n", rep + 1,
                       batteryCPU[rep], batteryMpx[rep],
                       (unsigned long)f, (unsigned long)p);

                ScrollOnce(url, PVPowerAC, &a, &b, &f, &p);
                acCPU[rep] = TotalCPU(&a, &b);
                acMpx[rep] = b.renderMegapixels - a.renderMegapixels;
                acFull += f; acPrev += p;
                printf("    run %d mains  : %6.3f s CPU  %6.2f Mpx  "
                       "%lu full + %lu preview requests\n", rep + 1,
                       acCPU[rep], acMpx[rep], (unsigned long)f, (unsigned long)p);
            }

            double bCPU = Median(batteryCPU, 0, PV_POWER_SCROLL_REPS);
            double aCPU = Median(acCPU, 0, PV_POWER_SCROLL_REPS);
            double bMpx = Median(batteryMpx, 0, PV_POWER_SCROLL_REPS);
            double aMpx = Median(acMpx, 0, PV_POWER_SCROLL_REPS);

            printf("    median CPU and megapixels of %d runs each, %d scroll steps "
                   "per run;\n    requests are the total over all %d:\n",
                   PV_POWER_SCROLL_REPS, PV_POWER_SCROLL_STEPS, PV_POWER_SCROLL_REPS);
            printf("      battery  %6.3f s CPU   %6.2f Mpx rasterised   "
                   "%lu full + %lu preview requests\n",
                   bCPU, bMpx, (unsigned long)batteryFull, (unsigned long)batteryPrev);
            printf("      mains    %6.3f s CPU   %6.2f Mpx rasterised   "
                   "%lu full + %lu preview requests\n",
                   aCPU, aMpx, (unsigned long)acFull, (unsigned long)acPrev);
            if (aCPU > 0)
                printf("      battery costs %.0f%% of the mains policy's CPU for the "
                       "same scroll\n", 100.0 * bCPU / aCPU);

            char msg[220];
            snprintf(msg, sizeof msg,
                     "every one of the %d documents finished tearing down (%d did not)",
                     2 * PV_POWER_SCROLL_REPS, gScrollTeardownTimeouts);
            OK(gScrollTeardownTimeouts == 0, msg);

            snprintf(msg, sizeof msg,
                     "the mains policy asks for more full-resolution bitmaps during "
                     "motion (%lu vs %lu)", (unsigned long)acFull, (unsigned long)batteryFull);
            OK(acFull > batteryFull, msg);

            snprintf(msg, sizeof msg,
                     "and the battery policy asks for none at all (%lu)",
                     (unsigned long)batteryFull);
            OK(batteryFull == 0, msg);

            // What the two arms do NOT differ in, measured rather than
            // assumed, and the more interesting half of the result.
            //
            // Over an episode that ENDS -- a reader who scrolls and then stops,
            // which is what this workload is -- both policies rasterise the
            // same pixels. The mains branch asks for them while the document is
            // still moving; the battery branch asks once it has stopped. The
            // gate defers work, it does not drop it, and a page the reader
            // settles on goes sharp under either policy. That is a correctness
            // property as much as an energy one, and it is the property that
            // would break first if the motion gate were ever tightened into
            // something that forgets what it refused.
            //
            // Which is also why the energy saving cannot be read off this
            // number, and why the assertions above are about what was ASKED
            // for. The battery policy only avoids work when the reader keeps
            // going -- the pages it declined to sharpen leave the screen before
            // anyone would have seen them -- and at that speed the mains branch
            // declines them too, for the same dwell reason. The measurable
            // difference between the two policies is confined to the speeds in
            // between, which is exactly what this drag was chosen to sit in.
            double spread = (aMpx > bMpx ? aMpx : bMpx);
            double gap    = spread > 0 ? fabs(aMpx - bMpx) / spread : 0;
            snprintf(msg, sizeof msg,
                     "both policies end up rasterising the same pixels -- the gate "
                     "defers, it does not drop (%.2f vs %.2f Mpx, %.0f%% apart)",
                     bMpx, aMpx, 100.0 * gap);
            OK(gap < 0.25, msg);

            // Reported, not asserted. The two arms do the same total work by
            // the paragraph above, so what is left in the difference is
            // scheduling and this machine's mood; a gate on it would be a gate
            // on noise. What it is worth printing for is the shape: a battery
            // arm that ever came out at several times the mains arm would mean
            // the gate was withholding bitmaps and paying for them anyway.
            printf("      (CPU is reported, not gated: both arms do the same work "
                   "here, so the difference is scheduling)\n");
        }

        // ------------------------------------------------------------------
        printf("\n[E5] what the scheduler withheld\n");
        // The counters the gate keeps about itself. These are the mechanism
        // behind [E4]: if the megapixel difference there is real, these say
        // which rule produced it. A build where the motion gate has been
        // accidentally disarmed shows a difference of zero here while [E4] is
        // still noisy enough to pass.
        {
            printf("  motion gate suppressed  : %.0f full renders\n",
                   PVStatValue(PVStatMotionSuppressed));
            printf("  dwell throttle suppressed: %.0f requests\n",
                   PVStatValue(PVStatRequestsSuppressed));
            printf("  cost gate suppressed    : %.0f   admitted: %.0f\n",
                   PVStatValue(PVStatCostSuppressed), PVStatValue(PVStatCostAdmitted));
            printf("  renders                 : %.0f full, %.0f preview, %.0f failed\n",
                   PVStatValue(PVStatRendersFull), PVStatValue(PVStatRendersPreview),
                   PVStatValue(PVStatRendersFailed));
            printf("  rasterised              : %.1f Mpx full, %.1f Mpx preview\n",
                   PVStatValue(PVStatPixelsFull), PVStatValue(PVStatPixelsPreview));

            OK(PVStatValue(PVStatMotionSuppressed) > 0,
               "the motion gate withheld work during the scrolls above");
            OK(PVStatValue(PVStatRendersPreview) > 0,
               "and previews were rendered instead, so motion still showed something");

            // Cheap pixels are the entire justification for the preview pass:
            // a third of the linear size is a ninth of the area, so a preview
            // that cost a full render's energy would be a worse deal than not
            // rendering at all.
            double fullMpx    = PVStatValue(PVStatPixelsFull);
            double previewMpx = PVStatValue(PVStatPixelsPreview);
            double fulls      = PVStatValue(PVStatRendersFull);
            double previews   = PVStatValue(PVStatRendersPreview);
            if (fulls > 0 && previews > 0) {
                double perFull    = fullMpx / fulls;
                double perPreview = previewMpx / previews;
                char msg[200];
                printf("  per render              : %.2f Mpx full, %.2f Mpx preview "
                       "(%.1fx cheaper)\n", perFull, perPreview,
                       perPreview > 0 ? perFull / perPreview : 0);
                snprintf(msg, sizeof msg,
                         "a preview covers a fraction of a full render's pixels "
                         "(%.2f vs %.2f Mpx)", perPreview, perFull);
                OK(perPreview < perFull / 2.0, msg);
            }
        }

        // ------------------------------------------------------------------
        printf("\n[E6] the whole run\n");
        {
            PVResources runEnd;
            SampleResources(&runEnd);
            ReportInterval("everything above", &runStart, &runEnd);

            double wall  = runEnd.wall - runStart.wall;
            double total = TotalCPU(&runStart, &runEnd);

            // The direct measurement, where the machine can make it. Amperage
            // is sampled at the two ends rather than integrated, so this is the
            // charge the cell actually gave up over the run -- not a model of
            // it. On a desktop both readings are -1 and the section says so
            // instead of printing a zero that would look like a result.
            if (runStart.batteryCharge >= 0 && runEnd.batteryCharge >= 0) {
                double mAh = runStart.batteryCharge - runEnd.batteryCharge;
                double watts = runEnd.batteryWatts >= 0 ? runEnd.batteryWatts : 0;
                printf("  battery         : %+.0f mAh over %.1f s, %.2f W at the end\n",
                       -mAh, wall, watts);
                if (mAh > 0 && wall > 0)
                    printf("                    = %.2f mAh per minute of this workload\n",
                           mAh * 60.0 / wall);
                printf("  NOTE: the whole machine's draw, not Postview's. This suite\n"
                       "        is the largest thing running, not the only one.\n");
            } else {
                printf("  battery         : not present on this machine\n");
            }

            printf("  CPU per wall second: %.3f (%.1f%% of one core, %d cores present)\n",
                   wall > 0 ? total / wall : 0, wall > 0 ? 100.0 * total / wall : 0,
                   (int)[[NSProcessInfo processInfo] processorCount]);

            // Nothing left running. A suite that has finished measuring and
            // still has a helper alive is a suite whose last reading included a
            // process it was not accounting for -- and, on a portable, a viewer
            // that leaves rasterisers behind is the worst energy bug there is.
            //
            // Zombies do not count, and the distinction is load-bearing rather
            // than pedantic: PVReapEventually hands a child that will not die
            // promptly to a detached thread precisely so the viewer is never
            // blocked tidying up after a wedged filesystem, so an unreaped
            // entry is the design working. See LiveChildren().
            OK(PumpUntil(^{ pid_t seen[16]; return (BOOL)(LiveChildren(seen, 16) == 0); }, 30.0),
               "no render helper is left running when the measurement ends");
            pid_t kids[16];
            int leftovers = LiveChildren(kids, 16);
            if (leftovers) {
                int i;
                printf("  still running   :");
                for (i = 0; i < leftovers; i++) printf(" %d", (int)kids[i]);
                printf("\n");
            }
            {
                pid_t all[16];
                int total = ChildPids(all, 16);
                if (total > leftovers)
                    printf("  unreaped        : %d exited helper(s) not yet collected "
                           "(not a leak; see LiveChildren)\n", total - leftovers);
            }
        }

        PVSetPowerSourceOverride(PVPowerUnknown, NO);
        printf("\n%d passed, %d failed\n", gPass, gFail);
        return gFail ? 1 : 0;
    }
}

#pragma mark ==================== dispatcher ====================

static int Usage(void)
{
    fprintf(stderr,
        "usage: pvsuite <suite> [arguments]\n"
        "\n"
        "  unit   <pdf> [rotation.pdf] [real.pdf]   headless logic checks\n"
        "  ui     <pdf> <outdir>                    drives a real controller\n"
        "  soak   <pdf> [cycles]                    long-uptime memory behaviour\n"
        "  stress <pdf> [scale]                     contention; run under sanitizers\n"
        "  band   <pdf> [pages] [reps]              banding cost probe (an experiment)\n"
        "  power  <pdf> [idle-seconds]              CPU, wakeups and battery\n"
        "  all    <pdf> <outdir> [rotation.pdf]     unit, ui, soak, power\n"
        "\n"
        "Each suite takes the arguments its own executable used to take. The\n"
        "Makefile targets `test`, `uitest`, `soak`, `stress`, `band` and `power`\n"
        "run them with the fixtures they need.\n");
    return 2;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) return Usage();

        const char *suite = argv[1];
        // Everything from the suite name onwards. Each Run* function is the
        // main() of the executable it replaces, unchanged, so it has to see the
        // argv that main() saw: its own name at [0] and its first argument at
        // [1]. Shifting here is what keeps those bodies untouched, and an
        // untouched body cannot have had an assertion quietly altered by the
        // merge.
        int subArgc = argc - 1;
        const char **subArgv = argv + 1;

        if (!strcmp(suite, "unit"))   return RunUnit(subArgc, subArgv);
        if (!strcmp(suite, "soak"))   return RunSoak(subArgc, subArgv);
        if (!strcmp(suite, "stress")) return RunStress(subArgc, subArgv);
        if (!strcmp(suite, "band"))   return RunBand(subArgc, subArgv);

        // The two suites that watch what the scheduler asks for need the
        // counting hook in place before a controller exists. It is not
        // installed for the others: it is a method swizzle on the render
        // queue's hottest entry point, and a suite that does not read the
        // counters should not be carrying it -- least of all the sanitizer
        // stress run, whose whole job is to report on the code as it ships.
        if (!strcmp(suite, "ui")) {
            PVInstallRequestCounter();
            return RunUI(subArgc, subArgv);
        }
        if (!strcmp(suite, "power")) {
            PVInstallRequestCounter();
            return RunPower(subArgc, subArgv);
        }

        if (!strcmp(suite, "all")) {
            // Everything that is a gate and needs nothing of its environment.
            //
            // `stress` is excluded because it refuses to run without a scratch
            // HOME and PV_HELPER_DIAGNOSTICS -- it rewrites the reading-position
            // store, and `make stress` is what provides both. `band` is
            // excluded because it is an experiment and not a gate: it asserts
            // nothing and prints a measurement for ENGINEERING.md to argue
            // from.
            if (subArgc < 3) {
                fprintf(stderr, "usage: pvsuite all <pdf> <outdir>\n");
                return 2;
            }
            PVInstallRequestCounter();

            // The rotation fixture is optional and forwarded when given: the
            // unit suite skips thirteen assertions without it, and a composite
            // run that silently checks less than `make test` does would be a
            // composite run nobody should trust.
            const char *unitArgv[] = { "unit", subArgv[1],
                                       subArgc > 3 ? subArgv[3] : NULL };
            int unitArgc = (subArgc > 3) ? 3 : 2;
            const char *uiArgv[]   = { "ui",   subArgv[1], subArgv[2] };
            const char *soakArgv[] = { "soak", subArgv[1], "150" };
            const char *pwrArgv[]  = { "power", subArgv[1] };

            printf("\n======================== unit ========================\n");
            RunUnit(unitArgc, unitArgv);
            printf("\n========================= ui =========================\n");
            RunUI(3, uiArgv);
            printf("\n======================== soak ========================\n");
            RunSoak(3, soakArgv);
            printf("\n======================== power =======================\n");
            RunPower(2, pwrArgv);

            printf("\n=============================================\n");
            printf("pvsuite all: %d passed, %d failed\n", gPass, gFail);
            return gFail ? 1 : 0;
        }

        fprintf(stderr, "pvsuite: unknown suite '%s'\n\n", suite);
        return Usage();
    }
}
