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

Double-click it, or drag it into a browser tab. No server, no CDN, no build.
Opening it with nothing loaded shows an import prompt, not an error.

1. **Import manifest.json** — pick the file the script wrote. Re-importing a
   file you previously exported works identically and continues where you left
   off.
2. **Work the table** — one row per return:
   `Return / ID` · `State` · `Date received` · the 8 status cells · `Remarks`.
   Each status cell is a dropdown: `—` (not started, grey), `Yes` (green),
   `No` (red), `Issue` (amber). Rows with an issue get an amber left edge,
   fully-qualified rows a green one.
3. **Export JSON** — downloads `manifest.json` with the current state. This is
   your save file; copy it back into the assignment folder.
   **Export CSV (Excel)** — downloads `returns-<date>.csv`, which Excel opens
   directly (UTF-8 BOM, CRLF, quoted fields). It exports **the rows currently
   visible**, so a filter applies to the export too. "Not started" cells are
   left blank in the CSV.

### Finding things

- Search box matches ID, filename, remarks and state.
- **State** filter, plus a `(no state assigned)` entry; clicking a state badge
  in a row filters to that state (click again to clear).
- **Show** filter: everything / has an issue / fully qualified / in progress /
  not started / needs state assignment.
- **Sort** by ID, state, date received, or issues-first; clicking the ID, State
  or Date column header sorts by it.
- **Group by state** inserts a heading row per state so same-state returns
  cluster.
- Summary bar across the top: returns, fully qualified, with an issue, not
  started, in progress, no state.

### Flagged returns

Returns the script couldn't assign a state to appear in the same table with an
amber **"Assign state…"** dropdown (all 51 codes) in place of the badge — fix
them here rather than editing JSON. A banner at the top counts them and can
filter the table down to just those. The original `flagged` array is preserved
on export; a return counts as resolved once it has a `state_code`.

### Data integrity

- The imported object is edited **in place** and exported with
  `JSON.stringify`, so any key this app doesn't know about (including future
  Stage-1 additions) round-trips untouched.
- Values it can't understand are the one exception: an unrecognised status flag
  or state code is reset to "not started" / no state, and a banner tells you how
  many were reset.
- **The JSON file is the source of truth.** As a safety net against an
  accidental tab close, the app also mirrors state into `localStorage` and
  offers to restore it next time you open the file — don't rely on it, export
  the JSON.

---

## Acceptance checks

| Check | Status |
|---|---|
| 12 well-named PDFs + 1 odd one → 12 clean folders, 1 flagged, valid manifest | Logic verified against the cases in §Stage 1; **not executed** — no PowerShell on the machine this was written on |
| Running `intake.ps1` twice does not duplicate folders or crash | Same — code path exists (existing-folder discovery + backup/merge), untested at runtime |
| `crm.html` with no file loaded shows an import prompt | Verified |
| Import → set flags + remark → export JSON → re-import preserves every value | Verified (byte-exact round-trip, including unknown keys, quotes, commas and newlines in remarks) |
| CSV opens cleanly in Excel with correct columns | Verified for quoting/BOM/CRLF generation |

**Please smoke-test `intake.ps1` on the work machine before a real
assignment** — run it on a throwaway folder of copied PDFs first. It was
written without a PowerShell runtime available to execute it.
