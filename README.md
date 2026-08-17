# Returns Intake & Tracking

Three stages, no external dependencies:

| File | What it is | Where it runs |
|---|---|---|
| `intake.ps1` | Stage 1 — validates a folder of return PDFs, files each into its own folder, writes `manifest.json` | Windows PowerShell 5.1 (no modules, no admin) |
| `run-intake.cmd` | Safe Windows launcher for `intake.ps1`; prevents partial/selected-line execution | Windows Command Prompt or PowerShell |
| `index.html` | Stage 2 — the whole tracker in one file | Any modern browser, opened directly (`file://`) |
| `batch-status.ps1` | Stage 3 — classifies numeric batch ZIPs from their internal XML extension and files them into return folders | Windows PowerShell 5.1 (no modules, no admin) |
| `run-batch-status.cmd` | Safe Windows launcher for `batch-status.ps1` | Windows Command Prompt or PowerShell |
| `sample-manifest.json` | 13-return test fixture (12 clean + 1 flagged) so you can try the app without running the script | — |

**Double-click `index.html` and it works.** No server, no CDN, no build step, no
install — one file of hand-written HTML, CSS and JS. The `.xlsx` export is written
byte by byte by the page itself rather than by a library.

Stage 3 currently handles Batch Status ZIP + XML filing. GS XMLs, Recon Outputs,
and TFR filing are not automated yet.

## Current state

There used to be two copies of the app — `crm.html` and the reviewed
`crm.fixed.html` — waiting to be merged. That merge is done: **`index.html` is
the app**, built from the reviewed copy, and both old files are gone. The test
suite and `intake.ps1` both point at `index.html`.

---

## Stage 1 — `intake.ps1`

### Running it

Keep `run-intake.cmd` and `intake.ps1` together. The recommended command is:

```bat
C:\Tools\run-intake.cmd -Path "C:\Work\Assignments\2026-08-11"
```

The launcher checks for PowerShell 3.0 or newer, bypasses the execution policy
for this invocation only, and runs `intake.ps1` as one complete script. **Do not
paste the script into a PowerShell window or use Run Selection.** Doing that
causes misleading `else is not recognized` and null `$PSCmdlet.ShouldProcess`
errors because the lines no longer share one script context.

When `-Path` is omitted, intake operates on the current directory. Other options
can be passed through the launcher:

```powershell
C:\Tools\run-intake.cmd -Path 'C:\Work\Assignments\2026-08-11'
C:\Tools\run-intake.cmd -WhatIf     # complete dry run: reports everything, touches nothing
C:\Tools\run-intake.cmd -Force      # answer Y to the prompts
C:\Tools\run-intake.cmd -StateMap 'C:\Work\state-overrides.json'
C:\Tools\run-intake.cmd -Log        # transcript to intake-log-<timestamp>.txt
```

Direct `.ps1` execution remains supported. If PowerShell blocks it, either use
the launcher or unblock it once (no admin needed):

```powershell
Unblock-File C:\Tools\intake.ps1
powershell -ExecutionPolicy Bypass -File C:\Tools\intake.ps1
```

### What it does

1. **Validation, before touching anything.**
   - Tolerated at the top level: `.pdf`, `.json`, `.ps1`, `.xlsx`, `.xls`,
     `.csv`, `.txt`, `.md`, `.log`. Anything else is listed and you get a `Y/N`
     — answer no and it exits (code 2) with nothing changed. `-Force` skips the
     question. Folders and hidden/system files are ignored.
   - Detects a 2-letter state code in each name: the name is split on spaces,
     hyphens and underscores, and each run of letters inside those tokens is
     checked. A run counts only if it is **exactly two letters**, so
     `CTC-01_MD510` → `MD` and `FL123-GS` → `FL`, but `MASTER_FILE` matches
     nothing. All 50 states + DC are recognised.
   - Zero matches or more than one match ⇒ **flagged**, never guessed.
   - **Overrides beat detection.** `-StateMap <path>`, plus a
     `state-overrides.json` in the assignment folder if one is there, map a
     return id or an exact filename to a state code. A name the detector cannot
     read gets fixed once and stays fixed, and an overridden return is not
     reported as flagged.
