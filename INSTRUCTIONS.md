# Start here

Everything you need is in this repository. You do not need any other computer,
any other file, or a network connection after cloning.

- **`Postview.zip`** — the built app plus every test harness. Committed to this
  repo on purpose, because the Mavericks machine cannot build it (see below).
- **`ENGINEERING.md`** — why the code is the way it is, what is measured, what
  is not, and what is left to do.
- **`README.md`** — what the app is and how to use it.

---

## Which machine are you on?

**On the 2013 MacBook Pro / Mac Pro (Mavericks, 10.9):** you cannot build this.
The Makefile requires a modern clang (`-Werror=unguarded-availability`, which
Xcode 6 does not have). Use the prebuilt `Postview.zip` in this repo. Skip to
*Install*.

**On a modern Mac:** you can rebuild everything from source:

```bash
make dist        # produces Postview.zip
make verify-all  # every test gate; takes a while
```

---

## Install (Mavericks machine)

1. Unzip `Postview.zip`.
2. **Drag `Postview.app` to `/Applications`.** Not optional. OS X reads an
   application's code out of its file the *whole time it runs*, not just at
   launch — run it from a USB stick and unplug the stick and the kernel kills
   the process instantly. That is the one crash report this project has.
3. Copy the rest (the `.command` files and `pvband`) somewhere on the internal
   disk, e.g. `~/Desktop/Postview-Tools`.
4. **If this build is unsigned:** right-click `/Applications/Postview.app` →
   Open, then confirm. Do not double-click it the first time — an unsigned app
   gives "unidentified developer" with no way past it, and right-click → Open
   gives you an "Open anyway" button. Once, ever. A build signed with a
   Developer ID (`make dist SIGN_IDENTITY=...`) opens on a double click:
   Mavericks predates notarization but understands Developer ID perfectly well,
   and what 10.9.5 will not accept is a SHA-256-only signature — which is why
   the Makefile signs with both SHA-1 and SHA-256.

---

## Step 1 — prove the new code runs on Mavericks (5 min)

Two minutes, and it confirms the app still starts and still instruments itself
on 10.9 after the latest changes. The 2026-08-31 run already established that it
does; this is the cheap check that nothing since has broken it, and it produces
the cost figures Step 2 is read against.

```bash
POSTVIEW_STATS=1 /Applications/Postview.app/Contents/MacOS/Postview
```

In the app: press ⌘O and open a real PDF (a long one you actually read), scroll
with the trackpad, hold Page Down, zoom in, open the sidebar, then ⌘Q.

A block of `PVSTAT` lines prints into Terminal. Check three:

| line | expected | meaning |
|---|---|---|
| `power.source` | `battery` or `ac` | the IOKit power detection worked on 10.9 |
| `cost.render.samples.full` | greater than 0 | the cost model measured real page renders |
| `cost.ms.per.mpx.full` | a real number, not `0.00` | it produced a usable rate for pages |
| `cost.ms.per.mpx.preview` | usually several times the `.full` rate | the two populations are being kept apart |

The last two are reported separately on purpose, and the `.full` one is the one
to quote. A preview is 1/9 the pixels but re-walks the whole content stream, so
its cost per megapixel is several times a page's; an ordinary reading session
produces about three previews per page render, so a single combined rate is
mostly a statement about previews. The 2026-08-31 run reported one combined
`cost.ms.per.mpx` of 432.55 from 96 samples, 72 of which were previews — a
number that was read as the cost of a page and was not.

Also record **the window size and the document** you used. A rate in
milliseconds per megapixel is comparable between runs only if you know what was
being rasterised; the same session at half the window width is a different
measurement.

Cross-check with `pmset -g batt` — it will say "Now drawing from 'Battery
Power'" or "'AC Power'", and `power.source` must agree.

> **If `power.source` says `unknown`, that is the finding to report.** The
> runtime IOKit lookup failed. The app is still safe — it falls back to the
> cautious battery behaviour — but the power feature is dead and needs fixing.
>
> It read `ac` correctly on the Mac Pro on 2026-08-31, so the lookup does work
> on 10.9 (`ENGINEERING.md` §9.1). `unknown` now means a regression rather than
> an untested call.

Save the output into `stats.txt`.

**Do not use** `open -a Postview file.pdf --args -PVStats YES`. Mavericks'
`open` has no `--args`: it reads it as `--` plus a filename `args` and you get
"the file … does not exist" errors. The command above avoids `open` entirely.

---

## Step 2 — the head-to-head measurement (30–50 min, unattended)

Postview against Preview: same document, same window size, seven scenarios,
five runs each, a winner per metric. This is the project's own arbiter.

It ran on 2026-08-31 and **refused to name a winner**, because two fairness
checks failed: the arrow key scrolled half as far as Preview's, and the wheel
scenario tripped a check that could not tell 3% from a page. Both are fixed
(`ENGINEERING.md` §9.2), so this run should be the first one that returns a
verdict. Expect `scroll`'s CPU margin to be smaller than the +63% on record —
that margin was partly bought by travelling half as far, and losing it is the
fix working.

Preparation, all of it matters:

- Quit Preview, Postview, and everything else. No browser, no Mail.
- **On the laptop: unplug the charger.** The battery case is the case under test.

```bash
cd ~/Desktop/Postview-Tools
./Postview-Showdown.command /path/to/a/document/you/actually/read.pdf
```

Use a **real** document, not a test fixture — render cost varies by 59× with
page content, so a synthetic file measures the wrong thing. A long, text-heavy
PDF is the right choice.

Confirm the header says `Power policy: Postview pinned to -PVPowerState battery`.
The saved verdict now records this too, along with the document and window size,
so the file can be read months later without the terminal it scrolled past.

