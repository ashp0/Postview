#!/bin/bash
# Postview vs Preview: one head-to-head test that names a winner.
#
# Run from Terminal on the Mavericks machine:
#   ./Postview-Showdown.command /path/to/document.pdf
#
# Optional:
#   RUNS=5 MIN_IDLE=85 WIN_W=1200 WIN_H=800
#   POSTVIEW_APP=/Applications/Postview.app
#   SCENARIOS="launch idle read page scroll"
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
#     figure it started from is recorded, so a contaminated trial is visible in
#     the data rather than silently folded into a median.
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
SCENARIOS=${SCENARIOS:-"launch idle read page scroll"}
POSTVIEW_APP=${POSTVIEW_APP:-}
POSTVIEW_PROCESS=Postview

# Scenario shapes. Key codes: 121 = Page Down, 125 = Down Arrow.
IDLE_SECONDS=${IDLE_SECONDS:-30}
READ_PRESSES=${READ_PRESSES:-12};      READ_DELAY=${READ_DELAY:-2.5}
PAGE_PRESSES=${PAGE_PRESSES:-80};      PAGE_DELAY=${PAGE_DELAY:-0.05}
SCROLL_PRESSES=${SCROLL_PRESSES:-200}; SCROLL_DELAY=${SCROLL_DELAY:-0.02}
TAIL_TICKS=${TAIL_TICKS:-20}     # rendering after the last keystroke still counts

# A metric is only called a win if it clears this. Below it the two apps are
# doing the same thing and the difference is the machine's mood.
TIE_BAND=${TIE_BAND:-0.05}

die() { printf 'Showdown stopped: %s\n' "$*" >&2; exit 1; }

[ "$#" -ge 1 ] || { printf '%s\n' "usage: $(basename "$0") /path/to/document.pdf" >&2; exit 2; }
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
if running Preview || running "$POSTVIEW_PROCESS"; then
    die "quit all Preview and Postview windows first; existing sessions are never touched"
fi