2. **Summary + confirmation.** Prints total / clean / flagged, and asks `Y/N`
   before proceeding if anything is flagged (exit code 2 if you answer no —
   nothing is changed).
3. **Filing.** For each PDF, creates a folder named exactly the filename minus
   `.pdf` and moves the PDF into it. Existing folders and files are never
   overwritten — those are reported as `[skip]`.
4. **Manifest.** Writes `manifest.json` in the assignment folder (UTF-8, no BOM,
   so the browser can parse it), with `schema_version` as the first key. Every
   return gets all 8 status flags set to `null`, plus `id`, `filename`,
   `folder`, `state_code`, `state_name`, `date_received`, `remarks`. Flagged
   returns still get a folder and a manifest entry (with `state_code: null`) and
   are also listed in the top-level `flagged` array.

Console output is colour-coded: green = done, yellow = flagged/skipped,
red = hard failure. It ends with e.g.
`Processed 13 returns, 1 flagged, manifest.json written.`

`-WhatIf` runs all of the above and writes none of it, so you can see what a
folder would turn into before committing to it.

### Re-running it

Safe, and it does not throw away your work. On a second run:

- Loose PDFs are already inside their folders, so the script also discovers
  returns from **existing subfolders** that contain a PDF, and reports them as
  `already processed`.
- If a `manifest.json` is present, it is **copied to
  `manifest.backup-<timestamp>.json`** first, and the existing
  `status_flags`, `remarks`, `date_received`, hand-assigned `state_code`, and
  any unrecognised keys are carried forward into the new manifest.
- A return that is in the old manifest but has no folder any more is kept
  (with a warning) rather than dropped.

So the intended loop is: run the script → work in the app → **Export JSON**
→ save it back over `manifest.json` in the assignment folder. A later re-run
picks it up from there.

---

## Stage 2 — `index.html`

Double-click it. Opening it with nothing loaded shows an import prompt, not an
error; if there is nothing to import, **+ Start a batch by hand** or **Just open
the Notepad** both work from cold.

The screen is deliberately four things and nothing else: a toolbar, a filter
row, the grid, and a status line. Chrome is monochrome on purpose so the only
colour on screen is your data — green `✓` yes, red `✕` no, amber `!` issue,
grey `·` not started.

### Press `?` first

`?` or `F1` opens **Shortcuts & what everything does** — every key, grouped, plus
a short explanation of each feature, with a filter box across the top. There's a
`?` button in the header and an **all shortcuts** button in the status bar for
anyone who doesn't know the key yet.

It is the reference, so it is the one place all of this is guaranteed current:
the sheet is generated from the same list the app itself uses, which means a key
cannot be documented there and missing from the app.

Keys are shown for **Windows** (`Ctrl`), and swap to `⌘` only on a Mac. The
shortcuts themselves were picked for Windows: nothing collides with a Chrome or
Edge shortcut the page never gets to see. That rules out `Ctrl+T`/`W`/`L`/`J`/`H`,
`Alt+E` and `Alt+F` (both open the browser menu), `Alt+D` (the address bar),
`Alt`+arrows (back/forward), and any `Ctrl`/`Alt` plus a digit (tab switching) —
so none of those are used.

### The buttons

