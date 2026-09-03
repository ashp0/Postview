#!/bin/bash
# Postview vs Preview: one head-to-head test that names a winner.
#
# Run from Terminal on the Mavericks machine:
#   ./Postview-Showdown.command /path/to/document.pdf
#
# Optional:
#   RUNS=5 MIN_IDLE=85 WIN_W=1200 WIN_H=800
#   IDLE_TOLERANCE=4 QUIET_TIMEOUT=20
#   POSTVIEW_APP=/Applications/Postview.app
#   SCENARIOS="launch idle read page scroll swipe wheel"
#
# Requires Terminal in System Preferences > Security & Privacy > Privacy >
# Accessibility. Quit both Preview and Postview first; this script only ever
# touches the instances it starts itself.
#
# ---------------------------------------------------------------------------
# What this measures, and why these numbers and not others
#
# The goal is battery life, so the metrics are ordered by how much they
# actually move a battery, not by how easy they are to collect.
#
#   cpu_seconds   The kernel's own per-process CPU counter, read before and
#                 after the window (`ps -o time`). Not a sampled percentage:
#                 sampling is a decaying estimate that lags by a second or two
#                 and starts at a different point in each app's startup, which
#                 is how an earlier benchmark managed to report either app as
#                 the winner depending on the session. This is the dominant
#                 term in energy use and it is exact.
#
#   energy_impact Mavericks' own composite figure (top's POWER column), which
#                 folds in CPU, wakeups, GPU and I/O. It is the number Activity
#                 Monitor shows the user, so it is the one an actual complaint
#                 would cite. Sampled, therefore reported as a mean and a peak.
#
#   idle_wakeups  Timer wakeups over the window, as a delta. This is the metric
#                 raw CPU time hides: a process that uses almost no CPU but
#                 wakes the core hundreds of times a second keeps the package
#                 out of its deep sleep states and costs battery anyway. It is
#                 the difference between "idle" and "actually asleep".
#
#   peak_rss_kb   Resident memory. Not a battery term directly, but memory
#                 pressure on a 2 GB Mavericks machine means swap, and swapping
#                 on a spinning disk costs far more power than any render.
#
# Fairness controls, all of which exist because their absence produced a
# different winner on different days:
#
#   * Each trial opens its own hardlink to the PDF at a path neither app has
#     seen, so neither restores a page position or zoom from a previous trial
#     and every run starts at page 1. Nothing in the user's preferences is read
#     or written.
#   * Both windows are set to the same size, so neither app is rasterising
#     more pixels than the other by virtue of its own default zoom.
#   * The machine must be measurably quiet before a trial starts, and the idle
#     figure it started from is recorded in the TSV, so a contaminated trial is
#     visible in the data rather than silently folded into a median. "Quiet" is
#     relative to this machine's own idle floor, measured once at startup: an
#     absolute threshold is a claim about the machine, and the machines this
#     runs on do not agree. See the quiet gate below.
#   * App order alternates between runs. Thermal drift and background activity
#     both trend over a session, and always measuring the same app first hands
#     that trend to one side.
#   * Medians, not means, over an odd number of runs, with the spread reported
#     so a noisy metric cannot quietly decide the verdict.
# ---------------------------------------------------------------------------

set -u
umask 077

RUNS=${RUNS:-5}
MIN_IDLE=${MIN_IDLE:-85}
WIN_W=${WIN_W:-1200}
WIN_H=${WIN_H:-800}
SCENARIOS=${SCENARIOS:-"launch idle read page scroll swipe wheel"}
POSTVIEW_APP=${POSTVIEW_APP:-}
POSTVIEW_PROCESS=Postview

# Scenario shapes. Key codes: 121 = Page Down, 125 = Down Arrow.
IDLE_SECONDS=${IDLE_SECONDS:-30}
READ_PRESSES=${READ_PRESSES:-12};      READ_DELAY=${READ_DELAY:-2.5}
PAGE_PRESSES=${PAGE_PRESSES:-80};      PAGE_DELAY=${PAGE_DELAY:-0.05}
SCROLL_PRESSES=${SCROLL_PRESSES:-200}; SCROLL_DELAY=${SCROLL_DELAY:-0.02}
# Trackpad and wheel. Deltas are negative because negative moves forward
# through the document; see the driver source for why the sign is fixed here.
# `swipe` is sized to land near `scroll`'s ~3000 pt/s so the keyboard and the
# trackpad can be read against each other: 240 events of 50 px at ~60 Hz is
# 3125 pt/s for 3.8 s, against 200 arrows at 50 Hz for 4.0 s. `wheel` is a
# mouse being spun hard -- 20 detents a second of 3 lines each -- which is a
# different shape on purpose, because a wheel cannot produce a trackpad's rate.
SWIPE_EVENTS=${SWIPE_EVENTS:-240};   SWIPE_DELTA=${SWIPE_DELTA:--50};  SWIPE_DELAY=${SWIPE_DELAY:-0.016}
WHEEL_EVENTS=${WHEEL_EVENTS:-60};    WHEEL_LINES=${WHEEL_LINES:--3};   WHEEL_DELAY=${WHEEL_DELAY:-0.05}
TAIL_TICKS=${TAIL_TICKS:-20}     # rendering after the last keystroke still counts

# A metric is only called a win if it clears this. Below it the two apps are
# doing the same thing and the difference is the machine's mood.
TIE_BAND=${TIE_BAND:-0.05}

die() { printf 'Showdown stopped: %s\n' "$*" >&2; exit 1; }

[ "$#" -ge 1 ] || { printf '%s\n' "usage: $(basename "$0") [--selftest] /path/to/document.pdf" >&2; exit 2; }
if [ "$1" = "--selftest" ]; then
    SELFTEST=1; shift
    [ "$#" -ge 1 ] || { printf '%s\n' "usage: $(basename "$0") --selftest /path/to/document.pdf" >&2; exit 2; }
fi
PDF=$1
[ -f "$PDF" ] || die "no such file: $PDF"
case "$PDF" in /*) ;; *) PDF=$(pwd)/$PDF ;; esac

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -z "$POSTVIEW_APP" ]; then
    for c in "$SCRIPT_DIR/Postview.app" "$SCRIPT_DIR/../Postview.app" /Applications/Postview.app; do
        [ -d "$c" ] && { POSTVIEW_APP=$(CDPATH= cd -- "$c" && pwd); break; }
    done
fi
[ -n "$POSTVIEW_APP" ] && [ -d "$POSTVIEW_APP" ] || die "cannot find Postview.app (set POSTVIEW_APP)"

running() { /usr/bin/pgrep -x "$1" >/dev/null 2>&1; }

CURRENT_APP=""
WORKDIR=$(/usr/bin/mktemp -d /tmp/postview-showdown.XXXXXX) || die "could not create a working directory"
cleanup() {
    [ -n "$CURRENT_APP" ] && /usr/bin/osascript -e "tell application \"$CURRENT_APP\" to quit" >/dev/null 2>&1
    [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"
    # The three keys open_app_with() writes into Postview's preference domain.
    # Removed here as well as after each trial so that a run killed with ^C, or
    # one that dies inside a trial, does not leave the user's copy of Postview
    # permanently writing a stats file to a path inside a deleted temp
    # directory -- or, worse, permanently pinned to a power state it was never
    # told about.
    command -v postview_settings_clear >/dev/null 2>&1 && postview_settings_clear
}
trap cleanup EXIT INT TERM

PDF_BASE=$(basename "$PDF"); PDF_STEM=${PDF_BASE%.*}
STAMP=$(/bin/date +%Y%m%d-%H%M%S)
OUTDIR=${OUTDIR:-$(pwd)}
OUTPUT="$OUTDIR/Postview-Showdown-$STAMP.tsv"
VERDICT="$OUTDIR/Postview-Showdown-$STAMP.txt"

now()     { /usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f\n", time'; }
elapsed() { /usr/bin/awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", b - a }'; }
pid_for() { /usr/bin/pgrep -x "$1" 2>/dev/null | /usr/bin/head -n 1; }

# A document neither app has seen before, so every trial starts at page 1 in
# the default view.
#
# This used to be a hard link, and a hard link does not do that. It is the same
# inode: one file with a second name. Postview keys its saved reading position
# on the path, so a new name did fool Postview -- which is exactly what made the
# bug survive review, because the app being developed visibly started at page 1.
# Preview does not key on the path. It keys on the document's identity, and a
# hard link has the identity it is a link to, so Preview restored the position
# it had saved the last time anyone opened that PDF.
#
# The recorded evidence is in `Postview-Profile-20260828-215944.tsv`, whose
# `launch` row -- a scenario that sends no input at all -- has Preview sitting
# on "page 1,174 of 1,263" of a freshly staged path while Postview is on page 1.
# The two apps were rasterising different parts of a 1,263-page book, and
# `ENGINEERING.md` measures the cost of a page varying by up to 59x with
# its content at identical pixel counts. Every CPU and energy figure produced
# that way is a comparison of two different workloads.
#
# A copy has its own inode and its own document identity, which is the property
# actually wanted. -X drops extended attributes and any resource fork, so
# quarantine flags and Finder metadata do not travel either. It costs one file
# copy per trial; correctness of the measurement is worth more than the seconds.
#
# Verified, not assumed: -assert_fresh_start below reads the page out of each
# app's own window title after it opens, and a trial that did not start on page
# 1 is recorded and disqualified rather than averaged in.
fresh_document() {
    label=$(printf '%s' "$1" | /usr/bin/tr ' /' '--')
    path="$WORKDIR/$PDF_STEM-$label.pdf"
    /bin/rm -f "$path" 2>/dev/null
    /bin/cp -X "$PDF" "$path" 2>/dev/null || /bin/cp "$PDF" "$path" 2>/dev/null || return 1
    /usr/bin/xattr -c "$path" 2>/dev/null || true
    printf '%s\n' "$path"
}

# The page an app is showing, read from its own window title.
#
# Both apps put it there in the same shape -- "... (page 6 of 1263)" -- and
# Preview writes the thousands separator its locale asks for, so the digits are
# taken and the separators dropped. Empty when the title says nothing about a
# page, which is not an error: it means this instrument cannot see the position
# for this app, and the caller treats "cannot see" differently from "saw the
# wrong page".
page_from_title() {
    printf '%s' "$1" | /usr/bin/sed -n 's/.*[Pp]age \([0-9][0-9.,]*\) of .*/\1/p' | \
        /usr/bin/tr -d '.,' | /usr/bin/head -n 1
}

window_title() {
    /usr/bin/osascript - "$1" <<'AS' 2>/dev/null
on run argv
    tell application "System Events"
        tell process (item 1 of argv)
            try
                if (count of windows) is 0 then return ""
                return name of window 1
            on error
                return ""
            end try
        end tell
    end tell
end run
AS
}

# Did this trial actually start where it claims to? Sets START_PAGE, and
# increments CONTAMINATED when an app resumed a saved position instead.
#
# A trial that began on a different page than its opposite number is not a
# slightly noisy trial, it is a measurement of a different document, so it is
# not something a median over runs can absorb. The verdict refuses to score
# while any of these are outstanding.
assert_fresh_start() {
    START_PAGE=$(page_from_title "$(window_title "$1")")
    [ -n "$START_PAGE" ] || { START_PAGE="-"; return 0; }
    [ "$START_PAGE" = "1" ] && return 0
    CONTAMINATED=$((CONTAMINATED+1))
    printf '  !! %s opened a freshly copied file on page %s, not page 1.\n' "$2" "$START_PAGE"
    printf '     It restored a saved reading position, so this trial is not\n'
    printf '     comparable with its opposite number and is disqualified.\n'
}

# --- The quiet gate --------------------------------------------------------
#
# System-wide idle, measured over a real interval.
#
# `top -l 1` cannot measure this, and the way it fails is self-inflicted. Its
# first sample has no earlier sample to difference against, so the window it
# reports over is top's own startup -- during which the busiest process on the
# machine is top itself, walking the whole process table. The cost of asking
# lands inside the answer. Measured back to back on one machine:
#
#     top -l 1 (what this script used to do)   80.5 - 83.0 % idle
#     top -l 2, second sample                  87.2 - 88.9 % idle
#     iostat -c 2, second row                  88   - 90   % idle
#
# The last two agree; the first reads 6-8 points low. On the Mavericks Mac Pro,
# where SIMBL is injected into every process and the table walk is heavier, the
# same bias measures about 20 points: a machine idling at 97% reads 77%, the
# gate never sees MIN_IDLE=85, and every trial pays the full timeout and then
# starts anyway. The threshold was unreachable because asking the question was
# what stopped it being true.
#
# `iostat -c 2 -w 1` reads the host's CPU tick counters: no process
# enumeration, 0.00s user and 0.00s system for the whole invocation against
# top's 0.34s, and its second row is a true one-second delta. Its FIRST row is
# cumulative since boot -- constant across invocations, and the other way to
# get a wrong answer here -- so the parser takes the last row, never the first.
IDLE_SAMPLE_SECONDS=${IDLE_SAMPLE_SECONDS:-1}
QUIET_TIMEOUT=${QUIET_TIMEOUT:-20}
IDLE_TOLERANCE=${IDLE_TOLERANCE:-4}

