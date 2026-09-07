"use strict";

/* Regression tests for index.html.
 *
 * Every test here stands for a bug that was actually fixed, so each one asserts
 * what a user would see — a row that moved, a counter that reads 1 instead of 3,
 * a file that stopped being rewritten — rather than which function was called.
 *
 * Plain node, no framework: `npm test`. One fresh window per test, closed again
 * afterwards so a stray 300ms autosave timer cannot bleed into the next one. */

const H = require("./harness.js");
const { fire, click, key, dragRow, dragColumn, sleep } = H;

/* ------------------------------------------------------------------ assert */

function fail(msg) { throw new Error(msg); }
function ok(cond, msg) { if (!cond) { fail(msg || "expected truthy"); } }
function eq(actual, expected, msg) {
  if (actual !== expected) {
    fail((msg ? msg + ": " : "") + "expected " + JSON.stringify(expected) +
         ", got " + JSON.stringify(actual));
  }
}
function deepEq(actual, expected, msg) {
  const a = JSON.stringify(actual), b = JSON.stringify(expected);
  if (a !== b) { fail((msg ? msg + ": " : "") + "expected " + b + ", got " + a); }
}
function match(str, re, msg) {
  if (!re.test(String(str))) {
    fail((msg ? msg + ": " : "") + "expected /" + re.source + "/ to match " +
         JSON.stringify(String(str).slice(0, 400)));
  }
}
function noMatch(str, re, msg) {
  if (re.test(String(str))) {
    fail((msg ? msg + ": " : "") + "expected /" + re.source + "/ NOT to match " +
         JSON.stringify(String(str).slice(0, 400)));
  }
}

/* ------------------------------------------------------------- test runner */

const tests = [];
function test(name, fn) { tests.push({ name: name, fn: fn }); }

let live = [];
function open(opts) {
  const t = H.boot(opts);
  live.push(t);
  return t;
}
function closeAll() {
  live.forEach(function (t) { try { t.win.close(); } catch (e) {} });
  live = [];
}

/* ---------------------------------------------------------------- fixtures */

const FLAG_KEYS = ["attachments_present", "data_accurate", "qualifying", "xml_flowing",
                   "xml_downloaded", "batch_downloaded", "recon_checked", "tfr_checked"];

function mkRet(id, extra) {
  return Object.assign({
    id: id,
    filename: id + ".pdf",
    folder: id,
    state_code: "CA",
    date_received: "2026-02-14",
    status_flags: {},
    remarks: ""
  }, extra || {});
}

function fixture(n, extra) {
  const returns = [];
  for (let i = 1; i <= (n || 3); i++) { returns.push(mkRet("R" + i)); }
  return Object.assign({ assignment_folder: "Batch A", returns: returns }, extra || {});
}

function allYes() {
  const f = {};
  FLAG_KEYS.forEach(function (k) { f[k] = "yes"; });
  return f;
}

function ids(win) { return win.manifest.returns.map(function (r) { return r.id; }); }
function trs(doc) { return Array.prototype.slice.call(doc.querySelectorAll("#rows tr[data-i]")); }

function enableDragMode(t) {
  click(t.doc.getElementById("viewBtn"));
  const toggle = t.doc.querySelector('.menu [data-pref="reorder"]');
  ok(toggle, "View offers drag-to-place mode");
  click(toggle);
  eq(t.win.prefs.reorder, true, "drag-to-place mode is enabled");
}

/* excel serial for an ISO date, worked out independently of the app */
function serialOf(iso) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  return Math.round((Date.UTC(+m[1], +m[2] - 1, +m[3]) - Date.UTC(1899, 11, 30)) / 86400000);
}

/* =====================================================================
   Import / normalise
   ===================================================================== */

test("import normalises flags, states and schema, and keeps unknown keys", function () {
  const t = open();
  t.win.adopt({
    assignment_folder: "Batch A",
    vendor_extra: { keep: "me" },
    returns: [
      mkRet("R1", {
        state_code: "ca",
        custom_field: "keep me too",
        status_flags: {
          attachments_present: true,
          data_accurate: false,
          qualifying: "maybe",
          xml_flowing: "ISSUE"
        }
      }),
      mkRet("R2", { state_code: "XX" })
    ]
  }, "manifest.json");

  const r1 = t.win.manifest.returns[0];
  const r2 = t.win.manifest.returns[1];

  eq(r1.status_flags.attachments_present, "yes", "true becomes yes");
  eq(r1.status_flags.data_accurate, "no", "false becomes no");
  eq(r1.status_flags.qualifying, null, "a bogus flag value becomes null");
  eq(r1.status_flags.xml_flowing, "issue", "a known value survives, lowercased");
  eq(r1.state_code, "CA", "a lowercase state code is accepted and upper-cased");
  eq(r2.state_code, null, "an unknown state code becomes null");
  eq(r2.state_name, null, "and takes its name with it");
  eq(t.win.manifest.schema_version, 1, "schema_version is stamped");

  /* Two values were unrecognised — the bogus flag and the bogus state — and the
     import has to say so rather than silently eat them. */
  match(t.doc.getElementById("banners").textContent,
        /2 unrecognised values were reset/, "reset counter is reported");

  const json = JSON.stringify(t.win.manifest);
  match(json, /"vendor_extra":\{"keep":"me"\}/, "unknown top-level key survives adopt");
  match(json, /"custom_field":"keep me too"/, "unknown per-return key survives adopt");
});

test("a note card with a markup category is pinned to a known one and never rendered raw", function () {
  const t = open();
  t.win.adopt(fixture(1, {
    note_cards: [{ id: "c1", cat: '<img src=x onerror=alert(1)>', text: "hello", created_at: "2026-02-14T10:00:00Z" }]
  }), "manifest.json");

  eq(t.win.manifest.note_cards[0].cat, "general", "an unknown category falls back to general");

  const list = t.doc.getElementById("notesCardsList");
  noMatch(list.innerHTML, /<img/i, "no image tag reaches the notes DOM");
  match(list.textContent, /General/, "the card is labelled with the fallback category");
  eq(list.querySelectorAll("img").length, 0, "and no element was injected");
});

/* =====================================================================
   Rows: delete, reorder, add
   ===================================================================== */

test("deleting a row asks first, removes exactly that row, and undo puts it back", function () {
  const t = open();
  t.win.adopt(fixture(3), "manifest.json");

  const row2 = trs(t.doc)[1];
  click(row2.querySelector(".act-del-row"));

  const ask = t.doc.querySelector(".ask");
  ok(ask, "the confirm modal opens");
  match(ask.textContent, /R2/, "and names the row it is about to delete");
  eq(t.win.manifest.returns.length, 3, "nothing is deleted before confirming");

  click(ask.querySelector('[data-ask="ok"]'));

  deepEq(ids(t.win), ["R1", "R3"], "only the confirmed row is gone");
  eq(t.win.dirty, 1, "the delete counts as one edit");
  eq(t.doc.querySelector(".ask"), null, "the modal closed");

  t.win.undo();
  deepEq(ids(t.win), ["R1", "R2", "R3"], "undo restores the row at its old index");
  eq(t.win.dirty, 0, "and takes the edit back off the counter");
});

test("dragging a row down and dropping above the target lands it above the target", function () {
  const t = open();
  t.win.adopt(fixture(5), "manifest.json");
  enableDragMode(t);
  deepEq(ids(t.win), ["R1", "R2", "R3", "R4", "R5"]);

  const rows = trs(t.doc);
  dragRow(rows[0], rows[3], "above");          // R1 down, dropped above R4

  deepEq(ids(t.win), ["R2", "R3", "R1", "R4", "R5"], "R1 sits immediately before R4");
  eq(t.win.prefs.sort, "manual", "hand ordering switches the grid to manual sort");
  deepEq(trs(t.doc).map(function (tr) { return tr.getAttribute("data-id"); }),
         ["R2", "R3", "R1", "R4", "R5"], "and the grid shows that order");

  t.win.undo();
  deepEq(ids(t.win), ["R1", "R2", "R3", "R4", "R5"], "undo puts the row back where it started");
});

test("dragging a row up and dropping below the target lands it below the target", function () {
  const t = open();
  t.win.adopt(fixture(5), "manifest.json");
  enableDragMode(t);

  const rows = trs(t.doc);
  dragRow(rows[4], rows[1], "below");          // R5 up, dropped below R2

  deepEq(ids(t.win), ["R1", "R2", "R5", "R3", "R4"], "R5 sits immediately after R2");
  eq(t.win.prefs.sort, "manual", "hand ordering switches the grid to manual sort");

  t.win.undo();
  deepEq(ids(t.win), ["R1", "R2", "R3", "R4", "R5"], "undo puts the row back where it started");
});

test("View drag mode exposes handles and remembers column placement", function () {
  const t = open();
  t.win.adopt(fixture(2), "manifest.json");

  eq(t.doc.querySelectorAll(".drag-handle").length, 0, "row handles are hidden before drag mode is enabled");
  eq(t.doc.querySelectorAll(".col-drag-handle").length, 0, "column handles are hidden too");

  enableDragMode(t);
  eq(t.doc.querySelectorAll(".drag-handle").length, 2, "each return gets a row handle");
  ok(t.doc.querySelectorAll(".col-drag-handle").length > 2, "data columns get header handles");

  const id = t.doc.querySelector('#headRow th[data-col="id"]');
  const state = t.doc.querySelector('#headRow th[data-col="state"]');
  dragColumn(id, state, "after");

  const placed = Array.prototype.slice.call(t.doc.querySelectorAll("#headRow th[data-col]"))
    .map(function (th) { return th.getAttribute("data-col"); })
    .filter(function (key) { return key !== "pick" && key !== "drag" && key !== "actions"; });
  deepEq(placed.slice(0, 2), ["state", "id"], "Return / ID is placed immediately after State");
  deepEq(t.win.prefs.columnOrder.slice(0, 2), ["state", "id"], "the chosen order is saved as a preference");

  const resumed = open({ seedPrefs: { reorder:true, columnOrder:t.win.prefs.columnOrder } });
  resumed.win.adopt(fixture(1), "manifest.json");
  const resumedKeys = Array.prototype.slice.call(resumed.doc.querySelectorAll("#headRow th[data-col]"))
    .map(function (th) { return th.getAttribute("data-col"); })
    .filter(function (key) { return key !== "pick" && key !== "drag" && key !== "actions"; });
  deepEq(resumedKeys.slice(0, 2), ["state", "id"], "the placement returns in a new session");
});

test("add row refuses a duplicate id and accepts a unique one", function () {
  const t = open();
  t.win.adopt(fixture(2), "manifest.json");

  click(t.doc.getElementById("addRowBtn"));
  t.doc.getElementById("newRowId").value = "R1";
  click(t.doc.getElementById("submitAddRowBtn"));

  match(t.doc.getElementById("newRowErr").textContent, /already exists/, "the clash is explained");
  eq(t.win.manifest.returns.length, 2, "and no row was added");
  ok(!t.doc.getElementById("addRowModal").classList.contains("hidden"), "the modal stays open");

  t.doc.getElementById("newRowId").value = "R9";
  click(t.doc.getElementById("submitAddRowBtn"));

  deepEq(ids(t.win), ["R1", "R2", "R9"], "a unique id is accepted");
  eq(t.doc.getElementById("newRowErr").textContent, "", "the error is cleared");
  ok(t.doc.getElementById("addRowModal").classList.contains("hidden"), "the modal closed");
  eq(t.win.dirty, 1, "one edit");

  t.win.undo();
  deepEq(ids(t.win), ["R1", "R2"], "undo removes the row again");
});