| Button | What it does |
|---|---|
| **?** | Shortcuts and what everything does (`?` or `F1`) |
| **Import** | Load a `manifest.json` (fresh from the script, or one you exported earlier) |
| **Manifest** | Slide-over panel: source folder, progress per column, breakdown by state, which returns the intake script flagged (and whether you've since fixed them), and a *Clear saved session* button |
| **Export Excel** | A real `.xlsx` workbook — see below |
| **Export JSON** | Your save file. `Ctrl+S` does the same |
| **Export CSV** | Plain CSV, UTF-8 BOM + CRLF, for when you just want raw text |
| **+ Add Row** | Create a return by hand — see *Rows* |
| **Notepad** | The blank page, full screen — see *Notepad* |
| **Quick Notes** | Note cards, scratchpad and every open issue — see *Notes* |
| **Link file** | Write every change straight into `manifest.json` on disk |
| **↻ New Session** | Clear the browser copy and start over |

Export Excel and Export CSV write **the rows currently visible**, so a filter
narrows the export too. If the filter matches nothing they refuse and say so,
rather than quietly writing every row instead. Export JSON is deliberately
different: it always writes the whole manifest.

### Working the grid — keyboard first

| Key | Action |
|---|---|
| `Tab` / `Shift+Tab` | **Next / previous return, same step.** Tab moves *down* a column, not across a row — you check attachments on every return, then move to the next step. At the bottom of a column it wraps to the top of the next one |
| `↑` `↓` | Same as Tab / Shift+Tab |
| `←` `→` | Move across steps within one return |
| `Home` / `End` | Top / bottom of this column |
| `Y` `N` `I` | Mark yes / no / issue (`1` `2` `3` also work), then jump to the next return automatically |
| `0` `X` `Delete` | Back to not-started |
| `Space` | Cycle the cell without moving (`Shift+Space` cycles backwards) |
| `R` | Jump to that row's remarks; `Enter` or `Esc` returns to the grid |
| `S` | Tick this row — see *Marking many at once* |
| `Ctrl+A` | Tick every row on screen |
| `Insert` | Add a return by hand |
| `Ctrl+Z` | Undo, 200 deep — see *Undo* |
| `Ctrl+F`, `/` | Jump to the search box |
| `Alt+R` | Clear the search and every filter |
| `Alt+G` | Group by state |
| `Ctrl+S` | Export JSON |
| `Alt+X` / `Alt+C` | Export Excel / CSV |
| `Alt+L` | Link `manifest.json` |
| `?` `F1` | Shortcuts and features |
| `Alt+P` | Notepad |
| `Ctrl+N`, `Alt+N` | Quick Notes. `Ctrl+N` is "new window" in some browsers and never reaches the page there, which is why `Alt+N` does it too |
| `Alt+M` / `Alt+V` | Manifest panel / View menu |
| `Esc` | Closes whatever is on top, one layer per press: dialog, menu, shortcut sheet, notepad, panel, modal, notes — and only then does it untick the rows |

Mouse still works: click a cell to cycle it forward, `Shift`-click to go back.
So marking a whole column is `Y Y Y Y…`, and one stray keypress is one `Ctrl+Z`.

If you'd rather have an explicit dropdown in every cell, **View → Dropdown in
each cell** switches the whole grid over; keyboard navigation is identical.
**View → Advance to next return after marking** turns off the auto-jump.

### Marking many at once

Ticking rows and setting them together, for when forty returns all get the same
answer:

- **Tick rows** with the boxes down the left edge, with `S` on the row you're on,
  with `Shift`-click for a whole run, or with `Ctrl+A` for everything on screen.
  The header box ticks the page and shows a third, partial state when only some
  of it is ticked. **Invert** flips the lot.
- A bar appears at the bottom with the count. Pick a **column** and a **value**,
  and every ticked row gets it. Choosing *Every yes/no/issue step* sets them all
  in one go. For a number or text column the three buttons are replaced by a box
  to type the value into, because "Yes" is not something those columns can hold.
- Faster still: if the row you're on is ticked, plain `Y` / `N` / `I` / `0` marks
  **the whole selection** in that column, and focus stays put so you can move
  right and do the next one. If the row you're on is *not* ticked, those keys do
  exactly what they always did to that one cell — which is the rule that keeps it
  predictable.
- Any of it is **one** entry on the undo stack and **one** edit on the counter, so
  a single `Ctrl+Z` takes back "marked 40 rows yes".
- The selection is keyed by return, not by row position, so re-sorting, filtering
  or dragging rows never moves it onto different returns. If some of what you're
  about to change is hidden by the current filter, the bar says how many.
- Don't want the tick boxes? **View → Tick boxes for selecting rows** hides the
  column; `S` and `Ctrl+A` still work.

### Rows

- **+ Add Row** creates a return by hand: id, state, date received, remarks. The
  id is required and must be new — a duplicate is refused with an inline message
  rather than accepted and left to break row lookup later. The suggested default
  skips any name already in use. The new row is scrolled to and flashed.
- **Delete** a return with the `✕` at the end of its row. The confirmation says
  plainly that the folder and the PDF on disk are left alone; only the tracker
  row goes. Undo puts it back.
- **Reorder** by dragging the `⋮⋮` handle. Dragging switches the grid to
  **manual row order** (also a checkbox in the View menu) and tells you it has,
  because hand-ordering means nothing while a sort is active. Click any column
  header to go back to sorting.

### Columns

Everything that changes a column lives in the **View** menu (`Alt+V`) and nowhere
else. In particular, **the header cannot rename a column.** The pencil icon, the
click-on-the-label and the double-click-the-header are all gone: the header's only
jobs are sort, collapse and resize, so nothing you do while sorting a column of
200 rows can rename it by accident. A rename is a change to the manifest that
every export carries — it should take a deliberate trip through a menu.

- **Add a column** — View → *Add a column…*. You name it and **choose what it
  holds** (see below). Applied to every return, and tracked like the original
  eight.
- **Rename a column** — View → *Rename a column…*. Names live in the manifest, so
  they travel with the file and show up in the exports.
- **Change what a column holds** — View → *Change what a column holds…*. See below.
- **Remove a column you added** — View → *Remove a column you added…*. Only
  columns added here; the eight the intake script writes are the contract with
  `intake.ps1`, so hide those instead. Undo brings a removed column back **with
  its data**.
- **Drag any column divider** to resize. Double-click a divider to reset that
  column to its default width.
- **Collapse a column** to a 24px sliver with the `‹` button that appears in the
  header on hover — status cells become a coloured dot, and a number or text cell
  becomes a dot that says whether it's filled. Click `›` to expand it again.
- **Hide it entirely** in the **View** menu, which lists every column with its
  current width, plus *Compact rows*, *Tick boxes*, *Manual row order* and *Reset
  column widths*.
- Widths, collapsed and hidden columns, density, sort, grouping, the marking mode
  and the notepad's own settings are all remembered between sessions
  (`localStorage`, UI only — never your data). Custom columns, their types and
  renames are data, and live in the manifest.
- Click a header to sort; click again to reverse. Sorting a status column puts
  `Issue` first, then `No`, `Yes`, not-started — so problems float up. A number
  column sorts numerically (so 9 before 20 before 100, not the `100 < 20` a text
  sort would give you), and **empty cells sink to the bottom in both
  directions** — reversing a sort to find the highest value shouldn't bury it
  under the blanks.

### What a column holds — yes/no, number, or text

Every column is one of three types, chosen when you add it and changeable
afterwards. The type lives in the manifest next to the column, so it travels with
the file.

| Type | The cell is | Counts towards |
|---|---|---|
| **Yes / No / Issue** | the original click-or-`Y`/`N`/`I` cell | *qualified*, and the per-step progress bars |
| **Number** | a numeric box — decimals and negatives fine | totalled, averaged and given a range in the Excel summary |
| **Text** | anything you can type | nothing; it's data you're keeping, not progress |

A column with no type at all — which is what every manifest written before this
existed looks like — is a yes/no/issue column, so **old files open unchanged.**

Things worth knowing:

- **A data column can't stop a return being qualified.** *Qualified* still means
  "every yes/no/issue step is yes", so adding a Refund-amount column doesn't
  un-finish work you'd already done.
- **% complete counts both**: a step marked yes, or a data cell with something in
  it, over every cell. So a finished return with one empty number column reads
  slightly under 100%, which is the honest answer to "is there anything left to
  fill in".
- **Not started** now means you haven't touched the row *at all* — no step marked
  and no data typed. A reference code in a text column counts as having started.
- **In a number or text cell the keyboard belongs to you.** `Y` types the letter
  Y. Only the keys that move you around the grid are taken — `Tab`, `Enter` and
  `↑`/`↓` walk the column exactly as they do over the steps, `←`/`→` move the
  caret, and `Esc` lets go of the cell. Typing a whole value is **one** edit and
  one undo, not one per keystroke.
- **Changing a type converts what it can.** `"42"` becomes `42`; `"about ten"`
  cannot be read as a number and is emptied rather than guessed at. It tells you
  how many cells that will happen to **before** doing anything, and the whole
  conversion is one undo.
- Numbers reach the workbook as **real numeric cells**, so `SUM` and `AVERAGE`
  work on them, and an empty one is left genuinely empty rather than filled with a
  dash that would turn the column into text.

### Finding things

Search (ID, filename, remarks, state), a **state** filter, a **progress**
filter (has an issue / not finished / fully qualified / in progress / not
started / needs a state), and **Group by state** which inserts a heading row
per state with a count. Clicking a state badge in a row filters to that state;
clicking it again clears. `Alt+R` clears the search and both filters at once. The
pills in the toolbar always show totals: returns, qualified, issues, untouched,
no-state, and overall % complete.

### States, right and wrong

Returns the script couldn't read a state code from show an amber
**"Assign state…"** dropdown instead of a badge — fix them here, not in the
JSON. A banner counts them and can filter the grid to just those. The original
`flagged` array is preserved on export; the Manifest panel shows each flagged
file as `open` or `TX assigned`.

A state that *was* detected can be corrected or cleared the same way: hover the
state cell and click the `▾`. The dropdown carries every code the app knows
(50 states, DC and `FED`), and its empty option clears the state outright.

### About that `.xlsx`

**Yes — it exports a genuine `.xlsx`, not a CSV with a spreadsheet name.** An
`.xlsx` is a ZIP of XML parts, so the app writes the ZIP itself (stored
entries plus a hand-rolled CRC32) and emits the SpreadsheetML by hand. Still no
libraries, still one file. You get:

- Three sheets: **Returns** (one row per return), **Summary** (totals,
  yes/no/issue/not-started per step, a block for the number and text columns with
  their filled counts, totals, averages and ranges, and a per-state breakdown) and
  **Notes** (the note cards, then the scratchpad line by line, so nothing you
  typed stays trapped in the app).
- A bold dark header row, **frozen** so it stays put, with **autofilter**
  enabled on every column.
- Status cells colour-filled to match the app — green Yes, red No, amber Issue.
- **Number columns as real numbers**, right-aligned, so `SUM` and `AVERAGE` work
  without coaxing; text columns left-aligned and wrapped.
- `date_received` as a **real Excel date** (`yyyy-mm-dd`, numeric) in the
  `Received` column, so date sorting and filtering behave. It is a plain column
  in the CSV. There is no Received column in the grid itself — you rarely need
  it while marking steps, but every export carries it.
- Sensible column widths and wrapped remarks.

CSV export stays as a second option — it's the safer thing to paste into other
systems, and it's what to fall back on if a future Excel build ever objects to
the workbook.

### Notes

**Quick Notes** (`Ctrl+N`, or `Alt+N`) is three tabs in one panel:

- **Note Cards.** One card per thought, with a category (Alpha through Epsilon,
  General, Urgent, Phone Log, Checklist, Linked Return). Pin a card to the top,
  tick off a checklist card with its done box, link a card to a return, and
  search or filter by category. Card text is editable in place. *Clear All*
  wipes cards and scratchpad together, and says how many first.
- **Scratchpad.** One bulk text box for raw logs and memos, with **+ Stamp** to
  insert the current date and time at the cursor, **Copy** to put the lot on the
  clipboard, and **⤢ Notepad** to open the same text full screen.
- **Issues & Remarks.** Every return that has a remark or an issue, in one list.
  Click an entry and the panel closes, the grid scrolls to that row and flashes
  it. The same works on a card's linked-return tag.

Notes live inside the manifest, so they auto-save, export and re-import with it,
get their own Notes sheet in the workbook, and survive a re-run of `intake.ps1`.

### Notepad

**`Alt+P`**, the **🗒️ Notepad** button in the header, or **⤢ Notepad** on the
Scratchpad tab. A blank page taking the whole window — no grid, no pills, no
toolbar — for the text you keep pasting somewhere else.

It is the **same text** as the Scratchpad tab, not a second copy: type in either
and the other keeps up, so it auto-saves with the manifest, exports to the Notes
sheet and survives a re-run of the script like everything else. It is deliberately
never parsed or validated — whatever you put in comes back out exactly as typed.

**Snippets.** Leave a **blank line** between chunks and each chunk becomes a
snippet in the rail on the right, with its own **Copy** button — so you can grab
one block out of a page of them without selecting it by hand. Clicking a snippet
card *selects* that block in the page instead of copying it, so you can also cut
it or type over it. A line of nothing but dashes is treated as a divider you drew,
not as a snippet of its own.

The rest of the bar:

| | |
|---|---|
| **＋ Time** | the date and time at the cursor |
| **＋ Snippet** | a blank line and a dashed rule, i.e. a visible split |
| **Copy all** | the whole page (`Ctrl+Enter`) |
| **↵ Wrap** | wrap long lines, or let them run off to the right — good for pasted tables |
| **Snippets *n*** | show or hide the rail |
| word count | words, lines and characters, live |

`Tab` indents rather than leaving the page — in a notepad it's a character, not
navigation. `Esc` goes back to the grid. Wrap and rail settings are remembered.
A whole visit is **one** edit and one undo, not one per keystroke.

### Never losing your work

There are two separate things keeping your work safe. They are not the same
thing, and the difference matters:

| | What it is | Survives |
|---|---|---|
| **Auto-save** | Every edit — flags, remarks, notes, rows, columns — is written to browser storage within 300ms, and the app **resumes automatically** next time you open it, with a banner saying when the copy was saved and how many edits are still unexported | Closing the tab, closing the browser, rebooting |
| **Export JSON** | Writes the actual `manifest.json` file. Still the canonical save | Anything — it's a real file on disk you can copy, back up and re-import |

Auto-save lives inside one browser profile. Clearing browsing data, a different
browser, or a different machine will not have it — so **export the JSON when you
finish a session.** The badge in the toolbar always tells you the truth:

| Badge | Means |
|---|---|
| `● Saved locally (14:32)` | The browser copy is current |
| `● Saving…` | A save is in flight |
| `● N edits to export` | Saved locally, but the JSON on disk is N edits behind |
| `● Saved to manifest.json (14:32)` | Linked to a real file, and that file is current |
| `● Auto-save unavailable` | The browser is refusing local storage. Nothing is being kept between sessions and exporting JSON is your only copy |

**↻ New Session** clears the browser copy and starts over. If there are edits
you never exported, the confirmation says how many will be lost rather than
calling it "session state".

**Link file** (next to the badge) closes the gap between the two. Click it, pick
your `manifest.json`, and from then on every change is written **straight into
that file on disk** — no exporting, and the badge reads *Saved to
manifest.json*. This uses the File System Access API, so it needs Chrome or
Edge, and it is often blocked on pages opened as `file://`. If that's your
machine, the button says so plainly and the browser copy carries on as normal.
Worth one click to find out.

### Undo

`Ctrl+Z`, 200 deep, and it covers everything that bumps the unexported-edits
counter: flags, number and text cells, remarks, state assignments, rows added,
deleted and reordered, notes and note cards, bulk marks, and columns renamed,
added, retyped and removed. If the counter counts it, undo can take it back —
otherwise the number would drift away from what is actually recoverable.

That is also why a bulk mark across 40 rows is **one** entry and **one** edit,
and why removing a column stores its cell values alongside the column definition:
putting the column back without its data wouldn't be an undo.

### Data integrity

- The imported object is edited **in place** and exported with
  `JSON.stringify`, so any key this app doesn't know about (including future
  Stage-1 additions) round-trips untouched.
