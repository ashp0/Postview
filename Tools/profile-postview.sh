#!/bin/bash
# Postview-Profile.command — where the battery actually goes.
#
#   ./Postview-Profile.command /path/to/document.pdf
#
# Optional: RUNS=3 SCENARIOS="idle read page scroll launch"
#           POSTVIEW_APP=/Applications/Postview.app MIN_IDLE=85
#           WIN_W=1200 WIN_H=800 EQUALISE=1
#
# ---------------------------------------------------------------------------
# Why this exists alongside Postview-Benchmark.command
#
# The benchmark answers "is Postview better than Preview" with one workload.
# This answers "what is Postview spending energy on", which needs several
# workloads and needs to see inside the process. Four things it does that the
# benchmark does not:
#
# 1. FIVE SCENARIOS, NOT ONE. 80 Page Downs in four seconds is ~17 pages a
#    second, which is not reading, it is flicking. Battery life on a PDF viewer
#    is dominated by the opposite case -- a document sitting open while someone
#    reads a page for half a minute -- and that case was never measured at all.
#    `idle` is the most important number in this file: a viewer with a document
#    open and nobody touching it should cost approximately nothing, and if it
#    does not, that is worth more than any amount of scrolling optimisation.
#
# 2. CPU SECONDS, NOT PERCENT. Percent is a rate; energy is an integral.
#    Postview deliberately renders at background QoS, which is slower in wall
#    time and cheaper in joules, so a *higher* momentary percentage over a
#    shorter burst can be less total work. Reporting percent alone actively
#    penalises the app's main battery optimisation. Every number here is a
#    total: CPU-seconds, megapixels, page count.
#
# 3. EQUAL WINDOWS. Left alone, the two apps open different window sizes and
#    pick their own default zoom, so they rasterise different pixel counts and
#    the comparison silently measures that instead of the renderers. Both
#    windows are set to the same size before any workload runs, and the size
#    each app actually ended up with is recorded so you can see whether it took.
#
# 4. IT ASKS THE APP. With -PVStats YES, Postview reports how many bitmaps it
#    produced, how many megapixels that was, and how many requests the throttle
#    declined. CPU seconds say a scenario cost something; those say whether it
#    went on pages that were looked at, on prefetch nobody reached, or on the
#    same page rendered repeatedly. Preview cannot be asked, so those columns
#    are blank for it -- which is a limit of the method, not a result.
#
# Needs Terminal in System Preferences > Security & Privacy > Privacy >
# Accessibility. Quit both apps first. Do not touch the Mac while it runs.
# ---------------------------------------------------------------------------

set -u
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RUNS=${RUNS:-3}
MIN_IDLE=${MIN_IDLE:-85}
WIN_W=${WIN_W:-1200}
WIN_H=${WIN_H:-800}
EQUALISE=${EQUALISE:-1}
SCENARIOS=${SCENARIOS:-"launch idle read page scroll"}
CURRENT_APP=""
WORKDIR=""
TIMEOUT_TICKS=300

# Scenario shapes: presses and the delay between them. `idle` sends nothing.
IDLE_SECONDS=${IDLE_SECONDS:-30}
READ_PRESSES=${READ_PRESSES:-12};   READ_DELAY=${READ_DELAY:-2.5}
PAGE_PRESSES=${PAGE_PRESSES:-80};   PAGE_DELAY=${PAGE_DELAY:-0.05}
SCROLL_PRESSES=${SCROLL_PRESSES:-200}; SCROLL_DELAY=${SCROLL_DELAY:-0.02}
SETTLE_SECONDS=${SETTLE_SECONDS:-2}

usage() {
    printf '%s\n' \
      'Usage: Postview-Profile.command /path/to/document.pdf' \
      '' \
      'Scenarios: launch  open a document and let it settle' \
      '           idle    document open, no input at all (the battery case)' \
      '           read    one page every 2.5 s (realistic)' \
      '           page    80 Page Downs at 20/s (flicking; the old benchmark)' \
      '           scroll  200 line-scrolls at 50/s (continuous motion)' \
      '' \
      'Close Preview and Postview first. Do not use the Mac while it runs.' \
      'Enable Terminal in Security & Privacy > Privacy > Accessibility.' \
      '' \
      'Optional: RUNS=3 SCENARIOS="idle read" MIN_IDLE=85 EQUALISE=1' \
      '          WIN_W=1200 WIN_H=800 POSTVIEW_APP=/Applications/Postview.app'
}