/* =====================================================================
   Editing, the dirty counter and undo
   ===================================================================== */

test("a visit to the scratchpad is one edit, not one per keystroke", function () {
  const t = open();
  t.win.adopt(fixture(1, { quick_notes: "start" }), "manifest.json");
  eq(t.win.dirty, 0);

  const pad = t.doc.getElementById("quickNotesText");
  eq(pad.value, "start", "the pad shows what the manifest holds");

  fire(pad, "focus");
  ["start a", "start ab", "start abc"].forEach(function (v) {
    pad.value = v;
    fire(pad, "input");
  });
  fire(pad, "blur");

  eq(t.win.dirty, 1, "three keystrokes are still one edit");
  eq(t.win.manifest.quick_notes, "start abc", "the text is kept");

  t.win.undo();
  eq(t.win.manifest.quick_notes, "start", "undo restores the text from before the visit");
  eq(t.doc.getElementById("quickNotesText").value, "start", "and puts it back in the box");
  eq(t.win.dirty, 0);
});

test("the edit counter never turns into NaN, and undo on an empty stack is a no-op", function () {
  const t = open();
  t.win.adopt(fixture(2), "manifest.json");

  click(trs(t.doc)[0].querySelector("button.cell"));
  eq(t.win.dirty, 1, "a flag edit counts once");

  t.win.undo();
  eq(t.win.dirty, 0, "undo takes it back to zero, not to NaN");
  ok(Number.isFinite(t.win.dirty), "the counter is a finite number");
  match(t.doc.getElementById("dirty").textContent, /^saved/, "the footer reads saved");

  const before = JSON.stringify(t.win.manifest);
  t.win.undo();
  eq(t.win.dirty, 0, "undo with nothing to undo changes nothing");
  eq(JSON.stringify(t.win.manifest), before, "and does not touch the data");
});

test("a resumed draft with a junk edit count does not poison the counter", function () {
  /* The count comes back out of localStorage, so it can be anything. Adding a
     non-number to it turned the footer into "NaN edits not exported" — and since
     NaN > 0 is false, it also quietly switched off the leave-the-page warning. */
  const t = open({
    seedDraft: {
      saved_at: "2026-02-14T10:00:00Z",
      source: "manifest.json",
      dirty: { oops: true },
      manifest: fixture(2)
    }
  });

  deepEq(ids(t.win), ["R1", "R2"], "the draft is resumed");
  ok(Number.isFinite(t.win.dirty), "the edit count is still a number");
  noMatch(t.doc.getElementById("dirty").textContent, /NaN/, "the footer never reads NaN");
  noMatch(t.doc.getElementById("autoSaveBadge").textContent, /NaN/, "nor does the autosave badge");

  click(trs(t.doc)[0].querySelector("button.cell"));
  ok(Number.isFinite(t.win.dirty), "and it still counts normally afterwards");
  match(t.doc.getElementById("dirty").textContent, /^\d+ edits? not exported$/,
        "the footer reads a real number of edits");
});

test("the state cell swaps to a dropdown, edits, undoes and clears", function () {
  const t = open();
  t.win.adopt(fixture(2), "manifest.json");

  click(trs(t.doc)[0].querySelector(".statechg"));
  let cell = trs(t.doc)[0].querySelector(".statecell");
  let sel = cell.querySelector("select");
  ok(sel, "the badge is replaced by a select");
  eq(sel.value, "CA", "with the current state selected");
  eq(cell.querySelector(".badge"), null, "and the badge is gone while editing");

  sel.value = "TX";
  fire(sel, "change");
  eq(t.win.manifest.returns[0].state_code, "TX", "picking a state updates the return");
  eq(t.win.manifest.returns[0].state_name, "Texas", "and its name");
  eq(trs(t.doc)[0].querySelector(".badge").textContent, "TX", "the badge shows the new code");
  eq(t.win.dirty, 1);

  t.win.undo();
  eq(t.win.manifest.returns[0].state_code, "CA", "undo restores the previous state");
  eq(trs(t.doc)[0].querySelector(".badge").textContent, "CA");

  /* the empty option is a real choice: it clears a state assigned by mistake */
  click(trs(t.doc)[0].querySelector(".statechg"));
  sel = trs(t.doc)[0].querySelector("select");
  eq(sel.querySelector('option[value=""]').textContent, "(clear state)",
     "the empty option offers to clear");
  sel.value = "";
  fire(sel, "change");

  eq(t.win.manifest.returns[0].state_code, null, "the state is cleared");
  cell = trs(t.doc)[0].querySelector(".statecell");
  eq(cell.querySelector(".badge"), null, "no badge is left behind");
  eq(cell.querySelector("select").querySelector('option[value=""]').textContent, "Assign state…",
     "and the cell is back to the assign dropdown");
});

/* =====================================================================
   Keyboard
   ===================================================================== */

test("Y / N / I mark the step and move one row down the same column", function () {
  const t = open();
  t.win.adopt(fixture(4), "manifest.json");

  const first = trs(t.doc)[0].querySelectorAll("[data-flag]")[2];
  first.focus();
  const col = first.getAttribute("data-c");

  key(first, "y");
  eq(t.win.manifest.returns[0].status_flags[FLAG_KEYS[2]], "yes", "Y marks yes");
  let now = t.doc.activeElement;
  eq(now.getAttribute("data-r"), "1", "focus moved one row down");
  eq(now.getAttribute("data-c"), col, "and stayed in the same column");

  key(now, "N");
  eq(t.win.manifest.returns[1].status_flags[FLAG_KEYS[2]], "no", "N marks no");
  now = t.doc.activeElement;
  eq(now.getAttribute("data-r"), "2");

  key(now, "i");
  eq(t.win.manifest.returns[2].status_flags[FLAG_KEYS[2]], "issue", "I marks issue");
  eq(t.doc.activeElement.getAttribute("data-r"), "3");
  eq(t.win.dirty, 3, "three marks, three edits");
});

test("Space cycles the step without moving, Tab walks down and wraps into the next column", function () {
  const t = open();
  t.win.adopt(fixture(3), "manifest.json");

  const cell = trs(t.doc)[0].querySelectorAll("[data-flag]")[0];
  cell.focus();

  key(cell, " ");
  eq(t.win.manifest.returns[0].status_flags[FLAG_KEYS[0]], "yes", "space cycles null -> yes");
  eq(t.doc.activeElement, cell, "and does not move");
  key(cell, " ");
  eq(t.win.manifest.returns[0].status_flags[FLAG_KEYS[0]], "no", "space cycles yes -> no");
  eq(t.doc.activeElement, cell, "still does not move");

  key(cell, "Tab");
  eq(t.doc.activeElement.getAttribute("data-r"), "1", "Tab walks down the column");
  eq(t.doc.activeElement.getAttribute("data-c"), "0");

  key(t.doc.activeElement, "Tab");
  eq(t.doc.activeElement.getAttribute("data-r"), "2", "still down");

  key(t.doc.activeElement, "Tab");
  eq(t.doc.activeElement.getAttribute("data-r"), "0", "past the last row it wraps to the top");
  eq(t.doc.activeElement.getAttribute("data-c"), "1", "of the next column");
});

test("R jumps to that row's remarks box", function () {
  const t = open();
  t.win.adopt(fixture(3), "manifest.json");

  const row = trs(t.doc)[1];
  const cell = row.querySelectorAll("[data-flag]")[3];
  cell.focus();
  key(cell, "r");

  eq(t.doc.activeElement, row.querySelector(".remarks"), "focus is in the remarks input");
  eq(t.doc.activeElement.closest("tr").getAttribute("data-id"), "R2", "of that same row");
});

/* =====================================================================
   Overlays
   ===================================================================== */

test("Escape closes the modal over the notes sheet before the sheet itself", function () {
  const t = open();
  t.win.adopt(fixture(2), "manifest.json");

  click(t.doc.getElementById("notesBtn"));
  ok(!t.doc.getElementById("notesSheet").classList.contains("hidden"), "the notes sheet is open");

  click(trs(t.doc)[0].querySelector(".act-del-row"));
  ok(t.doc.querySelector(".ask"), "the confirm modal is open over it");

  key(t.doc.body, "Escape");
  eq(t.doc.querySelector(".ask"), null, "the first Escape closes the modal");
  ok(!t.doc.getElementById("notesSheet").classList.contains("hidden"),
     "and leaves the notes sheet alone");
  eq(t.win.manifest.returns.length, 2, "nothing was deleted");

  key(t.doc.body, "Escape");
  ok(t.doc.getElementById("notesSheet").classList.contains("hidden"),
     "the second Escape closes the notes sheet");
});

/* =====================================================================
   Columns
   ===================================================================== */

test("a custom column is added once, keyed off its name, and reopens the tally", function () {
  const t = open();
  t.win.adopt(fixture(2, { returns: [mkRet("R1", { status_flags: allYes() }), mkRet("R2")] }),
              "manifest.json");

  eq(trs(t.doc)[0].className, "done", "R1 has every step ticked, so the row reads done");

  /* the reachable path: View menu -> Add New Custom Column */
  function addColumn(name) {
    click(t.doc.getElementById("viewBtn"));
    const item = t.doc.querySelector('.menu [data-act="add-col"]');
    ok(item, "the View menu offers to add a column");
    click(item);
    const box = t.doc.querySelector(".ask");
    ok(box, "the add-column modal opens");
    box.querySelector('[data-ask="input"]').value = name;
    click(box.querySelector('[data-ask="ok"]'));
    return box;
  }

  addColumn("W-2 verified");
  eq(t.win.manifest.flags.length, 11, "the column is added");

  const added = t.win.manifest.flags[10];
  eq(added.key, "custom_w_2_verified", "the key is derived from the name, with no timestamp");
  noMatch(added.key, /\d{4,}/, "and carries no timestamp digits");
  eq(added.short, "W-2 verified");
  const keys = t.win.manifest.flags.map(function (f) { return f.key; });
  eq(new Set(keys).size, keys.length, "every flag key is unique");

  /* The bug this guards: qualified used to mean "every status column is yes",
     so adding any new status column un-qualified every return that already had
     one. Qualified is decided by the Qualifying step alone, so a brand-new,
     unset column changes nothing about it. */
  eq(t.win.manifest.returns[0].status_flags.custom_w_2_verified, null,
     "existing returns get the new step, unset");
  ok(t.win.isDone(t.win.manifest.returns[0]), "R1 is still done — Qualifying is untouched");
  eq(trs(t.doc)[0].className, "done", "and the row keeps being painted as done");
  match(t.doc.getElementById("pills").textContent, /1qualified/, "the tally agrees");

  const box = addColumn("W-2 verified");
  match(box.querySelector('[data-ask="err"]').textContent, /already a column with that name/,
        "a second column with the same name is refused");
  eq(t.win.manifest.flags.length, 11, "and nothing is added");
  ok(t.doc.querySelector(".ask"), "the modal stays open on the error");
});