- Unreadable values are the one exception, and it is now **type-aware**: a status
  flag that isn't yes/no/issue is reset, a number cell that can't be read as a
  number is emptied — but a number arriving as the string `"42.5"` becomes `42.5`
  rather than being thrown away, which is what a hand-edit or a spreadsheet paste
  produces. A banner tells you how many were actually reset. A column with no
  `type` is a yes/no/issue column, so every manifest written before typed columns
  existed opens unchanged.
- `schema_version` (currently `1`) is written into every manifest, by the script
  and by the app. A manifest stamped with a higher number still opens, with a
  banner saying it came from a newer version.
- The status bar shows **`N edits not exported`** until you export JSON, and the
  browser warns you if you try to close the tab while edits are pending.
- **The JSON file is the source of truth.** As a safety net the app also mirrors
  state into `localStorage` and restores it next time — don't rely on it; export
  the JSON.

---

## Stage 3 — `batch-status.ps1`

Put the downloaded numeric ZIPs in a separate batch folder, then run a dry run:

```bat
C:\Tools\run-batch-status.cmd -Path "C:\Work\Assignments\2026-08-11" -BatchPath "C:\Work\Batch Status" -WhatIf
```

If the summary is correct, run the same command without `-WhatIf`:

```bat
C:\Tools\run-batch-status.cmd -Path "C:\Work\Assignments\2026-08-11" -BatchPath "C:\Work\Batch Status"
```