die() { printf 'Profile stopped: %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [ -n "$CURRENT_APP" ]; then
        /usr/bin/osascript - "$CURRENT_APP" <<'AS' >/dev/null 2>&1 || true
on run argv
    try
        tell application (item 1 of argv) to quit
    end try
end run
AS
    fi
    [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] && /bin/rm -rf -- "$WORKDIR"
    return 0
}
trap cleanup EXIT HUP INT TERM

if [ "$#" -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then usage; exit 0; fi
[ "$#" -eq 1 ] || { usage >&2; exit 2; }
PDF=$1
[ -f "$PDF" ] || die "not a readable file: $PDF"
case "$RUNS" in ''|*[!0-9]*) die "RUNS must be a positive integer" ;; esac
[ "$RUNS" -gt 0 ] || die "RUNS must be greater than zero"

POSTVIEW_APP=${POSTVIEW_APP:-}
if [ -z "$POSTVIEW_APP" ]; then
    if   [ -d "$SCRIPT_DIR/Postview.app" ];    then POSTVIEW_APP="$SCRIPT_DIR/Postview.app"
    elif [ -d "$SCRIPT_DIR/../Postview.app" ]; then POSTVIEW_APP="$SCRIPT_DIR/../Postview.app"
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

acc=$(/usr/bin/osascript -e 'tell application "System Events" to return UI elements enabled' 2>/dev/null || true)
[ "$acc" = "true" ] || die "enable Terminal in Security & Privacy > Privacy > Accessibility, then retry"

running() { /usr/bin/pgrep -x "$1" >/dev/null 2>&1; }
if running Preview || running "$POSTVIEW_PROCESS"; then
    die "quit all Preview and Postview windows first; existing sessions are never touched"
fi

WORKDIR=$(/usr/bin/mktemp -d /tmp/postview-profile.XXXXXX) || die "could not create a working directory"
PDF_BASE=$(basename "$PDF"); PDF_STEM=${PDF_BASE%.*}

# Each trial gets a document neither app has opened before, so neither restores
# a page position, zoom or window frame from a previous trial. Without this,
# every run after the first starts somewhere different and measures different
# pages -- and a run that resumes at the end of the document measures an app
# doing nothing at all.
#
# A copy, not a hard link. A hard link is the same inode and therefore the same
# document: Postview keys its saved position on the path and was fooled, Preview
# keys on the document's identity and was not. This script's own TSV is where
# that was caught -- see the `end_title` column, which has Preview on page 1,174
# of a freshly staged file in the `launch` scenario, before any key is pressed.
# The same fix is in Tools/showdown.sh, with the reasoning in full.
fresh_document() {
    label=$(printf '%s' "$1" | /usr/bin/tr ' /' '--')
    path="$WORKDIR/$PDF_STEM-$label.pdf"
    /bin/rm -f "$path" 2>/dev/null
    /bin/cp -X "$PDF" "$path" 2>/dev/null || /bin/cp "$PDF" "$path" 2>/dev/null || return 1
    /usr/bin/xattr -c "$path" 2>/dev/null || true
    printf '%s\n' "$path"
}

