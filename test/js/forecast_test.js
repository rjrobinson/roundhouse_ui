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
  "module.exports = { forecast: forecast, humanizeEta: humanizeEta };",
].join("\n");

const sandbox = { module: { exports: {} } };
new Function("module", src)(sandbox.module);
const { forecast, humanizeEta } = sandbox.module.exports;

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

console.log(`forecast decision table: ${ran} cases, all passing`);