For each numeric ZIP, the script looks only at file entries with one of these
exact extension shapes:

- `.xAA`, where `AA` is one of the 50 state codes or DC. For example,
  `P0376VY5.xal` is classified as Alabama.
- `.xml`, which is classified as federal.

Extensions containing a digit, including `.x75`, `.x7l`, and `.x8y`, are
ignored. The script does not open an inner attachments ZIP, and it never
rewrites the outer archive. A successful Alabama result looks like this:

```text
RETURN_2026_AL_01\
  original-return.pdf
  AL.zip                 (the unchanged bytes of 64099419.zip)
  P0376VY5.xml           (a copy of P0376VY5.xal from inside it)
```

The state destination is a unique immediate child folder whose name contains
that two-letter code. Federal uses a unique folder containing `FED` or
`Federal`; if its folder has another naming convention, pass its exact child
folder name:

```bat
C:\Tools\run-batch-status.cmd -Path "C:\Work\Assignments\2026-08-11" -BatchPath "C:\Work\Batch Status" -FederalFolder "Federal Return"
```

The script never overwrites. An unreadable ZIP, missing or multiple XML
classification files, unknown alphabetic `.xAA`, missing or multiple matching
return folders, nonnumeric outer ZIP name, an existing destination, or two
archives targeting the same destination is flagged. That source ZIP remains in
the batch folder. Every real run writes a timestamped
`batch-status-report-*.csv` there; exit code `2` means to read that report.