now()     { /usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f\n", time'; }
elapsed() { /usr/bin/awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", b - a }'; }
pid_for() { /usr/bin/pgrep -x "$1" 2>/dev/null | /usr/bin/head -n 1; }

system_idle() {
    /usr/bin/top -l 1 -n 0 2>/dev/null | /usr/bin/awk '
        /^CPU usage/ { for (i=1;i<=NF;i++) if ($i=="idle") { gsub(/%/,"",$(i-1)); print $(i-1); exit } }'
}
wait_for_quiet_machine() {
    a=0
    while [ "$a" -lt 20 ]; do
        idle=$(system_idle); case "$idle" in ''|*[!0-9.]*) idle=0 ;; esac
        q=$(/usr/bin/awk -v i="$idle" -v m="$MIN_IDLE" 'BEGIN { print (i>=m)?1:0 }')
        [ "$q" = "1" ] && { printf '%s\n' "$idle"; return 0; }
        /bin/sleep 1; a=$((a+1))
    done
    printf '%s\n' "$idle"; return 1
}

# Exact CPU seconds from the kernel's own counter; `ps -o time` is [[HH:]MM:]SS.ss.
cpu_seconds_for() {
    /bin/ps -o time= -p "$1" 2>/dev/null | /usr/bin/awk '
        NR==1 { gsub(/^[ \t]+/,"",$0); n=split($1,f,":"); s=0
                for (i=1;i<=n;i++) s=s*60+f[i]; printf "%.2f", s }'
}

document_window_ready() {
    /usr/bin/osascript - "$1" "$2" <<'AS'
on run argv
    tell application "System Events"
        if not (exists process (item 1 of argv)) then return "0"
        tell process (item 1 of argv)
            repeat with w in windows
                try
                    if ((name of w) as text) contains (item 2 of argv) then return "1"
                end try
            end repeat
        end tell
    end tell
    return "0"
end run
AS
}
wait_for_document_window() {
    t=0
    while [ "$t" -lt "$TIMEOUT_TICKS" ]; do
        r=$(document_window_ready "$1" "$2" 2>/dev/null) || return 2
        [ "$r" = "1" ] && return 0
        /bin/sleep 0.1; t=$((t+1))
    done
    return 1
}

# Put both apps' windows at the same size, so neither is measured rasterising a
# different number of pixels than the other. Echoes the size actually achieved,
# which is not always the size asked for -- an app may clamp to its own minimum
# or to the screen -- and reporting what happened rather than what was
# requested is the whole point of measuring it.
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

# Which page the app is showing, read out of the window title. Postview puts
# the page number there; Preview does not, so this is blank for it. It answers
# a question the old benchmark could not: did the workload actually move the
# document, or did it run against a document already at its last page?
current_page_label() {
    /usr/bin/osascript - "$1" <<'AS' 2>/dev/null
on run argv
    tell application "System Events"
        tell process (item 1 of argv)
            try
                return (name of window 1) as text
            on error
                return ""
            end try
        end tell
    end tell
end run
AS
}

send_keys() {
    # $1 app, $2 key code, $3 count, $4 delay
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

quit_app() {
    /usr/bin/osascript - "$1" <<'AS' >/dev/null 2>&1 || return 1
on run argv
    try
        tell application (item 1 of argv) to quit
    end try
end run
AS
    t=0
    while running "$2"; do
        [ "$t" -lt 100 ] || return 1
        /bin/sleep 0.1; t=$((t+1))
    done
}

reset_samples() { samples=0; cpu_sum=0; cpu_peak=0; rss_peak=0; rss_sum=0; }

# One counter out of the app's census, matched exactly on field 2 rather than by
# a regex over the line.
#
# `requests.suppressed` is a prefix of `requests.suppressed.motion` and
# `requests.suppressed.total`, so the older `/requests.suppressed/` pattern
# matched all three and printed three numbers into a single TSV field, newlines
# included -- which does not fail loudly, it corrupts the file. Anchoring on the
# field means a key added later cannot quietly do it again.
pvstat() {
    /usr/bin/awk -v k="$1" '$1 == "PVSTAT" && $2 == k { print $3; exit }' "$2"
}

# Every variable here is prefixed, because a shell function has no locals and
# this one is called from inside the run loop several hundred times a trial.
#
# It used to take its two readings into `c` and `r`. `r` is the run counter of
# the loop at the bottom of this script, so the first sample of the first trial
# overwrote it with a resident-set size in kilobytes. Two consequences, both
# silent: the `run` column recorded an RSS reading instead of a run number --
# visible in every TSV this script has ever written -- and `while [ "$r" -le
# "$RUNS" ]` compared ~150000 against RUNS and ended after a single pass, so
# RUNS was accepted, printed in the header, and then ignored. Every profile ever
# taken with it is one unrepeated trial per scenario with no spread to check it
# against, which is the one thing this project's own methodology says must never
# be allowed to decide anything.
sample_process() {
    _sp_line=$(/bin/ps -o %cpu= -o rss= -p "$1" 2>/dev/null | /usr/bin/awk 'NR==1 { print $1, $2 }')
    set -- $_sp_line
    [ "$#" -eq 2 ] || return 0
    _sp_cpu=$1; _sp_rss=$2
    case "$_sp_cpu" in ''|*[!0-9.-]*) return 0 ;; esac
    case "$_sp_rss" in ''|*[!0-9]*) return 0 ;; esac
    cpu_sum=$(/usr/bin/awk -v a="$cpu_sum" -v b="$_sp_cpu" 'BEGIN { printf "%.4f", a+b }')
    cpu_peak=$(/usr/bin/awk -v a="$cpu_peak" -v b="$_sp_cpu" 'BEGIN { print (b>a)?b:a }')
    rss_sum=$(/usr/bin/awk -v a="$rss_sum" -v b="$_sp_rss" 'BEGIN { printf "%.0f", a+b }')
    [ "$_sp_rss" -le "$rss_peak" ] || rss_peak=$_sp_rss
    samples=$((samples+1))
}