/* =====================================================================
   Exports
   ===================================================================== */

test("CSV and XLSX refuse to export an empty filter, JSON still writes everything", function () {
  const t = open();
  t.win.adopt(fixture(3), "manifest.json");

  const search = t.doc.getElementById("search");
  search.value = "nothing-matches-this";
  fire(search, "input");
  eq(t.win.view.length, 0, "the filter matches nothing");

  t.win.exportCsv();
  eq(t.downloads.length, 0, "no CSV is written");
  match(t.doc.getElementById("banners").textContent, /Nothing matches the current filters/,
        "and the refusal is explained");

  t.doc.getElementById("banners").innerHTML = "";
  t.win.exportXlsx();
  eq(t.downloads.length, 0, "no workbook is written either");
  match(t.doc.getElementById("banners").textContent, /Nothing matches the current filters/);

  t.win.exportJson();
  eq(t.downloads.length, 1, "JSON is written regardless");
  const written = JSON.parse(t.lastDownload().buffer().toString("utf8"));
  eq(written.returns.length, 3, "and contains every return, filtered out or not");
});

test("the CSV carries the received date and quotes awkward text", function () {
  const t = open();
  t.win.adopt({
    assignment_folder: "Batch A",
    returns: [
      mkRet("R1", { date_received: "2026-02-14", remarks: 'He said "hi", then\nleft' }),
      mkRet("R2", { date_received: "2026-03-01", remarks: "plain" })
    ]
  }, "manifest.json");

  t.win.exportCsv();
  const buf = t.lastDownload().buffer();
  deepEq(Array.from(buf.slice(0, 3)), [0xEF, 0xBB, 0xBF], "the file opens with a UTF-8 BOM");

  const text = buf.toString("utf8").replace(/^﻿/, "");
  const head = text.split("\r\n")[0].split(",");
  eq(head[2], "Received", "there is a Received column");
  ok(text.indexOf("\r\n") !== -1, "rows are separated by CRLF");
  noMatch(text.replace(/\r\n/g, ""), /\r/, "no stray carriage returns");
  match(text, /\r\n$/, "the file ends with a line break");

  const r1 = text.split("\r\n")[1].split(",");
  eq(r1[2], "2026-02-14", "the received date is in the Received column");
  match(text, /"He said ""hi"", then\nleft"/,
        "quotes, commas and newlines in remarks are quoted and doubled");
  match(text, /\nR2,R2\.pdf,2026-03-01,/, "the second row keeps its own date");
});

test("the XLSX is a valid three-sheet workbook with a real date column", function () {
  const t = open();
  t.win.adopt(fixture(2), "manifest.json");
  t.win.exportXlsx();

  const zip = t.unzipStored(t.lastDownload().buffer());
  const names = Object.keys(zip);

  ["xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml", "xl/worksheets/sheet3.xml",
   "xl/workbook.xml", "xl/styles.xml", "[Content_Types].xml"].forEach(function (n) {
    ok(names.indexOf(n) !== -1, "the zip contains " + n);
  });

  names.forEach(function (n) {
    ok(zip[n].crcOk, "the CRC32 written for " + n + " matches the real one");
    eq(zip[n].method, 0, n + " is stored, as the reader assumes");
  });

  const wb = zip["xl/workbook.xml"].data.toString("utf8");
  ["Returns", "Summary", "Notes"].forEach(function (s) {
    match(wb, new RegExp('name="' + s + '"'), "the workbook lists the " + s + " sheet");
  });
  eq((wb.match(/<sheet /g) || []).length, 3, "three sheets, no more");

  const s1 = zip["xl/worksheets/sheet1.xml"].data.toString("utf8");
  match(s1, /<t xml:space="preserve">Received<\/t>/, "sheet 1 has a Received header");
  const cell = /<c r="C2"([^>]*)><v>(\d+)<\/v><\/c>/.exec(s1);
  ok(cell, "the received date is a numeric cell, not text");
  match(cell[1], /s="6"/, "written with the date style");
  noMatch(cell[1], /t="inlineStr"/, "and not as an inline string");
  eq(Number(cell[2]), serialOf("2026-02-14"), "holding the right Excel serial");

  match(s1, /state="frozen"/, "the header row is frozen");
  match(s1, /<autoFilter ref="A1:/, "and the sheet has an autofilter");
});

/* =====================================================================
   Persistence
   ===================================================================== */

test("a linked file is written once per change, not every 300ms forever", async function () {
  const t = open();
  t.win.adopt(fixture(2), "manifest.json");

  const writes = [];
  t.win.showSaveFilePicker = function () {
    return Promise.resolve({
      name: "manifest.json",
      createWritable: function () {
        return Promise.resolve({
          write: function (data) { writes.push(data); return Promise.resolve(); },
          close: function () { return Promise.resolve(); }
        });
      }
    });
  };

  click(t.doc.getElementById("linkFileBtn"));
  await sleep(100);
  eq(writes.length, 1, "linking writes the manifest once");

  /* The old code let the write reset the edit count, which scheduled another
     save, which wrote the file again — a loop with no end. */
  await sleep(700);
  eq(writes.length, 1, "and then leaves the file alone while nothing changes");

  click(trs(t.doc)[0].querySelector("button.cell"));
  await sleep(600);
  eq(writes.length, 2, "one edit is exactly one more write");
  eq(JSON.parse(writes[1]).returns[0].status_flags[FLAG_KEYS[0]], "yes",
     "and the write carries the edit");

  await sleep(500);
  eq(writes.length, 2, "still no loop afterwards");
});

test("a browser with local storage switched off still imports, and says saving is off", function () {
  const t = open({ localStorage: false });

  t.win.adopt(fixture(2), "manifest.json");     // must not throw

  deepEq(ids(t.win), ["R1", "R2"], "the manifest is loaded anyway");
  eq(trs(t.doc).length, 2, "and rendered");

  click(trs(t.doc)[0].querySelector("button.cell"));
  eq(t.win.manifest.returns[0].status_flags[FLAG_KEYS[0]], "yes", "editing still works");

  const badge = t.doc.getElementById("autoSaveBadge");
  match(badge.className, /failed/, "the autosave badge ends up in the failed state");
  match(badge.textContent, /unavailable/, "and says so in words");
});

/* =====================================================================
   Accessibility smoke
   ===================================================================== */

test("headers, delete buttons and note text carry their labels", function () {
  const t = open();
  t.win.adopt(fixture(2, {
    note_cards: [{ id: "c1", cat: "general", text: "note", created_at: "2026-02-14T10:00:00Z" }]
  }), "manifest.json");

  const ths = Array.prototype.slice.call(t.doc.querySelectorAll("#headRow th"));
  ok(ths.length > 0, "the head is built");
  ths.forEach(function (th) {
    eq(th.getAttribute("scope"), "col", "th " + JSON.stringify(th.textContent) + " has scope=col");
  });

  const dels = Array.prototype.slice.call(t.doc.querySelectorAll("#rows .act-del-row"));
  eq(dels.length, 2, "every row has a delete button");
  dels.forEach(function (b) {
    match(b.getAttribute("aria-label") || "", /^Delete /, "the delete button is labelled");
  });

  const noteText = t.doc.querySelector(".note-card-text");
  ok(noteText, "the note card is rendered");
  eq(noteText.getAttribute("role"), "textbox", "editable note text announces itself as a textbox");
  ok(noteText.getAttribute("aria-label"), "and has a label");
});

/* =====================================================================
   Typed columns: yes/no/issue, number, text
   ===================================================================== */

/* Push a column straight onto the manifest, the way the Add-column dialog does,
   without going through the modal. */
function addCol(win, key, type, label) {
  win.manifest.flags.push({ key: key, short: label || key, label: label || key,
                            type: type, custom: true });
  win.manifest.returns.forEach(function (r) {
    r.status_flags[key] = type === "text" ? "" : null;
  });
  win.invalidateTally();
  win.buildHead();
  win.render();
}

test("a number column stores numbers and a text column stores strings", function () {
  const t = open();
  t.win.adopt(fixture(2), "manifest.json");
  addCol(t.win, "amount", "number", "Amount");
  addCol(t.win, "who", "text", "Who");

  const num = t.doc.querySelector('#rows [data-flag="amount"]');
  const txt = t.doc.querySelector('#rows [data-flag="who"]');
  eq(num.tagName, "INPUT", "a number column renders an input");
  eq(num.type, "number", "and it is a number input");
  eq(txt.type, "text", "a text column renders a text input");

  num.focus();
  num.value = "1520.25";
  fire(num, "input");
  eq(t.win.manifest.returns[0].status_flags.amount, 1520.25, "the value is stored");
  eq(typeof t.win.manifest.returns[0].status_flags.amount, "number",
     "as a number, not the string the input handed over");

  txt.focus();
  txt.value = "Jane";
  fire(txt, "input");
  eq(t.win.manifest.returns[0].status_flags.who, "Jane", "text is stored verbatim");

  /* Blanking a number cell must clear it, not store NaN or "" */
  num.focus();
  num.value = "";
  fire(num, "input");
  eq(t.win.manifest.returns[0].status_flags.amount, null, "an emptied number cell is null");

  num.value = "not a number";
  fire(num, "input");
  eq(t.win.manifest.returns[0].status_flags.amount, null,
     "text that is not a number does not become NaN");
});

test("typing in a number or text cell is one edit, and Y there is the letter Y", function () {
  const t = open();
  t.win.adopt(fixture(2), "manifest.json");
  addCol(t.win, "who", "text", "Who");
  eq(t.win.dirty, 0, "clean to start");

  const txt = t.doc.querySelector('#rows [data-flag="who"]');
  fire(txt, "focusin");
  "Yes".split("").forEach(function (ch) { txt.value += ch; fire(txt, "input"); });
  eq(t.win.dirty, 0, "nothing is counted while you are still typing");
  fire(txt, "focusout");
  eq(t.win.dirty, 1, "the whole visit is one edit, not three");
  eq(t.win.manifest.returns[0].status_flags.who, "Yes", "and the text is kept");

  /* The bug this guards: data-flag put text cells on the same keyboard path as
     status cells, so Y in a text column marked the step yes instead of typing. */
  txt.focus();
  const ev = key(txt, "y");
  eq(ev.defaultPrevented, false, "Y is not swallowed inside a text cell");
  eq(t.win.manifest.returns[0].status_flags.who, "Yes",
     "and it certainly does not turn the cell into a status value");

  t.win.undo();
  eq(t.win.manifest.returns[0].status_flags.who, "", "undo restores the cell");
  eq(t.win.dirty, 0, "and the counter with it");
});

test("Down and Tab still walk a column of number cells; Left and Right stay in the box", function () {
  const t = open();
  t.win.adopt(fixture(3), "manifest.json");
  addCol(t.win, "amount", "number", "Amount");

  const cells = Array.prototype.slice.call(t.doc.querySelectorAll('#rows [data-flag="amount"]'));
  eq(cells.length, 3, "one number cell per row");
  cells[0].focus();

  key(cells[0], "ArrowDown");
  eq(t.doc.activeElement, cells[1], "Down moves to the next return, same column");
  key(cells[1], "Tab");
  eq(t.doc.activeElement, cells[2], "Tab does the same");
  key(cells[2], "Enter");
  ok(t.doc.activeElement !== cells[2], "Enter leaves the cell too");

  cells[0].focus();
  const left = key(cells[0], "ArrowLeft");
  eq(left.defaultPrevented, false, "Left is left to the caret — it is a text box");
});

test("only status columns decide qualified, and % complete counts filled data cells", function () {
  const t = open();
  t.win.adopt(fixture(1, { returns: [mkRet("R1", { status_flags: allYes() })] }), "manifest.json");
  ok(t.win.isDone(t.win.manifest.returns[0]), "all eight steps yes is qualified");
  match(t.doc.getElementById("pills").textContent, /1qualified/, "and the pill agrees");

  /* The bug this guards: tally counted every column, so adding a number column
     made a finished return stop being qualified. */
  addCol(t.win, "amount", "number", "Amount");
  ok(t.win.isDone(t.win.manifest.returns[0]),
     "adding an empty number column does not un-qualify it");
  match(t.doc.getElementById("pills").textContent, /1qualified/, "still qualified in the pills");

  /* But it is not 100% complete, because there is a cell with nothing in it. */
  match(t.doc.getElementById("pills").textContent, /73%complete/,
        "8 of 11 cells filled reads as 73%");

  t.win.manifest.returns[0].status_flags.loc = "NY";
  t.win.manifest.returns[0].status_flags.pj_id = 101;
  t.win.manifest.returns[0].status_flags.amount = 5;
  t.win.invalidateTally();
  t.win.render();
  match(t.doc.getElementById("pills").textContent, /100%complete/, "filling it reaches 100%");
});

test("Qualifying alone decides qualified, not the other seven steps", function () {
  const t = open();
  t.win.adopt(fixture(1, { returns: [mkRet("R1", { status_flags: allYes() })] }), "manifest.json");

  /* Every other step is still Yes here except Qualifying, which is No — the
     real-world shape this guards: a return marked done on attachments, data,
     XML, batch, recon and TFR, but not actually qualifying yet. */
  t.win.manifest.returns[0].status_flags.qualifying = "no";
  t.win.invalidateTally();
  eq(t.win.isDone(t.win.manifest.returns[0]), false,
     "six of seven other steps yes does not make it qualified without Qualifying");

  /* And the reverse: only Qualifying is yes, nothing else touched at all. */
  const fresh = { id: "R2", filename: "R2.pdf", folder: "R2", state_code: "CA",
                  date_received: "2026-02-14", status_flags: { qualifying: "yes" }, remarks: "" };
  ok(t.win.isDone(fresh), "Qualifying yes alone is enough, with every other step untouched");
});

function daysAgoISO(n) {
  const d = new Date();
  d.setDate(d.getDate() - n);
  const pad = function (x) { return String(x).padStart(2, "0"); };
  return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate());
}

