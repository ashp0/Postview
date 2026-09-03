#!/bin/bash
# Repeatable Preview vs Postview benchmark for OS X 10.9 Mavericks.
#
# Run from Terminal:
#   ./Postview-Benchmark.command /path/to/document.pdf
#
# Optional: RUNS=7 PAGEDOWNS=80 POSTVIEW_APP=/Applications/Postview.app
#           MIN_IDLE=85 WARMUP=1 WIN_W=1200 WIN_H=800
#
# The benchmark requires both apps to be closed first and quits only the test
# instances it creates. It measures launch-to-document-window time and the CPU
# and memory cost of the same Page Down workload in both apps. It needs Terminal
# enabled in System Preferences > Security & Privacy > Privacy > Accessibility.
#
# ---------------------------------------------------------------------------
# What this controls for, and why
#
# An earlier version of this script produced a different winner on CPU
# depending on which session you looked at: five sessions of the same workload,
# minutes apart on one machine, put Postview's mean CPU anywhere between 39%
# and 106% and Preview's between 37% and 112%. The app-to-app difference was
# smaller than the session-to-session noise, so the median of five runs looked
# authoritative and meant nothing. Three causes, all fixed here.
#
# 1. Every run started somewhere different. Both apps remember the page you
#    were last on, keyed by file path, so run 2 resumed where run 1 stopped and
#    paged through a later part of the document -- different pages, different
#    content, different cost. Once a run resumed at the end of the document the
#    Page Downs moved nothing at all and the app was measured doing nothing.
#    Each trial now opens its own COPY of the PDF at a path neither app has
#    seen, so every run starts at page 1 in the default view, and the page each
#    app actually opened on is read back and checked. A hard link is not enough:
#    it is the same inode, so Preview -- which keys on document identity rather
#    than path -- restores the position it saved last time. Nothing in the
#    user's preferences is read or written to achieve any of this.
#
# 2. Nothing checked whether the machine was busy. The noisiest session had
#    BOTH apps pinned near 105% because something else on the system was
#    running. Each trial now waits for the machine to go quiet and records the
#    idle figure it started with, so a contaminated trial is visible in the TSV
#    rather than silently folded into a median.
#
# 3. Sampled `ps %cpu` was the only CPU number reported. It is a decaying
#    estimate that takes a second or two to catch up, over a window that starts
#    at a different point in each app's startup. The primary CPU metric is now
#    the exact CPU time the process accumulated across the window, read from
#    the kernel's own counter. The sampled mean and peak are still reported,
#    because burstiness is worth seeing, but they no longer decide anything.
#
# 4. The two apps were not rasterising the same number of pixels. Nothing set
#    the window size and nothing set the zoom, so each app opened at its own
#    default -- Postview at fit-WIDTH, Preview at fit-PAGE. For a 432x648 page
#    that is roughly 2.4 screenfuls against one, so a single Page Down moved
#    Preview a whole page and Postview about four tenths of one: 80 keystrokes
#    travelled 80 pages against 27. The keystroke counts matched and the
#    workloads did not, and because a page costs up to 59x another at identical
#    pixel counts, every CPU figure produced that way compared two different
#    jobs. Both windows are now pinned to the same frame and both apps to
#    fit-page -- the only zoom mode both have a command for, since Preview has
#    no fit-width. Key codes rather than characters, so the keyboard layout
#    cannot reinterpret them: 19 = "2" (Postview), 25 = "9" (Preview).
#
#    Setting it is not achieving it, so it is not trusted. Each trial reads the
#    page number out of the app's own window title before and after the
#    workload and records how far it ACTUALLY travelled. At equal zoom one Page
#    Down advances exactly one page, so `pages_travelled` must equal PAGEDOWNS
#    in both apps; the summary refuses a verdict when it does not, rather than
#    averaging two different workloads into a median. This is the fairness
#    property the whole section exists for, and it is invisible in the CPU
#    numbers themselves -- which is exactly how it survived four revisions.
#
# What it still does not control for: display brightness, and everything else
# outside the two processes. That is why the reported metric is the kernel's
# per-process CPU counter and not wall-clock energy. Tools/showdown.sh measures
# the battery directly and is the instrument for a power claim.
# ---------------------------------------------------------------------------

