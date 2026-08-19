"use strict";

/* Boots index.html inside jsdom and hands back the live window.
 *
 * The app is one classic <script>, so every top-level `var` and `function` in
 * it is a property of `window`. That is what makes it testable at all: the
 * tests call adopt()/exportCsv()/undo() directly and dispatch real DOM events
 * for anything the user would click or type.
 *
 * jsdom is missing a handful of browser APIs the app leans on (TextEncoder,
 * URL.createObjectURL, CSS.escape, clipboard). They are injected before the
 * script is evaluated, and Blob is replaced with a version that keeps its bytes
 * so a download can be inspected byte-for-byte. */

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const { JSDOM } = require("jsdom");

const APP = path.join(__dirname, "..", "index.html");

/* ------------------------------------------------------------------ blobs */

class TestBlob {
  constructor(parts, opts) {
    this.parts = parts || [];
    this.type = (opts && opts.type) || "";
  }
  buffer() {
    const chunks = [];
    const walk = (part) => {
      if (part == null) { return; }
      if (typeof part === "string") { chunks.push(Buffer.from(part, "utf8")); }
      else if (part instanceof TestBlob) { chunks.push(part.buffer()); }
      /* ArrayBuffer.isView, not `instanceof Uint8Array`: the app runs inside the
       * jsdom realm, so its typed arrays are not instances of this realm's. */
      else if (ArrayBuffer.isView(part)) { chunks.push(Buffer.from(part.buffer, part.byteOffset, part.byteLength)); }
      else if (Array.isArray(part)) { part.forEach(walk); }
      else { chunks.push(Buffer.from(String(part), "utf8")); }
    };
    this.parts.forEach(walk);
    return Buffer.concat(chunks);
  }
  text() { return Promise.resolve(this.buffer().toString("utf8")); }
  get size() { return this.buffer().length; }
}

/* ZIP entries written by zipStore() are all STORED (method 0), so the payload
 * needs no inflating — walk the local headers and slice. The CRC in each header
 * is checked against zlib's, which is the real test of the hand-rolled one. */
function unzipStored(buf) {
  const out = {};
  let i = 0;
  while (i + 30 <= buf.length && buf.readUInt32LE(i) === 0x04034b50) {
    const method = buf.readUInt16LE(i + 8);
    const crc = buf.readUInt32LE(i + 14);
    const size = buf.readUInt32LE(i + 18);
    const nameLen = buf.readUInt16LE(i + 26);
    const extraLen = buf.readUInt16LE(i + 28);
    const name = buf.slice(i + 30, i + 30 + nameLen).toString("utf8");
    const start = i + 30 + nameLen + extraLen;
    const data = buf.slice(start, start + size);
    out[name] = { data, method, crc, crcOk: zlib.crc32(data) === crc };
    i = start + size;
  }
  return out;
}

/* ------------------------------------------------------------------- boot */