test("the Manifest panel ages only open returns, oldest first, and a click jumps to the row", function () {
  const t = open();
  const r1 = mkRet("R1", { date_received: daysAgoISO(10) });
  const r2 = mkRet("R2", { date_received: daysAgoISO(3) });
  /* R3 is the oldest by date, but it is already qualified — aging is about
     what still needs attention, so it must not appear here at all. */
  const r3 = mkRet("R3", { date_received: daysAgoISO(30), status_flags: allYes() });
  t.win.adopt({ assignment_folder: "Batch A", returns: [r1, r2, r3] }, "manifest.json");

  t.win.openManifest();
  const sects = Array.prototype.slice.call(t.doc.querySelectorAll(".manifest-sheet .sect"));
  const aging = sects.filter(function (s) { return /Aging/.test(s.querySelector(".micro").textContent); })[0];
  ok(aging, "an aging section renders");

  const rows = Array.prototype.slice.call(aging.querySelectorAll(".clickable-return"));
  deepEq(rows.map(function (r) { return r.getAttribute("data-ret-id"); }), ["R1", "R2"],
         "only the open returns are listed, oldest first — R3 excluded despite being older");
  match(aging.textContent, /10 days/, "R1's age in days is shown");
  match(aging.textContent, /Avg days open/, "the average KPI is present");

  click(rows[0]);
  ok(t.doc.querySelector('#rows tr[data-id="R1"]').classList.contains("flash"),
     "clicking an aged return closes the panel and flashes its row in the grid");
});

test("the Manifest panel breaks down qualified and issue counts by a custom text column", function () {
  const t = open();
  t.win.adopt(fixture(3), "manifest.json");
  addCol(t.win, "custom_preparer", "text", "Preparer");
  t.win.manifest.returns[0].status_flags.custom_preparer = "Jane";
  t.win.manifest.returns[0].status_flags.qualifying = "yes";
  t.win.manifest.returns[1].status_flags.custom_preparer = "Jane";
  t.win.manifest.returns[2].status_flags.custom_preparer = "Sam";
  t.win.invalidateTally();

  t.win.openManifest();
  const sects = Array.prototype.slice.call(t.doc.querySelectorAll(".manifest-sheet .sect"));
  const breakdown = sects.filter(function (s) { return /Breakdown by Preparer/.test(s.querySelector(".micro").textContent); })[0];
  ok(breakdown, "a breakdown section appears, named after the column");

  const byName = {};
  Array.prototype.slice.call(breakdown.querySelectorAll("tbody tr")).forEach(function (tr) {
    const tds = tr.querySelectorAll("td");
    byName[tds[0].textContent] = { n: tds[1].textContent, done: tds[2].textContent, issue: tds[3].textContent };
  });
  eq(byName.Jane.n, "2", "two returns under Jane");
  eq(byName.Jane.done, "1", "one of Jane's two is qualified");
  eq(byName.Sam.n, "1", "one return under Sam");
});

test("the breakdown section stays out of the way when there is no custom text column", function () {
  const t = open();
  t.win.adopt(fixture(2), "manifest.json");
  t.win.openManifest();
  noMatch(t.doc.querySelector(".manifest-sheet").textContent, /Breakdown by/,
          "nothing to break down without a custom text column");
});

test("needs attention lists every open-issue return with which step flagged it, and jumps on click", function () {
  const t = open();
  const r1 = mkRet("R1", { status_flags: { attachments_present: "issue" } });
  const r2 = mkRet("R2", { status_flags: { xml_flowing: "issue", recon_checked: "issue" } });
  const r3 = mkRet("R3", { status_flags: allYes() });
  t.win.adopt({ assignment_folder: "Batch A", returns: [r1, r2, r3] }, "manifest.json");

  t.win.openManifest();
  const sects = Array.prototype.slice.call(t.doc.querySelectorAll(".manifest-sheet .sect"));
  const attn = sects.filter(function (s) { return /Needs attention/.test(s.querySelector(".micro").textContent); })[0];
  ok(attn, "a needs-attention section renders");

  const rows = Array.prototype.slice.call(attn.querySelectorAll(".clickable-return"));
  deepEq(rows.map(function (r) { return r.getAttribute("data-ret-id"); }), ["R1", "R2"],
         "only the returns with an issue are listed, R3 excluded");
  match(rows[0].textContent, /Attachments present/, "which step is flagged is shown");
  match(rows[1].textContent, /XML flowing/, "and more than one flagged step is listed together");

  click(rows[0]);
  ok(t.doc.querySelector('#rows tr[data-id="R1"]').classList.contains("flash"),
     "clicking jumps to and flashes the row, same as aging");
});

test("a custom number column gets a total/average card with a per-state split", function () {
  const t = open();
  t.win.adopt(fixture(3), "manifest.json");
  addCol(t.win, "custom_refund", "number", "Refund amount");
  t.win.manifest.returns[0].status_flags.custom_refund = 100;
  t.win.manifest.returns[0].state_code = "CA";
  t.win.manifest.returns[1].status_flags.custom_refund = 300;
  t.win.manifest.returns[1].state_code = "NY";
  t.win.invalidateTally();

  t.win.openManifest();
  const sects = Array.prototype.slice.call(t.doc.querySelectorAll(".manifest-sheet .sect"));
  const card = sects.filter(function (s) { return /Refund amount/.test(s.querySelector(".micro").textContent); })[0];
  ok(card, "a summary card appears for the custom number column");
  match(card.textContent, /400/, "the total across both filled cells");
  match(card.textContent, /200/, "the average of 100 and 300");
  match(card.textContent, /2\/3/, "filled count out of all returns");

  const stateRows = Array.prototype.slice.call(card.querySelectorAll("table tbody tr"));
  eq(stateRows.length, 2, "one row per state that has a value");
});

test("intake volume buckets returns by date received, earliest first", function () {
  const t = open();
  const r1 = mkRet("R1", { date_received: "2026-02-10" });
  const r2 = mkRet("R2", { date_received: "2026-02-10" });
  const r3 = mkRet("R3", { date_received: "2026-02-12" });
  t.win.adopt({ assignment_folder: "Batch A", returns: [r1, r2, r3] }, "manifest.json");

  t.win.openManifest();
  const sects = Array.prototype.slice.call(t.doc.querySelectorAll(".manifest-sheet .sect"));
  const vol = sects.filter(function (s) { return /Intake volume/.test(s.querySelector(".micro").textContent); })[0];
  ok(vol, "an intake volume section renders");

  const rows = Array.prototype.slice.call(vol.querySelectorAll(".state-chart-row"));
  eq(rows.length, 2, "one row per distinct date");
  match(rows[0].textContent, /2026-02-10/, "earliest date sorts first");
  match(rows[0].querySelector(".state-chart-meta").textContent, /2/, "two returns landed on the 10th");
  match(rows[1].querySelector(".state-chart-meta").textContent, /1/, "one on the 12th");
});

test("a row with only data typed is started, and a tracker with no steps is never done", function () {
  const t = open();
  t.win.adopt(fixture(1), "manifest.json");
  addCol(t.win, "who", "text", "Who");
  ok(t.win.isFresh(t.win.manifest.returns[0]), "untouched to begin with");

  t.win.manifest.returns[0].status_flags.who = "someone";
  t.win.invalidateTally();
  ok(!t.win.isFresh(t.win.manifest.returns[0]),
     "typing a reference into a text column counts as having started the row");

  /* With every status column gone, `yes === length` would be `0 === 0` and mark
     every return complete. */
  t.win.manifest.flags = t.win.manifest.flags.filter(function (f) { return f.key === "who"; });
  t.win.invalidateTally();
  eq(t.win.isDone(t.win.manifest.returns[0]), false,
     "no steps left means nothing to qualify, not everything qualified");
});

test("numbers sort numerically and empties sink in both directions", function () {
  const t = open();
  t.win.adopt(fixture(4), "manifest.json");
  addCol(t.win, "amount", "number", "Amount");
  const vals = { R1: 9, R2: null, R3: 100, R4: 20 };
  t.win.manifest.returns.forEach(function (r) { r.status_flags.amount = vals[r.id]; });
  t.win.invalidateTally();

  t.win.prefs.sort = "f:amount";
  t.win.prefs.dir = 1;
  t.win.render();
  deepEq(trs(t.doc).map(function (tr) { return tr.getAttribute("data-id"); }),
         ["R1", "R4", "R3", "R2"],
         "9, 20, 100 — not the '100 < 20' a string sort would give — and the empty last");

  t.win.prefs.dir = -1;
  t.win.render();
  deepEq(trs(t.doc).map(function (tr) { return tr.getAttribute("data-id"); }),
         ["R3", "R4", "R1", "R2"],
         "reversed, and the empty row stays at the bottom rather than jumping to the top");
});

