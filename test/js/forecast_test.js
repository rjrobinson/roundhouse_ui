// Decision-table test for the drain forecast (#35).
//
// The forecast lives in the layout because it needs the browser's previous
// sample, and the layout is inline because Roundhouse has no build step. So this
// lifts the pure functions straight out of the ERB rather than duplicating them
// — a copy here would drift, which is the exact failure this project already hit
// with duration formatting (#31).
const fs = require("fs");
const assert = require("assert");

const erb = fs.readFileSync("app/views/layouts/roundhouse_ui/application.html.erb", "utf8");

function lift(name) {
  const start = erb.indexOf("function " + name + "(");
  assert.notStrictEqual(start, -1, "could not find function " + name + " in the layout");
  let depth = 0, i = erb.indexOf("{", start);
  const open = i;
  for (; i < erb.length; i++) {
    if (erb[i] === "{") depth++;
    else if (erb[i] === "}" && --depth === 0) break;
  }
  return erb.slice(start, i + 1);
}

// humanizeEta and rateLabel are pure; forecast reads STALLED_PER_MIN.
const src = [
  "var STALLED_PER_MIN = 1;",
  lift("humanizeEta"),
  lift("rateLabel"),
  lift("forecast"),
  lift("capacity"),
  "module.exports = { forecast: forecast, humanizeEta: humanizeEta, capacity: capacity };",
].join("\n");

const sandbox = { module: { exports: {} } };
new Function("module", src)(sandbox.module);
const { forecast, humanizeEta, capacity } = sandbox.module.exports;

let ran = 0;
function check(label, actual, expected) {
  assert.strictEqual(actual, expected, `${label}: expected ${expected}, got ${actual}`);
  ran++;
}

// An empty queue is not "draining", it is done — and says so regardless of noise.
check("empty", forecast(0, null).text, "clear");
check("empty while growing", forecast(0, 5).text, "clear");

// One sample cannot produce a velocity. Saying so beats implying zero.
check("no sample", forecast(500, null).text, "measuring…");
assert.strictEqual(forecast(500, null).cls, "rh-fc-wait");

// The state that matters during an incident.
check("growing fast", forecast(84210, 12).text, "growing 12/s — will not drain");
check("growing slowly", forecast(400, 0.5).text, "growing 30/min — will not drain");
assert.strictEqual(forecast(400, 0.5).cls, "rh-fc-growing");

// Draining, with the sign handled correctly — a negative velocity must not
// produce a negative ETA.
check("drains in minutes", forecast(84210, -40).text, "clears in ~35m");
check("drains in seconds", forecast(120, -4).text, "clears in ~30s");
check("drains in hours", forecast(360000, -40).text, "clears in ~2.5h");
assert.ok(!forecast(84210, -40).text.includes("-"), "an ETA must never render negative");

// Below a job a minute either way, nothing is happening in either direction and
// an ETA would be precision invented from noise.
check("stalled at zero", forecast(900, 0).text, "stalled");
check("stalled draining imperceptibly", forecast(900, -0.01).text, "stalled");
check("stalled growing imperceptibly", forecast(900, 0.01).text, "stalled");

// The boundary itself: one job a minute is movement, just barely — and 900 jobs
// at that rate is fifteen hours, which is the honest answer rather than a
// reassuring one.
check("just above the floor", forecast(900, -1 / 60 - 0.0001).text, "clears in ~14.9h");
check("just below the floor", forecast(900, -1 / 60 + 0.0001).text, "stalled");

// A small queue draining slowly is draining, not stalled — the floor is a rate,
// not a fraction of depth, precisely so this case reads correctly.
check("small queue, slow drain", forecast(20, -0.3).text, "clears in ~1m");

// ---- capacity (#36) ------------------------------------------------------
// Whole-fleet sizing. The trap this table exists to pin: sizing to the backlog
// alone under-provisions exactly when it matters, because work keeps arriving
// while you drain.

// 3600 backlog, 10/s throughput, 5 threads, no arrivals, clear within an hour.
// 3600/3600 = 1/s needed, perThread = 2/s → 1 thread would do, fleet already
// clears it.
check("fleet already sufficient", capacity(3600, 10, -10, 5, 3600).text, "5 ✓");

// Same fleet, but 84k waiting and still growing 12/s. Needed rate is
// 84000/3600 + (10+12) = 45.3/s, perThread = 2/s → 23 threads, so +18.
check("badly under-provisioned", capacity(84000, 10, 12, 5, 3600).text, "+18");
assert.ok(capacity(84000, 10, 12, 5, 3600).note.includes("23 threads"),
  "the note has to say the total, not just the delta");

// Arrivals must count. Same backlog and fleet, once with inflow and once
// without: ignoring inflow would give the same answer, which is the bug.
const withInflow = capacity(36000, 10, 20, 5, 3600).text;
const noInflow = capacity(36000, 10, -10, 5, 3600).text;
assert.notStrictEqual(withInflow, noInflow, "arrival rate must change the answer");

// A shorter deadline needs more threads. Monotonic, or the control lies.
const hour = parseInt(capacity(84000, 10, 0, 5, 3600).text, 10);
const quarter = parseInt(capacity(84000, 10, 0, 5, 900).text, 10);
assert.ok(quarter > hour, `15m (${quarter}) must need more than 1h (${hour})`);

// Degenerate inputs say so rather than rendering Infinity or NaN.
check("no workers", capacity(5000, 0, 0, 0, 3600).text, "—");
assert.ok(capacity(5000, 0, 0, 0, 3600).note.includes("no workers"));
check("no throughput yet", capacity(5000, 0, 0, 5, 3600).text, "—");
check("empty backlog", capacity(0, 10, 0, 5, 3600).text, "0");

// Never a fractional thread, and never a negative suggestion.
[ [ 84000, 10, 12, 5 ], [ 137, 3.3, 0.7, 2 ], [ 9, 0.4, -0.1, 1 ] ].forEach(function (a) {
  const t = capacity(a[0], a[1], a[2], a[3], 3600).text;
  assert.ok(/^(\+?\d+( ✓)?|—)$/.test(t), `capacity must be a whole thread count, got ${t}`);
});

console.log(`forecast decision table: ${ran} cases, all passing`);
console.log("capacity decision table: 11 cases, all passing");
