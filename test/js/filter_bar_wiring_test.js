// The EVENT WIRING, not the pure functions — filter_bar_test.js covers those and
// still passed while the bar looked broken in a browser. What was untested was the
// layer in between: listener registration, the menu element, and whether Tab is
// actually intercepted. "Tab escapes to the help button and there is no typeahead"
// is one symptom of an empty suggestion list, and only this layer shows it.
//
// A DOM stub rather than a browser: the engine has no build step and no npm, so
// there is no jsdom to reach for. The handlers touch a small, fixed set of DOM
// APIs, and those are what is stubbed.
const assert = require("assert");
const fs = require("fs");
const erb = fs.readFileSync("app/views/layouts/roundhouse_ui/application.html.erb", "utf8");
const src = erb.slice(erb.indexOf("// ── Filter bar: Tab completes"),
                      erb.indexOf('document.addEventListener("DOMContentLoaded"'));

// --- minimum DOM the handlers actually touch ---------------------------------
function El(tag, attrs, cls) {
  const el = {
    tagName: tag, className: cls || "", hidden: false, value: "",
    children: [], _attrs: attrs || {}, classList: { contains: (c) => (cls||"").split(" ").includes(c) },
    getAttribute(a) { return this._attrs[a] !== undefined ? this._attrs[a] : null; },
    setAttribute(a, v) { this._attrs[a] = v; },
    appendChild(c) { this.children.push(c); return c; },
    querySelector(sel) { return sel.includes(".rh-ac") ? this.children.find(c => c.className === "rh-ac") || null : null; },
    matches(sel) {
      if (sel === ".rh-bar input[type=search]") return this.tagName === "INPUT" && this._attrs.type === "search";
      return false;
    },
    closest(sel) { return sel === ".rh-bar" ? bar : null; },
    focus() {}
  };
  // A real browser drops every child when innerHTML is assigned. The stub kept them,
  // so a re-render appended to the previous list and the row count was the SUM of
  // every render — which read as a product bug and was not one.
  Object.defineProperty(el, "innerHTML", {
    get() { return ""; },
    set(v) { if (v === "") el.children.length = 0; }
  });
  return el;
}
const box = El("INPUT", { type: "search",
  "data-rh-filter-keys": "class,error,queue,tag,text",
  "data-rh-filter-values": JSON.stringify({ tag: ["squad:core", "squad:platform"], queue: ["ai"] }) }, "");
const bar = El("DIV", {}, "rh-bar");
bar.children.push(box);

const listeners = {};
global.document = {
  addEventListener(t, fn) { (listeners[t] = listeners[t] || []).push(fn); },
  querySelector(sel) {
    if (sel === ".rh-bar") return bar;
    if (sel === ".rh-bar input[type=search]") return box;
    return null;
  },
  querySelectorAll() { return []; },
  createElement(t) { return El(t.toUpperCase(), {}, ""); }
};
new Function(src)();

function fire(type, ev) { (listeners[type] || []).forEach(fn => fn(ev)); }

// --- the actual user flow ----------------------------------------------------
box.value = "cla";
fire("input", { target: box });
const menu = bar.children.find(c => c.className === "rh-ac");
assert.ok(menu, "typing built no suggestion menu");
assert.strictEqual(menu.hidden, false, "the menu was built but left hidden");
assert.strictEqual(menu.children.length, 1, "expected exactly one completion for 'cla'");

let prevented = false;
fire("keydown", { key: "Tab", shiftKey: false, target: box, preventDefault: () => { prevented = true; } });
assert.ok(prevented, "Tab was not intercepted, so focus escapes to the help button");
assert.strictEqual(box.value, "class=", "Tab must complete the key in place");

box.value = "tag=squad:p";
fire("input", { target: box });
fire("keydown", { key: "Tab", shiftKey: false, target: box, preventDefault: () => {} });
assert.strictEqual(box.value, "tag=squad:platform ", "Tab must complete a value and start a new token");

// Focusing an empty box must offer the keys, or Tab has no target at all — which
// is what made the bar feel inert.
box.value = "";
acItemsCheck = null;
fire("focusin", { target: box });
const onFocus = bar.children.find((c) => c.className === "rh-ac");
assert.ok(onFocus && !onFocus.hidden, "focusing an empty box offered nothing");
assert.strictEqual(onFocus.children.length, 4, "expected the four facet keys, not text=");

let escaped = false;
fire("keydown", { key: "Tab", shiftKey: false, target: box, preventDefault: () => { escaped = true; } });
assert.ok(escaped, "Tab on a freshly focused empty box must complete, not move focus");

// Shift+Tab must always move focus, or the bar is a keyboard trap.
let trapped = false;
box.value = "cla";
fire("input", { target: box });
fire("keydown", { key: "Tab", shiftKey: true, target: box, preventDefault: () => { trapped = true; } });
assert.ok(!trapped, "Shift+Tab must move focus backwards, never be swallowed");

console.log("bar wiring: 9 cases, all passing");