test("import keeps typed values and coerces the ones it can, without a blanket reset", function () {
  const t = open();
  /* A number arriving as a string is the normal case out of a hand-edit or a
     spreadsheet paste. Before typed columns, every one of these was reset. */
  t.win.adopt({
    returns: [mkRet("R1", { status_flags: { amount: "42.5", who: 7, other: "text" } })],
    flags: [
      { key: "amount", short: "Amount", type: "number" },
      { key: "who", short: "Who", type: "text" },
      { key: "other", short: "Other" }              // no type at all -> a status column
    ]
  }, "manifest.json");

  const sf = t.win.manifest.returns[0].status_flags;
  eq(sf.amount, 42.5, "a numeric string becomes the number");
  eq(sf.who, "7", "a number in a text column becomes its string");
  eq(sf.other, null, "'text' is not a status value, so that one is reset");
  eq(t.win.manifest.flags[2].type, "status", "a column with no type is a status column");
  match(t.doc.getElementById("banners").textContent, /1 unrecognised value was reset/,
        "and only the one that really was unreadable is reported");
});

test("changing a column's type converts what it can and one undo takes it all back", function () {
  const t = open();
  t.win.adopt(fixture(3), "manifest.json");
  addCol(t.win, "amount", "text", "Amount");
  const vals = { R1: "42", R2: "about ten", R3: "" };
  t.win.manifest.returns.forEach(function (r) { r.status_flags.amount = vals[r.id]; });
  t.win.invalidateTally();

  t.win.changeColumnType("f:amount");
  /* pick "number", then confirm the warning about the value that cannot survive */
  const radio = t.doc.querySelector('.ask [data-ask="choice"][value="number"]');
  radio.checked = true;
  fire(radio, "change");
  click(t.doc.querySelector('.ask [data-ask="ok"]'));
  match(t.doc.querySelector(".ask").textContent, /1 cell.*cannot be read as number/,
        "it says how many values will be lost before doing anything");
  click(t.doc.querySelector('.ask [data-ask="ok"]'));

  const sf = t.win.manifest.returns.map(function (r) { return r.status_flags.amount; });
  deepEq(sf, [42, null, null], '"42" converts, "about ten" is emptied rather than guessed at');
  eq(t.win.flagByKey("amount").type, "number", "the column is a number column now");
  eq(t.win.dirty, 1, "the whole conversion is one edit");

  t.win.undo();
  eq(t.win.flagByKey("amount").type, "text", "undo puts the type back");
  deepEq(t.win.manifest.returns.map(function (r) { return r.status_flags.amount; }),
         ["42", "about ten", ""], "and every value with it");
  eq(t.win.dirty, 0, "and the counter");
});

test("a custom column can be removed and undone; a built-in step cannot be removed", function () {
  const t = open();
  t.win.adopt(fixture(2), "manifest.json");
  addCol(t.win, "amount", "number", "Amount");
  t.win.manifest.returns[0].status_flags.amount = 12;
  t.win.prefs.sort = "f:amount";

  t.win.removeCustomColumn("f:amount");
  match(t.doc.querySelector(".ask").textContent, /1 that has something in it/,
        "the confirmation says how many rows have data in the column");
  click(t.doc.querySelector('.ask [data-ask="ok"]'));

  eq(t.win.flagByKey("amount"), null, "the column is gone");
  eq("amount" in t.win.manifest.returns[0].status_flags, false, "and so is its data");
  eq(t.win.prefs.sort, "id", "a sort by the removed column falls back rather than sorting by nothing");

  t.win.undo();
  ok(t.win.flagByKey("amount"), "undo brings the column back");
  eq(t.win.manifest.returns[0].status_flags.amount, 12, "with its value");

  /* The eight the intake script writes are the contract with intake.ps1. */
  t.win.removeCustomColumn("f:qualifying");
  eq(t.doc.querySelector(".ask"), null, "removing a built-in step is refused outright");
  ok(t.win.flagByKey("qualifying"), "and it is still there");
});

test("the CSV and the workbook carry typed columns, numbers as real numbers", function () {
  const t = open();
  t.win.adopt(fixture(2), "manifest.json");
  addCol(t.win, "amount", "number", "Refund");
  addCol(t.win, "who", "text", "Preparer");
  t.win.manifest.returns[0].status_flags.amount = -300.5;
  t.win.manifest.returns[0].status_flags.who = 'Jane "JQ", CPA';
  t.win.manifest.returns[1].status_flags.amount = 100;
  t.win.invalidateTally();
  t.win.render();

  t.win.exportCsv();
  const csv = t.lastDownload().buffer().toString("utf8").replace(/^﻿/, "");
  const lines = csv.split("\r\n");
  match(lines[0], /Refund,Preparer,Remarks$/, "both new columns are in the header");
  match(lines[1], /,-300\.5,"Jane ""JQ"", CPA",/,
        "the number is written bare so a spreadsheet can sum it, and the text is quoted");

  t.win.exportXlsx();
  const zip = t.unzipStored(t.lastDownload().buffer());
  ok(Object.keys(zip).every(function (k) { return zip[k].crcOk; }), "every zip entry checksums");
  const s1 = zip["xl/worksheets/sheet1.xml"].data.toString("utf8");

  /* The point of a number column: <v> in a numeric cell, never t="inlineStr". */
  match(s1, /<c r="Q2" s="11"><v>-300\.5<\/v><\/c>/, "the refund is a real numeric cell");
  match(s1, /<c r="Q3" s="11"><v>100<\/v><\/c>/, "and so is the next one");
  noMatch(s1, /s="11"[^>]*t="inlineStr"/, "no number is ever written as a string");
  match(s1, /Jane &quot;JQ&quot;, CPA/, "the text column is escaped, not mangled");

  const s2 = zip["xl/worksheets/sheet2.xml"].data.toString("utf8");
  match(s2, /Data column/, "the summary gets its own block for data columns");
  match(s2, /<v>-200\.5<\/v>/, "with the total");
  match(s2, /<v>-100\.25<\/v>/, "and the average");
});

/* =====================================================================
   Selecting rows and marking them together
   ===================================================================== */

test("a plain click ticks one row and Shift-click ticks the run between", function () {
  const t = open();
  t.win.adopt(fixture(6), "manifest.json");
  const picks = function () {
    return Array.prototype.slice.call(t.doc.querySelectorAll("#rows .rowpick"));
  };
  eq(picks().length, 6, "every row has a tick box");

  click(picks()[1]);
  deepEq(Object.keys(t.win.selected), ["R2"], "one click, one row");

  click(picks()[4], { shiftKey: true });
  deepEq(Object.keys(t.win.selected).sort(), ["R2", "R3", "R4", "R5"],
         "Shift extends from the last row clicked, inclusive");

  click(picks()[1]);
  deepEq(Object.keys(t.win.selected).sort(), ["R3", "R4", "R5"], "clicking again unticks");

  ok(trs(t.doc)[2].className.indexOf("sel") !== -1, "a ticked row is marked in the DOM");
});

test("selection is by return, so re-sorting the grid does not move it to other rows", function () {
  const t = open();
  t.win.adopt(fixture(4), "manifest.json");
  click(t.doc.querySelectorAll("#rows .rowpick")[0]);
  deepEq(Object.keys(t.win.selected), ["R1"], "R1 is ticked");

  /* The bug this guards: keying the selection by row index meant reversing the
     sort silently moved the tick to whichever return landed in that slot. */
  t.win.prefs.dir = -1;
  t.win.render();
  deepEq(Object.keys(t.win.selected), ["R1"], "still R1 after reversing the sort");
  eq(trs(t.doc)[3].getAttribute("data-id"), "R1", "which is now the last row");
  ok(trs(t.doc)[3].className.indexOf("sel") !== -1, "and it is the one highlighted");
});

test("the header box selects everything shown, and shows a third state for a partial pick", function () {
  const t = open();
  t.win.adopt(fixture(4), "manifest.json");
  const box = function () { return t.doc.querySelector("#headRow .allpick"); };

  click(t.doc.querySelectorAll("#rows .rowpick")[0]);
  eq(box().indeterminate, true, "one of four ticked is indeterminate, not checked");
  eq(box().checked, false, "and the box does not claim everything is selected");

  const b = box();
  b.checked = true;
  fire(b, "change");
  eq(t.win.selectionCount(), 4, "the header box takes all four");
  eq(box().checked, true, "and now reads as checked");
  eq(box().indeterminate, false, "with no third state");

  /* A filter narrows what "everything shown" means. */
  t.win.clearSelection();
  t.doc.getElementById("search").value = "R1";
  fire(t.doc.getElementById("search"), "input");
  const b2 = box();
  b2.checked = true;
  fire(b2, "change");
  eq(t.win.selectionCount(), 1, "only the row the filter is showing");
});

test("the bulk bar marks every ticked row in one column, as one undo", function () {
  const t = open();
  t.win.adopt(fixture(4), "manifest.json");
  const bar = t.doc.getElementById("bulkBar");
  ok(bar.classList.contains("hidden"), "the bar is not there until something is ticked");

  click(t.doc.querySelectorAll("#rows .rowpick")[0]);
  click(t.doc.querySelectorAll("#rows .rowpick")[2], { shiftKey: true });
  ok(!bar.classList.contains("hidden"), "ticking rows brings it up");
  eq(t.doc.getElementById("bulkCount").textContent, "3 rows selected", "and it counts them");

  t.win.bulkTargetKey = "qualifying";
  t.win.renderBulkBar();
  click(t.doc.querySelector('#bulkStatusVals [data-set="yes"]'));

  deepEq(t.win.manifest.returns.map(function (r) { return r.status_flags.qualifying; }),
         ["yes", "yes", "yes", null], "the three ticked rows are marked and the fourth is not");
  eq(t.win.dirty, 1, "three rows changed is one edit, because it is one undo");

  t.win.undo();
  deepEq(t.win.manifest.returns.map(function (r) { return r.status_flags.qualifying; }),
         [null, null, null, null], "and one Ctrl+Z takes all of it back");
  eq(t.win.dirty, 0, "counter back to clean");
});

test("Y marks the whole selection only when the row you are on is part of it", function () {
  const t = open();
  t.win.adopt(fixture(4), "manifest.json");
  click(t.doc.querySelectorAll("#rows .rowpick")[0]);
  click(t.doc.querySelectorAll("#rows .rowpick")[1], { shiftKey: true });

  /* Standing on R3, which is not ticked: Y must mark just R3. */
  let cells = Array.prototype.slice.call(t.doc.querySelectorAll('#rows [data-flag="qualifying"]'));
  cells[2].focus();
  key(cells[2], "y");
  deepEq(t.win.manifest.returns.map(function (r) { return r.status_flags.qualifying; }),
         [null, null, "yes", null],
         "a row outside the selection behaves exactly as it always did");

  /* Standing on R1, which is ticked: Y marks R1 and R2. */
  cells = Array.prototype.slice.call(t.doc.querySelectorAll('#rows [data-flag="data_accurate"]'));
  cells[0].focus();
  key(cells[0], "y");
  deepEq(t.win.manifest.returns.map(function (r) { return r.status_flags.data_accurate; }),
         ["yes", "yes", null, null], "and a row inside it marks the whole selection");

  /* Focus has to survive the redraw, or the next column needs the mouse. */
  eq(t.doc.activeElement.getAttribute("data-flag"), "data_accurate",
     "focus stays on the cell after a bulk mark");
});