## Acceptance checks

### The app

Automated regression suite at `test/crm.test.js`, run with `npm test`. It drives
the real `index.html` through a real DOM (jsdom) — **53 tests**, covering import
and normalisation, the keyboard paths, adding / deleting / reordering rows, the
state cell, undo, the edit counter, `Esc` layering, the note-card sanitising, the
linked-file writer, a browser with storage switched off, the accessibility labels,
all three exports, and everything added since:

- typed columns — values stored as the right type, `Y` being a letter inside a
  text cell, column navigation still working in a number cell, numeric sorting
  with empties sinking both ways, qualified/% complete/not-started, type
  conversion and its warning, removing a custom column and being refused a
  built-in one, and typed columns through the CSV and the workbook
- selecting rows — plain click, `Shift`-click ranges, the header box's third
  state, selection surviving a re-sort, stale ids dropping out after a delete
- bulk marking — one column and every column, one undo for the lot, the
  focused-row-must-be-ticked rule, and the value box that replaces Yes/No/Issue
  for a data column
- the Notepad — the two surfaces staying in step, snippet splitting and copying,
  one edit per visit, opening from cold
- the shortcut sheet — `?` and `F1`, filtering, `Ctrl` vs `⌘`, `?` being a
  character while you're typing, and an assertion that `Alt+E`/`Alt+F`/`Alt+D` and
  the digit combinations are deliberately **not** bound
