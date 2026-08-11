# Returns Intake & Tracking (MVP)

Two pieces, no dependencies:

| File | What it is | Where it runs |
|---|---|---|
| `intake.ps1` | Stage 1 — validates a folder of return PDFs, files each into its own folder, writes `manifest.json` | Windows PowerShell 5.1 (no modules, no admin) |
| `crm.html` | Stage 2 — single-file browser app to track the 8 qualifying steps per return | Any modern browser, opened directly (`file://`) |
| `sample-manifest.json` | 13-return test fixture (12 clean + 1 flagged) so you can try `crm.html` without running the script | — |

Stage 3 (splitting each return folder into Batch Status / GS XMLs / Recon Outputs / TFR) is **not** in this MVP.

---

## Stage 1 — `intake.ps1`

### Running it

Copy `intake.ps1` somewhere handy, then from the assignment folder:

```powershell
cd C:\Work\Assignments\2026-08-11
C:\Tools\intake.ps1
```

It always operates on the **current directory**. To point it elsewhere:

```powershell
C:\Tools\intake.ps1 -Path 'C:\Work\Assignments\2026-08-11'
C:\Tools\intake.ps1 -Force        # skip the Y/N prompt when files are flagged
```

If PowerShell blocks the script, unblock it once (no admin needed):

```powershell
Unblock-File C:\Tools\intake.ps1
powershell -ExecutionPolicy Bypass -File C:\Tools\intake.ps1
```

### What it does

1. **Validation, before touching anything.**
   - Hard stops (exit code 1) if the top level contains any file that isn't
     `.pdf`, `.json`, or `.ps1` — the offending files are listed. Folders and
     hidden/system files are ignored.
   - Detects a 2-letter state code in each name: the name is split on spaces,
     hyphens and underscores, and each run of letters inside those tokens is
     checked. A run counts only if it is **exactly two letters**, so
     `CTC-01_MD510` → `MD` and `FL123-GS` → `FL`, but `MASTER_FILE` matches
     nothing. All 50 states + DC are recognised.
   - Zero matches or more than one match ⇒ **flagged**, never guessed.
2. **Summary + confirmation.** Prints total / clean / flagged, and asks `Y/N`
   before proceeding if anything is flagged (exit code 2 if you answer no —
   nothing is changed).
3. **Filing.** For each PDF, creates a folder named exactly the filename minus
   `.pdf` and moves the PDF into it. Existing folders and files are never
   overwritten — those are reported as `[skip]`.
4. **Manifest.** Writes `manifest.json` in the assignment folder (UTF-8, no BOM,
   so the browser can parse it). Every return gets all 8 status flags set to
   `null`, plus `id`, `filename`, `folder`, `state_code`, `state_name`,
   `date_received`, `remarks`. Flagged returns still get a folder and a
   manifest entry (with `state_code: null`) and are also listed in the
   top-level `flagged` array.

Console output is colour-coded: green = done, yellow = flagged/skipped,
red = hard failure. It ends with e.g.
`Processed 13 returns, 1 flagged, manifest.json written.`

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

So the intended loop is: run the script → work in `crm.html` → **Export JSON**
→ save it back over `manifest.json` in the assignment folder. A later re-run
picks it up from there.

---

## Stage 2 — `crm.html`

Double-click it. No server, no CDN, no build step — one file, hand-written CSS
and JS. Opening it with nothing loaded shows an import prompt, not an error.

The screen is deliberately four things and nothing else: a toolbar, a filter
row, the grid, and a status line. Chrome is monochrome on purpose so the only
colour on screen is your data — green `✓` yes, red `✕` no, amber `!` issue,
grey `·` not started.

### The four actions