OUTPUT="$PWD/Postview-Profile-$(/bin/date +%Y%m%d-%H%M%S).tsv"
printf 'app\tscenario\trun\twall_seconds\tcpu_seconds\tcpu_per_second\tmean_cpu_percent\tpeak_cpu_percent\tmean_rss_kb\tpeak_rss_kb\twindow_size\tstart_idle\tstart_title\tend_title\trenders_full\trenders_preview\tmegapixels_total\trequests_suppressed\trequests_suppressed_motion\n' > "$OUTPUT"

# $1 bundle  $2 app  $3 process  $4 scenario  $5 run
run_scenario() {
    bundle=$1; app=$2; process=$3; scen=$4; iter=$5
    CURRENT_APP=$app

    # Staged before the quiet gate, not after. Since the staging became a real
    # copy rather than a hard link it does actual disk I/O, and doing that after
    # the machine has been declared quiet puts it inside the window the gate
    # exists to keep clean. Copy first, then wait for it to settle.
    trial_pdf=$(fresh_document "$app-$scen-$iter") || die "could not stage a copy of the PDF"
    start_idle=$(wait_for_quiet_machine) || true
    trial_name=$(basename "$trial_pdf" .pdf)
    statfile="$WORKDIR/stat-$app-$scen-$iter.txt"

    if [ "$app" = "Postview" ]; then
        /usr/bin/open -n -a "$bundle" "$trial_pdf" --args \
            -PVStats YES -PVStatsPath "$statfile" || die "could not launch $app"
    else
        /usr/bin/open -n -a "$bundle" "$trial_pdf" || die "could not launch $app"
    fi

    wait_for_document_window "$process" "$trial_name" || die "$app did not show a window in 30 s"
    pid=$(pid_for "$process")
    [ -n "$pid" ] || die "$app showed a window but could not be sampled"

    winsize="not-set"
    [ "$EQUALISE" = "1" ] && winsize=$(set_window_size "$process")
    [ -n "$winsize" ] || winsize="unknown"

    # Let the opening render finish before any scenario clock starts, so what
    # follows measures the scenario and not the tail of the launch.
    /bin/sleep "$SETTLE_SECONDS"

    # Where the app opened, recorded before any input is sent. `end_title` alone
    # could not distinguish "read four pages from page 1" from "read four pages
    # from page 1,174", and the difference decides whether the two apps
    # rasterised comparable content at all.
    start_title=$(current_page_label "$process" | /usr/bin/tr '\t' ' ')
    [ -n "$start_title" ] || start_title="-"
    # Both apps write "(page N of M)"; only the thousands separator differs, and
    # page 1 never has one. A title with no page in it at all is not evidence of
    # anything and is left alone.
    case "$start_title" in
        -|*"page 1 of"*) : ;;
        *"page "*)
           printf '  !! %s opened a freshly copied file at "%s", not page 1.\n' "$app" "$start_title"
           printf '     It restored a saved position; this trial is not comparable.\n' ;;
    esac

    reset_samples
    driver=""
    cpu_before=$(cpu_seconds_for "$pid")
    # `launch` asks a different question: not "what did this workload cost"
    # but "what did opening the document cost in total". ps -o time counts from
    # process start, so the whole answer is already in cpu_after and the
    # baseline must be zero rather than whatever launch had spent by now.
    [ "$scen" = "launch" ] && cpu_before=0
    t0=$(now)

    case "$scen" in
        launch) : ;;                                   # already measured by getting here
        idle)
                end=$(/usr/bin/awk -v a="$(now)" -v d="$IDLE_SECONDS" 'BEGIN { printf "%.6f", a+d }')
                while [ "$(/usr/bin/awk -v a="$(now)" -v b="$end" 'BEGIN { print (a<b)?1:0 }')" = "1" ]; do
                    sample_process "$pid"; /bin/sleep 0.25
                done ;;
        read)   send_keys "$process" 121 "$READ_PRESSES" "$READ_DELAY" >/dev/null 2>&1 & driver=$! ;;
        page)   send_keys "$process" 121 "$PAGE_PRESSES" "$PAGE_DELAY" >/dev/null 2>&1 & driver=$! ;;
        scroll) send_keys "$process" 125 "$SCROLL_PRESSES" "$SCROLL_DELAY" >/dev/null 2>&1 & driver=$! ;;
        *)      die "unknown scenario: $scen" ;;
    esac

    if [ "$scen" != "idle" ] && [ "$scen" != "launch" ]; then
        while kill -0 "$driver" 2>/dev/null; do sample_process "$pid"; /bin/sleep 0.1; done
        wait "$driver" || die "$app stopped accepting input during '$scen'"
    fi

    # Rendering that follows the last event is part of the scenario's cost.
    t=0
    while [ "$t" -lt 20 ]; do
        running "$process" || die "$app terminated during '$scen'"
        sample_process "$pid"; /bin/sleep 0.1; t=$((t+1))
    done

    t1=$(now)
    cpu_after=$(cpu_seconds_for "$pid")
    cpu_used=$(/usr/bin/awk -v a="$cpu_before" -v b="$cpu_after" 'BEGIN { printf "%.2f", b-a }')
    wall=$(elapsed "$t0" "$t1")
    end_title=$(current_page_label "$process" | /usr/bin/tr '\t' ' ')
    [ -n "$end_title" ] || end_title="-"

    mean_cpu=$(/usr/bin/awk -v t="$cpu_sum" -v n="$samples" 'BEGIN { printf "%.1f", n?t/n:0 }')
    mean_rss=$(/usr/bin/awk -v t="$rss_sum" -v n="$samples" 'BEGIN { printf "%.0f", n?t/n:0 }')
    cpu_rate=$(/usr/bin/awk -v c="$cpu_used" -v w="$wall" 'BEGIN { printf "%.3f", (w>0)?c/w:0 }')

    quit_app "$app" "$process" || die "$app did not quit cleanly after '$scen'"
    CURRENT_APP=""

    # A copy is the whole file, unlike the hard link this replaced, so it goes
    # as soon as the app has let go of it rather than accumulating until the
    # trap fires.
    [ -n "$trial_pdf" ] && /bin/rm -f "$trial_pdf" 2>/dev/null

    rf="-"; rp="-"; mp="-"; sup="-"; supm="-"
    if [ -f "$statfile" ]; then
        rf=$(pvstat  renders.full               "$statfile")
        rp=$(pvstat  renders.preview            "$statfile")
        mp=$(pvstat  megapixels.total           "$statfile")
        sup=$(pvstat requests.suppressed        "$statfile")
        supm=$(pvstat requests.suppressed.motion "$statfile")
        [ -n "$rf" ]  || rf="-";  [ -n "$rp" ]  || rp="-"
        [ -n "$mp" ]  || mp="-";  [ -n "$sup" ] || sup="-"
        [ -n "$supm" ] || supm="-"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$app" "$scen" "$iter" "$wall" "$cpu_used" "$cpu_rate" "$mean_cpu" "$cpu_peak" \
        "$mean_rss" "$rss_peak" "$winsize" "$start_idle" "$start_title" "$end_title" \
        "$rf" "$rp" "$mp" "$sup" "$supm" >> "$OUTPUT"

    printf '  %-9s %-7s run %s: %5.1f s wall, %6.2f CPU-s (%.2f/s), RSS %s MB, win %s' \
        "$app" "$scen" "$iter" "$wall" "$cpu_used" "$cpu_rate" \
        "$(/usr/bin/awk -v r="$rss_peak" 'BEGIN { printf "%.0f", r/1024 }')" "$winsize"
    [ "$mp" != "-" ] && printf ', %s MP in %s+%s renders, %s+%s skipped' "$mp" "$rf" "$rp" "$sup" "$supm"
    printf '\n'

    /bin/sleep 0.5
}