- the header no longer renaming a column, while the View menu still does
- the contract with `intake.ps1`, against a fixture that is real script output

**Every one of the new tests was checked by re-introducing the bug it covers and
confirming it fails** — 21 mutations in all, including counting every column in
the tally, letting typed cells fall through to the `Y`/`N`/`I` path, pushing one
undo per cell in a bulk mark, dropping the typing guard on bare-letter shortcuts,
keying the selection by row index, writing numbers as inline strings, putting the
header rename back, and dropping a manifest key on export. One assertion that
turned out to be unfalsifiable was rewritten until it wasn't.

jsdom is the only devDependency and it is only for the tests: the app itself is
still one file, no dependencies, no build step.

### `intake.ps1`

The no-dependency filename regression can be run on the target Windows machine:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\intake-state-detection.ps1
```

**Executed** against throwaway folders using **PowerShell 7.7.0-preview.3 on
macOS**. That is not the target runtime — **Windows PowerShell 5.1 on the work
machine is still untested**, so anything host-specific (`Start-Transcript`
capture, the `-Confirm` prompt wording, long paths, backslash separators, a PDF
locked open by a viewer) remains unverified. Everything in the table below was
actually run.

| Check | Status |
|---|---|
| Parses clean under the PowerShell parser | Verified — zero parse errors |
| Well-named PDFs + unreadable ones → a folder each, the bad ones flagged, valid manifest | Verified by running it |
| `CI6AIF_12.31.25_<STATE>_Return_E-File.pdf` names, including `NJ-CBT` and lowercase `E-file` | Covered end to end for MA, MN, MT, NJ, NY, OR, PA and SC by `test/intake-state-detection.ps1` |
| A name with no state code, and a name with two, are both flagged and never guessed | **Fixed earlier, re-verified.** `MASTER_FILE` → `no state code detected`, `NY-NJ-both` → `multiple state codes detected: NY, NJ` |
| Running `intake.ps1` twice does not duplicate folders or crash | Verified — the second run reports `already processed`, backs up the manifest, and carries forward status flags, remarks, a hand-assigned state and unknown keys |
| `-WhatIf` changes nothing | Verified — no folders, no manifest, no log file; the manifest is still rendered, so a dry run proves it builds |
| Stray top-level files prompt instead of hard-stopping | Verified — `.txt` tolerated silently |
| `state-overrides.json` beats detection | Verified — the override applied; an unknown code and a key matching no return were each warned about and ignored |
| `manifest.json` is UTF-8 with **no BOM** | Verified byte by byte — a BOM would make `JSON.parse` fail in the browser |
| **Custom and typed columns survive a script re-run** | Verified — `flags` (with every `type`), `col_labels`, `note_cards` and `quick_notes` all carried forward untouched, and a per-return unknown key (`some_future_key`, a nested object) with them |
| **A PDF filed on a later run gets the app's columns too** | **Fixed, then verified.** `New-StatusFlagSet` only ever wrote the eight built-in keys, so a return added after the app had made columns arrived with holes in it. It now reads the column set out of the existing manifest and gives each key the empty value its own type wants — `null` for a number, `""` for text |
| A manifest from *before* typed columns still works | Verified — `flags` entries with no `type` are treated as yes/no/issue by both halves |
| Numbers and text round-trip through the script unharmed | Verified — `1520.25`, `-300`, `Jane "JQ" Public, CPA`, and a value containing a newline and a tab all came back identical |

### `batch-status.ps1`

The no-dependency end-to-end test can be run on the target Windows machine:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\batch-status.ps1
```

