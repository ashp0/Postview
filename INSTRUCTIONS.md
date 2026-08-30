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
4. **Right-click `/Applications/Postview.app` → Open**, then confirm. Do not
   double-click it the first time: the app is unsigned, so double-clicking gives
   "unidentified developer" with no way past it. Right-click → Open gives you an
   "Open anyway" button. Once, ever. (Signing needs a paid Apple Developer ID;
   Mavericks predates notarization entirely.)

---

## Step 1 — prove the new code runs on Mavericks (5 min)

**This is the most important step.** All of the recent work was verified on a
modern Mac under Rosetta, on a host that cannot even display the app's windows.
None of it had ever executed on a 2013 Mac.

```bash
POSTVIEW_STATS=1 /Applications/Postview.app/Contents/MacOS/Postview
```

In the app: press ⌘O and open a real PDF (a long one you actually read), scroll
with the trackpad, hold Page Down, zoom in, open the sidebar, then ⌘Q.

A block of `PVSTAT` lines prints into Terminal. Check three:

| line | expected | meaning |
|---|---|---|
| `power.source` | `battery` or `ac` | the IOKit power detection worked on 10.9 |
| `cost.render.samples` | greater than 0 | the cost model measured real renders |
| `cost.ms.per.mpx` | a real number, not `0.00` | it produced a usable rate |

Cross-check with `pmset -g batt` — it will say "Now drawing from 'Battery
Power'" or "'AC Power'", and `power.source` must agree.

> **If `power.source` says `unknown`, that is the finding to report.** The
> runtime IOKit lookup failed on 10.9. The app is still safe — it falls back to
> the cautious battery behaviour — but the power feature is dead and needs
> fixing. This is the single most likely thing to be wrong, because it is the
> one call that could only be tested on a modern OS.

Save the output into `step1-stats.txt`.

**Do not use** `open -a Postview file.pdf --args -PVStats YES`. Mavericks'
`open` has no `--args`: it reads it as `--` plus a filename `args` and you get
"the file … does not exist" errors. The command above avoids `open` entirely.

---

## Step 2 — the head-to-head measurement (30–50 min, unattended)

Postview against Preview: same document, same window size, seven scenarios,
five runs each, a winner per metric. This is the project's own arbiter and it
has **never been run against any of the recent work**.

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

Every timing figure in `ENGINEERING.md` §2 was measured on a different machine.
This is the one that counts. Save the output as `step3-band.txt`.

---

## Step 4 — just use it

Read PDFs with it for a few days. Note anything that crashes, hangs, renders
blurry when it should not, or feels slow.

---

## What to bring back

- `step1-stats.txt` — the `PVSTAT` block
- the `.tsv` from the showdown (both, if you ran the AC one)
- `step3-band.txt`
- any crash reports from `~/Library/Logs/DiagnosticReports/Postview*`

Those decide whether this is finished or whether there is more to do.

---

## Known limits — not bugs, do not report

- No text selection, copy, search, printing, annotation, export, or encrypted
  PDFs. It is a reader, not a PDF application.
- Zooming past ~1.1× on an 8 GB machine renders slightly soft. Deliberate memory
  limit, recorded and pinned by tests (`ENGINEERING.md` §4.1).
- Peak memory is higher than Preview's. Known, measured, still open.
- Right-click → Open on first launch is normal for an unsigned app.

## If something goes wrong

```bash
defaults delete com.postview.Postview
rm -rf ~/Library/Application\ Support/Postview
```

Deleting `/Applications/Postview.app` removes the app entirely. It installs
nothing else — no background processes, no login items, no kernel extensions.

---

## Continuing with Claude on another computer

```bash
git clone https://github.com/ashp0/Postview.git
```

Open the folder and start with:

> Read ENGINEERING.md, then §7 "Still open". Here are the results from the
> Mavericks machine: [paste step1-stats.txt, the .tsv, and step3-band.txt].
> Tell me what they say and what to do next.

### State as of the last session

Four features landed, all adaptive, none exposed as a user-visible mode:

1. **A measured cost model** (`Sources/PVCostModel.{h,m}`) — ms-per-megapixel per
   document; the scheduler's gates are expressed in time instead of a constant
   that is wrong by 59× between documents.
2. **Power-source awareness** — battery is byte-for-byte the old behaviour; AC
   turns the blanket motion gate into a per-page cost question.
3. **A fourth RAM tier** (> 8 GB) — moves the silent zoom cliff from 1.09× to
   1.54× on the 64 GB Mac Pro. Tiers at 8 GB and below are unchanged to the byte.
4. **Cost-aware eviction** — GreedyDual-Size; keeps the page that is expensive to
   rebuild over the one that is cheap, at identical bytes.

All gates green on the development host: analyser clean, **pvtest 307**,
**pvuitest 134**, soak 20, stress 14 + ASan/UBSan + TSan (no races), no leaks,
showdown self-test. Soak improved against the previous commit: settled
179.3 → 169.4 MB, peak 210.2 → 198.8 MB, drift +0.084 → +0.002 MB/cycle.

**Not verified on any 2013 Mac.** That is what the steps above are for.

### The biggest remaining piece of work

Banded rendering with concurrent workers — the only change that improves
latency, CPU *and* memory at once on vector documents, and the one that would
finally use the Mac Pro's idle cores (rendering is single-threaded by
construction today). `ENGINEERING.md` §7 has the detail and the caveats; it is
gated on the Step 2 and Step 3 numbers above.
