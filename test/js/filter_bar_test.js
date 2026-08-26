// Decision table for the filter bar's completion, lifted from the layout rather
// than copied. A copy drifts — which this project has already been bitten by
// twice (duration formatting in #31, CARD_CUMULATIVE in the card tests).
//
// The property under test is the one that made 2A viable: Tab completes and
// stays, and once a facet is FINISHED there is nothing left to suggest — which is
// what lets Enter fall through to submitting instead of re-completing forever.
// The mockup shipped with exactly that bug and could never produce a pill.
const fs = require("fs");
const assert = require("assert");

const erb = fs.readFileSync("app/views/layouts/roundhouse_ui/application.html.erb", "utf8");

function lift(name) {
  const start = erb.indexOf("function " + name + "(");
  assert.notStrictEqual(start, -1, "could not find function " + name + " in the layout");
  let depth = 0, i = erb.indexOf("{", start);
  for (; i < erb.length; i++) {
    if (erb[i] === "{") depth++;
    else if (erb[i] === "}" && --depth === 0) break;
  }
  return erb.slice(start, i + 1);
}

const KEYS = "class,error,queue,tag,text";
const VALUES = { queue: ["default", "default_low", "ai"], tag: ["squad:core", "squad:platform"] };

// A stand-in for the input element: only the two data attributes and .value are
// read by the lifted functions.
function fakeBox(value) {
  return {
    value: value,
    getAttribute: function (a) {
      if (a === "data-rh-filter-keys") return KEYS;
      if (a === "data-rh-filter-values") return JSON.stringify(VALUES);
      return null;
    }
  };
}

const sandbox = { JSON: JSON };
new Function("sandbox", [
  lift("acData"), lift("acSplit"), lift("acSuggest"),
  "sandbox.acSplit = acSplit; sandbox.acSuggest = acSuggest;"
].join("\n"))(sandbox);
const { acSplit, acSuggest } = sandbox;
const suggest = (v) => acSuggest(fakeBox(v), acSplit(v).token).map((s) => s.insert);

// ── the token being completed is the LAST one, never the whole box ────────────
const SPLITS = [
  ["cla",                        { head: "", token: "cla" }],
  ["class=A err",                { head: "class=A ", token: "err" }],
  ["class=A ",                   { head: "class=A ", token: "" }],
  ["",                           { head: "", token: "" }]
];
SPLITS.forEach(([input, want]) => {
  assert.deepStrictEqual(acSplit(input), want, "acSplit(" + JSON.stringify(input) + ")");
});
console.log("bar token split: " + SPLITS.length + " cases, all passing");

// ── key completion ───────────────────────────────────────────────────────────
assert.deepStrictEqual(suggest("cla"), ["class="]);
assert.deepStrictEqual(suggest("t"), ["tag=", "text="], "every matching key, in KEYS order");
assert.deepStrictEqual(suggest(""), [], "an empty box suggests nothing");
assert.deepStrictEqual(suggest("zzz"), [], "no key matches");
// THE bug from the mockup: a key already complete has nothing left to complete,
// so the menu closes and Enter can submit.
assert.deepStrictEqual(suggest("class"), [], "a finished key must not re-suggest itself");

// ── value completion, only for keys with a free vocabulary ───────────────────
assert.deepStrictEqual(suggest("queue=def"), ["queue=default", "queue=default_low"]);
assert.deepStrictEqual(suggest("queue=default"), ["queue=default_low"],
  "an exact match drops out; only the genuine completions remain");
assert.deepStrictEqual(suggest("queue=default_low"), [],
  "a finished facet must not re-suggest itself, or Enter never applies");
assert.deepStrictEqual(suggest("tag=squad:p"), ["tag=squad:platform"]);
assert.deepStrictEqual(suggest("class=Bil"), [],
  "class values need a whole-set scan and are deliberately not offered");
assert.deepStrictEqual(suggest("QUEUE=def"), [],
  "keys are lowercase; the parser refuses anything else");

// Completion is case-insensitive on the VALUE but emits the canonical casing, so
// what lands in the box is what the exact filter will match on.
assert.deepStrictEqual(suggest("queue=DEF"), ["queue=default", "queue=default_low"]);

// A value with whitespace comes back quoted, or the next parse would read the
// space as a facet boundary and mean something different.
const spaced = acSuggest(
  { value: "", getAttribute: (a) => a === "data-rh-filter-keys" ? KEYS : JSON.stringify({ tag: ["squad:eu west"] }) },
  "tag=squad:eu"
);
assert.deepStrictEqual(spaced.map((s) => s.insert), ['tag="squad:eu west"']);

// Completing mid-query must preserve everything already settled.
assert.deepStrictEqual(suggest("error=KeyError que"), ["queue="]);
console.log("bar completion: 13 cases, all passing");

// ── no state, and no way to draw a pill early ────────────────────────────────
const src = erb.slice(erb.indexOf("// ── Filter bar:"), erb.indexOf("document.addEventListener(\"DOMContentLoaded\""));
assert.ok(!/rh-pillf['"]\s*\)|createElement\(['"]span['"]\)[\s\S]{0,200}rh-pillf/.test(src),
  "the JS must never CREATE a pill: a pill exists only because the server applied its filter");
assert.ok(/e\.key === "Tab"[\s\S]{0,200}acItems\.length/.test(src),
  "Tab must only be intercepted when there is something to complete, or the bar is a keyboard trap");
console.log("bar invariants: 2 cases, all passing");