# Both parsers read stdin, so the self-test can drive them from a canned sample
# and check that the since-boot row is the one being discarded. A parser that
# can only be tested by running the tool it parses is not being tested.
parse_iostat_idle() {
    /usr/bin/awk '
        /KB\// { for (i = 1; i <= NF; i++) if ($i == "id") col = i; next }
        col && $col ~ /^[0-9.]+$/ { last = $col }
        END { if (last != "") print last }'
}
parse_top_idle() {
    /usr/bin/awk '
        /^CPU usage/ { for (i = 1; i <= NF; i++)
                           if ($i == "idle") { gsub(/%/, "", $(i-1)); last = $(i-1) } }
        END { if (last != "") print last }'
}

system_idle() {
    v=$(/usr/sbin/iostat -c 2 -w "$IDLE_SAMPLE_SECONDS" 2>/dev/null | parse_iostat_idle)
    case "$v" in
        ''|*[!0-9.]*)
            # No iostat, or an output shape this does not understand. `top -l 2`
            # is the same measurement taken expensively: the second sample is a
            # real delta, so it is right, it just costs 0.34s of system time to
            # collect. Correct and slow beats cheap and wrong.
            v=$(/usr/bin/top -l 2 -n 0 2>/dev/null | parse_top_idle) ;;
    esac
    case "$v" in ''|*[!0-9.]*) return 1 ;; esac
    printf '%s\n' "$v"
}

# The gate is relative to this machine's own floor, not to an absolute number.
# An absolute threshold encodes an assumption about how quiet a quiet machine
# reads, and that is a property of the machine: a 2013 Mac Pro with a dozen
# daemons and third-party code in every process has a lower floor than a new
# iMac, and no single constant is right for both. MIN_IDLE stays on as a cap on
# strictness rather than a floor, so this can only ever make the gate easier to
# pass than it was -- it cannot introduce a stall of its own.
BASELINE_IDLE=""
QUIET_TARGET=$MIN_IDLE
measure_idle_baseline() {
    b1=$(system_idle) || b1=""
    b2=$(system_idle) || b2=""
    b3=$(system_idle) || b3=""
    BASELINE_IDLE=$(/usr/bin/awk -v a="$b1" -v b="$b2" -v c="$b3" 'BEGIN {
        n = 0
        if (a ~ /^[0-9.]+$/) { v[n] = a+0; n++ }
        if (b ~ /^[0-9.]+$/) { v[n] = b+0; n++ }
        if (c ~ /^[0-9.]+$/) { v[n] = c+0; n++ }
        if (n == 0) { printf ""; exit }
        for (i = 0; i < n; i++) for (j = i+1; j < n; j++)
            if (v[j] < v[i]) { t = v[i]; v[i] = v[j]; v[j] = t }
        printf "%.1f", v[int(n/2)] }')
    QUIET_TARGET=$(/usr/bin/awk -v base="$BASELINE_IDLE" -v m="$MIN_IDLE" -v tol="$IDLE_TOLERANCE" 'BEGIN {
        if (base !~ /^[0-9.]+$/) { printf "%.1f", m; exit }
        t = base - tol
        printf "%.1f", (t < m) ? t : m }')
}

# Returns the idle figure the trial started from, on stdout, whether or not the
# gate passed -- the caller records it either way, so a contaminated trial is
# visible in the TSV rather than folded silently into a median. Progress goes
# to stderr because stdout is being captured.
wait_for_quiet_machine() {
    waited=0
    idle=0
    while :; do
        idle=$(system_idle) || idle=0
        case "$idle" in ''|*[!0-9.]*) idle=0 ;; esac
        q=$(/usr/bin/awk -v i="$idle" -v t="$QUIET_TARGET" 'BEGIN { print (i>=t)?1:0 }')
        [ "$q" = "1" ] && { printf '%s\n' "$idle"; return 0; }
        waited=$((waited + IDLE_SAMPLE_SECONDS))
        [ "$waited" -ge "$QUIET_TIMEOUT" ] && break
        [ $((waited % 5)) -eq 0 ] && printf \
            '  waiting for a quiet machine: %s%% idle, need %s%% (%ss of %ss)\n' \
            "$idle" "$QUIET_TARGET" "$waited" "$QUIET_TIMEOUT" >&2
    done
    printf '%s\n' "$idle"; return 1
}

# Every pid in the process tree rooted at $1, $1 included, space separated.
#
# This exists because the app under test is not one process. Rasterisation moved
# into a child when the render helper landed, and `ps -o time` reports a
# process's own utime+stime and never a child's, reaped or not. Reading the
# viewer's pid alone therefore counted about 3% of what Postview cost while
# reporting the whole of Preview for Preview -- so the CPU columns were not a
# comparison at all. ENGINEERING.md 13.2 measured the hole: 3.520 s viewer
# against 108.069 s of helpers over one run.
#
# Applied to both apps or to neither. Preview has children of its own, and
# fixing one side alone would swap a known bias for a new and unmeasured one.
#
# Known limit, worth stating where a reader will meet it: an XPC service is a
# child of launchd rather than of the app that uses it, so it falls outside this
# tree for BOTH apps. What this closes is the helper Postview spawns itself with
# posix_spawn, which is where its rasterisation actually lives.
tree_pids_for() {
    /bin/ps -axo pid=,ppid= 2>/dev/null | /usr/bin/awk -v root="$1" '
        { pid[n] = $1; par[$1] = $2; n++ }
        END {
            keep[root] = 1
            # A few hundred rows and a depth of two or three. Sweeping the table
            # a fixed number of times is simpler than building an adjacency list
            # and cannot spin forever on a parent cycle that should not exist.
            for (pass = 0; pass < 8; pass++)
                for (i = 0; i < n; i++)
                    if ((par[pid[i]] in keep) && keep[par[pid[i]]] == 1) keep[pid[i]] = 1
            for (p in keep) if (keep[p] == 1) printf "%s ", p
        }'
}

# Exact CPU seconds from the kernel counter, summed over the tree.
# `ps -o time` is [[HH:]MM:]SS.ss. Empty -- not zero -- when nothing is alive,
# so a dead app is distinguishable from an idle one.
cpu_seconds_for() {
    _tp_args=""
    for _tp in $(tree_pids_for "$1"); do _tp_args="$_tp_args -p $_tp"; done
    [ -n "$_tp_args" ] || return 0
    /bin/ps -o time= $_tp_args 2>/dev/null | /usr/bin/awk '
        { gsub(/^[ \t]+/,"",$0); n=split($1,f,":"); s=0
          for (i=1;i<=n;i++) s=s*60+f[i]; total += s; rows++ }
        END { if (rows > 0) printf "%.2f", total }'
}

# Energy Impact and cumulative idle wakeups for the tree, as "power idlew",
# both summed. One top invocation, so every pid describes the same instant.
# A machine or OS that declines to report either yields "-", which the analysis
# treats as missing rather than as zero.
power_sample_for() {
    _tp_args=""; _tp_n=0
    for _tp in $(tree_pids_for "$1"); do
        _tp_args="$_tp_args -pid $_tp"; _tp_n=$((_tp_n+1))
    done
    [ "$_tp_n" -gt 0 ] || { printf '%s %s\n' "-" "-"; return 0; }
    # -n must admit every pid asked for; it caps rows, and it used to be 1
    # because there was only ever one pid.
    /usr/bin/top -l 1 -n "$_tp_n" $_tp_args -stats pid,power,idlew 2>/dev/null | /usr/bin/awk '
        $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9.]+$/ && $3 ~ /^[0-9]+$/ {
            pw += $2; iw += $3; found = 1 }
        END { if (found) printf "%.2f %d\n", pw, iw; else print "-", "-" }'
}

document_window_ready() {
    /usr/bin/osascript - "$1" <<'AS' 2>/dev/null
on run argv
    tell application "System Events"
        tell process (item 1 of argv)
            try
                if (count of windows) is 0 then return "no"
                if name of window 1 is "" then return "no"
                return "yes"
            on error
                return "no"
            end try
        end tell
    end tell
end run
AS
}
wait_for_document_window() {
    t=0
    while [ "$t" -lt 300 ]; do
        [ "$(document_window_ready "$1")" = "yes" ] && return 0
        /bin/sleep 0.1; t=$((t+1))
    done
    return 1
}

# Equalise the ZOOM, not merely the window size.
#
# The window has been equalised since the first version; the zoom never was, and
# the two apps do not default to the same one. Postview opens at fit-WIDTH,
# which for this document's 432x648 page in a 1200x800 window is about 2.4
# screenfuls per page. Preview opens at fit-PAGE, which is one. So one Page Down
# moved Preview a whole page and Postview about four tenths of one, and 80
# keystrokes travelled 80 pages against 27 -- measured 2026-09-03. The fairness
# gate caught it and refused a verdict in every keyboard scenario, correctly:
# nothing was being dropped and nothing was slow, the two apps were simply
# showing the page at different sizes and therefore doing different work.
#
# Fit-page is the common ground because it is the only one both apps have a
# command for -- Preview has no fit-width. Key codes rather than characters so
# the layout cannot reinterpret them: 19 = "2" (Postview), 25 = "9" (Preview).
set_fit_page() {
    case "$1" in
        Postview) _fp_key=19 ;;
        Preview)  _fp_key=25 ;;
        *)        return 0 ;;
    esac
    /usr/bin/osascript - "$1" "$_fp_key" <<'AS' >/dev/null 2>&1
on run argv
    set appName to item 1 of argv
    set kc to (item 2 of argv) as integer
    tell application "System Events"
        tell process appName
            set frontmost to true
            delay 0.3
            key code kc using command down
        end tell
    end tell
end run
AS
    /bin/sleep 0.8
}

set_window_size() {
    /usr/bin/osascript - "$1" "$WIN_W" "$WIN_H" <<'AS' 2>/dev/null
on run argv
    set appName to item 1 of argv
    set w to (item 2 of argv) as integer
    set h to (item 3 of argv) as integer
    tell application "System Events"
        tell process appName
            try
                set position of window 1 to {40, 40}
                set size of window 1 to {w, h}
            end try
            delay 0.4
            try
                set s to size of window 1
                return ((item 1 of s) as text) & "x" & ((item 2 of s) as text)
            on error
                return "unknown"
            end try
        end tell
    end tell
end run
AS
}

send_keys() {
    /usr/bin/osascript - "$1" "$2" "$3" "$4" <<'AS'
on run argv
    set appName to item 1 of argv
    set kc to (item 2 of argv) as integer
    set n to (item 3 of argv) as integer
    set d to (item 4 of argv) as real
    tell application "System Events"
        tell process appName
            set frontmost to true
            delay 0.25
            repeat with i from 1 to n
                key code kc
                delay d
            end repeat
        end tell
    end tell
end run
AS
}

# --- Trackpad and mouse-wheel scrolling ------------------------------------
#
# `send_keys` covers the keyboard. It cannot cover the other two devices: System
# Events can press a key but has no vocabulary for a scroll, so every scenario
# above this line drives the one input path that AppKit handles by *not* being
# involved -- a key event turns into an explicit `-scrollToPoint:`. The wheel
# and the trackpad go through `NSScrollView` itself, and that is a different
# code path in AppKit and a different branch of Postview's motion state:
#
#   trackpad   Continuous pixel deltas inside a Began/Changed/Ended phase
#              envelope. AppKit turns the envelope into
#              NSScrollViewWillStartLiveScroll / DidEndLiveScroll, which is
#              what sets `_liveScrolling`, and responsive scrolling blits the
#              already-drawn pixels and redraws only the exposed strip.
#   wheel      Line deltas with no phase at all. No live-scroll notification,
#              so the scheduler has no announcement to work from and falls back
#              to its measured-speed model -- the same position the keyboard is
#              in, but continuous.
#
# Two devices, two branches, and neither was being measured. Synthesising them
# needs CGEventCreateScrollWheelEvent, which no shell tool exposes, so the
# driver is compiled here from source and probed at startup like Energy Impact
# is: a scenario that cannot be driven is dropped and said out loud, never
# quietly recorded as a zero.
SCROLL_DRIVER=""
SCROLL_DRIVER_KIND="none"