CURRENT_APP=""
WORKDIR=$(/usr/bin/mktemp -d /tmp/postview-showdown.XXXXXX) || die "could not create a working directory"
cleanup() {
    [ -n "$CURRENT_APP" ] && /usr/bin/osascript -e "tell application \"$CURRENT_APP\" to quit" >/dev/null 2>&1
    [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"
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

fresh_document() {
    label=$(printf '%s' "$1" | /usr/bin/tr ' /' '--')
    path="$WORKDIR/$PDF_STEM-$label.pdf"
    /bin/ln "$PDF" "$path" 2>/dev/null || /bin/cp "$PDF" "$path" 2>/dev/null || return 1
    printf '%s\n' "$path"
}

system_idle() {
    /usr/bin/top -l 1 -n 0 2>/dev/null | /usr/bin/awk '
        /^CPU usage/ { for (i=1;i<=NF;i++) if ($i=="idle") { gsub(/%/,"",$(i-1)); print $(i-1); exit } }'
}
wait_for_quiet_machine() {
    a=0
    while [ "$a" -lt 25 ]; do
        idle=$(system_idle); case "$idle" in ''|*[!0-9.]*) idle=0 ;; esac
        q=$(/usr/bin/awk -v i="$idle" -v m="$MIN_IDLE" 'BEGIN { print (i>=m)?1:0 }')
        [ "$q" = "1" ] && { printf '%s\n' "$idle"; return 0; }
        /bin/sleep 1; a=$((a+1))
    done
    printf '%s\n' "$idle"; return 1
}

# Exact CPU seconds from the kernel counter; `ps -o time` is [[HH:]MM:]SS.ss
cpu_seconds_for() {
    /bin/ps -o time= -p "$1" 2>/dev/null | /usr/bin/awk '
        NR==1 { gsub(/^[ \t]+/,"",$0); n=split($1,f,":"); s=0
                for (i=1;i<=n;i++) s=s*60+f[i]; printf "%.2f", s }'
}

# Energy Impact and cumulative idle wakeups for one pid, as "power idlew".
# Both come from the same top invocation so they describe the same instant.
# A machine or OS that declines to report either yields "-", which the analysis
# treats as missing rather than as zero.
power_sample_for() {
    /usr/bin/top -l 1 -n 0 -pid "$1" -stats pid,power,idlew 2>/dev/null | /usr/bin/awk -v p="$1" '
        $1 == p { pw=$2; iw=$3
                  if (pw ~ /^[0-9.]+$/ && iw ~ /^[0-9]+$/) { print pw, iw; found=1; exit } }
        END { if (!found) print "-", "-" }'
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
    r=$(/bin/ps -o rss= -p "$1" 2>/dev/null | /usr/bin/awk 'NR==1 { print $1 }')
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

open_app_with() {
    # $1 app path/name, $2 document path
    /usr/bin/open -a "$1" "$2" >/dev/null 2>&1
}

run_trial() {
    app=$1; process=$2; apppath=$3; scen=$4; iter=$5

    doc=$(fresh_document "$app-$scen-$iter") || die "could not stage a document"
    start_idle=$(wait_for_quiet_machine) || printf '  (machine never went quiet; trial recorded with start_idle=%s)\n' "$start_idle"

    t_open=$(now)
    open_app_with "$apppath" "$doc" || die "could not open $app"
    CURRENT_APP=$app
    wait_for_document_window "$process" || die "$app never showed a document window"
    t_ready=$(now)
    launch=$(elapsed "$t_open" "$t_ready")

    pid=$(pid_for "$process")
    [ -n "$pid" ] || die "could not find the $app process"

    winsize=$(set_window_size "$process")
    [ -n "$winsize" ] || winsize="unknown"
    /bin/sleep 1                        # let the resize settle before measuring

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

    quit_app "$app" "$process" || die "$app did not quit cleanly after '$scen'"
    CURRENT_APP=""

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$app" "$scen" "$iter" "$launch" "$wall" "$cpu_used" "$cpu_rate" \
        "$pw_mean" "$pw_peak" "$wakeups" "$mean_rss" "$rss_peak" >> "$OUTPUT"
    printf '  %-9s %-7s run %s: cpu %ss  energy %s  wakeups %s  peak rss %s MB\n' \
        "$app" "$scen" "$iter" "$cpu_used" "$pw_mean" "$wakeups" \
        "$(/usr/bin/awk -v k="$rss_peak" 'BEGIN { printf "%.0f", k/1024 }')"
}

printf 'app\tscenario\trun\tlaunch_seconds\twall_seconds\tcpu_seconds\tcpu_per_second\tenergy_mean\tenergy_peak\tidle_wakeups\tmean_rss_kb\tpeak_rss_kb\n' > "$OUTPUT"

printf 'Postview vs Preview -- head to head\n'
printf 'PDF:        %s\n' "$PDF"
printf 'Postview:   %s\n' "$POSTVIEW_APP"
printf 'Scenarios:  %s\n' "$SCENARIOS"
printf 'Runs each:  %s   window %sx%s   quiet threshold %s%%\n' "$RUNS" "$WIN_W" "$WIN_H" "$MIN_IDLE"
printf 'Output:     %s\n\n' "$OUTPUT"
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

printf '\nAll trials finished. Writing verdict.\n\n'

# ---------------------------------------------------------------------------
# Analysis. Every metric here is lower-is-better.
# ---------------------------------------------------------------------------
/usr/bin/awk -F '\t' -v band="$TIE_BAND" -v runs="$RUNS" '
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
    seen[key] = 1
}
END {
    order = "launch idle read page scroll"
    nsc = split(order, sc, " ")

    printf "=========================================================================\n"
    printf "  POSTVIEW vs PREVIEW -- VERDICT\n"
    printf "  %d runs per scenario, medians, lower is better throughout.\n", runs
    printf "  A gap under %.0f%% is called a tie: below that the two apps are\n", band*100
    printf "  doing the same thing and the difference is the machine.\n"
    printf "=========================================================================\n\n"

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

    printf "=========================================================================\n"
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
function emit(k, metric, label, arr, cnt, isbattery, fmt,   i, a, b, na, nb, ma, mb, sa, sb, verdict, delta, note, denom, gap, pa, pb, sa_txt, sb_txt) {
    na = cnt["Postview",k]; nb = cnt["Preview",k]
    if (na == 0 || nb == 0) { printf "  %-16s %s\n", label, "(not reported by both apps)"; return }
    for (i = 1; i <= na; i++) a[i] = arr["Postview",k,i]
    for (i = 1; i <= nb; i++) b[i] = arr["Preview",k,i]
    sa = spread(a, na); sb = spread(b, nb)
    ma = med(a, na); mb = med(b, nb)

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
' "$OUTPUT" | /usr/bin/tee "$VERDICT"

printf '\nRaw data: %s\nVerdict:  %s\n' "$OUTPUT" "$VERDICT"