set -u
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RUNS=${RUNS:-7}
PAGEDOWNS=${PAGEDOWNS:-80}
MIN_IDLE=${MIN_IDLE:-85}
WARMUP=${WARMUP:-1}
# The frame both windows are pinned to. Equal pixel counts are a precondition
# for comparing render cost at all; see the equalisation note in the header.
WIN_W=${WIN_W:-1200}
WIN_H=${WIN_H:-800}
CURRENT_APP=""
CURRENT_PROCESS=""
TIMEOUT_TICKS=300
WORKDIR=""

usage() {
    printf '%s\n' \
      'Usage: Postview-Benchmark.command /path/to/document.pdf' \
      '' \
      'Close Preview and Postview first. Do not use the Mac while it runs.' \
      'Enable Terminal in Security & Privacy > Privacy > Accessibility.' \
      '' \
      'Optional: RUNS=7 PAGEDOWNS=80 POSTVIEW_APP=/Applications/Postview.app' \
      '          MIN_IDLE=85 WARMUP=1 WIN_W=1200 WIN_H=800'
}

die() {
    printf 'Benchmark stopped: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [ -n "$CURRENT_APP" ]; then
        /usr/bin/osascript - "$CURRENT_APP" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
    try
        tell application (item 1 of argv) to quit
    end try
end run
APPLESCRIPT
    fi
    # Only ever the hardlinks this script made, and only inside its own
    # directory. Removing a hardlink cannot affect the user's PDF: the original
    # path still names the same inode.
    [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] && /bin/rm -rf -- "$WORKDIR"
    return 0
}
trap cleanup EXIT HUP INT TERM

if [ "$#" -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
    usage
    exit 0
fi
[ "$#" -eq 1 ] || { usage >&2; exit 2; }
PDF=$1
[ -f "$PDF" ] || die "not a readable file: $PDF"

case "$RUNS" in ''|*[!0-9]*) die "RUNS must be a positive integer" ;; esac
case "$PAGEDOWNS" in ''|*[!0-9]*) die "PAGEDOWNS must be a positive integer" ;; esac
case "$MIN_IDLE" in ''|*[!0-9]*) die "MIN_IDLE must be an integer percentage" ;; esac
case "$WARMUP" in ''|*[!0-9]*) die "WARMUP must be 0 or a positive integer" ;; esac
case "$WIN_W" in ''|*[!0-9]*) die "WIN_W must be a positive integer" ;; esac
case "$WIN_H" in ''|*[!0-9]*) die "WIN_H must be a positive integer" ;; esac
[ "$RUNS" -gt 0 ] || die "RUNS must be greater than zero"
[ "$PAGEDOWNS" -gt 0 ] || die "PAGEDOWNS must be greater than zero"
# A window smaller than this is not a reading window, and both apps clamp their
# own minimum size -- which would silently leave the two frames unequal, which
# is the one thing this script must not let happen quietly.
[ "$WIN_W" -ge 480 ] || die "WIN_W must be at least 480"
[ "$WIN_H" -ge 360 ] || die "WIN_H must be at least 360"

POSTVIEW_APP=${POSTVIEW_APP:-}
if [ -z "$POSTVIEW_APP" ]; then
    if [ -d "$SCRIPT_DIR/Postview.app" ]; then
        POSTVIEW_APP="$SCRIPT_DIR/Postview.app"
    elif [ -d "$SCRIPT_DIR/../Postview.app" ]; then
        POSTVIEW_APP="$SCRIPT_DIR/../Postview.app"
    fi
fi
[ -d "$POSTVIEW_APP" ] || die "Postview.app was not found (set POSTVIEW_APP to override)"
[ -d /Applications/Preview.app ] || die "Preview.app was not found in /Applications"

for tool in /usr/bin/osascript /usr/bin/open /bin/ps /usr/bin/pgrep /usr/bin/perl \
            /usr/bin/awk /usr/bin/sort /usr/bin/top /usr/bin/tr /bin/ln /bin/cp; do
    [ -x "$tool" ] || die "missing Mavericks tool: $tool"
done

POSTVIEW_PROCESS=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
    "$POSTVIEW_APP/Contents/Info.plist" 2>/dev/null) || die "could not read Postview's executable name"
[ -n "$POSTVIEW_PROCESS" ] || die "Postview's executable name is empty"