scroll_driver_source() {
    /bin/cat <<'SRC'
/* pvscroll -- synthesises trackpad and mouse-wheel scrolling for the showdown.
 *
 * usage: pvscroll swipe|wheel <events> <delta> <delay-seconds> <x> <y>
 *
 * <delta> is per event and negative moves forward through the document. The
 * sign is applied here rather than being left to the "natural scrolling"
 * preference: a CGEvent carries the delta the driver already inverted, so a
 * synthesised event means the same thing on both machines and the benchmark
 * does not silently measure a system preference.
 */
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Phase values are written as literals. They are kCGScrollPhaseBegan (1),
 * kCGScrollPhaseChanged (2) and kCGScrollPhaseEnded (4); the names are not
 * declared by every SDK this may be compiled against, and a driver that fails
 * to build is a dropped scenario. */
#define PHASE_BEGAN   1
#define PHASE_CHANGED 2
#define PHASE_ENDED   4

static void nap(double seconds) {
    struct timespec ts;
    if (seconds <= 0.0) return;
    ts.tv_sec  = (time_t)seconds;
    ts.tv_nsec = (long)((seconds - (double)ts.tv_sec) * 1e9);
    nanosleep(&ts, NULL);
}

int main(int argc, char **argv) {
    int trackpad, n, delta, i;
    double delay;
    CGPoint at;

    if (argc != 7) {
        fprintf(stderr, "usage: %s swipe|wheel <events> <delta> <delay> <x> <y>\n", argv[0]);
        return 2;
    }
    trackpad = (strcmp(argv[1], "swipe") == 0);
    n     = atoi(argv[2]);
    delta = atoi(argv[3]);
    delay = atof(argv[4]);
    at    = CGPointMake(atof(argv[5]), atof(argv[6]));
    if (n < 1) return 2;

    /* A scroll event is delivered to the window under the pointer, not to the
     * focused window. Without this warp the whole scenario lands in whatever
     * happens to be under the cursor -- Terminal, most likely -- and the trial
     * records an app that did nothing, which reads as a very good result. */
    CGWarpMouseCursorPosition(at);
    nap(0.25);

    for (i = 0; i < n; i++) {
        CGEventRef e = CGEventCreateScrollWheelEvent(NULL,
            trackpad ? kCGScrollEventUnitPixel : kCGScrollEventUnitLine, 1, delta);
        if (!e) return 1;
        if (trackpad) {
            CGEventSetIntegerValueField(e, kCGScrollWheelEventIsContinuous, 1);
            CGEventSetIntegerValueField(e, kCGScrollWheelEventScrollPhase,
                                        (i == 0) ? PHASE_BEGAN : PHASE_CHANGED);
        }
        CGEventPost(kCGHIDEventTap, e);
        CFRelease(e);
        nap(delay);
    }

    /* Fingers lifting. Without it NSScrollView never ends its live scroll, so
     * the sharp pass that follows a real gesture never arrives and the app
     * under test looks cheaper than it is. */
    if (trackpad) {
        CGEventRef e = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 1, 0);
        if (e) {
            CGEventSetIntegerValueField(e, kCGScrollWheelEventIsContinuous, 1);
            CGEventSetIntegerValueField(e, kCGScrollWheelEventScrollPhase, PHASE_ENDED);
            CGEventPost(kCGHIDEventTap, e);
            CFRelease(e);
        }
    }
    return 0;
}
SRC
}

# The PyObjC path exists for a machine with no toolchain. Mavericks ships
# /usr/bin/python 2.7 with PyObjC, so the 10.9 test machine always has one of
# these two even if Xcode was never installed on it. Field ids are written as
# numbers because the constant names moved between PyObjC versions.
scroll_driver_python_source() {
    /bin/cat <<'SRC'
import sys, time
from Quartz import (CGEventCreateScrollWheelEvent, CGEventPost,
                    CGEventSetIntegerValueField, CGWarpMouseCursorPosition,
                    CGPointMake, kCGHIDEventTap)

UNIT_PIXEL, UNIT_LINE = 0, 1
IS_CONTINUOUS, SCROLL_PHASE = 88, 99
BEGAN, CHANGED, ENDED = 1, 2, 4

kind, n, delta, delay, x, y = sys.argv[1:7]
trackpad = (kind == "swipe")
n, delta, delay = int(n), int(delta), float(delay)

CGWarpMouseCursorPosition(CGPointMake(float(x), float(y)))
time.sleep(0.25)

for i in range(n):
    e = CGEventCreateScrollWheelEvent(None, UNIT_PIXEL if trackpad else UNIT_LINE, 1, delta)
    if trackpad:
        CGEventSetIntegerValueField(e, IS_CONTINUOUS, 1)
        CGEventSetIntegerValueField(e, SCROLL_PHASE, BEGAN if i == 0 else CHANGED)
    CGEventPost(kCGHIDEventTap, e)
    time.sleep(delay)

if trackpad:
    e = CGEventCreateScrollWheelEvent(None, UNIT_PIXEL, 1, 0)
    CGEventSetIntegerValueField(e, IS_CONTINUOUS, 1)
    CGEventSetIntegerValueField(e, SCROLL_PHASE, ENDED)
    CGEventPost(kCGHIDEventTap, e)
SRC
}

build_scroll_driver() {
    [ -n "$SCROLL_DRIVER" ] && return 0
    # `xcrun clang`, not the path xcrun resolves. Invoking the resolved binary
    # directly drops the SDK that xcrun would have configured, and a current
    # toolchain then cannot find ApplicationServices/ApplicationServices.h at
    # all -- which reads as "no compiler here" and silently drops two scenarios
    # on the one machine that certainly has one.
    cc=""
    if /usr/bin/xcrun clang --version >/dev/null 2>&1; then cc="/usr/bin/xcrun clang"
    elif command -v clang >/dev/null 2>&1;              then cc="clang"
    fi
    if [ -n "$cc" ]; then
        scroll_driver_source > "$WORKDIR/pvscroll.c"
        if $cc -O2 -o "$WORKDIR/pvscroll" "$WORKDIR/pvscroll.c" \
               -framework ApplicationServices >"$WORKDIR/pvscroll.log" 2>&1; then
            SCROLL_DRIVER="$WORKDIR/pvscroll"; SCROLL_DRIVER_KIND="compiled"; return 0
        fi
    fi
    for py in /usr/bin/python /usr/bin/python2.7 /usr/bin/python3; do
        [ -x "$py" ] || continue
        "$py" -c 'import Quartz' >/dev/null 2>&1 || continue
        scroll_driver_python_source > "$WORKDIR/pvscroll.py"
        SCROLL_DRIVER="$py $WORKDIR/pvscroll.py"; SCROLL_DRIVER_KIND="PyObjC ($py)"; return 0
    done
    return 1
}

# Where set_window_size() should have put the window. Only a fallback: that
# function's body is a `try` and is allowed to fail, and a pointer computed from
# WIN_W/WIN_H when the resize did not take is a pointer somewhere else entirely
# -- which would route the whole scenario to another window and record an app
# that did nothing, a result that reads as a very good one.
scroll_point() {
    /usr/bin/awk -v w="$WIN_W" -v h="$WIN_H" 'BEGIN { printf "%d %d", 40 + w/2, 40 + h/2 }'
}

# Activation and the real window rect in one osascript call rather than two.
# The centre, not a corner: a corner puts the pointer on the scrollbar, and a
# gesture on the scroll knob is a drag in one app and a scroll in the other.
scroll_target_point() {
    /usr/bin/osascript - "$1" <<'AS' 2>/dev/null
on run argv
    tell application "System Events"
        tell process (item 1 of argv)
            set frontmost to true
            delay 0.25
            try
                set p to position of window 1
                set s to size of window 1
                return (((item 1 of p) + ((item 1 of s) div 2)) as text) & " " & ¬
                       (((item 2 of p) + ((item 2 of s) div 2)) as text)
            on error
                return ""
            end try
        end tell
    end tell
end run
AS
}

send_scroll() {
    # $1 process name, $2 swipe|wheel, $3 events, $4 delta, $5 delay
    [ -n "$SCROLL_DRIVER" ] || die "no scroll driver was built; '$2' cannot be driven"
    pt=$(scroll_target_point "$1")
    good=$(printf '%s' "$pt" | /usr/bin/awk '{ print ($1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/) ? 1 : 0 }')
    [ "$good" = "1" ] || pt=$(scroll_point)
    set -- "$1" "$2" "$3" "$4" "$5" $pt
    $SCROLL_DRIVER "$2" "$3" "$4" "$5" "$6" "$7"
}

quit_app() {
    /usr/bin/osascript -e "tell application \"$1\" to quit" >/dev/null 2>&1
    t=0
    while running "$2"; do
        [ "$t" -lt 120 ] || return 1
        /bin/sleep 0.1; t=$((t+1))
    done
    return 0
}

samples=0; rss_peak=0; rss_sum=0; pw_sum=0; pw_peak=0; pw_n=0
reset_samples() { samples=0; rss_peak=0; rss_sum=0; pw_sum=0; pw_peak=0; pw_n=0; }
sample_process() {
    # Summed over the tree, for the reason in tree_pids_for(). Resident pages
    # shared between parent and child are counted twice by this, which is the
    # same overstatement both apps get and still far closer than charging the
    # viewer alone for bitmaps the helper is holding.
    _tp_args=""
    for _tp in $(tree_pids_for "$1"); do _tp_args="$_tp_args -p $_tp"; done
    r=$([ -n "$_tp_args" ] && /bin/ps -o rss= $_tp_args 2>/dev/null | /usr/bin/awk '
        { total += $1; rows++ } END { if (rows > 0) print total }')
    case "$r" in ''|*[!0-9]*) ;; *)
        samples=$((samples+1)); rss_sum=$((rss_sum+r))
        [ "$r" -gt "$rss_peak" ] && rss_peak=$r ;;
    esac
}
# Energy sampling is a separate, slower cadence: `top` costs real CPU itself,
# and sampling it as fast as ps would contaminate the very measurement it is
# taking. Called roughly once a second.
sample_power() {
    set -- $(power_sample_for "$1")
    [ "$#" -eq 2 ] || return 0
    [ "$1" = "-" ] && return 0
    pw_n=$((pw_n+1))
    pw_sum=$(/usr/bin/awk -v a="$pw_sum" -v b="$1" 'BEGIN { printf "%.2f", a+b }')
    hi=$(/usr/bin/awk -v a="$pw_peak" -v b="$1" 'BEGIN { print (b>a)?b:a }')
    pw_peak=$hi
}

# Postview reports what it actually rasterised when asked. Preview has no such
# switch, so these columns are diagnostics for one side rather than a metric to
# compare -- but they are the only way to confirm on the machine that matters
# that the scheduler is doing what the offline replays say it does.
# One value out of a PVSTAT census file, by exact key.
#
# Exact match on field 2, not a substring search on the whole line, because
# `requests.suppressed` is a prefix of `requests.suppressed.motion` and of
# `requests.suppressed.total`. A /pattern/ match would print all three into a
# single shell variable and put three lines in one TSV cell -- silently, and
# only once those keys existed. The self-test covers exactly that case.
pvstat() { /usr/bin/awk -v k="$1" '$1 == "PVSTAT" && $2 == k { print $3; exit }' "$2"; }

# Which power branch Postview is pinned to for the run. See open_app_with().
#
# Validated rather than trusted. PVApplyPowerDefaultOnce treats an unrecognised
# value as "no override" and falls back to asking the machine -- which on the
# Mac Pro arbiter is always AC. So `POWERSTATE=bettery` silently measured the AC
# policy while every header, filename and verdict line said battery, and nothing
# in the recorded output would ever say otherwise. An unrecognised value is a
# typo, and a typo here invalidates the run.
POWERSTATE="${POWERSTATE:-battery}"
case "$POWERSTATE" in
    battery|ac|auto) ;;
    *) die "POWERSTATE must be battery, ac, or auto (got '$POWERSTATE')" ;;
esac

POSTVIEW_DOMAIN="com.postview.Postview"

# Postview's settings for a trial, written to its preference domain.
#
# NOT `open --args`, which is what this used to do and which does not work on
# the machine that matters. Mavericks' open(1) has no --args: it parses the
# token as `--` (end of options) followed by a filename `args`, then treats
# everything after it as more filenames, resolved against the working
# directory. The symptom is an error naming files like `<cwd>/args` and
# `<cwd>/-PVStats`, and the consequence for this harness is worse than an
# error -- every PVSTAT column would come out empty and, far more seriously,
# -PVPowerState would never arrive, so the Mac Pro would measure the mains
# policy while the header claimed battery. That is the exact failure the pin
# exists to prevent.
#
# The preference domain is honoured by NSUserDefaults on every OS X version
# and, unlike an environment variable, survives being launched through
# LaunchServices -- which both apps must be, or launch_seconds stops being
# comparable between them.
#
# Written immediately before the launch and removed immediately after, with the
# EXIT trap removing them again in case a trial dies in between. Nothing is
# left in the user's preferences by a completed run.
# Whatever the operator already had, captured before the first write so the
# restore below puts it back instead of deleting it. A profiling harness that
# clears settings it did not set is a harness that quietly edits the machine it
# is measuring.
POSTVIEW_SAVED_STATS=
POSTVIEW_SAVED_STATSPATH=
POSTVIEW_SAVED_POWER=
POSTVIEW_SETTINGS_SAVED=0

postview_settings_save() {
    [ "$POSTVIEW_SETTINGS_SAVED" = "1" ] && return 0
    POSTVIEW_SAVED_STATS=$(/usr/bin/defaults read "$POSTVIEW_DOMAIN" PVStats 2>/dev/null || true)
    POSTVIEW_SAVED_STATSPATH=$(/usr/bin/defaults read "$POSTVIEW_DOMAIN" PVStatsPath 2>/dev/null || true)
    POSTVIEW_SAVED_POWER=$(/usr/bin/defaults read "$POSTVIEW_DOMAIN" PVPowerState 2>/dev/null || true)
    POSTVIEW_SETTINGS_SAVED=1
    return 0
}