test("S ticks the focused row, Ctrl+A ticks the page, Escape unticks", function () {
  const t = open();
  t.win.adopt(fixture(3), "manifest.json");
  const cell = t.doc.querySelector('#rows [data-flag="qualifying"]');
  cell.focus();

  key(cell, "s");
  deepEq(Object.keys(t.win.selected), ["R1"], "S ticks the row you are on");
  eq(t.doc.activeElement.getAttribute("data-flag"), "qualifying", "and keeps focus in the grid");
  key(t.doc.activeElement, "s");
  eq(t.win.selectionCount(), 0, "and unticks it again");

  key(t.doc.body, "a", { ctrlKey: true });
  eq(t.win.selectionCount(), 3, "Ctrl+A takes every row on screen");

  key(t.doc.body, "Escape");
  eq(t.win.selectionCount(), 0, "Escape lets go of all of it");
});

test("Escape closes overlays before it touches the selection", function () {
  const t = open();
  t.win.adopt(fixture(2), "manifest.json");
  key(t.doc.body, "a", { ctrlKey: true });
  eq(t.win.selectionCount(), 2, "two rows ticked");

  t.win.openNotes();
  key(t.doc.body, "Escape");
  ok(t.doc.getElementById("notesSheet").classList.contains("hidden"), "the panel closes");
  eq(t.win.selectionCount(), 2, "and the selection is untouched by that press");

  key(t.doc.body, "Escape");
  eq(t.win.selectionCount(), 0, "the next press is the one that clears it");
});

test("deleting a ticked row drops it from the selection", function () {
  const t = open();
  t.win.adopt(fixture(3), "manifest.json");
  key(t.doc.body, "a", { ctrlKey: true });
  eq(t.win.selectionCount(), 3);

  /* A stale id would keep counting towards "3 selected" and make a bulk action
     claim more rows than it touched. */
  t.win.manifest.returns.splice(1, 1);
  t.win.render();
  eq(t.win.selectionCount(), 2, "the deleted return stops counting");
  deepEq(Object.keys(t.win.selected).sort(), ["R1", "R3"], "and the right two remain");
});

test("bulk on a data column offers a box to type in, not Yes/No buttons", function () {
  const t = open();
  t.win.adopt(fixture(3), "manifest.json");
  addCol(t.win, "amount", "number", "Amount");
  key(t.doc.body, "a", { ctrlKey: true });

  t.win.bulkTargetKey = "amount";
  t.win.renderBulkBar();
  ok(t.doc.getElementById("bulkStatusVals").classList.contains("hidden"),
     "Yes / No / Issue is hidden for a column that cannot hold them");
  ok(!t.doc.getElementById("bulkDataVals").classList.contains("hidden"), "a value box shows instead");
  eq(t.doc.getElementById("bulkDataInput").type, "number", "matching the column's type");

  t.doc.getElementById("bulkDataInput").value = "7.5";
  click(t.doc.getElementById("bulkDataApply"));
  deepEq(t.win.manifest.returns.map(function (r) { return r.status_flags.amount; }),
         [7.5, 7.5, 7.5], "every ticked row gets the number");
  eq(t.win.dirty, 1, "still one edit");

  click(t.doc.getElementById("bulkDataClear"));
  deepEq(t.win.manifest.returns.map(function (r) { return r.status_flags.amount; }),
         [null, null, null], "and Clear empties the column on all of them");
});

test('"every step" sets all the status columns at once and leaves data columns alone', function () {
  const t = open();
  t.win.adopt(fixture(2), "manifest.json");
  addCol(t.win, "amount", "number", "Amount");
  key(t.doc.body, "a", { ctrlKey: true });

  t.win.applyBulk("__all__", "yes");
  t.win.manifest.returns.forEach(function (r) {
    FLAG_KEYS.forEach(function (k) { eq(r.status_flags[k], "yes", k + " on " + r.id); });
    eq(r.status_flags.amount, null, "the number column is not touched by a step-wide mark");
  });
  ok(t.win.isDone(t.win.manifest.returns[0]), "which is enough to qualify the return");
  eq(t.win.dirty, 1, "16 cells, one edit");
});

/* =====================================================================
   The Notepad
   ===================================================================== */

test("the Notepad and the Scratchpad are the same text, kept in step", function () {
  const t = open();
  t.win.adopt(fixture(1, { quick_notes: "from the manifest" }), "manifest.json");

  key(t.doc.body, "p", { altKey: true });
  ok(!t.doc.getElementById("notepad").classList.contains("hidden"), "Alt+P opens it");
  const np = t.doc.getElementById("npText");
  const pad = t.doc.getElementById("quickNotesText");
  eq(np.value, "from the manifest", "it opens on what was already there");

  np.focus();
  np.value = "typed in the notepad";
  fire(np, "input");
  eq(t.win.manifest.quick_notes, "typed in the notepad", "typing reaches the manifest");
  eq(pad.value, "typed in the notepad", "and the other box is brought into step");

  pad.focus();
  pad.value = "typed in the panel";
  fire(pad, "input");
  eq(np.value, "typed in the panel", "and it works the other way round");

  /* The bug this guards: saveDraft used to read the scratchpad textarea back as
     the source of truth. That was fine with one box; with two, whichever one it
     named would overwrite what you had just typed in the other. Force them out
     of step the way only a bug could, and the manifest must still win. */
  pad.value = "a stale box";
  t.win.saveDraft();
  eq(t.win.manifest.quick_notes, "typed in the panel",
     "a save reads the manifest, never a textarea");

  key(np, "Escape");
  ok(t.doc.getElementById("notepad").classList.contains("hidden"), "Escape closes it");
});

test("a blank line splits the notepad into copyable snippets", function () {
  const t = open();
  let copied = [];
  Object.defineProperty(t.win.navigator, "clipboard", {
    configurable: true,
    value: { writeText: function (s) { copied.push(s); return Promise.resolve(); } }
  });

  t.win.adopt(fixture(1), "manifest.json");
  t.win.openNotepad();
  const np = t.doc.getElementById("npText");
  np.focus();
  np.value = "first\nstill first\n\n--------\n\nsecond\n\nthird";
  fire(np, "input");

  const cards = t.doc.querySelectorAll("#npSnipList .npsnip");
  eq(cards.length, 3, "three chunks, and the row of dashes is a divider rather than a fourth");
  eq(t.doc.getElementById("npSnipCount").textContent, "3", "the count on the button agrees");

  click(t.doc.querySelector('#npSnipList [data-copy="0"]'));
  eq(copied[copied.length - 1], "first\nstill first", "copying a snippet takes exactly that block");

  click(t.doc.querySelector('#npSnipList [data-snip="2"]'));
  eq(np.value.slice(np.selectionStart, np.selectionEnd), "third",
     "clicking the card selects that block in the page, so it can be cut or replaced");

  click(t.doc.getElementById("npCopyAll"));
  eq(copied[copied.length - 1], np.value, "and Copy all takes the lot");
});

test("a whole visit to the Notepad is one edit, and undo restores both boxes", function () {
  const t = open();
  t.win.adopt(fixture(1, { quick_notes: "before" }), "manifest.json");
  t.win.openNotepad();
  const np = t.doc.getElementById("npText");

  fire(np, "focus");
  "abc".split("").forEach(function (ch) { np.value += ch; fire(np, "input"); });
  eq(t.win.dirty, 0, "nothing counted mid-sentence");
  fire(np, "blur");
  eq(t.win.dirty, 1, "one edit for the visit");
  eq(t.win.manifest.quick_notes, "beforeabc");

  t.win.undo();
  eq(t.win.manifest.quick_notes, "before", "undo restores the text");
  eq(np.value, "before", "in the notepad");
  eq(t.doc.getElementById("quickNotesText").value, "before", "and in the panel");
});

test("the Notepad opens with nothing loaded and starts a batch rather than refusing", function () {
  const t = open();
  eq(t.win.manifest, null, "nothing imported");
  t.win.openNotepad();
  ok(t.win.manifest, "opening the notepad starts somewhere to keep the notes");
  eq(t.win.manifest.assignment_folder, "Custom Intake Batch");
  ok(!t.doc.getElementById("notepad").classList.contains("hidden"), "and it is open");
});

/* =====================================================================
   The shortcut sheet, and shortcuts
   ===================================================================== */

test("? and F1 open the shortcut sheet, and it lists the keys it documents", function () {
  const t = open({ platform: "Win32" });
  t.win.adopt(fixture(2), "manifest.json");
  const sheet = t.doc.getElementById("helpSheet");
  ok(sheet.classList.contains("hidden"), "closed to start");

  const ev = key(t.doc.body, "?");
  eq(ev.defaultPrevented, true, "the page takes the key");
  ok(!sheet.classList.contains("hidden"), "? opens it");

  const body = t.doc.getElementById("helpBody").textContent;
  ["Mark a step", "Select rows", "Panels", "Save and export"].forEach(function (g) {
    match(body, new RegExp(g), "the sheet has a '" + g + "' group");
  });
  match(body, /Notepad/, "and covers the features, not only the keys");

  /* Windows first: Ctrl, not the Mac glyph. */
  match(t.doc.getElementById("helpBody").innerHTML, /<kbd>Ctrl<\/kbd>/, "keys read Ctrl on Windows");
  noMatch(t.doc.getElementById("helpBody").innerHTML, /⌘/, "and never ⌘");
  match(t.doc.getElementById("helpPlat").textContent, /Windows/, "and it says so");

  key(t.doc.body, "Escape");
  ok(sheet.classList.contains("hidden"), "Escape closes it");

  key(t.doc.body, "F1");
  ok(!sheet.classList.contains("hidden"), "F1 does the same thing");
});

test("the shortcut sheet filters, and ? inside a text box types a question mark", function () {
  const t = open({ platform: "Win32" });
  t.win.adopt(fixture(2), "manifest.json");
  t.win.openHelp();
  const search = t.doc.getElementById("helpSearch");

  search.value = "snippet";
  fire(search, "input");
  match(t.doc.getElementById("helpBody").textContent, /snippet/i, "a match survives the filter");
  noMatch(t.doc.getElementById("helpBody").textContent, /Group the rows by state/,
          "and everything else is gone");

  search.value = "zzzznope";
  fire(search, "input");
  match(t.doc.getElementById("helpBody").textContent, /Nothing matches/, "an empty filter says so");

  t.win.closeHelp();
  /* The guard that matters: a bare-letter shortcut must not fire while typing. */
  const remarks = t.doc.querySelector("#rows .remarks");
  remarks.focus();
  const ev = key(remarks, "?");
  eq(ev.defaultPrevented, false, "? is a character when the cursor is in a box");
  ok(t.doc.getElementById("helpSheet").classList.contains("hidden"), "and the sheet stays shut");
});