accessibility=$(/usr/bin/osascript -e 'tell application "System Events" to return UI elements enabled' 2>/dev/null || true)
[ "$accessibility" = "true" ] || die \
    "enable Terminal in Security & Privacy > Privacy > Accessibility, then retry"

running() { /usr/bin/pgrep -x "$1" >/dev/null 2>&1; }
if running Preview || running "$POSTVIEW_PROCESS"; then
    die "quit all Preview and Postview windows first; existing sessions are never touched"
fi

# One directory of hardlinks to the PDF, one per trial. A path neither app has
# opened before is a path neither app has saved a page position, zoom, sidebar
# state or window frame for, so every trial starts from the same place without
# this script touching either app's preferences.
WORKDIR=$(/usr/bin/mktemp -d /tmp/postview-bench.XXXXXX) || die "could not create a working directory"
PDF_BASE=$(basename "$PDF")
PDF_STEM=${PDF_BASE%.*}

# A document neither app has seen before, so every trial starts at page 1 in
# the default view.
#
# This used to be a hard link, and a hard link does not do that. It is the same
# inode: one file with a second name. Postview keys its saved reading position
# on the path, so a new name did fool Postview -- which is exactly what let the
# bug survive, because the app being developed visibly started at page 1.
# Preview does not key on the path. It keys on the document's identity, and a
# hard link has the identity it is a link to, so Preview restored the position
# it had saved the last time anyone opened that PDF.
#
# The recorded evidence is in Postview-Profile-20260828-215944.tsv, whose
# `launch` row -- a scenario that sends no input at all -- has Preview sitting
# on "page 1,174 of 1,263" of a freshly staged path while Postview is on page 1.
# The two apps were rasterising different parts of a 1,263-page book, and a page
# costs up to 59x another at identical pixel counts. Every CPU figure produced
# that way compares two different workloads.
#
# A copy has its own inode and its own document identity, which is the property
# actually wanted. -X drops extended attributes and any resource fork, so
# quarantine flags and Finder metadata do not travel either. It costs one file
# copy per trial; correctness of the measurement is worth more than the seconds.
#
# Verified, not assumed: assert_fresh_start below reads the page out of the
# app's own window title, and a trial that did not start on page 1 is
# disqualified rather than averaged in.
fresh_document() {
    # $1: a label unique to this trial. Echoes a path to an unseen copy.
    # Spaces and slashes are squeezed out of the label so the staged name stays
    # one word; the document's own name may still contain them and is quoted
    # throughout.
    label=$(printf '%s' "$1" | /usr/bin/tr ' /' '--')
    path="$WORKDIR/$PDF_STEM-$label.pdf"
    /bin/rm -f "$path" 2>/dev/null
    /bin/cp -X "$PDF" "$path" 2>/dev/null ||
        /bin/cp "$PDF" "$path" 2>/dev/null ||
        return 1
    /usr/bin/xattr -c "$path" 2>/dev/null || true
    printf '%s\n' "$path"
}

# The page an app is showing, read from its own window title.
#
# Both apps put it there in the same shape -- "... (page 6 of 1263)" -- and
# Preview writes the thousands separator its locale asks for, so the digits are
# taken and the separators dropped. Empty when the title says nothing about a
# page, which is not an error: it means this instrument cannot see the position
# for this app, and that is treated differently from seeing the wrong page.
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
# returns non-zero when the app resumed a saved position instead.
#
# A trial that began on a different page than its opposite number is not a
# slightly noisy trial, it is a measurement of a different document, so it is
# not something a median over runs can absorb. It is refused outright.
assert_fresh_start() {
    START_PAGE=$(page_from_title "$(window_title "$1")")
    # No page in the title means this instrument cannot see the position for
    # this app, not that the position is wrong.
    [ -n "$START_PAGE" ] || { START_PAGE="-"; return 0; }
    [ "$START_PAGE" = "1" ] && return 0
    printf '  !! %s opened a freshly copied file on page %s, not page 1.\n' \
        "$2" "$START_PAGE" >&2
    printf '     It restored a saved reading position, so this trial is not\n' >&2
    printf '     comparable with its opposite number.\n' >&2
    return 1
}