# Returns non-zero if any write failed.
#
# These used to be three unchecked commands. A failed write is not a cosmetic
# problem here: PVStats not being set means the census never runs and every
# internal-render column is a dash, and PVPowerState not being set means the app
# asks the machine -- which on the arbiter is a Mac Pro, so the run measures the
# AC policy under a header that says battery. Both produce a complete-looking
# TSV that describes a different program from the one named in it.
postview_settings_set() {
    # $1 statfile
    postview_settings_save
    /usr/bin/defaults write "$POSTVIEW_DOMAIN" PVStats -bool YES &&
    /usr/bin/defaults write "$POSTVIEW_DOMAIN" PVStatsPath "$1" &&
    /usr/bin/defaults write "$POSTVIEW_DOMAIN" PVPowerState "$POWERSTATE"
}

# Restore, not delete. Deleting is only the right answer when the operator had
# nothing set, and postview_settings_save is what knows whether that was true.
postview_settings_clear() {
    [ "$POSTVIEW_SETTINGS_SAVED" = "1" ] || return 0
    if [ -n "$POSTVIEW_SAVED_STATS" ]; then
        /usr/bin/defaults write "$POSTVIEW_DOMAIN" PVStats "$POSTVIEW_SAVED_STATS" >/dev/null 2>&1 || true
    else
        /usr/bin/defaults delete "$POSTVIEW_DOMAIN" PVStats >/dev/null 2>&1 || true
    fi
    if [ -n "$POSTVIEW_SAVED_STATSPATH" ]; then
        /usr/bin/defaults write "$POSTVIEW_DOMAIN" PVStatsPath "$POSTVIEW_SAVED_STATSPATH" >/dev/null 2>&1 || true
    else
        /usr/bin/defaults delete "$POSTVIEW_DOMAIN" PVStatsPath >/dev/null 2>&1 || true
    fi
    if [ -n "$POSTVIEW_SAVED_POWER" ]; then
        /usr/bin/defaults write "$POSTVIEW_DOMAIN" PVPowerState "$POSTVIEW_SAVED_POWER" >/dev/null 2>&1 || true
    else
        /usr/bin/defaults delete "$POSTVIEW_DOMAIN" PVPowerState >/dev/null 2>&1 || true
    fi
    return 0
}

open_app_with() {
    # $1 app path/name, $2 document path, $3 statfile (Postview only)
    #
    # Both apps are launched by exactly the same command, with no extra
    # arguments on either side, so the launch path being timed is the same one
    # for both.
    #
    # POWERSTATE is battery by default because that is the case under test:
    # Postview runs a more expensive policy on mains power (sharp pages during
    # a slow scroll, deeper prefetch), and the arbiter machine is a desktop
    # that always reports AC. Run with POWERSTATE=ac to measure the other
    # branch deliberately; the value is printed in the run header and recorded
    # in the TSV so no run is ambiguous about which policy it measured.
    if [ -n "${3:-}" ]; then
        postview_settings_set "$3" ||
            die "could not configure Postview statistics and power policy"
    fi
    /usr/bin/open -n -a "$1" "$2" >/dev/null 2>&1
}

run_trial() {
    app=$1; process=$2; apppath=$3; scen=$4; iter=$5

    doc=$(fresh_document "$app-$scen-$iter") || die "could not stage a document"
    start_idle=$(wait_for_quiet_machine) || printf \
        '  (machine never reached %s%% idle in %ss; trial recorded with start_idle=%s)\n' \
        "$QUIET_TARGET" "$QUIET_TIMEOUT" "$start_idle"

    statfile=""
    [ "$app" = "Postview" ] && statfile="$WORKDIR/stat-$app-$scen-$iter.txt"

    t_open=$(now)
    open_app_with "$apppath" "$doc" "$statfile" || die "could not open $app"
    CURRENT_APP=$app
    wait_for_document_window "$process" || die "$app never showed a document window"
    t_ready=$(now)
    launch=$(elapsed "$t_open" "$t_ready")

    pid=$(pid_for "$process")
    [ -n "$pid" ] || die "could not find the $app process"

    winsize=$(set_window_size "$process")
    [ -n "$winsize" ] || winsize="unknown"
    /bin/sleep 1                        # let the resize settle before measuring

    # Same window AND same zoom, or the keystroke counts are not the same
    # workload. See set_fit_page().
    set_fit_page "$process"

    # Before the clock starts, and before any input is sent: the position an app
    # opens at decides which pages it rasterises, and the cost of a page varies
    # by up to 59x with its content. Checked every trial rather than trusted to
    # the staging, because the staging is exactly what was silently wrong.
    assert_fresh_start "$process" "$app"

    reset_samples
    iw_start=$(power_sample_for "$pid" | /usr/bin/awk '{ print $2 }')
    cpu_before=$(cpu_seconds_for "$pid")
    [ "$scen" = "launch" ] && cpu_before=0
    t0=$(now)
    driver=""

    case "$scen" in
        launch) : ;;
        idle)
            end=$(/usr/bin/awk -v a="$(now)" -v d="$IDLE_SECONDS" 'BEGIN { printf "%.6f", a+d }')
            tick=0
            while [ "$(/usr/bin/awk -v a="$(now)" -v b="$end" 'BEGIN { print (a<b)?1:0 }')" = "1" ]; do
                sample_process "$pid"
                tick=$((tick+1)); [ $((tick % 4)) -eq 0 ] && sample_power "$pid"
                /bin/sleep 0.25
            done ;;
        read)   send_keys "$process" 121 "$READ_PRESSES" "$READ_DELAY" >/dev/null 2>&1 & driver=$! ;;
        page)   send_keys "$process" 121 "$PAGE_PRESSES" "$PAGE_DELAY" >/dev/null 2>&1 & driver=$! ;;
        scroll) send_keys "$process" 125 "$SCROLL_PRESSES" "$SCROLL_DELAY" >/dev/null 2>&1 & driver=$! ;;
        swipe)  send_scroll "$process" swipe "$SWIPE_EVENTS" "$SWIPE_DELTA" "$SWIPE_DELAY" >/dev/null 2>&1 & driver=$! ;;
        wheel)  send_scroll "$process" wheel "$WHEEL_EVENTS" "$WHEEL_LINES" "$WHEEL_DELAY" >/dev/null 2>&1 & driver=$! ;;
        *)      die "unknown scenario: $scen" ;;
    esac

    if [ -n "$driver" ]; then
        tick=0
        while kill -0 "$driver" 2>/dev/null; do
            sample_process "$pid"
            tick=$((tick+1)); [ $((tick % 10)) -eq 0 ] && sample_power "$pid"
            /bin/sleep 0.1
        done
        wait "$driver" || die "$app stopped accepting input during '$scen'"
    fi

    # Work that follows the last keystroke is part of what the scenario cost.
    t=0
    while [ "$t" -lt "$TAIL_TICKS" ]; do
        running "$process" || die "$app terminated during '$scen'"
        sample_process "$pid"
        [ $((t % 10)) -eq 0 ] && sample_power "$pid"
        /bin/sleep 0.1; t=$((t+1))
    done

    t1=$(now)
    cpu_after=$(cpu_seconds_for "$pid")
    iw_end=$(power_sample_for "$pid" | /usr/bin/awk '{ print $2 }')
    cpu_used=$(/usr/bin/awk -v a="$cpu_before" -v b="$cpu_after" 'BEGIN { printf "%.2f", b-a }')
    wall=$(elapsed "$t0" "$t1")

    wakeups=$(/usr/bin/awk -v a="${iw_start:--}" -v b="${iw_end:--}" 'BEGIN {
        if (a ~ /^[0-9]+$/ && b ~ /^[0-9]+$/ && b >= a) printf "%d", b-a; else printf "-" }')
    mean_rss=$(/usr/bin/awk -v t="$rss_sum" -v n="$samples" 'BEGIN { printf "%.0f", n?t/n:0 }')
    cpu_rate=$(/usr/bin/awk -v c="$cpu_used" -v w="$wall" 'BEGIN { printf "%.3f", (w>0)?c/w:0 }')
    pw_mean=$(/usr/bin/awk -v t="$pw_sum" -v n="$pw_n" 'BEGIN { if (n) printf "%.2f", t/n; else printf "-" }')
    [ "$pw_n" -eq 0 ] && pw_peak="-"

    # Read while the window still exists, and after the clock has stopped so the
    # osascript round trip is not charged to the scenario.
    LAST_TITLE=$(window_title "$process")

    quit_app "$app" "$process" || die "$app did not quit cleanly after '$scen'"

    # The staged copy has served its purpose. Hard links cost nothing to keep,
    # but a copy is the whole file, and a full run stages one per app per
    # scenario per iteration -- 70 of them at the defaults. On the machine this
    # targets, with a spinning disk and a book-sized PDF, keeping them all until
    # the trap fires is gigabytes of avoidable occupancy during the measurement.
    # Removed after the app has quit, so nothing is reading it.
    [ -n "$doc" ] && /bin/rm -f "$doc" 2>/dev/null
    CURRENT_APP=""

    # The app has quit, so its stats file is fully written and the preference
    # keys have done their job. Removed per trial rather than once at the end,
    # so the window in which the user's own copy of Postview would behave
    # differently is only ever the length of one trial.
    [ -n "$statfile" ] && postview_settings_clear

    rf="-"; rp="-"; mp="-"; sup="-"; supm="-"; res="-"; resu="-"; resc="-"; resr="-"
    if [ -n "$statfile" ] && [ -f "$statfile" ]; then
        rf=$(pvstat renders.full "$statfile")
        rp=$(pvstat renders.preview "$statfile")
        mp=$(pvstat megapixels.total "$statfile")
        sup=$(pvstat requests.suppressed "$statfile")
        supm=$(pvstat requests.suppressed.motion "$statfile")
        res=$(pvstat resident.peak.mb "$statfile")
        resu=$(pvstat resident.peak.undelivered.mb "$statfile")
        resc=$(pvstat resident.peak.cache.mb "$statfile")
        # RSS as it stood when the census peaked. Paired with `res` by the app,
        # so the two can be subtracted; see the resident block in the analysis.
        resr=$(pvstat resident.peak.rss.mb "$statfile")
        [ -n "$rf" ]   || rf="-";   [ -n "$rp" ]   || rp="-"
        [ -n "$mp" ]   || mp="-";   [ -n "$sup" ]  || sup="-"
        [ -n "$supm" ] || supm="-"; [ -n "$res" ]  || res="-"
        [ -n "$resu" ] || resu="-"; [ -n "$resc" ] || resc="-"
        [ -n "$resr" ] || resr="-"
    fi

    # Where the document ended up, beside where it started. The pair is what
    # makes an unequal workload visible after the fact: two apps that began on
    # the same page and travelled a different distance were not asked the same
    # question either, even though nothing about the staging was wrong.
    end_page=$(page_from_title "$LAST_TITLE")
    [ -n "$end_page" ] || end_page="-"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$app" "$scen" "$iter" "$launch" "$wall" "$cpu_used" "$cpu_rate" \
        "$pw_mean" "$pw_peak" "$wakeups" "$mean_rss" "$rss_peak" \
        "$rf" "$rp" "$mp" "$sup" "$supm" "$res" "$resu" "$resc" \
        "$start_idle" "$START_PAGE" "$end_page" "$resr" >> "$OUTPUT"
    printf '  %-9s %-7s run %s: cpu %ss  energy %s  wakeups %s  peak rss %s MB  pages %s->%s%s\n' \
        "$app" "$scen" "$iter" "$cpu_used" "$pw_mean" "$wakeups" \
        "$(/usr/bin/awk -v k="$rss_peak" 'BEGIN { printf "%.0f", k/1024 }')" \
        "$START_PAGE" "$end_page" \
        "$([ "$rf" = "-" ] || printf '  [%s full, %s preview, %s Mpx, %s+%s suppressed, %s MB resident]' \
            "$rf" "$rp" "$mp" "$sup" "$supm" "$res")"
}