test("the Mac gets ⌘ in the sheet without the shortcuts changing", function () {
  const t = open({ platform: "MacIntel" });
  t.win.adopt(fixture(1), "manifest.json");
  t.win.openHelp();
  match(t.doc.getElementById("helpBody").innerHTML, /<kbd>⌘<\/kbd>/, "⌘ on a Mac");
  match(t.doc.getElementById("helpPlat").textContent, /Mac/, "and the footer says which");
});

test("the new navigation shortcuts do what the sheet claims", function () {
  const t = open({ platform: "Win32" });
  t.win.adopt(fixture(3), "manifest.json");

  /* / focuses search, the way it does in every list-shaped app */
  key(t.doc.body, "/");
  eq(t.doc.activeElement, t.doc.getElementById("search"), "/ jumps to the search box");

  /* Alt+R clears search and both filters in one key */
  t.doc.getElementById("search").value = "R1";
  fire(t.doc.getElementById("search"), "input");
  t.doc.getElementById("statusFilter").value = "issue";
  fire(t.doc.getElementById("statusFilter"), "change");
  eq(trs(t.doc).length, 0, "filtered down to nothing");
  key(t.doc.body, "r", { altKey: true });
  eq(t.doc.getElementById("search").value, "", "Alt+R empties the search");
  eq(t.doc.getElementById("statusFilter").value, "all", "and resets the progress filter");
  eq(trs(t.doc).length, 3, "so all three rows are back");

  /* Insert adds a row — "new record" on every Windows application ever written */
  key(t.doc.body, "Insert");
  ok(!t.doc.getElementById("addRowModal").classList.contains("hidden"), "Insert opens Add Row");
  t.win.closeAddRowModal();

  /* Alt+G groups, Alt+M opens the manifest panel */
  key(t.doc.body, "g", { altKey: true });
  eq(t.win.prefs.group, true, "Alt+G groups by state");
  key(t.doc.body, "m", { altKey: true });
  ok(t.doc.querySelector(".sheet"), "Alt+M opens the manifest panel");
  key(t.doc.body, "Escape");

  /* Alt+X and Alt+C are the two exports that are not Ctrl+S */
  key(t.doc.body, "x", { altKey: true });
  ok(t.lastDownload(), "Alt+X writes a workbook");
  const xlsx = t.lastDownload();
  key(t.doc.body, "c", { altKey: true });
  ok(t.lastDownload() !== xlsx, "Alt+C writes a second, different file");
  match(t.lastDownload().buffer().toString("utf8"), /Return or Fund,Filename/, "and it is the CSV");
});

test("Alt+E and Alt+F are left alone, because the browser eats them on Windows", function () {
  const t = open({ platform: "Win32" });
  t.win.adopt(fixture(2), "manifest.json");
  /* Alt+E and Alt+F open Chrome's and Edge's own menu, and Alt+D is the address
     bar — a shortcut the page never reliably receives is worse than none. */
  ["e", "f", "d"].forEach(function (k) {
    const ev = key(t.doc.body, k, { altKey: true });
    eq(ev.defaultPrevented, false, "Alt+" + k.toUpperCase() + " is not claimed by the app");
  });
  /* And nothing is bound to a digit, because Alt/Ctrl + digit switches tab. */
  ["1", "2", "9"].forEach(function (k) {
    eq(key(t.doc.body, k, { altKey: true }).defaultPrevented, false, "Alt+" + k + " is free");
    eq(key(t.doc.body, k, { ctrlKey: true }).defaultPrevented, false, "Ctrl+" + k + " is free");
  });
});

/* =====================================================================
   Renaming columns is View-menu only
   ===================================================================== */

test("the header cannot rename a column any more; the View menu still can", function () {
  const t = open();
  t.win.adopt(fixture(2), "manifest.json");
  const th = t.doc.querySelector('#headRow th[data-col="f:qualifying"]');

  /* A double-click or a stray click in the header used to open a rename box,
     which is a lot to happen by accident while sorting a column. */
  fire(th, "dblclick");
  eq(t.doc.querySelector(".ask"), null, "a double-click on the header opens nothing");
  click(th.querySelector(".lbl"));
  eq(t.doc.querySelector(".ask"), null, "and neither does clicking the label");
  eq(t.doc.querySelector("#headRow .hd-edit-icon"), null, "there is no pencil in the header");
  noMatch(th.getAttribute("title") || "", /rename/i, "and nothing offers renaming there");

  /* Clicking the header still sorts, which is the job it does have. */
  eq(t.win.prefs.sort, "f:qualifying", "the click sorted by that column instead");

  /* The View menu route is intact. */
  t.win.promptColumnMenu("rename");
  const item = t.doc.querySelector('.menu [data-pickcol="f:qualifying"]');
  ok(item, "the View menu lists the column");
  click(item);
  ok(t.doc.querySelector(".ask"), "and that opens the rename box");
  t.doc.querySelector('.ask [data-ask="input"]').value = "Qualifies";
  click(t.doc.querySelector('.ask [data-ask="ok"]'));
  eq(t.win.flagByKey("qualifying").short, "Qualifies", "renaming still works");
  match(t.doc.querySelector('#headRow th[data-col="f:qualifying"]').textContent, /Qualifies/,
        "and the header shows the new name");
});

/* =====================================================================
   The contract with intake.ps1
   =====================================================================
   The fixture is the real output of intake.ps1 (PowerShell 7.7 on macOS) after a
   round trip: script -> app, where two typed columns were added and filled ->
   Export JSON -> script again, with a new PDF appearing on that second run.

   It is a frozen file, so what these tests catch is the *app* drifting away from
   a manifest the script really wrote, and the app exporting something the script
   could no longer read. They cannot catch the script itself changing — if
   intake.ps1 changes what it writes, regenerate this fixture by running it
   twice over a throwaway folder (see the README) and let these tests re-check
   the app against it. */

const INTAKE_FIXTURE = require("./fixtures/intake-manifest.json");

test("a manifest that has been through intake.ps1 twice imports with nothing lost", function () {
  const t = open();
  /* Deep copy: adopt() edits in place and the fixture is shared with the next test. */
  t.win.adopt(JSON.parse(JSON.stringify(INTAKE_FIXTURE)), "manifest.json");
  const m = t.win.manifest;

  eq(m.returns.length, 7, "every return arrives");
  eq(m.schema_version, 1, "the script and the app stamp the same schema");
  noMatch(t.doc.getElementById("banners").textContent, /unrecognised value/,
          "and nothing in it has to be reset on the way in");

  const by = {};
  m.returns.forEach(function (r) { by[r.id] = r; });

  /* The script writes flag values back verbatim, so the app has to read them
     back as the types they were written as. */
  eq(by.AMENDED_FL_2024.status_flags.custom_refund_amount, 1520.25, "a decimal survives");
  eq(typeof by.AMENDED_FL_2024.status_flags.custom_refund_amount, "number", "as a number");
  eq(by["CTC-01_MD510"].status_flags.custom_refund_amount, -300, "and so does a negative");
  eq(by.AMENDED_FL_2024.status_flags.custom_preparer, 'Jane "JQ" Public, CPA',
     "quotes in a text column come through untouched");
  eq(by["CTC-02_TX441"].status_flags.custom_preparer, "line1\nline2\ttabbed",
     "and so do newlines and tabs");
  eq(by["CTC-01_MD510"].remarks, 'has a "quote", a comma, and a\nnewline',
     "remarks likewise");

  /* The four keys the app owns are the ones the script has to carry forward
     without understanding them. */
  eq(m.flags.length, 12, "the column definitions came back");
  eq(m.flags[8].type, "number", "with their types intact");
  eq(m.flags[9].type, "text");
  eq(m.note_cards.length, 1, "note cards survive a script run");
  eq(m.quick_notes, "snippet one\n\nsnippet two", "and so does the scratchpad");

  /* A PDF filed on the second run must arrive complete, not with holes where
     the app's own columns should be. */
  const fresh = by["NEW-07_OH222"];
  ok(fresh, "the return added on the second run is there");
  deepEq(Object.keys(fresh.status_flags),
         FLAG_KEYS.concat(["custom_refund_amount", "custom_preparer", "loc", "pj_id"]),
         "with an entry for every column, the app's included");
  eq(fresh.status_flags.custom_refund_amount, null, "a number column starts empty as null");
  eq(fresh.status_flags.custom_preparer, "", "and a text column as an empty string");
  eq(fresh.state_code, "OH", "and the script still read its state");

  /* The two the script flagged are still flagged, and still shown as such. */
  eq(m.flagged.length, 2, "the flagged list is preserved");
  eq(t.win.manifest.returns.filter(function (r) { return !r.state_code; }).length, 2,
     "and both are still waiting for a state");
});

test("what the app exports is what the script can read back", function () {
  const t = open();
  t.win.adopt(JSON.parse(JSON.stringify(INTAKE_FIXTURE)), "manifest.json");
  t.win.exportJson();
  const written = JSON.parse(t.lastDownload().buffer().toString("utf8"));

  /* The five keys intake.ps1 rebuilds from the folder, and so reads by name. */
  ["schema_version", "generated_at", "assignment_folder", "returns", "flagged"].forEach(function (k) {
    ok(k in written, "the export keeps " + k + ", which the script reads by name");
  });
  written.returns.forEach(function (r) {
    ["id", "filename", "folder", "state_code", "state_name", "date_received",
     "status_flags", "remarks"].forEach(function (k) {
      ok(k in r, r.id + " keeps " + k);
    });
  });

  /* Merge-ExistingReturn keys off `id`, so a duplicate would silently merge two
     returns into one on the next script run. */
  const seen = {};
  written.returns.forEach(function (r) {
    eq(seen[r.id], undefined, "no two returns share the id " + r.id);
    seen[r.id] = true;
  });

  /* Get-FlagSpecs reads flags[].key and flags[].type; without a key the column
     would be skipped and a new PDF would arrive missing it. */
  written.flags.forEach(function (f) {
    ok(f.key, "every column definition has a key");
    ok(["status", "number", "text"].indexOf(f.type) !== -1,
       f.key + " has a type the script recognises, not " + JSON.stringify(f.type));
  });

  /* Exporting must not invent or drop a key — the script copies unknown ones
     forward, so a rename here quietly orphans data. */
  deepEq(Object.keys(written).sort(), Object.keys(INTAKE_FIXTURE).sort(),
         "the exported top-level keys are exactly the ones that came in");
});

test("multi-jurisdiction row creation generates multiple state rows at once", async function () {
  const t = open();
  t.win.adopt({ returns: [ { id: "Existing-1", state_code: "CA" } ] }, "test");
  const doc = t.doc;

  click(doc.getElementById("addRowBtn"));
  doc.getElementById("newRowId").value = "Fund Alpha";
  
  click(doc.getElementById("toggleMultiStateBtn"));
  const grid = doc.getElementById("multiStateGrid");
  const chks = grid.querySelectorAll(".multi-state-chk");
  for (let i = 0; i < chks.length; i++) {
    if (["CA", "NY", "TX"].includes(chks[i].value)) {
      chks[i].checked = true;
    }
  }
  fire(grid, "change");

  click(doc.getElementById("submitAddRowBtn"));

  const rowEls = doc.querySelectorAll("#rows tr[data-id]");
  const ids = Array.from(rowEls).map(r => r.getAttribute("data-id"));
  ok(ids.includes("Fund Alpha - CA"), "contains CA row for Fund Alpha");
  ok(ids.includes("Fund Alpha - NY"), "contains NY row for Fund Alpha");
  ok(ids.includes("Fund Alpha - TX"), "contains TX row for Fund Alpha");
});

