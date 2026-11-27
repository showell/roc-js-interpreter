// node_clock -- node's timers on a virtual clock, so the oracle can't depend
// on the box's load.
//
//   node --require <this file's path> program.js
//
// node runs a program's timers on the real clock, so on a busy box its own
// order moves: in js/tests/37-interval.js the interval's second tick is set
// from when its first actually ran, and once a callback runs late enough the
// timeout set for "between ticks 2 and 3" comes before tick 2 (seen with
// CPU burners beside it, 2026-11-27). The subset's timers run on a virtual
// clock (js/README.md, "Timers run after the program"; js/roc/Events.roc),
// which is node's order on a machine with no delays, and that is what this
// file gives node: each of setTimeout, setInterval, clearTimeout and
// clearInterval is replaced by one on a clock that reads 0 while the program
// runs and moves to each callback's time as it runs. Once the program ends
// (`beforeExit`), the timers run earliest first, two due at one time in the
// order they were set, an interval set again `ms` after its due time, until
// none is left. A delay is coerced as node coerces it (below 1, past
// 2^31 - 1, or not a number: 1 ms); a callback that isn't a function is
// handed to node's own setTimeout, which throws node's own error. A throw
// nothing catches in a callback is node's uncaught exception, reported as
// node reports it. It is a CommonJS file, loaded by `--require`: under
// `--import` node runs the program through its ES module loader, and its
// report of a throw of a value that isn't an error (44-uncaught-value.js)
// then names node's own loader where it names the program's line.
//
// js/page_check.mjs, js/oracle.shale and x86/executables.shale's `node_run`
// start node with it, each where it asks node what a program prints.

const nodeSetTimeout = globalThis.setTimeout;
const TIMEOUT_MAX = 2 ** 31 - 1;

let clock = 0;
let made = 0;
const pending = [];

class Timeout {
  constructor(id, callback, args, every) {
    this.id = id;
    this.callback = callback;
    this.args = args;
    this.every = every;
    this.due = 0;
    this.order = 0;
    this.cleared = false;
  }
  ref() { return this; }
  unref() { return this; }
  hasRef() { return true; }
  [Symbol.toPrimitive]() { return this.id; }
}

function delayOf(ms) {
  const after = ms * 1;
  return after >= 1 && after <= TIMEOUT_MAX ? after : 1;
}

function queued(timer, ms) {
  timer.due = clock + ms;
  timer.order = made++;
  pending.push(timer);
  return timer;
}

function set(callback, ms, args, repeats) {
  if (typeof callback !== "function") return nodeSetTimeout(callback, ms);
  const after = delayOf(ms);
  return queued(new Timeout(made, callback, args, repeats ? after : null), after);
}

function clear(timer) {
  if (timer instanceof Timeout) { timer.cleared = true; return; }
  if (timer === undefined || timer === null) return;
  for (const t of pending) if (t.id === Number(timer)) t.cleared = true;
}

globalThis.setTimeout = (callback, ms, ...args) => set(callback, ms, args, false);
globalThis.setInterval = (callback, ms, ...args) => set(callback, ms, args, true);
globalThis.clearTimeout = clear;
globalThis.clearInterval = clear;

function earliest() {
  let at = -1;
  for (let i = 0; i < pending.length; i++) {
    const t = pending[i];
    if (at < 0 || t.due < pending[at].due || (t.due === pending[at].due && t.order < pending[at].order)) at = i;
  }
  return at;
}

process.on("beforeExit", () => {
  for (let at = earliest(); at >= 0; at = earliest()) {
    const [timer] = pending.splice(at, 1);
    if (timer.cleared) continue;
    clock = timer.due;
    timer.callback.apply(timer, timer.args);
    if (timer.every !== null && !timer.cleared) queued(timer, timer.every);
  }
});