# Energy Impact is a Mavericks feature and is not reported by every kernel or on
# every machine. Probing once, up front, means a run that cannot collect it says
# so at the start rather than producing a verdict with a silently missing metric.
# CPU seconds and idle wakeups are the metrics the battery verdict cannot do
# without; Energy Impact is corroboration, and the analysis drops any metric
# that both apps failed to report rather than scoring it as a zero.
# ---------------------------------------------------------------------------
# Self-test. Run with --selftest to check the instruments without measuring
# anything.
#
# This exists because a broken sampler is silent: `top -n 0` asks for zero
# process rows, so an earlier version of power_sample_for returned no columns
# at all and would have produced a verdict with two of its three battery
# metrics quietly missing, after half an hour of unattended running. An
# instrument that cannot be checked before use is not an instrument.
# ---------------------------------------------------------------------------
selftest() {
    fails=0
    ok() { if [ "$1" = "1" ]; then printf '  ok    %s\n' "$2"; else printf '  FAIL  %s\n' "$2"; fails=$((fails+1)); fi; }

    printf 'Showdown self-test\n\n'

    v=$(now)
    ok "$(/usr/bin/awk -v v="$v" 'BEGIN { print (v > 1000000000) ? 1 : 0 }')" "now() returns a plausible epoch time"

    v=$(elapsed 10.0 12.5)
    ok "$(/usr/bin/awk -v v="$v" 'BEGIN { print (v > 2.49 && v < 2.51) ? 1 : 0 }')" "elapsed() subtracts correctly"

    v=$(cpu_seconds_for $$)
    ok "$(/usr/bin/awk -v v="$v" 'BEGIN { print (v ~ /^[0-9.]+$/) ? 1 : 0 }')" "cpu_seconds_for() reads the kernel counter"

    v=$(cpu_seconds_for 999999)
    ok "$([ -z "$v" ] && echo 1 || echo 0)" "cpu_seconds_for() is empty for a dead pid, not garbage"

    # --- the tree, which is the whole of ENGINEERING.md 13.2's fifth fault ---
    v=$(tree_pids_for $$ | /usr/bin/tr ' ' '\n' | /usr/bin/grep -c "^$$$")
    ok "$([ "$v" = "1" ] && echo 1 || echo 0)" "tree_pids_for() includes the root itself"

    /bin/sh -c 'sleep 4' &
    _kid=$!
    v=$(tree_pids_for $$ | /usr/bin/tr ' ' '\n' | /usr/bin/grep -c "^$_kid$")
    ok "$([ "$v" = "1" ] && echo 1 || echo 0)" "tree_pids_for() finds a spawned child"
    kill "$_kid" 2>/dev/null; wait "$_kid" 2>/dev/null

    # The fault itself: a child's CPU is never the parent's, so the viewer-only
    # reading missed the render helper -- 97% of what Postview spends. Burn CPU
    # in a live child and check the reading grows by it.
    /bin/sh -c 'i=0; while [ $i -lt 100000000 ]; do i=$((i+1)); done' &
    _burner=$!
    sleep 2
    _own=$(/bin/ps -o time= -p $$ 2>/dev/null | /usr/bin/awk '
        NR==1 { gsub(/^[ \t]+/,"",$0); n=split($1,f,":"); s=0
                for (i=1;i<=n;i++) s=s*60+f[i]; printf "%.2f", s }')
    _tree=$(cpu_seconds_for $$)
    kill "$_burner" 2>/dev/null; wait "$_burner" 2>/dev/null
    ok "$(/usr/bin/awk -v o="$_own" -v t="$_tree" 'BEGIN { print (t > o + 0.5) ? 1 : 0 }')" \
       "cpu_seconds_for() counts a live child's CPU, not just the viewer's"

    _r0=0; _rss_probe() { samples=0; rss_sum=0; rss_peak=0; sample_process "$1"; _r0=$rss_peak; }
    _rss_probe $$
    ok "$([ "$_r0" -gt 0 ] && echo 1 || echo 0)" "sample_process() sums resident memory over the tree"

    set -- $(power_sample_for $$)
    ok "$([ "$#" -eq 2 ] && echo 1 || echo 0)" "power_sample_for() returns two fields"
    ok "$([ "$2" != "-" ] && echo 1 || echo 0)" "idle wakeups are reported by this machine"
    [ "$2" = "-" ] && printf '        (the battery verdict will rest on CPU seconds alone)\n'
    case "$1" in
        -)   printf '        (Energy Impact is not reported here; it will be omitted)\n' ;;
        0.0) printf '        (Energy Impact reads 0.0 for this process -- it may not be\n'
             printf '         supported on this hardware. Mavericks on Intel does report it.)\n' ;;
    esac

    set -- $(power_sample_for 999999)
    ok "$([ "$1" = "-" ] && echo 1 || echo 0)" "power_sample_for() degrades for a dead pid"

    v=$(system_idle)
    ok "$(/usr/bin/awk -v v="$v" 'BEGIN { print (v ~ /^[0-9.]+$/ && v >= 0 && v <= 100) ? 1 : 0 }')" "system_idle() returns a percentage"

    # The idle sampler's two failure modes are both silent, and both were live
    # in this script: reporting a window the measurement itself dominates, and
    # reporting iostat's first row, which is cumulative since boot. Neither
    # looks wrong -- they return a plausible percentage -- so both are checked
    # against canned output with a known right answer rather than by eye.
    v=$(printf '%s\n' \
        '              disk0               disk4       cpu    load average' \
        '    KB/t  tps  MB/s     KB/t  tps  MB/s  us sy id   1m   5m   15m' \
        '   29.78  151  4.38    20.87    9  0.18  12  2 85  2.05 2.32 3.04' \
        '    9.18  159  1.43     0.00    0  0.00   4  2 94  2.05 2.32 3.04' | parse_iostat_idle)
    ok "$([ "$v" = "94" ] && echo 1 || echo 0)" "parse_iostat_idle() takes the delta row, not the since-boot row"

    v=$(printf '%s\n' \
        '              disk0       cpu    load average' \
        '    KB/t  tps  MB/s  us sy id   1m   5m   15m' \
        '   29.78  151  4.38  12  2 85  2.05 2.32 3.04' \
        '    9.18  159  1.43   4  2 97  2.05 2.32 3.04' | parse_iostat_idle)
    ok "$([ "$v" = "97" ] && echo 1 || echo 0)" "...and finds the column whatever the disk count"

    v=$(printf '%s\n' \
        'CPU usage: 5.14% user, 10.61% sys, 84.24% idle ' \
        'CPU usage: 3.4% user, 1.38% sys, 95.57% idle ' | parse_top_idle)
    ok "$([ "$v" = "95.57" ] && echo 1 || echo 0)" "parse_top_idle() takes the second sample, not the first"

    # MIN_IDLE is a cap on strictness, not a floor. If this inverts, a machine
    # with a low idle floor waits out the timeout on every one of ~50 trials.
    bad=0
    for b in 97 90 85 80 77 60; do
        t=$(/usr/bin/awk -v base="$b" -v m="$MIN_IDLE" -v tol="$IDLE_TOLERANCE" 'BEGIN {
            t = base - tol; printf "%.1f", (t < m) ? t : m }')
        /usr/bin/awk -v t="$t" -v m="$MIN_IDLE" -v b="$b" 'BEGIN {
            exit !(t <= m && t <= b) }' || bad=1
    done
    ok "$([ "$bad" = "0" ] && echo 1 || echo 0)" "the quiet target is never stricter than MIN_IDLE"

    # The scroll driver is compiled, so "does it exist" and "does it build" are
    # different questions and only the second one matters.
    if build_scroll_driver; then
        ok 1 "scroll driver built ($SCROLL_DRIVER_KIND)"
        $SCROLL_DRIVER 2>/dev/null; rc=$?
        ok "$([ "$rc" -eq 2 ] && echo 1 || echo 0)" "...and rejects a call with no arguments"
        set -- $(scroll_point)
        ok "$([ "$1" -gt 40 ] && [ "$2" -gt 40 ] && echo 1 || echo 0)" \
           "scroll_point() lands inside the ${WIN_W}x${WIN_H} window at ($1, $2)"
    else
        ok 0 "scroll driver built"
        printf '        (no clang and no PyObjC here; swipe and wheel will be skipped)\n'
    fi

    d=$(fresh_document selftest)
    ok "$([ -f "$d" ] && echo 1 || echo 0)" "fresh_document() stages a readable copy"
    ok "$([ "$d" != "$PDF" ] && echo 1 || echo 0)" "...at a path neither app has opened"

    ok "$([ -d "$POSTVIEW_APP" ] && echo 1 || echo 0)" "Postview.app found at $POSTVIEW_APP"
    pv=""
    for c in /Applications/Preview.app /System/Applications/Preview.app; do
        [ -d "$c" ] && { pv=$c; break; }
    done
    ok "$([ -n "$pv" ] && echo 1 || echo 0)" "Preview.app found${pv:+ at $pv}"

    /usr/bin/osascript -e 'tell application "System Events" to return name of current user' >/dev/null 2>&1
    ok "$([ "$?" -eq 0 ] && echo 1 || echo 0)" "System Events is scriptable (Accessibility granted)"

    # The analysis half, against a fixture with a known answer: Postview wins
    # every metric, so anything other than a clean sweep means the verdict
    # logic is miscounting.
    fixture="$WORKDIR/selftest.tsv"
    printf 'app\tscenario\trun\tlaunch_seconds\twall_seconds\tcpu_seconds\tcpu_per_second\tenergy_mean\tenergy_peak\tidle_wakeups\tmean_rss_kb\tpeak_rss_kb\n' > "$fixture"
    for r in 1 2 3; do
        printf 'Preview\tidle\t%s\t1.0\t30\t1.00\t0.03\t4.0\t9.0\t900\t150000\t160000\n' "$r" >> "$fixture"
        printf 'Postview\tidle\t%s\t0.5\t30\t0.10\t0.00\t0.4\t1.0\t60\t60000\t70000\n' "$r" >> "$fixture"
    done
    sweep=$(/usr/bin/awk -F '\t' -v band=0.05 -v runs=3 -f /dev/stdin "$fixture" <<'AWKEOF'
NR==1 { next }
{ if ($1=="Postview") { pc[++np]=$6+0 } else { vc[++nv]=$6+0 } }
END { print (np==3 && nv==3 && pc[1] < vc[1]) ? "1" : "0" }
AWKEOF
)
    ok "$sweep" "analysis fixture parses and orders correctly"

    # The census parser, against the prefix collision that motivated it. A key
    # that is a prefix of two others must still yield exactly one value.
    census="$WORKDIR/selftest-stats.txt"
    {
        printf 'PVSTAT renders.full 7\n'
        printf 'PVSTAT requests.suppressed 12\n'
        printf 'PVSTAT requests.suppressed.motion 388\n'
        printf 'PVSTAT requests.suppressed.total 400\n'
        printf 'PVSTAT resident.peak.mb 124.53\n'
        printf 'PVSTAT resident.peak.undelivered.mb 55.00\n'
    } > "$census"
    v=$(pvstat requests.suppressed "$census")
    ok "$([ "$v" = "12" ] && echo 1 || echo 0)" "pvstat() reads a key that is a prefix of two others"
    v=$(pvstat requests.suppressed.motion "$census")
    ok "$([ "$v" = "388" ] && echo 1 || echo 0)" "pvstat() reads the motion-suppression key"
    v=$(pvstat resident.peak.mb "$census")
    ok "$([ "$v" = "124.53" ] && echo 1 || echo 0)" "pvstat() reads the resident high-water mark"
    v=$(pvstat nosuchkey "$census")
    ok "$([ -z "$v" ] && echo 1 || echo 0)" "pvstat() is empty for a missing key, not garbage"

    # The analysis has to survive a TSV recorded before the resident columns
    # existed: those rows are twelve fields wide, and the new field references
    # must read as absent rather than as zero.
    narrow="$WORKDIR/selftest-narrow.tsv"
    printf 'app\tscenario\trun\tlaunch_seconds\twall_seconds\tcpu_seconds\tcpu_per_second\tenergy_mean\tenergy_peak\tidle_wakeups\tmean_rss_kb\tpeak_rss_kb\n' > "$narrow"
    for r in 1 2 3; do
        printf 'Preview\tidle\t%s\t1.0\t30\t1.00\t0.03\t4.0\t9.0\t900\t150000\t160000\n' "$r" >> "$narrow"
        printf 'Postview\tidle\t%s\t0.5\t30\t0.10\t0.00\t0.4\t1.0\t60\t60000\t70000\n' "$r" >> "$narrow"
    done
    v=$(/usr/bin/awk -F '\t' -v band=0.05 -v runs=3 '
        NR==1 { next }
        { if ($18 ~ /^[0-9.]+$/) n++ }
        END { print (n+0 == 0) ? "1" : "0" }' "$narrow")
    ok "$v" "a TSV without the resident columns reads them as absent, not as zero"

    # The page parser, against the two title shapes actually recorded. Preview
    # writes a thousands separator and Postview does not, and the bug this
    # exists to catch is exactly a four-digit page, so a parser that only ever
    # saw "page 6 of 60" would not have caught it.
    v=$(page_from_title "Computer Graphics-Postview-launch-1.pdf (page 6 of 1263)")
    ok "$([ "$v" = "6" ] && echo 1 || echo 0)" "page_from_title() reads an unseparated page number"
    v=$(page_from_title "Computer Graphics-Preview-launch-1.pdf (page 1,174 of 1,263)")
    ok "$([ "$v" = "1174" ] && echo 1 || echo 0)" "page_from_title() reads a page number with separators"
    v=$(page_from_title "Something.pdf")
    ok "$([ -z "$v" ] && echo 1 || echo 0)" "page_from_title() is empty for a title with no page in it"

    # The fairness gate itself, against the recorded failure: Preview resuming
    # on page 1,174 while Postview starts on page 1. A run like this must not
    # be allowed to name a winner, however clean its CPU columns look.
    unfairtsv="$WORKDIR/selftest-unfair.tsv"
    printf 'app\tscenario\trun\tlaunch_seconds\twall_seconds\tcpu_seconds\tcpu_per_second\tenergy_mean\tenergy_peak\tidle_wakeups\tmean_rss_kb\tpeak_rss_kb\trenders_full\trenders_preview\tmegapixels\trequests_suppressed\trequests_suppressed_motion\tresident_peak_mb\tresident_peak_undelivered_mb\tresident_peak_cache_mb\tstart_idle\tstart_page\tend_page\tresident_peak_rss_mb\n' > "$unfairtsv"
    # Rows transcribed from recorded runs. Four scenarios, four different things
    # the gate has to do, and each one is invisible to the others:
    #
    #   read    the resumed-page case. Preview opens on 1,174 and travels about
    #           as far as Postview does, so only the start check can catch it.
    #   scroll  unequal travel: 200 of the same keystrokes move Preview 48 pages
    #           and Postview 7. The start check passes it; only travel catches it.
    #   wheel   travel inside the instrument's own resolution -- 0 pages against
    #           1, from the 2026-08-31 run, where the two apps were 3% apart on
    #           either side of a page boundary. The ratio is infinite and means
    #           nothing. Must be reported and must NOT block the verdict.
    #   page    unequal-looking travel that is real and fine: 26 against 23,
    #           also from that run. Must be checked and must pass.
    #
    # Driven through render_verdict, i.e. the shipping analysis, rather than
    # through a second copy of the rule written here. A self-test that
    # reimplements the gate it is testing passes whichever way the gate breaks.
    for r in 1 2 3; do
        printf 'Preview\tread\t%s\t1.0\t30\t0.84\t0.03\t4.0\t9.0\t900\t146676\t156936\t-\t-\t-\t-\t-\t-\t-\t-\t88\t1174\t1178\n'  "$r" >> "$unfairtsv"
        printf 'Postview\tread\t%s\t0.5\t30\t6.03\t0.18\t0.4\t1.0\t60\t255561\t334268\t51\t25\t380.73\t0\t0\t120\t50\t90\t88\t1\t6\n' "$r" >> "$unfairtsv"
        printf 'Preview\tscroll\t%s\t1.0\t7\t1.46\t0.20\t4.0\t9.0\t900\t141755\t143700\t-\t-\t-\t-\t-\t-\t-\t-\t75\t1\t49\n'      "$r" >> "$unfairtsv"
        printf 'Postview\tscroll\t%s\t0.5\t7\t5.88\t0.82\t0.4\t1.0\t60\t231422\t272644\t126\t54\t962.19\t47\t388\t120\t50\t90\t75\t1\t8\n' "$r" >> "$unfairtsv"
        printf 'Preview\twheel\t%s\t0.86\t8.7\t0.86\t0.099\t0.00\t0\t215\t125952\t139252\t-\t-\t-\t-\t-\t-\t-\t-\t96\t1\t2\n'      "$r" >> "$unfairtsv"
        printf 'Postview\twheel\t%s\t0.59\t8.6\t0.75\t0.087\t0.00\t0\t129\t210837\t226208\t5\t4\t35.45\t0\t1\t102.50\t32.17\t101.58\t95\t1\t1\n' "$r" >> "$unfairtsv"
        printf 'Preview\tpage\t%s\t1.02\t8.9\t8.14\t0.917\t0.00\t0\t41\t145087\t169836\t-\t-\t-\t-\t-\t-\t-\t-\t96\t1\t24\n'      "$r" >> "$unfairtsv"
        printf 'Postview\tpage\t%s\t0.42\t9.0\t3.37\t0.376\t0.00\t0\t47\t212130\t267316\t6\t9\t51.20\t223\t129\t136.67\t32.17\t114.70\t96\t1\t27\n' "$r" >> "$unfairtsv"
    done
    unfairout="$WORKDIR/selftest-unfair.txt"
    render_verdict "$unfairtsv" 0.05 3 > "$unfairout" 2>&1

    v=$(/usr/bin/awk -F '\t' '
        NR==1 { next }
        $22 ~ /^[0-9]+$/ && $22+0 != 1 { bad++ }
        END { print (bad+0 == 3) ? "1" : "0" }' "$unfairtsv")
    ok "$v" "the fairness gate sees an app that resumed a saved page"
    v=$(/usr/bin/grep -c 'read  *an app did not start on page 1' "$unfairout")
    ok "$([ "$v" -ge 1 ] && echo 1 || echo 0)" "the verdict reports the resumed page"
    v=$(/usr/bin/grep -c 'scroll  *unequal travel' "$unfairout")
    ok "$([ "$v" -ge 1 ] && echo 1 || echo 0)" "the verdict reports unequal travel"
    v=$(/usr/bin/grep -c 'NO VERDICT -- 2 fairness check' "$unfairout")
    ok "$([ "$v" -ge 1 ] && echo 1 || echo 0)" "two failures block the verdict, and only those two"

    # The resolution rule, stated as its two halves: it must speak, and it must
    # not count. `wheel` is the reason the rule exists; `page` is the reason it
    # is bounded at one page rather than at some larger number that would have
    # swallowed a 26-against-23 comparison as well.
    v=$(/usr/bin/grep -c 'wheel  *travel not checkable' "$unfairout")
    ok "$([ "$v" -ge 1 ] && echo 1 || echo 0)" "travel inside the page counter's resolution is reported"
    v=$(/usr/bin/grep -c 'wheel  *unequal travel' "$unfairout")
    ok "$([ "$v" -eq 0 ] && echo 1 || echo 0)" "...and is not counted as a failure"
    v=$(/usr/bin/grep -c 'page  *\(unequal travel\|travel not checkable\)' "$unfairout")
    ok "$([ "$v" -eq 0 ] && echo 1 || echo 0)" "26 pages against 23 is checked, and passes"

    # And the staging that caused it. A hard link is the same inode, which is
    # the identity Preview restores against; a copy is a different document.
    src="$WORKDIR/selftest-src.pdf"; printf 'x' > "$src"
    lnk="$WORKDIR/selftest-link.pdf"; /bin/rm -f "$lnk"; /bin/ln "$src" "$lnk" 2>/dev/null
    cpy="$WORKDIR/selftest-copy.pdf"; /bin/rm -f "$cpy"; /bin/cp -X "$src" "$cpy" 2>/dev/null
    i_src=$(/usr/bin/stat -f '%i' "$src" 2>/dev/null)
    i_lnk=$(/usr/bin/stat -f '%i' "$lnk" 2>/dev/null)
    i_cpy=$(/usr/bin/stat -f '%i' "$cpy" 2>/dev/null)
    ok "$([ -n "$i_lnk" ] && [ "$i_lnk" = "$i_src" ] && echo 1 || echo 0)" \
       "a hard link is the same inode (the staging bug this replaced)"
    ok "$([ -n "$i_cpy" ] && [ "$i_cpy" != "$i_src" ] && echo 1 || echo 0)" \
       "fresh_document()'s copy is a different inode, so it is a different document"

    # How Postview is told to keep a census and which power branch to run.
    #
    # This replaced `open --args`, which does not exist on Mavericks: open(1)
    # there reads it as `--` plus a filename, and the settings simply never
    # arrive. That failure is silent in the worst possible way -- the run
    # completes, every PVSTAT column is empty, and the power branch is
    # whatever the machine happened to report, while the header says otherwise.
    # A measurement harness must not be able to fail that way without saying
    # so, hence these four checks.
    st_prev_state=$(/usr/bin/defaults read "$POSTVIEW_DOMAIN" PVPowerState 2>/dev/null || true)
    postview_settings_set "/tmp/pv-selftest-stats.txt"
    st_stats=$(/usr/bin/defaults read "$POSTVIEW_DOMAIN" PVStats 2>/dev/null || echo "")
    st_path=$(/usr/bin/defaults read "$POSTVIEW_DOMAIN" PVStatsPath 2>/dev/null || echo "")
    st_power=$(/usr/bin/defaults read "$POSTVIEW_DOMAIN" PVPowerState 2>/dev/null || echo "")
    ok "$([ "$st_stats" = "1" ] && echo 1 || echo 0)" \
       "the census is switched on by a route that works on 10.9 (PVStats=$st_stats)"
    ok "$([ "$st_path" = "/tmp/pv-selftest-stats.txt" ] && echo 1 || echo 0)" \
       "the stats path reaches the app's preference domain"
    ok "$([ "$st_power" = "$POWERSTATE" ] && echo 1 || echo 0)" \
       "the power branch is pinned to '$POWERSTATE' and not left to the machine"
    postview_settings_clear
    # "As found", which is not the same as "deleted": the harness now snapshots
    # whatever the operator had and puts that back, so a machine with a standing
    # PVPowerState keeps it. Asserted against the snapshot rather than against
    # absence, because deleting a setting the harness did not create is itself
    # the bug this replaced.
    st_after=$(/usr/bin/defaults read "$POSTVIEW_DOMAIN" PVStats 2>/dev/null || echo "gone")
    st_power_after=$(/usr/bin/defaults read "$POSTVIEW_DOMAIN" PVPowerState 2>/dev/null || echo "gone")
    ok "$([ "$st_after" = "gone" ] && echo 1 || echo 0)" \
       "the census switch is removed again"
    if [ -n "$st_prev_state" ]; then
        ok "$([ "$st_power_after" = "$st_prev_state" ] && echo 1 || echo 0)" \
           "a pre-existing power setting is restored, not deleted"
    else
        ok "$([ "$st_power_after" = "gone" ] && echo 1 || echo 0)" \
           "no power setting is left behind where there was none"
    fi

    printf '\n'
    if [ "$fails" -eq 0 ]; then
        printf 'Self-test passed. The instruments are working.\n'
        return 0
    fi
    printf '%s check(s) failed. Fix these before trusting a measurement run.\n' "$fails"
    return 1
}

# ---------------------------------------------------------------------------
# Analysis. Every metric here is lower-is-better.
#
# A function, and written to a file rather than passed inline, for one reason:
# the self-test has to be able to run THIS program over a fixture. It used to
# assert against its own second copy of the fairness rule, which is a test
# that passes while the gate it is named after is broken -- and the rule has
# since changed once, which is exactly when that gap costs something.
# ---------------------------------------------------------------------------
VERDICT_AWK=""
verdict_program() {
    [ -n "$VERDICT_AWK" ] && [ -f "$VERDICT_AWK" ] && return 0
    VERDICT_AWK="$WORKDIR/verdict.awk"
    /bin/cat > "$VERDICT_AWK" <<'AWKEOF'
function med(a, n,   i, t) {
    if (n == 0) return "-"
    for (i = 1; i <= n; i++) for (t = i+1; t <= n; t++) if (a[t] < a[i]) { x=a[i]; a[i]=a[t]; a[t]=x }
    if (n % 2) return a[(n+1)/2]
    return (a[n/2] + a[n/2+1]) / 2
}
function spread(a, n,   i, lo, hi) {
    if (n == 0) return 0
    lo = a[1]; hi = a[1]
    for (i = 2; i <= n; i++) { if (a[i] < lo) lo = a[i]; if (a[i] > hi) hi = a[i] }
    return hi - lo
}
NR == 1 { next }
{
    app = $1; scen = $2
    key = scen
    if ($6  ~ /^[0-9.]+$/) { n_cpu[app,key]++;  cpu[app,key,n_cpu[app,key]]  = $6 + 0 }
    if ($8  ~ /^[0-9.]+$/) { n_pw[app,key]++;   pw[app,key,n_pw[app,key]]    = $8 + 0 }
    if ($10 ~ /^[0-9]+$/)  { n_iw[app,key]++;   iw[app,key,n_iw[app,key]]    = $10 + 0 }
    if ($12 ~ /^[0-9]+$/)  { n_rss[app,key]++;  rss[app,key,n_rss[app,key]]  = $12 + 0 }
    if ($4  ~ /^[0-9.]+$/) { n_l[app,key]++;    lau[app,key,n_l[app,key]]    = $4 + 0 }
    # Postview-only diagnostics: what it actually rasterised, what it declined
    # to rasterise, and how much of it was resident at the worst instant.
    if ($13 ~ /^[0-9.]+$/) { n_rf[app,key]++;  rf[app,key,n_rf[app,key]]    = $13 + 0 }
    if ($15 ~ /^[0-9.]+$/) { n_mp[app,key]++;  mpx[app,key,n_mp[app,key]]   = $15 + 0 }
    if ($16 ~ /^[0-9.]+$/) { n_sp[app,key]++;  spr[app,key,n_sp[app,key]]   = $16 + 0 }
    if ($17 ~ /^[0-9.]+$/) { n_sm[app,key]++;  spm[app,key,n_sm[app,key]]   = $17 + 0 }
    if ($18 ~ /^[0-9.]+$/) { n_rb[app,key]++;  rbp[app,key,n_rb[app,key]]   = $18 + 0 }
    if ($19 ~ /^[0-9.]+$/) { n_ru[app,key]++;  rbu[app,key,n_ru[app,key]]   = $19 + 0 }
    if ($20 ~ /^[0-9.]+$/) { n_rc[app,key]++;  rbc[app,key,n_rc[app,key]]   = $20 + 0 }
    # Column 24, appended after the page columns for the same reason they were
    # appended after the census ones: every index above keeps its meaning and a
    # TSV recorded before this column reads it as absent rather than as zero.
    if ($24 ~ /^[0-9.]+$/) { n_rat[app,key]++; rat[app,key,n_rat[app,key]]   = $24 + 0 }
    # Where each app started, and how far it travelled. Not scored -- these
    # decide whether the scored metrics mean anything at all. A row from a TSV
    # recorded before these columns existed reads as absent and is skipped,
    # which is why the check counts what it saw rather than what it expected.
    if ($22 ~ /^[0-9]+$/) {
        n_sp2[app,key]++
        if ($22 + 0 != 1) badstart[app,key]++
        sp0[app,key] = $22 + 0
    }
    if ($22 ~ /^[0-9]+$/ && $23 ~ /^[0-9]+$/) {
        d = $23 - $22; if (d < 0) d = -d
        n_tr[app,key]++; trav[app,key] = trav[app,key] + d
    }
    seen[key] = 1
}
END {
    order = "launch idle read page scroll swipe wheel"
    nsc = split(order, sc, " ")

    printf "=========================================================================\n"
    printf "  POSTVIEW vs PREVIEW -- VERDICT\n"
    printf "  %d runs per scenario, medians, lower is better throughout.\n", runs
    printf "  A gap under %.0f%% is called a tie: below that the two apps are\n", band*100
    printf "  doing the same thing and the difference is the machine.\n"
    printf "=========================================================================\n"
    # The conditions, in the file rather than only on the terminal the run
    # scrolled past. The saved verdict is what gets carried back and read weeks
    # later, and the power branch is not a detail: section 4.2 of ENGINEERING.md
    # makes battery and AC two different scheduling policies, so a verdict that
    # does not say which one it measured is a verdict whose subject is unknown.
    # The 2026-08-31 file is the one that proved this -- it had to be inferred
    # from the script's default.
    if (power != "" || pdf != "" || win != "") {
        printf "\n"
        if (pdf   != "") printf "  document      %s\n", pdf
        if (win   != "") printf "  window        %s\n", win
        if (power != "") {
            printf "  power policy  Postview pinned to -PVPowerState %s\n", power
            if (power != "battery")
                printf "                NOT the battery case; not comparable with default runs.\n"
        }
        if (host  != "") printf "  host          %s\n", host
        if (when  != "") printf "  recorded      %s\n", when
    }
    printf "\n"

    wins = 0; losses = 0; ties = 0
    bwins = 0; blosses = 0; bties = 0

    for (s = 1; s <= nsc; s++) {
        k = sc[s]
        if (!(k in seen)) continue
        printf "-- %s %s\n", k, substr("--------------------------------------------------------", 1, 60 - length(k))

        emit(k, "cpu_seconds",  "CPU seconds",    cpu,  n_cpu, 1, "%.2f")
        emit(k, "energy_mean",  "Energy Impact",  pw,   n_pw,  1, "%.2f")
        emit(k, "idle_wakeups", "Idle wakeups",   iw,   n_iw,  1, "%d")
        emit(k, "peak_rss_kb",  "Peak memory MB", rss,  n_rss, 0, "%.0f")
        if (k == "launch") emit(k, "launch_seconds", "Launch seconds", lau, n_l, 0, "%.3f")
        printf "\n"
    }

    # What Postview rasterised, for confirming the scheduler on hardware.
    # Preview reports nothing comparable, so this is diagnosis, not a contest.
    any = 0
    for (s = 1; s <= nsc; s++) if ((sc[s] in seen) && n_rf["Postview",sc[s]] > 0) any = 1
    if (any) {
        printf "-- what Postview rasterised (Preview has no equivalent counter) ----\n"
        for (s = 1; s <= nsc; s++) {
            k = sc[s]
            if (!(k in seen) || n_rf["Postview",k] == 0) continue
            for (i = 1; i <= n_rf["Postview",k]; i++) a1[i] = rf["Postview",k,i]
            for (i = 1; i <= n_mp["Postview",k]; i++) a2[i] = mpx["Postview",k,i]
            for (i = 1; i <= n_sp["Postview",k]; i++) a3[i] = spr["Postview",k,i]
            for (i = 1; i <= n_sm["Postview",k]; i++) a4[i] = spm["Postview",k,i]
            printf "  %-8s %6.0f full renders   %8.1f Mpx   %6.0f suppressed (%.0f dwell + %.0f motion)\n",
                k, med(a1, n_rf["Postview",k]), med(a2, n_mp["Postview",k]),
                med(a3, n_sp["Postview",k]) + med(a4, n_sm["Postview",k]),
                med(a3, n_sp["Postview",k]), med(a4, n_sm["Postview",k])
        }
        printf "\n  Reference, before the scheduler work (same machine, one run):\n"
        printf "    read        51 full renders      380.7 Mpx        0 suppressed\n"
        printf "    page        90 full renders      666.7 Mpx      323 suppressed\n"
        printf "    scroll     126 full renders      962.2 Mpx       47 suppressed\n"
        printf "  Zero DWELL suppression on 'read' is correct: 2.5 s between key\n"
        printf "  presses leaves the document at rest, and a page being read wants to\n"
        printf "  be sharp. The motion column is separate and was not counted at all\n"
        printf "  before this run, which is why 'scroll' used to report zero while the\n"
        printf "  motion gate was doing the suppressing.\n\n"
    }

    # Resident rendered pixels: the part of peak RSS Postview actually decides.
    # Preview reports nothing comparable, so like the census above this is
    # diagnosis and not a contest -- but it is the only way to tell a peak_rss_kb
    # change caused by the render pipeline from one caused by the frameworks.
    any = 0
    for (s = 1; s <= nsc; s++) if ((sc[s] in seen) && n_rb["Postview",sc[s]] > 0) any = 1
    if (any) {
        printf "-- resident rendered pixels, high water (Postview only) -----------\n"
        for (s = 1; s <= nsc; s++) {
            k = sc[s]
            if (!(k in seen) || n_rb["Postview",k] == 0) continue
            for (i = 1; i <= n_rb["Postview",k]; i++) b1[i] = rbp["Postview",k,i]
            for (i = 1; i <= n_ru["Postview",k]; i++) b2[i] = rbu["Postview",k,i]
            for (i = 1; i <= n_rc["Postview",k]; i++) b3[i] = rbc["Postview",k,i]
            for (i = 1; i <= n_rss["Postview",k]; i++) b4[i] = rss["Postview",k,i]
            for (i = 1; i <= n_rat["Postview",k]; i++) b5[i] = rat["Postview",k,i]
            peakrss = med(b4, n_rss["Postview",k]) / 1024
            resident = med(b1, n_rb["Postview",k])
            # 'non-bitmap' is only a quantity if its two terms were read off the
            # same instant. resident.peak.rss.mb is RSS sampled by the app at
            # the moment it set the resident high-water mark, so that pair is
            # simultaneous by construction and the subtraction is a real one.
            #
            # peak_rss_kb is a maximum in its own right, taken by the sampler on
            # its own schedule, and max(bitmaps+rest) - max(rest) is not
            # 'bitmaps' -- it equals it only if the two maxima coincide, and
            # sags towards zero when they do not. Subtracting those two is what
            # the 2026-08-31 run did, and it is why its 'non-bitmap' column ran
            # from 68.8 MB to 177.6 MB across scenarios underneath a note saying
            # the quantity should be roughly constant. Kept as a fallback for
            # TSVs recorded before the app reported the paired reading, and
            # marked when that is what is being shown.
            atpeak = (n_rat["Postview",k] > 0) ? med(b5, n_rat["Postview",k]) : 0
            if (atpeak > 0) { nonbitmap = atpeak - resident; mark = " " }
            else            { nonbitmap = peakrss - resident; mark = "?" }
            if (nonbitmap < 0) nonbitmap = 0
            printf "  %-8s %7.1f MB resident  (cache %6.1f, undelivered %5.1f)   peak rss %6.1f MB   non-bitmap %6.1f MB%s\n", k, resident, med(b3, n_rc["Postview",k]), med(b2, n_ru["Postview",k]), peakrss, nonbitmap, mark
            if (atpeak <= 0) sawlegacy = 1
        }
        printf "  The undelivered column is bounded by PV_MAX_INFLIGHT_FULL bitmaps.\n"
        printf "  'non-bitmap' is everything else in the process at the instant the\n"
        printf "  bitmap census peaked: frameworks, the window backing store, the\n"
        printf "  binary. Both terms are read off that same instant, so it should be\n"
        printf "  roughly constant across scenarios -- if it is not, the peak moved\n"
        printf "  for a reason that has nothing to do with the render pipeline.\n"
        if (sawlegacy) {
            printf "  Rows marked ? predate resident.peak.rss.mb and fall back to\n"
            printf "  subtracting two maxima taken at different moments. That is not\n"
            printf "  the same quantity and it is not comparable with the rest.\n"
        }
        printf "\n"
    }

    # Fairness, checked before anything above is allowed to mean something.
    #
    # Two ways the same document produces two different workloads. Both are
    # invisible in every metric this script scores, and both have happened:
    #
    #  - an app opened on a page it remembered instead of page 1, so the two
    #    apps rasterised different parts of the file. The cost of one page
    #    varies by up to 59x with its content (ENGINEERING.md), so this
    #    can dwarf every real difference between the two programs.
    #  - both started on page 1 but travelled different distances, because the
    #    same key scrolls by a different amount in each app. Then the CPU
    #    figures are per-keypress rather than per-page, and the app that moved
    #    further did more work for its seconds.
    #
    # Reported, never silently corrected. The run is what it is; what changes is
    # whether it is allowed to declare a winner.
    unfair = 0; fairhdr = 0
    for (s = 1; s <= nsc; s++) {
        k = sc[s]; if (!seen[k]) continue
        if (badstart["Postview",k] > 0 || badstart["Preview",k] > 0) {
            if (!fairhdr) { printf "\n"; printf "  FAIRNESS\n"; fairhdr = 1 }
            unfair++
            printf "  %-8s an app did not start on page 1 (Postview %d of %d trials, Preview %d of %d)\n",
                   k, badstart["Postview",k]+0, n_sp2["Postview",k]+0,
                      badstart["Preview",k]+0,  n_sp2["Preview",k]+0
        }
    }
    for (s = 1; s <= nsc; s++) {
        k = sc[s]; if (!seen[k]) continue
        if (n_tr["Postview",k] > 0 && n_tr["Preview",k] > 0) {
            ta = trav["Postview",k] / n_tr["Postview",k]
            tb = trav["Preview",k]  / n_tr["Preview",k]
            hi = (ta > tb) ? ta : tb; lo = (ta > tb) ? tb : ta
            # This instrument reads a page number out of a window title, so its
            # resolution is one page and nothing finer. Two apps that travelled
            # the SAME distance still report a page apart whenever that distance
            # straddles a page boundary: one viewport top has crossed it and the
            # other has not.
            #
            # So a gap of one page is exactly what equal travel looks like at
            # this resolution, and the ratio computed from it is not evidence of
            # anything -- at lo=0 it is not even finite. Recorded 2026-08-31:
            # `wheel` moved Postview 1800 pt and Preview about 1860, a 3%
            # difference either side of a 1859 pt page pitch, which the counter
            # rendered as 0 pages against 1 and the ratio test as an infinite
            # disparity. A gap of two pages or more cannot be manufactured this
            # way and is the app.
            #
            # Said out loud rather than skipped, because "the check did not run"
            # and "the check passed" are different facts about a run. Equal
            # readings are silent: there is no gap to be unsure about.
            #
            # The band is one page on the AVERAGED travel, and stays one page
            # there: averaging N trials cannot spread two equal-travel apps
            # further than the single-trial quantum that produced each reading.
            if (hi > 0 && hi - lo > 0 && hi - lo <= 1) {
                if (!fairhdr) { printf "\n"; printf "  FAIRNESS\n"; fairhdr = 1 }
                printf "  %-8s travel not checkable: Postview %.0f pages, Preview %.0f pages per trial\n",
                       k, ta, tb
                printf "           one page apart is what equal travel looks like to a page\n"
                printf "           counter, so the ratio carries no information here. The\n"
                printf "           scenario is scored; its staging is unverified.\n"
            }
            # Twice as far is not the same workload. Below that, the scenarios
            # land close enough that the metric is still about the apps.
            else if (hi > 0 && hi - lo > 1 && lo * 2 < hi) {
                if (!fairhdr) { printf "\n"; printf "  FAIRNESS\n"; fairhdr = 1 }
                unfair++
                printf "  %-8s unequal travel: Postview %.0f pages, Preview %.0f pages per trial\n",
                       k, ta, tb
                printf "           the same keystrokes move the two apps different distances, so\n"
                printf "           these CPU figures are per-keypress and not per-page.\n"
            }
        }
    }
    printf "\n"

    printf "=========================================================================\n"
    if (unfair > 0) {
        printf "  NO VERDICT -- %d fairness check(s) failed above.\n", unfair
        printf "\n"
        printf "  The two apps were not asked the same question, so the medians\n"
        printf "  below describe two different workloads and no winner can be read\n"
        printf "  from them. Fix the staging and re-run; they are recorded only so\n"
        printf "  the failure is visible rather than averaged away.\n"
        printf "\n"
        printf "  (unscored) battery: %d/%d/%d   overall: %d/%d/%d  win/loss/tie\n",
               bwins, blosses, bties, wins, losses, ties
        printf "=========================================================================\n"
        exit 0
    }
    printf "  BATTERY VERDICT   (CPU seconds, Energy Impact and wakeups only --\n"
    printf "                     the three metrics that actually drain a battery)\n"
    printf "  Postview wins %d, loses %d, ties %d\n", bwins, blosses, bties
    if (blosses == 0 && bwins > 0) printf "  ==> Postview is at least equivalent on every battery metric.\n"
    else if (blosses > 0)          printf "  ==> NOT YET. %d battery metric(s) still favour Preview.\n", blosses
    printf "\n"
    printf "  OVERALL           Postview wins %d, loses %d, ties %d\n", wins, losses, ties
    if (losses == 0 && wins > 0) printf "  ==> Postview is equivalent or better on every metric measured.\n"
    else if (losses > 0)         printf "  ==> %d metric(s) still favour Preview. Not done.\n", losses
    printf "=========================================================================\n"
}
function emit(k, metric, label, arr, cnt, isbattery, fmt,   i, a, b, na, nb, ma, mb, sa, sb, verdict, delta, note, denom, gap, pa, pb, sa_txt, sb_txt, allzero) {
    na = cnt["Postview",k]; nb = cnt["Preview",k]
    if (na == 0 || nb == 0) { printf "  %-16s %s\n", label, "(not reported by both apps)"; return }
    for (i = 1; i <= na; i++) a[i] = arr["Postview",k,i]
    for (i = 1; i <= nb; i++) b[i] = arr["Preview",k,i]
    sa = spread(a, na); sb = spread(b, nb)
    ma = med(a, na); mb = med(b, nb)

    # A metric that reads zero for both apps in every single trial was not
    # measured; it is an absent instrument wearing the clothes of a dead heat.
    #
    # The guard above catches a field that is literally missing ("-"). Energy
    # Impact is not missing -- the sampler returns 0.00 on a machine that does
    # not report it -- so it reached the comparison below, took the ma == 0 &&
    # mb == 0 branch, and was scored TIE. Recorded 2026-08-31: all 70 rows of
    # both apps read 0.00, and the verdict counted seven ties from it, which is
    # seven ninths of every tie in the run. "The two apps drew" and "nobody
    # asked" are not the same sentence.
    #
    # Every sample, not just the median, so a metric that genuinely spent most
    # of a scenario at zero is still scored on the trials where it moved.
    allzero = 1
    for (i = 1; i <= na && allzero; i++) if (a[i] != 0) allzero = 0
    for (i = 1; i <= nb && allzero; i++) if (b[i] != 0) allzero = 0
    if (allzero) {
        printf "  %-16s %s\n", label, "(not reported by this machine -- not scored)"
        return
    }

    if (ma == 0 && mb == 0)      { verdict = "TIE";  delta = 0 }
    else {
        denom = (ma > mb) ? ma : mb
        delta = (mb - ma) / denom
        if (delta > band)       verdict = "WIN"
        else if (delta < -band) verdict = "LOSS"
        else                    verdict = "TIE"
    }

    if (verdict == "WIN")  { wins++;  if (isbattery) bwins++ }
    if (verdict == "LOSS") { losses++; if (isbattery) blosses++ }
    if (verdict == "TIE")  { ties++;  if (isbattery) bties++ }

    pa = ma; pb = mb
    if (metric == "peak_rss_kb") { pa = ma/1024; pb = mb/1024 }

    note = ""
    # A spread wider than the gap between the apps means the run-to-run noise is
    # larger than the effect, so the verdict is not yet trustworthy.
    if (sa + sb > 0 && ma != mb) {
        gap = (ma > mb) ? ma - mb : mb - ma
        if ((sa > gap) || (sb > gap)) note = "   [noisy: spread exceeds the gap]"
    }

    # Formatted into strings first so that a %d metric and a %.2f metric still
    # line up in the same column.
    sa_txt = sprintf(fmt, pa); sb_txt = sprintf(fmt, pb)
    printf "  %-16s Postview %10s   Preview %10s   %-4s %+.0f%%%s\n",
        label, sa_txt, sb_txt, verdict, delta*100, note
}
AWKEOF
}

# $1 tsv, $2 tie band, $3 runs per scenario. Writes the verdict to stdout.
render_verdict() {
    verdict_program
    /usr/bin/awk -F '\t' -v band="$2" -v runs="$3" \
        -v power="${POWERSTATE:-}" -v pdf="${PDF_BASE:-}" \
        -v win="${VERDICT_WINDOW:-}" -v host="${VERDICT_HOST:-}" \
        -v when="${VERDICT_WHEN:-}" \
        -f "$VERDICT_AWK" "$1"
}

if [ "${SELFTEST:-0}" = "1" ]; then
    selftest
    exit $?
fi

# Checked here rather than with the other preconditions at the top.
#
# Nothing above this line starts an application: --selftest exercises the
# samplers and the analysis and returns. Gating it on a quiet machine meant that
# `make verify-all` -- which runs the self-test as its last gate -- failed
# whenever the developer happened to have a Preview window open, on a check that
# has nothing to do with either app. A precondition applied earlier than the
# thing it protects is a precondition that fails for the wrong reasons.
if running Preview || running "$POSTVIEW_PROCESS"; then
    die "quit all Preview and Postview windows first; existing sessions are never touched"
fi

# The machine's own idle floor, measured before anything is launched and with
# the same instrument the gate will use. Three samples, median, ~3s.
printf 'Measuring the idle floor of this machine...'
measure_idle_baseline
printf '\r%-60s\r' ''
# The scroll driver, probed the same way. A scenario that cannot be driven is
# removed from the list here rather than failing thirty minutes in, and the
# removal is stated: a run whose verdict silently covers five scenarios instead
# of seven is worse than one that says which two are missing.
if ! build_scroll_driver; then
    kept=""
    for scen in $SCENARIOS; do
        case "$scen" in swipe|wheel) ;; *) kept="$kept $scen" ;; esac
    done
    SCENARIOS=$(printf '%s' "$kept" | /usr/bin/sed 's/^ //')
    [ -n "$SCENARIOS" ] || die "the only scenarios requested need a scroll driver, and none could be built (see $WORKDIR/pvscroll.log)"