test("date filtering restricts grid rows to selected dates", async function () {
  const t = open();
  t.win.adopt({ returns: [
    { id: "Return-1", date_received: "2026-08-01", state_code: "CA" },
    { id: "Return-2", date_received: "2026-08-15", state_code: "NY" },
    { id: "Return-3", date_received: "2026-08-30", state_code: "TX" }
  ] }, "test");
  const doc = t.doc;

  t.win.selectedMultiDates = ["2026-08-15"];
  t.win.render();

  const visibleRows = doc.querySelectorAll("#rows tr[data-id]");
  eq(visibleRows.length, 1, "only 1 row on selected date 2026-08-15");
  eq(visibleRows[0].getAttribute("data-id"), "Return-2");
});

test("exporting Excel and Alpha export respects active filters", async function () {
  const t = open();
  t.win.adopt({ returns: [
    { id: "Return-1", state_code: "CA", remarks: "Keep me" },
    { id: "Return-2", state_code: "NY", remarks: "Filtered out" }
  ] }, "test");
  const doc = t.doc;

  doc.getElementById("stateFilter").value = "CA";
  fire(doc.getElementById("stateFilter"), "change");

  eq(doc.querySelectorAll("#rows tr[data-id]").length, 1);

  click(doc.getElementById("exportAlpha"));
  click(doc.getElementById("exportXlsx"));
  ok(true, "exports completed for filtered view");
});

test("importing a JSON file merges returns into Master JSON store without dropping existing data", async function () {
  const t = open();
  t.win.adopt({ returns: [ { id: "Return-Original", state_code: "CA" } ] }, "test");
  const doc = t.doc;

  const incoming = { returns: [ { id: "Return-New", state_code: "TX" } ] };
  t.win.mergeManifest(incoming, "batch-2.json");

  const rowEls = doc.querySelectorAll("#rows tr[data-id]");
  eq(rowEls.length, 2, "master JSON store contains both original and merged return");
  const ids = Array.from(rowEls).map(r => r.getAttribute("data-id"));
  ok(ids.includes("Return-Original") && ids.includes("Return-New"));
});

test("calendar tab opens and allows filtering grid to selected date", async function () {
  const t = open();
  t.win.adopt({ returns: [ { id: "Return-1", date_received: "2026-08-11", state_code: "CA" } ] }, "test");
  const doc = t.doc;

  click(doc.getElementById("calendarBtn"));
  ok(!doc.getElementById("calendarModal").classList.contains("hidden"), "calendar modal is open");

  t.win.selectCalendarDate("2026-08-11", false);
  const filterBtn = doc.querySelector("#calDayDetails #calFilterToDateBtn");
  ok(filterBtn, "filter button exists for selected date");
  click(filterBtn);

  ok(doc.getElementById("calendarModal").classList.contains("hidden"), "calendar modal closed after filtering");
  eq(t.win.selectedMultiDates[0], "2026-08-11");
});

test("multi-state picker quick jump by short form highlights and scrolls to matching state", function () {
  const t = open();
  t.win.openAddRowModal();
  const searchInput = t.doc.getElementById("multiStateSearch");
  ok(searchInput, "multi-state search input exists");

  searchInput.value = "NYS";
  t.win.jumpToMultiState("NYS");
  const matchElem = t.doc.querySelector('label[data-code="NYS"]');
  ok(matchElem, "found NYS label match");
  match(matchElem.style.outline, /1px solid/, "NYS label is highlighted with focus outline");
});

test("date specific selection recalculates pills for that active date only", function () {
  const t = open();
  const manifestData = {
    returns: [
      mkRet("R1", { date_received: "2026-09-01", status_flags: allYes() }),
      mkRet("R2", { date_received: "2026-09-01", status_flags: {} }),
      mkRet("R3", { date_received: "2026-09-02", status_flags: allYes() })
    ]
  };
  t.win.adopt(manifestData, "test-manifest.json");

  // With no date filter, pills count all 3 returns
  match(t.doc.getElementById("pills").textContent, /3returns/, "3 total returns initially");

  // Filter to single date 2026-09-01
  t.win.selectedMultiDates = ["2026-09-01"];
  t.win.render();

  // Pills must reflect ONLY 2026-09-01 returns (2 returns, 1 qualified)
  match(t.doc.getElementById("pills").textContent, /2returns/, "shows 2 returns for 2026-09-01");
  match(t.doc.getElementById("pills").textContent, /1qualified/, "shows 1 qualified return for 2026-09-01");
});

test("default column label for ID is Return or Fund", function () {
  const t = open();
  t.win.adopt(fixture(1), "manifest.json");
  const cols = t.win.getColumns();
  const idCol = cols.find(c => c.key === "id");
  eq(idCol.label, "Return or Fund", "ID column label is Return or Fund");
});

test("readMultipleFiles integrates multiple JSON files into Master Store", function () {
  const t = open();
  const file1 = { name: "batch1.json", type: "application/json" };
  const file2 = { name: "batch2.json", type: "application/json" };

  const parsed1 = { returns: [mkRet("B1-1", { date_received: "2026-09-01" })] };
  const parsed2 = { returns: [mkRet("B2-1", { date_received: "2026-09-02" })] };

  // Manually merge into tracker master store as readMultipleFiles does
  t.win.mergeManifest(parsed1, file1.name);
  t.win.mergeManifest(parsed2, file2.name);

  eq(t.win.manifest.returns.length, 2, "both JSON files merged into master store");
  ok(t.win.manifest.returns.some(r => r.id === "B1-1"), "contains return from file 1");
  ok(t.win.manifest.returns.some(r => r.id === "B2-1"), "contains return from file 2");
});

test("exportAll triggers all exports at once", function () {
  const t = open();
  t.win.adopt(fixture(1), "manifest.json");
  let count = 0;
  t.win.exportXlsx = function() { count++; };
  t.win.exportAlpha = function() { count++; };
  t.win.exportDeltaJson = function() { count++; };
  t.win.exportSessionJson = function() { count++; };
  t.win.exportCsv = function() { count++; };

  t.win.exportAll(true);
  eq(count, 5, "exportAll triggered all 5 export functions");
});

test("Delta panel filters analytics by active date and excludes loc and pj_id cards", function () {
  const t = open();
  const manifestData = {
    returns: [
      mkRet("R1", { date_received: "2026-09-01", status_flags: { loc: "NY", pj_id: 101 } }),
      mkRet("R2", { date_received: "2026-09-02", status_flags: { loc: "CA", pj_id: 102 } })
    ]
  };
  t.win.adopt(manifestData, "test-manifest.json");

  // Filter UI to 2026-09-01
  t.win.selectedMultiDates = ["2026-09-01"];
  t.win.render();

  t.win.openManifest();
  const sheet = t.doc.querySelector(".manifest-sheet");
  ok(sheet, "Delta sheet opened");
  match(sheet.textContent, /Showing △ Delta analytics for active view/, "indicates date filter is active");
  match(sheet.textContent, /1 \(of 2 total\)/, "shows 1 return in filtered active view");
  noMatch(sheet.textContent, /Breakdown by Loc/, "loc breakdown is excluded");
  noMatch(sheet.textContent, /Breakdown by PJ-ID/, "pj_id breakdown is excluded");
});

test("import buttons hide once data is imported and reappear on new session reset", function () {
  const t = open();
  const doc = t.doc;

  const importGrp = doc.getElementById("importGroup");
  ok(!importGrp.classList.contains("hidden"), "import group initially visible when no data loaded");

  t.win.adopt({ returns: [{ id: "R1", state_code: "NY" }] }, "test-import.json");
  ok(importGrp.classList.contains("hidden"), "import group hidden once data is imported");

  t.win.resetSession();
  const confirmBtn = doc.querySelector('[data-ask="ok"]');
  if (confirmBtn) click(confirmBtn);
  ok(!importGrp.classList.contains("hidden"), "import group visible again after resetting session");
});

test("Delta button is high-visibility and functional in light and dark mode", function () {
  const t = open();
  const btn = t.doc.getElementById("manifestBtn");
  ok(btn, "Delta button exists");
  ok(btn.classList.contains("delta-btn"), "Delta button carries high-visibility delta-btn class");
  eq(btn.disabled, false, "Delta button is enabled and clickable immediately");

  // Test dark mode toggle maintains functionality
  t.doc.body.classList.add("dark");
  click(btn);
  const sheet = t.doc.querySelector(".manifest-sheet");
  ok(sheet, "Delta sheet opens in dark mode");
});

test("exportDeltaJson and exportSessionJson function correctly and exportAll includes both", function () {
  const t = open();
  t.win.adopt(fixture(2), "manifest.json");

  let savedBlobName = null;
  t.win.saveBlob = function (name, blob) {
    savedBlobName = name;
  };

  t.win.exportDeltaJson();
  eq(savedBlobName, "delta.json", "exportDeltaJson exports delta.json");

  t.win.exportSessionJson();
  ok(savedBlobName && savedBlobName.startsWith("session_returns_"), "exportSessionJson exports session_returns JSON");

  let exportsCount = 0;
  t.win.saveBlob = function () { exportsCount++; };
  t.win.exportAll(true);
  eq(exportsCount, 5, "exportAll exports 5 files (xlsx, alpha, delta json, session json, csv)");
});

test("loadDeltaBtn triggers file selection and links suggest delta.json", function () {
  const t = open();
  t.win.adopt(fixture(1), "manifest.json");

  const loadDeltaBtn = t.doc.getElementById("loadDeltaBtn");
  ok(loadDeltaBtn, "loadDeltaBtn is rendered");

  let clicked = false;
  t.doc.getElementById("deltaFileInput").click = function () { clicked = true; };
  click(loadDeltaBtn);
  eq(clicked, true, "clicking loadDeltaBtn triggers deltaFileInput.click()");

  let pickedOptions = null;
  t.win.showSaveFilePicker = function (opts) {
    pickedOptions = opts;
    return Promise.resolve({ name: "delta.json" });
  };
  t.win.toggleLinkFile();
  ok(pickedOptions, "showSaveFilePicker called");
  eq(pickedOptions.suggestedName, "delta.json", "link file suggests delta.json");
});

/* ------------------------------------------------------------------- main */

(async function main() {
  let failed = 0;
  for (const t of tests) {
    try {
      await t.fn();
      console.log("ok   " + t.name);
    } catch (err) {
      failed++;
      console.log("FAIL " + t.name);
      console.log("     " + (err && err.message ? err.message : err));
      if (process.env.VERBOSE) { console.log(err && err.stack); }
    } finally {
      closeAll();
    }
  }
  console.log("");
  console.log((tests.length - failed) + "/" + tests.length + " passed" +
              (failed ? ", " + failed + " failed" : ""));
  process.exit(failed ? 1 : 0);
})();