# --- Equalising the render load -------------------------------------------
#
# Two knobs decide how many pixels a Page Down costs, and both belong to the
# app rather than to this script: the window's size, and the zoom mode inside
# it. Left alone they differ, and the CPU comparison then measures two
# different jobs. Both are set here, and both are read back.

# Pin the window to WIN_W x WIN_H at a fixed origin. Echoes the size the window
# actually ended up at -- which is not always the one asked for, because an app
# may clamp to its own minimum or to the screen -- so an unequal frame shows up
# in the TSV instead of being assumed away.
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

# Put both apps in fit-page.
#
# Fit-page is the common ground because it is the only mode both apps have a
# command for: Preview has no fit-width, and Postview's own default IS
# fit-width, so leaving this alone is what produced the 80-pages-against-27
# mismatch described in the header. Key codes, not characters, so a non-US
# layout cannot turn Command-2 into something else.
#   19 = "2"  Postview  (View > Fit Page)
#   25 = "9"  Preview   (View > Zoom to Fit)
# Echoes the mode this trial is claiming, for the TSV. It is a claim and not a
# measurement; pages_travelled below is the measurement that checks it.
#
# $1 is the app, which chooses the key; $2 is the process, which is what System
# Events addresses. They are two different names: POSTVIEW_APP is overridable
# and the process name comes out of whatever bundle it points at, so a build
# whose executable is not called "Postview" would otherwise have its keystroke
# sent to a process that does not exist -- silently, since a failed `tell` here
# would leave the app at its own default zoom and the TSV still saying
# "fit-page". The travel check would catch it; not having to is better.
set_fit_page() {
    case "$1" in
        Postview) fit_key=19 ;;
        Preview)  fit_key=25 ;;
        *)        printf '%s\n' "unset"; return 0 ;;
    esac
    /usr/bin/osascript - "$2" "$fit_key" <<'AS' >/dev/null 2>&1
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
    if [ "$?" -eq 0 ]; then
        /bin/sleep 0.8
        printf '%s\n' "fit-page"
    else
        printf '%s\n' "unset"
    fi
}

# How far the document actually moved, in pages. "-" when either end of the
# window could not be read out of the title, which is a statement about this
# instrument and not about the app, and is kept distinct from a wrong number.
pages_travelled() {
    case "$1" in ''|*[!0-9]*) printf '%s\n' "-"; return 0 ;; esac
    case "$2" in ''|*[!0-9]*) printf '%s\n' "-"; return 0 ;; esac
    /usr/bin/awk -v a="$1" -v b="$2" 'BEGIN { d = b - a; if (d < 0) d = -d; printf "%d", d }'
}

now() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f\n", time'; }
elapsed() { /usr/bin/awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", b - a }'; }
pid_for() { /usr/bin/pgrep -x "$1" 2>/dev/null | /usr/bin/head -n 1; }

# System-wide idle percentage. The trial does not begin until the machine is
# actually quiet, because a busy machine inflates both apps' numbers and
# destroys the comparison rather than biasing it in a knowable direction.
system_idle() {
    /usr/bin/top -l 1 -n 0 2>/dev/null | /usr/bin/awk '
        /^CPU usage/ { for (i = 1; i <= NF; i++) if ($i == "idle") { gsub(/%/, "", $(i-1)); print $(i-1); exit } }'
}

wait_for_quiet_machine() {
    attempt=0
    while [ "$attempt" -lt 20 ]; do
        idle=$(system_idle)
        case "$idle" in ''|*[!0-9.]*) idle=0 ;; esac
        quiet=$(/usr/bin/awk -v i="$idle" -v m="$MIN_IDLE" 'BEGIN { print (i >= m) ? 1 : 0 }')
        [ "$quiet" = "1" ] && { printf '%s\n' "$idle"; return 0; }
        /bin/sleep 1
        attempt=$((attempt + 1))
    done
    printf '%s\n' "$idle"
    return 1
}

document_window_ready() {
    /usr/bin/osascript - "$1" "$2" <<'APPLESCRIPT'
on run argv
    set appName to item 1 of argv
    set documentName to item 2 of argv
    tell application "System Events"
        if not (exists process appName) then return "0"
        tell process appName
            repeat with aWindow in windows
                try
                    if ((name of aWindow) as text) contains documentName then return "1"
                end try
            end repeat
        end tell
    end tell
    return "0"
end run
APPLESCRIPT
}