fi

probe_pid=$$
probe_out=$(power_sample_for "$probe_pid")
probe_pw=$(printf '%s' "$probe_out" | /usr/bin/awk '{ print $1 }')
probe_iw=$(printf '%s' "$probe_out" | /usr/bin/awk '{ print $2 }')
ENERGY_OK=no; WAKEUPS_OK=no
case "$probe_pw" in ''|-) ;; *) ENERGY_OK=yes ;; esac
case "$probe_iw" in ''|-) ;; *) WAKEUPS_OK=yes ;; esac
# A kernel that reports the column but pins it at zero for a process that is
# demonstrably busy is reporting nothing useful either.
[ "$probe_pw" = "0.0" ] && ENERGY_OK="probably not (reads 0.0 for this process)"

# Columns 17-21 are new and are appended rather than inserted, so every field
# index the analysis below already uses keeps its meaning and TSVs recorded
# before them still parse. The analysis reads fields by number and never NF,
# which is what makes appending safe.
printf 'app\tscenario\trun\tlaunch_seconds\twall_seconds\tcpu_seconds\tcpu_per_second\tenergy_mean\tenergy_peak\tidle_wakeups\tmean_rss_kb\tpeak_rss_kb\trenders_full\trenders_preview\tmegapixels\trequests_suppressed\trequests_suppressed_motion\tresident_peak_mb\tresident_peak_undelivered_mb\tresident_peak_cache_mb\tstart_idle\tstart_page\tend_page\tresident_peak_rss_mb\n' > "$OUTPUT" ||
    die "cannot create $OUTPUT"