| Button | What it does |
|---|---|
| **Import** | Load a `manifest.json` (fresh from the script, or one you exported earlier) |
| **Manifest** | Slide-over panel: source folder, progress per step, breakdown by state, and which returns the intake script flagged (and whether you've since fixed them) |
| **Export Excel** | A real `.xlsx` workbook — see below |
| **Export JSON** | Your save file. `Ctrl/Cmd+S` does the same |
| **Export CSV** | Plain CSV, UTF-8 BOM + CRLF, for when you just want raw text |

Export Excel and Export CSV write **the rows currently visible**, so a filter
narrows the export too. Export JSON always writes everything.

### Working the grid — keyboard first

The status bar shows these at all times:

| Key | Action |
|---|---|
| `Tab` / `Shift+Tab` | **Next / previous return, same step.** Tab moves *down* a column, not across a row — you check attachments on every return, then move to the next step. At the bottom of a column it wraps to the top of the next one |
| `↑` `↓` | Same as Tab / Shift+Tab |
| `←` `→` | Move across steps within one return |
| `Y` `N` `I` | Mark yes / no / issue (`1` `2` `3` also work), then jump to the next return automatically |
| `0` `X` `Delete` | Back to not-started |
| `Space` | Cycle the cell without moving (`Shift+Space` cycles backwards) |
| `R` | Jump to that row's remarks; `Enter` or `Esc` returns to the grid |
| `Ctrl/Cmd+Z` | Undo — flags, remarks and state assignments, 200 deep |
| `Ctrl/Cmd+F` | Jump to the search box |
| `Ctrl/Cmd+S` | Export JSON |

Mouse still works: click a cell to cycle it forward, `Shift`-click to go back.
So marking a whole column is `Y Y Y Y…`, and one stray keypress is one `Cmd+Z`.

If you'd rather have an explicit dropdown in every cell, **View → Dropdown in
each cell** switches the whole grid over; keyboard navigation is identical.
**View → Advance to next return after marking** turns off the auto-jump.

### Columns

- **Drag any column divider** to resize. Double-click a divider to reset that
  column to its default width.
- **Collapse a column** to a 24px sliver with the `‹` button that appears in the
  header on hover — status cells become a coloured dot, still readable at a
  glance. Click `›` to expand it again. Good for `Received`, which you rarely
  need while working.
- **Hide it entirely** in the **View** menu, which lists every column with its
  current width, plus *Compact rows* and *Reset column widths*.
- Widths, collapsed and hidden columns, density, sort, grouping and the marking
  mode are all remembered between sessions (`localStorage`, UI only — never
  your data).
- Click a header to sort; click again to reverse. Sorting a status column puts
  `Issue` first, then `No`, `Yes`, not-started — so problems float up.

### Finding things

Search (ID, filename, remarks, state), a **state** filter, a **progress**
filter (has an issue / not finished / fully qualified / in progress / not
started / needs a state), and **Group by state** which inserts a heading row
per state with a count. Clicking a state badge in a row filters to that state;
clicking it again clears. The pills in the toolbar always show totals:
returns, qualified, issues, untouched, no-state, and overall % complete.

### Flagged returns

Returns the script couldn't read a state code from show an amber
**"Assign state…"** dropdown (all 51 codes) instead of a badge — fix them here,
not in the JSON. A banner counts them and can filter the grid to just those.
The original `flagged` array is preserved on export; the Manifest panel shows
each flagged file as `open` or `TX assigned`.

### About that `.xlsx`

**Yes — it exports a genuine `.xlsx`, not a CSV with a spreadsheet name.** An
`.xlsx` is a ZIP of XML parts, so `crm.html` writes the ZIP itself (stored
entries plus a hand-rolled CRC32) and emits the SpreadsheetML by hand. Still no
libraries, still one file. You get:

- Two sheets: **Returns** (one row per return) and **Summary** (totals,
  yes/no/issue/not-started per step, and a per-state breakdown).
- A bold dark header row, **frozen** so it stays put, with **autofilter**
  enabled on every column.
- Status cells colour-filled to match the app — green Yes, red No, amber Issue.
- `Received` as a **real Excel date** (`yyyy-mm-dd`), so date sorting and
  filtering behave, not text.
- Sensible column widths and wrapped remarks.

CSV export stays as a second option — it's the safer thing to paste into other
systems, and it's what to fall back on if a future Excel build ever objects to
the workbook.

### Data integrity

- The imported object is edited **in place** and exported with
  `JSON.stringify`, so any key this app doesn't know about (including future
  Stage-1 additions) round-trips untouched.
- Unreadable values are the one exception: an unrecognised status flag or state
  code is reset to not-started / no-state, and a banner tells you how many.
- The status bar shows **`N edits not exported`** until you export JSON, and the
  browser warns you if you try to close the tab while edits are pending.
- **The JSON file is the source of truth.** As a safety net the app also mirrors
  state into `localStorage` and offers to restore it next time — don't rely on
  it; export the JSON.

## Acceptance checks

`crm.html` has an automated test suite behind it — 92 assertions driven through
a real DOM (jsdom), covering import, every keyboard path, column
resize/collapse/hide, filters, sorting, undo, the manifest panel and all three
exports. The `.xlsx` it produces was opened and inspected with `openpyxl`.

| Check | Status |
|---|---|
| 12 well-named PDFs + 1 odd one → 12 clean folders, 1 flagged, valid manifest | Detection logic verified against 19 filename cases; **script not executed** — no PowerShell on the machine this was written on |
| Running `intake.ps1` twice does not duplicate folders or crash | Same — the code path exists (existing-folder discovery, backup, merge), untested at runtime |
| `crm.html` with no file loaded shows an import prompt | Verified |
| Import → set flags + remark → export JSON → re-import preserves every value | Verified — byte-identical round-trip, including unknown keys, quotes, commas and newlines in remarks |
| Exported spreadsheet opens cleanly with correct columns | Verified — valid ZIP, both sheets, real dates, styles, freeze pane and autofilter all read back correctly; CSV verified for BOM/CRLF/quoting |

**Please smoke-test `intake.ps1` on the work machine before a real
assignment** — run it against a throwaway folder of copied PDFs first. It was
written without a PowerShell runtime available to execute it.