med() {
    /usr/bin/awk -F '\t' -v a="$1" -v s="$2" -v c="$3" \
        'NR>1 && $1==a && $2==s { print $c }' "$OUTPUT" | /usr/bin/sort -n | \
        /usr/bin/awk '{ v[NR]=$1 } END {
            if (NR==0) { printf "0"; exit }
            if (NR%2) printf "%.2f", v[(NR+1)/2]; else printf "%.2f", (v[NR/2]+v[NR/2+1])/2 }'
}

printf 'Postview battery profile\n'
printf 'PDF: %s\n' "$PDF"
printf 'Scenarios: %s   runs each: %s\n' "$SCENARIOS" "$RUNS"
[ "$EQUALISE" = "1" ] && printf 'Both windows set to %sx%s so neither rasterises more pixels than the other.\n' "$WIN_W" "$WIN_H"
printf 'Each trial opens a fresh path, so every run starts at page 1.\n'
printf 'Waiting for >= %s%% idle before each trial. Do not touch the Mac.\n\n' "$MIN_IDLE"

r=1
while [ "$r" -le "$RUNS" ]; do
    for scen in $SCENARIOS; do
        run_scenario /Applications/Preview.app Preview Preview "$scen" "$r"
        run_scenario "$POSTVIEW_APP" Postview "$POSTVIEW_PROCESS" "$scen" "$r"
    done
    r=$((r+1))