# Trials whose app restored a saved reading position instead of starting at
# page 1. Any at all and the run compared two different workloads, which is not
# a thing a median absorbs -- see fresh_document().
CONTAMINATED=0
START_PAGE="-"
LAST_TITLE=""

printf 'Postview vs Preview -- head to head\n'
printf 'PDF:        %s\n' "$PDF"
printf 'Postview:   %s\n' "$POSTVIEW_APP"
printf 'Scenarios:  %s\n' "$SCENARIOS"
printf 'Runs each:  %s   window %sx%s\n' "$RUNS" "$WIN_W" "$WIN_H"
printf 'Output:     %s\n' "$OUTPUT"
if [ -n "$BASELINE_IDLE" ]; then
    printf 'Quiet gate:  this machine idles at %s%%; a trial starts at %s%% or better\n' \
        "$BASELINE_IDLE" "$QUIET_TARGET"
else
    printf 'Quiet gate:  idle could not be measured; falling back to %s%% absolute\n' "$QUIET_TARGET"
fi
case "$SCROLL_DRIVER_KIND" in
    none) printf 'Scroll driver: none available; the swipe and wheel scenarios are skipped\n' ;;
    *)    printf 'Scroll driver: %s\n' "$SCROLL_DRIVER_KIND" ;;
esac
printf 'Power policy: Postview pinned to -PVPowerState %s\n' "$POWERSTATE"
if [ "$POWERSTATE" != "battery" ]; then
    printf '  NOTE: this is NOT the battery case. Postview renders sharp pages during\n'
    printf '        slow scrolling and prefetches deeper on mains power, so these numbers\n'
    printf '        are not comparable with runs recorded at the default.\n'