wait_for_document_window() {
    ticks=0
    while [ "$ticks" -lt "$TIMEOUT_TICKS" ]; do
        ready=$(document_window_ready "$1" "$2" 2>/dev/null) || return 2
        [ "$ready" = "1" ] && return 0
        /bin/sleep 0.1
        ticks=$((ticks + 1))
    done
    return 1
}

page_down_workload() {
    /usr/bin/osascript - "$1" "$PAGEDOWNS" <<'APPLESCRIPT'
on run argv
    set appName to item 1 of argv
    set presses to (item 2 of argv) as integer
    tell application "System Events"
        tell process appName
            set frontmost to true
            delay 0.25
            repeat with n from 1 to presses
                key code 121 -- Page Down on the Mavericks virtual-key map
                delay 0.05
            end repeat
        end tell
    end tell
end run
APPLESCRIPT
}

quit_test_app() {
    /usr/bin/osascript - "$1" <<'APPLESCRIPT' >/dev/null 2>&1 || return 1
on run argv
    try
        tell application (item 1 of argv) to quit
    end try
end run
APPLESCRIPT
    ticks=0
    while running "$2"; do
        [ "$ticks" -lt 100 ] || return 1
        /bin/sleep 0.1
        ticks=$((ticks + 1))
    done
}

# Exact CPU seconds this process has consumed since it started, from the
# kernel's own counter. Differencing two of these across the workload window
# gives the CPU cost of the workload with no sampling error and no dependence
# on where in the process's life the window happens to fall -- which is what
# sampled %cpu could not offer. `ps -o time` prints [[HH:]MM:]SS.ss.
cpu_seconds_for() {
    /bin/ps -o time= -p "$1" 2>/dev/null | /usr/bin/awk '
        NR == 1 {
            gsub(/^[ \t]+/, "", $0)
            n = split($1, f, ":")
            s = 0
            for (i = 1; i <= n; i++) s = s * 60 + f[i]
            printf "%.2f", s
        }'
}

reset_samples() { samples=0; cpu_sum=0; cpu_peak=0; rss_peak=0; }
sample_process() {
    line=$(/bin/ps -o %cpu= -o rss= -p "$1" 2>/dev/null | /usr/bin/awk 'NR == 1 { print $1, $2 }')
    set -- $line
    [ "$#" -eq 2 ] || return 0
    cpu=$1
    rss=$2
    case "$cpu" in ''|*[!0-9.-]*) return 0 ;; esac
    case "$rss" in ''|*[!0-9]*) return 0 ;; esac
    cpu_sum=$(/usr/bin/awk -v a="$cpu_sum" -v b="$cpu" 'BEGIN { printf "%.4f", a + b }')
    cpu_peak=$(/usr/bin/awk -v a="$cpu_peak" -v b="$cpu" \
        'BEGIN { if (b > a) printf "%.1f", b; else printf "%.1f", a }')
    [ "$rss" -le "$rss_peak" ] || rss_peak=$rss
    samples=$((samples + 1))
}
cpu_average() {
    /usr/bin/awk -v total="$cpu_sum" -v count="$samples" \
        'BEGIN { printf "%.1f", count ? total / count : 0 }'
}

OUTPUT="$PWD/Postview-vs-Preview-$(/bin/date +%Y%m%d-%H%M%S).tsv"
# Columns 1-10 are the measurement; 11-15 are the evidence that the two apps
# were given the same job to do. verdict() addresses columns positionally, so
# the equalisation columns are appended rather than inserted.
printf 'app\trun\tlaunch_seconds\tpage_down_input_seconds\tcpu_seconds\tmean_cpu_percent\tpeak_cpu_percent\tpeak_rss_kb\tstart_idle_percent\tsamples\twindow_size\tzoom_mode\tstart_page\tend_page\tpages_travelled\n' > "$OUTPUT"