done

printf '\n== CPU seconds consumed, median of %s runs ==\n\n' "$RUNS"
printf '  %-8s %10s %10s   %s\n' "scenario" "Preview" "Postview" "verdict"
for scen in $SCENARIOS; do
    p=$(med Preview "$scen" 5); o=$(med Postview "$scen" 5)
    /usr/bin/awk -v s="$scen" -v p="$p" -v o="$o" 'BEGIN {
        d = (p > 0) ? (o / p) : 0
        if (o < p) v = sprintf("Postview %.2fx cheaper", (o>0)?p/o:0)
        else if (o > p) v = sprintf("Postview %.2fx dearer", d)
        else v = "level"
        printf "  %-8s %8.2f s %8.2f s   %s\n", s, p, o, v
    }'
done

printf '\nRaw TSV: %s\n\n' "$OUTPUT"
printf 'Read `idle` first. A document open with nobody touching it is where a\n'
printf 'reader spends almost all of its wall-clock life, so a difference there\n'
printf 'outweighs anything the paging scenarios show. `page` is a stress case at\n'
printf '~17 pages a second and is not representative of reading.\n'
printf 'CPU seconds are not joules: work at background QoS is cheaper per second\n'
printf 'than work at default QoS, and this cannot see the difference.\n'

trap - EXIT HUP INT TERM
cleanup