**Then do not touch the Mac until it finishes.** It waits for a quiet machine
before each trial; any input corrupts the measurement.

It prints a verdict and writes a `.tsv` next to itself. **Save that `.tsv`.**

A metric reported as "noisy" is fine — it means run-to-run spread exceeded the
gap between the apps, so it refuses to declare a winner rather than invent one.

On the Mac Pro, also run the other branch to see what mains power buys:

```bash
POWERSTATE=ac ./Postview-Showdown.command /path/to/the/same/document.pdf
```

---

## Step 3 — the render cost probe (2 min)

```bash
cd ~/Desktop/Postview-Tools
chmod +x ./pvband
./pvband /path/to/the/same/document.pdf 6 3
```

This ran on 2026-08-31 and its answer was decisive: banding costs more than it
saves on a text document, which is what retired the largest planned feature
(`ENGINEERING.md` §9.3). Re-run it only if you are using a **different**
document — particularly a vector-heavy one, where §2 predicts the opposite sign
and nobody has measured it on this machine. Save the output as `band.txt`.

---

## Step 4 — just use it

Read PDFs with it for a few days. Note anything that crashes, hangs, renders
blurry when it should not, or feels slow.

---

## What to bring back

Named for what they contain, not for the step that produced them. The two
copies of these instructions have historically numbered the same procedure
differently — this file called the head-to-head Step 2 and `INSTRUCTIONS.txt`
called it Step 3 — so the 2026-08-31 band probe came back as `step4-stats.txt`,
which is neither document's name for it and reads like a second stats file.

- `stats.txt` — the `PVSTAT` block, plus the window size and document
- the `.tsv` from the showdown (both, if you ran the AC one)
- `band.txt` (only if you ran the probe on a new document)
- any crash reports from `~/Library/Logs/DiagnosticReports/Postview*`

Those decide whether this is finished or whether there is more to do.

---

## Known limits — not bugs, do not report

- No text selection, copy, search, printing, annotation, export, or encrypted
  PDFs. It is a reader, not a PDF application.
- Zooming past ~1.1× on an 8 GB machine renders slightly soft. Deliberate memory
  limit, recorded and pinned by tests (`ENGINEERING.md` §4.1).
- Peak memory is higher than Preview's — the one metric it loses on across the
  board. Known, measured, still open (`ENGINEERING.md` §9.5).
- Right-click → Open on first launch is normal for an *unsigned* build. A
  release built with `make dist SIGN_IDENTITY=...` is Developer ID signed with a
  dual SHA-1/SHA-256 digest, which 10.9.5 accepts, and opens with a double click.

## If something goes wrong

```bash
defaults delete com.postview.Postview
rm -rf ~/Library/Application\ Support/Postview
```

Deleting `/Applications/Postview.app` removes the app entirely. It installs
nothing else — no login items, no kernel extensions, nothing outside its own
bundle.

While a document is open you will see one or more `PostviewRenderHelper`
processes in Activity Monitor. Those are Postview's own, they live inside the
bundle, and they exist so that a malformed PDF that hangs or crashes CoreGraphics
takes down a helper instead of the viewer. They start when a document opens and
are gone the moment it closes; quitting Postview ends them.

---

## Continuing with Claude on another computer

```bash
git clone https://github.com/ashp0/Postview.git
```

Open the folder and start with:

> Read ENGINEERING.md, then §9 "The Mavericks run" and §7 "Still open". Here are
> the results from the Mavericks machine: [paste stats.txt, the .tsv, and
> band.txt]. Tell me what they say and what to do next.

### State as of the last session

The 2026-08-31 Mavericks run happened, and `ENGINEERING.md` §9 is what it said.
In short:

- **The power lookup works on 10.9** (`power.source ac`). That was the single
  most-likely-broken thing in the program and it is now closed.
- **The showdown returned no verdict**, on two fairness checks. One was a real
  defect — the arrow key scrolled 60 pt against Preview's ~121, so a reader
  holding Down covered half the ground — and is fixed. The other was the
  instrument: `wheel` moved the two apps 3% apart across a page boundary and a
  page-resolution counter read that as 0 pages against 1. The gate no longer
  treats a one-page gap as evidence.
- **Banding does not pay on text documents**, measured on the target. It would
  cost the `read` workload +1.99 s against a surplus of 1.73 s. This retires
  what used to be the biggest planned feature; see below.
- **Three instruments were reporting numbers that were not what they claimed** —
  the cost rate mixed full renders with previews, the "non-bitmap" memory column
  subtracted two maxima taken at different moments, and a saved verdict recorded
  neither the power branch nor the document. All three are fixed, and the
  affected figures from that run should not be quoted.

Before that, four adaptive features landed, none exposed as a user-visible mode:
a measured cost model, power-source awareness, a fourth RAM tier (> 8 GB), and
cost-aware eviction. `ENGINEERING.md` §3, §4.2, §4.1 and §4.3 respectively.

All gates green on the development host: analyser clean, **pvtest 319**,
**pvuitest 140**, soak 19, stress 14 + ASan/UBSan + TSan (no races), no leaks,
showdown self-test 26 checks.

### The biggest remaining piece of work

**Re-run Step 2.** No showdown has yet been allowed to name a winner, and both
fairness checks should now pass. Expect `scroll`'s CPU margin to fall — it was
partly bought by travelling half as far — and take that as the fix working.

After that, **peak memory**: the only metric Postview loses on in all seven
scenarios, by 22–43%, and the one that was being reasoned about with a broken
column until §9.4. The column is now a real quantity and the question is
untouched.

Banded rendering *was* the answer here and the measurement says it is not, at
least not for text. §9.3 has the numbers.