# $1 bundle  $2 app name  $3 process name  $4 run label  $5 record? (1/0)
run_trial() {
    bundle=$1
    app=$2
    process=$3
    iteration=$4
    record=$5
    CURRENT_APP=$app
    CURRENT_PROCESS=$process

    start_idle=$(wait_for_quiet_machine) || \
        printf '  (machine did not settle above %s%% idle; recording %s%% and continuing)\n' \
            "$MIN_IDLE" "$start_idle"

    trial_pdf=$(fresh_document "$app-$iteration") || die "could not stage a copy of the PDF"
    # Match the window title on the stem, not the full filename: whether a
    # title carries the .pdf extension depends on the Finder's "show all
    # filename extensions" setting, and a title match that silently never
    # succeeds would fail the run as a 30-second launch timeout.
    trial_name=$(basename "$trial_pdf" .pdf)

    started=$(now)
    /usr/bin/open -n -a "$bundle" "$trial_pdf" || die "could not launch $app"
    wait_for_document_window "$process" "$trial_name" || die "$app did not show the PDF window within 30 seconds"
    opened=$(now)
    launch=$(elapsed "$started" "$opened")
    pid=$(pid_for "$process")
    [ -n "$pid" ] || die "$app showed a window but could not be sampled"

    # Same pixels, then the same pages per keystroke. Both before the clock
    # starts, and the zoom AFTER the frame, because fit-page is defined against
    # the window it is fitting into and resizing afterwards would move it.
    win_size=$(set_window_size "$process")
    [ -n "$win_size" ] || win_size="unknown"
    zoom_mode=$(set_fit_page "$app" "$process")
    [ -n "$zoom_mode" ] || zoom_mode="unset"

    # Checked before the clock starts, so a contaminated trial is refused rather
    # than measured and then folded into a median that hides it. Read after the
    # zoom change, since that is what the workload will actually run against.
    assert_fresh_start "$process" "$app" ||
        die "$app did not start on page 1; the comparison would be between two different workloads"

    /bin/sleep 1
    reset_samples
    cpu_before=$(cpu_seconds_for "$pid")
    workload_started=$(now)
    page_down_workload "$process" >/dev/null 2>&1 &
    driver=$!
    while kill -0 "$driver" 2>/dev/null; do
        sample_process "$pid"
        /bin/sleep 0.1
    done
    wait "$driver" || die "$app stopped accepting the Page Down workload"
    workload_finished=$(now)
    sample_process "$pid"

    # Capture rendering that follows the final input event, not just the
    # AppleScript event sender's activity.
    tick=0
    while [ "$tick" -lt 20 ]; do
        running "$process" || die "$app terminated during its workload"
        sample_process "$pid"
        /bin/sleep 0.1
        tick=$((tick + 1))
    done
    cpu_after=$(cpu_seconds_for "$pid")
    cpu_used=$(/usr/bin/awk -v a="$cpu_before" -v b="$cpu_after" 'BEGIN { printf "%.2f", b - a }')

    # Read after the settle loop, so the title reflects where the document
    # finally came to rest rather than where it was mid-scroll. This is the one
    # number that says whether the two apps did the same amount of work: the
    # keystroke count is equal by construction, the distance travelled is not.
    end_page=$(page_from_title "$(window_title "$process")")
    [ -n "$end_page" ] || end_page="-"
    travelled=$(pages_travelled "$START_PAGE" "$end_page")

    input_seconds=$(elapsed "$workload_started" "$workload_finished")
    mean_cpu=$(cpu_average)
    if [ "$record" = "1" ]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$app" "$iteration" "$launch" "$input_seconds" "$cpu_used" "$mean_cpu" \
            "$cpu_peak" "$rss_peak" "$start_idle" "$samples" \
            "$win_size" "$zoom_mode" "$START_PAGE" "$end_page" "$travelled" >> "$OUTPUT"
        printf '  %-9s run %-7s: window %6.3f s, CPU %6.2f s (avg/peak %5.1f/%5.1f %%), RSS peak %s MB, idle %s%%, %s px %s, moved %s pages\n' \
            "$app" "$iteration" "$launch" "$cpu_used" "$mean_cpu" "$cpu_peak" \
            "$(/usr/bin/awk -v rss="$rss_peak" 'BEGIN { printf "%.1f", rss / 1024.0 }')" \
            "$start_idle" "$win_size" "$zoom_mode" "$travelled"
    else
        printf '  %-9s %-11s: window %6.3f s, CPU %6.2f s, %s px %s, moved %s pages  (discarded)\n' \
            "$app" "$iteration" "$launch" "$cpu_used" "$win_size" "$zoom_mode" "$travelled"
    fi

    quit_test_app "$app" "$process" || die "$app did not quit cleanly after its test"
    CURRENT_APP=""
    CURRENT_PROCESS=""
    /bin/sleep 0.5
}