It creates throwaway state and federal archives, verifies digit-bearing
extensions are ignored, confirms the moved ZIP's SHA-256 hash is unchanged,
checks the extracted XML content, exercises corrupt/missing/ambiguous/unknown
classification and destination errors, confirms same-run and existing-file
collisions cannot pick a winner, and verifies `-WhatIf` changes nothing.

Executed successfully with a temporary PowerShell 7.4.6 runtime on macOS. The
target runtime, Windows PowerShell 5.1 on the work machine, still needs a smoke
test before using real assignment files.

### The two halves together

Ran the full loop: `intake.ps1` → app (added a number column and a text column,
filled them, marked steps, wrote notes) → Export JSON → `intake.ps1` again with a
new PDF appearing → back into the app.

| Check | Status |
|---|---|
| Nothing is lost in either direction | Verified — see the two tables above |
| The app re-imports script output with no reset banner | Verified |
| Exported spreadsheet opens cleanly | Verified — valid ZIP, three sheets, **every entry's CRC32 checked against zlib**, **every XML part checked for well-formedness with a real parser**, real numeric dates, numeric data cells, styles, freeze pane and autofilter |
| The workbook's summary totals and averages are right | Verified — total `1220.25` and average `610.125` computed independently |
| CSV quotes awkward text and leaves numbers bare | Verified |

The frozen result of that loop is `test/fixtures/intake-manifest.json`, and two of
the 53 tests assert the app against it. Those tests catch the *app* drifting; they
cannot catch the script changing, so **if you change `intake.ps1`, regenerate the
fixture** by running it twice over a throwaway folder and re-running `npm test`.

**Still smoke-test `intake.ps1` on the work machine before a real assignment** —
run it against a throwaway folder of copied PDFs, under Windows PowerShell 5.1,
and start with `-WhatIf`.