fi
printf 'Energy Impact reported by this machine: %s\n' "$ENERGY_OK"
printf 'Idle wakeups reported by this machine:  %s\n\n' "$WAKEUPS_OK"
if [ "$WAKEUPS_OK" != "yes" ]; then
    printf 'NOTE: idle wakeups are unavailable here, so the battery verdict will\n'
    printf '      rest on CPU seconds alone. That is still the dominant term.\n\n'
fi
printf 'Do not touch the Mac while this runs. Roughly %s minutes.\n\n' \
    "$(/usr/bin/awk -v r="$RUNS" -v s="$(printf '%s' "$SCENARIOS" | /usr/bin/wc -w)" 'BEGIN { printf "%.0f", r*s*1.1 }')"

iter=1
while [ "$iter" -le "$RUNS" ]; do
    printf 'Run %s of %s\n' "$iter" "$RUNS"
    for scen in $SCENARIOS; do
        # Alternate which app goes first, so a session-long thermal or
        # background trend is not handed to one side every time.
        if [ $((iter % 2)) -eq 1 ]; then
            run_trial Preview  Preview  Preview          "$scen" "$iter"
            run_trial Postview "$POSTVIEW_PROCESS" "$POSTVIEW_APP" "$scen" "$iter"
        else
            run_trial Postview "$POSTVIEW_PROCESS" "$POSTVIEW_APP" "$scen" "$iter"
            run_trial Preview  Preview  Preview          "$scen" "$iter"
        fi
    done
    iter=$((iter+1))
done

printf '\nAll trials finished.'
if [ "$CONTAMINATED" -gt 0 ]; then
    # Said here as well as in the analysis, because by the time the verdict
    # prints the operator has been away for half an hour and the per-trial
    # warnings have scrolled off. The analysis reaches the same conclusion from
    # the TSV independently -- this line is the one that is seen.
    printf ' %s trial(s) did not start on page 1.\n' "$CONTAMINATED"
    printf 'That is a staging failure, not noise: the two apps read different\n'
    printf 'parts of the document, so no verdict can be drawn from this run.\n\n'
else
    printf ' Every trial started on page 1. Writing verdict.\n\n'
fi

VERDICT_WINDOW="${WIN_W}x${WIN_H}"
VERDICT_HOST="$(/usr/bin/uname -s) $(/usr/bin/uname -r) $(/usr/bin/uname -m)"
VERDICT_WHEN="$(/bin/date '+%Y-%m-%d %H:%M:%S %Z')"
export VERDICT_WINDOW VERDICT_HOST VERDICT_WHEN
# Not `render_verdict ... | tee`. A pipeline exits with the status of its LAST
# command, so `tee` succeeding hid a verdict generator that had failed -- and
# what it printed in that case was a truncated verdict, or none, under a run
# that reported success. The same mistake `verify-all` made with its gates.
render_verdict "$OUTPUT" "$TIE_BAND" "$RUNS" > "$VERDICT" ||
    die "verdict generation failed"
/bin/cat "$VERDICT" || die "cannot read $VERDICT"

printf '\nRaw data: %s\nVerdict:  %s\n' "$OUTPUT" "$VERDICT"