stat_for() {
    # $1 app, $2 column, $3 one of min|median|max
    /usr/bin/awk -F '\t' -v app="$1" -v column="$2" \
        'NR > 1 && $1 == app { print $column }' "$OUTPUT" | /usr/bin/sort -n | \
        /usr/bin/awk -v want="$3" '{ v[NR] = $1 } END {
            if (NR == 0) { printf "0"; exit }
            if (want == "min") printf "%.3f", v[1]
            else if (want == "max") printf "%.3f", v[NR]
            else if (NR % 2) printf "%.3f", v[(NR + 1) / 2]
            else printf "%.3f", (v[NR / 2] + v[NR / 2 + 1]) / 2
        }'
}

# A metric is only called when the two apps' observed ranges do not overlap.
# With this much run-to-run movement, a median that differs by less than the
# spread is not a result, and saying so is the whole point of measuring.
verdict() {
    label=$1; column=$2; unit=$3; scale=$4
    p_min=$(stat_for Preview  "$column" min);  p_med=$(stat_for Preview  "$column" median);  p_max=$(stat_for Preview  "$column" max)
    o_min=$(stat_for Postview "$column" min);  o_med=$(stat_for Postview "$column" median);  o_max=$(stat_for Postview "$column" max)
    /usr/bin/awk -v label="$label" -v unit="$unit" -v s="$scale" \
        -v pmin="$p_min" -v pmed="$p_med" -v pmax="$p_max" \
        -v omin="$o_min" -v omed="$o_med" -v omax="$o_max" 'BEGIN {
        pmin /= s; pmed /= s; pmax /= s; omin /= s; omed /= s; omax /= s
        printf "  %-22s Preview  %8.2f %s  (%.2f - %.2f)\n", label, pmed, unit, pmin, pmax
        printf "  %-22s Postview %8.2f %s  (%.2f - %.2f)\n", "", omed, unit, omin, omax
        if (omax < pmin)      printf "  %-22s -> Postview lower, ranges do not overlap (%.2fx)\n\n", "", pmed / (omed ? omed : 1)
        else if (pmax < omin) printf "  %-22s -> Preview lower, ranges do not overlap (%.2fx)\n\n", "", omed / (pmed ? pmed : 1)
        else                  printf "  %-22s -> not separated: the run-to-run spread covers the difference\n\n", ""
    }'
}

printf 'Postview vs Preview: %s alternating runs, %s Page Down events each\n' "$RUNS" "$PAGEDOWNS"
printf 'PDF: %s\n' "$PDF"
printf 'Each trial opens a fresh path, so both apps start at page 1.\n'
printf 'Both windows are set to %sx%s and both apps to fit-page, and how far the\n' "$WIN_W" "$WIN_H"
printf 'document actually moved is checked afterwards rather than assumed.\n'
printf 'Waiting for >= %s%% system idle before each trial. Do not interact with the Mac.\n\n' "$MIN_IDLE"

warm=1
while [ "$warm" -le "$WARMUP" ]; do
    run_trial /Applications/Preview.app Preview Preview "warmup $warm" 0
    run_trial "$POSTVIEW_APP" Postview "$POSTVIEW_PROCESS" "warmup $warm" 0
    warm=$((warm + 1))
done
[ "$WARMUP" -gt 0 ] && printf '\n'

run=1
while [ "$run" -le "$RUNS" ]; do
    run_trial /Applications/Preview.app Preview Preview "$run" 1
    run_trial "$POSTVIEW_APP" Postview "$POSTVIEW_PROCESS" "$run" 1
    run=$((run + 1))
done