function boot(options) {
  const opts = options || {};
  const html = fs.readFileSync(APP, "utf8");
  const scriptMatch = html.match(/<script>([\s\S]*?)<\/script>/);
  if (!scriptMatch) { throw new Error("no <script> found in " + APP); }
  const source = scriptMatch[1];

  /* Parse the page with the script removed, shim what jsdom lacks, then run it. */
  const dom = new JSDOM(html.replace(scriptMatch[0], ""), {
    url: "http://localhost/index.html", // file:// gives an opaque origin and no localStorage
    pretendToBeVisual: true,
    runScripts: "dangerously"           // needed so the app runs as a real classic script
  });

  const win = dom.window;
  const downloads = [];

  win.TextEncoder = TextEncoder;
  win.TextDecoder = TextDecoder;
  win.Blob = TestBlob;
  win.URL.createObjectURL = function (blob) { downloads.push(blob); return "blob:test/" + downloads.length; };
  win.URL.revokeObjectURL = function () {};

  if (!win.CSS || typeof win.CSS.escape !== "function") {
    win.CSS = win.CSS || {};
    win.CSS.escape = function (v) { return String(v).replace(/["\\\]\[]/g, "\\$&"); };
  }
  Object.defineProperty(win.navigator, "clipboard", {
    configurable: true,
    value: { writeText: function () { return Promise.resolve(); } }
  });
  Object.defineProperty(win.navigator, "platform", { configurable: true, value: opts.platform || "MacIntel" });

  /* Layout APIs jsdom either lacks or leaves unimplemented. */
  win.Element.prototype.scrollIntoView = function () {};
  win.Element.prototype.setPointerCapture = function () {};
  win.Element.prototype.releasePointerCapture = function () {};

  /* Anchor clicks would try to navigate in jsdom; the blob is already captured. */
  const realClick = win.HTMLAnchorElement.prototype.click;
  win.HTMLAnchorElement.prototype.click = function () {
    if (this.download) { return; }
    return realClick.apply(this, arguments);
  };

  if (opts.localStorage === false) {
    /* A browser in private mode: every access throws. */
    Object.defineProperty(win, "localStorage", {
      configurable: true,
      get() { throw new win.DOMException("denied", "SecurityError"); }
    });
  } else if (opts.seedDraft) {
    win.localStorage.setItem("returns-tracker-draft-v1", JSON.stringify(opts.seedDraft));
  }
  if (opts.seedPrefs) {
    win.localStorage.setItem("returns-tracker-prefs-v1", JSON.stringify(opts.seedPrefs));
  }

  /* Run the app the way the browser does — as a classic <script>. `win.eval`
   * would not do: the source opens with "use strict", and a strict eval keeps
   * its own variable environment, so none of the top-level vars/functions the
   * tests reach for would land on window. */
  const tag = win.document.createElement("script");
  tag.textContent = source;
  win.document.body.appendChild(tag);

  return {
    dom,
    win,
    doc: win.document,
    downloads,
    lastDownload() { return downloads[downloads.length - 1]; },
    unzipStored,
    TestBlob
  };
}

/* ------------------------------------------------------------------ events */

function fire(node, type, props) {
  const win = node.ownerDocument.defaultView;
  const ev = new win.Event(type, { bubbles: true, cancelable: true });
  Object.assign(ev, props || {});
  node.dispatchEvent(ev);
  return ev;
}

function click(node, props) {
  const win = node.ownerDocument.defaultView;
  const ev = new win.MouseEvent("click", Object.assign({ bubbles: true, cancelable: true }, props || {}));
  node.dispatchEvent(ev);
  return ev;
}

function key(node, k, props) {
  const win = node.ownerDocument.defaultView;
  const ev = new win.KeyboardEvent("keydown", Object.assign(
    { key: k, bubbles: true, cancelable: true }, props || {}));
  node.dispatchEvent(ev);
  return ev;
}

function dataTransfer() {
  const store = {};
  return {
    effectAllowed: "",
    dropEffect: "",
    setData(type, val) { store[type] = String(val); },
    getData(type) { return store[type] || ""; }
  };
}

/* Drag row `fromTr` onto `toTr`. `where` is "above" or "below"; every rect in
 * jsdom is zero-sized, so clientY of -1 / 1 straddles the midpoint reliably. */
function dragRow(fromTr, toTr, where) {
  const dt = dataTransfer();
  const handle = fromTr.querySelector(".drag-handle");
  fire(handle, "dragstart", { dataTransfer: dt });
  const clientY = where === "above" ? -1 : 1;
  fire(toTr, "dragover", { dataTransfer: dt, clientY });
  fire(toTr, "drop", { dataTransfer: dt, clientY });
  fire(handle, "dragend", { dataTransfer: dt });
}

/* Drag a column header handle onto another data-column header. */
function dragColumn(fromTh, toTh, where) {
  const dt = dataTransfer();
  const handle = fromTh.querySelector(".col-drag-handle");
  const headRow = fromTh.parentElement;
  fire(handle, "dragstart", { dataTransfer: dt });
  const clientX = where === "before" ? -1 : 1;
  fire(toTh, "dragover", { dataTransfer: dt, clientX });
  fire(toTh, "drop", { dataTransfer: dt, clientX });
  fire(headRow, "dragend", { dataTransfer: dt });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

module.exports = { boot, fire, click, key, dragRow, dragColumn, dataTransfer, sleep, unzipStored, TestBlob, APP };