# Did the two apps actually get the same job?
#
# Equal window and equal zoom mean one Page Down advances exactly one page, so
# PAGEDOWNS keystrokes must move the document PAGEDOWNS pages in both apps.
# That single number covers both knobs at once and is measured rather than
# asserted: it is what the title bar says happened, not what this script asked
# for. Reported before the verdicts because if it fails, the verdicts below are
# a comparison of two different workloads and mean nothing -- which is the exact
# failure that made four earlier revisions of this benchmark disagree.
fairness_gate() {
    /usr/bin/awk -F '\t' -v want="$PAGEDOWNS" '
    NR == 1 { next }
    {
        app = $1
        n[app]++
        if (!(app in wsz)) wsz[app] = $11; else if (wsz[app] != $11) wsz[app] = "MIXED"
        if (!(app in zsz)) zsz[app] = $12; else if (zsz[app] != $12) zsz[app] = "MIXED"
        if ($15 == "-") { blind[app]++; next }
        seen[app]++
        t = $15 + 0
        if (!(app in lo) || t < lo[app]) lo[app] = t
        if (!(app in hi) || t > hi[app]) hi[app] = t
        if (t != want + 0) wrong[app]++
    }
    END {
        # Two different failures, kept apart on purpose. "Unequal" is a fact
        # about the apps and disqualifies the comparison. "Unverified" is a
        # limit of this instrument -- the title did not carry a page number --
        # and disqualifies only the CLAIM of fairness, not the run. Collapsing
        # them would report a missing measurement as a measured mismatch.
        split("Preview Postview", apps, " ")
        unequal = 0; unverified = 0
        printf "Equalisation check -- were both apps given the same work?\n\n"
        for (k = 1; k <= 2; k++) {
            a = apps[k]
            if (!(a in n)) { printf "  %-9s no trials recorded\n", a; unequal = 1; continue }
            printf "  %-9s window %-11s zoom %-9s ", a, wsz[a], zsz[a]
            if (wsz[a] == "MIXED" || zsz[a] == "MIXED") unequal = 1
            if (zsz[a] == "unset") unverified = 1
            if (seen[a] == 0) {
                printf "pages moved: no page number in this window title\n"
                unverified = 1
                continue
            }
            if (lo[a] == hi[a]) printf "moved %d of %d pages", lo[a], want
            else                printf "moved %d-%d of %d pages", lo[a], hi[a], want
            if (wrong[a] > 0) { printf "   <-- %d of %d trials off\n", wrong[a], n[a]; unequal = 1 }
            else              { printf "   ok\n" }
        }
        if (("Preview" in n) && ("Postview" in n) && wsz["Preview"] != wsz["Postview"]) {
            printf "\n  The two windows did not end up the same size (%s vs %s).\n",
                   wsz["Preview"], wsz["Postview"]
            unequal = 1
        }
        if (unequal)
            printf "\n  NOT COMPARABLE. The two apps rasterised different amounts, so the\n  figures below describe two different workloads and name no winner.\n\n"
        else if (unverified)
            printf "\n  NOT VERIFIED. The window and zoom were set for both apps, but this\n  script could not read back how far the document moved, so equal render\n  load is an assumption here rather than a measurement.\n\n"
        else
            printf "\n  Same window, same zoom, one page per keystroke in both. Comparable.\n\n"
        exit (unequal || unverified) ? 0 + unequal + 2 * unverified : 0
    }' "$OUTPUT"
}

printf '\n'
fairness_gate
case "$?" in
    0) FAIR=ok ;;
    2) FAIR=unverified ;;
    *) FAIR=unequal ;;
esac

printf 'Median and observed range over %s runs (lower is better for every metric):\n\n' "$RUNS"
verdict "launch to window"   3 "s"  1
verdict "CPU during workload" 5 "s"  1
verdict "peak memory"        8 "MB" 1024

case "$FAIR" in
    unequal)
        printf 'The equalisation check above FAILED, so no line in this table is a\n'
        printf 'like-for-like comparison. Fix the equalisation and re-run rather than\n'
        printf 'reading a winner out of it.\n\n' ;;
    unverified)
        printf 'The equalisation was applied but could not be verified, so treat any\n'
        printf 'winner above as provisional: the check that would have caught an\n'
        printf 'unequal render load did not run.\n\n' ;;
esac

printf 'Raw TSV: %s\n\n' "$OUTPUT"
printf 'Scope: a launch and resource comparison on one PDF, both apps in the same\n'
printf 'window at the same zoom, verified by how far the document actually moved.\n'
printf 'It says nothing about visual quality, and it measures CPU rather than the\n'
printf 'battery -- Tools/showdown.sh is the instrument for a power claim. Run it\n'
printf 'with the PDFs you actually read.\n'

trap - EXIT HUP INT TERM
cleanup
