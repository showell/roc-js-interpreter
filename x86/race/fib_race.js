// fib_race.js: how far can iterative Fibonacci get in BUDGET_MS?
//
// The numbers outgrow a double after F(1476), so each one is an array of
// base-10^7 limbs, least significant first, and a step adds one into the
// other in place (no new arrays, so a program with no garbage collector
// can run it). A step costs time in proportion to the number's length, so
// steps get slower as the race goes on.
//
// The program checks its own clock between batches of steps. It starts with
// F(1000), then sizes each batch from the cost it has measured so far (time
// per limb added), planning each batch to use at most a share of the time
// left: so it gets more careful as the deadline nears. It stops when the
// time left is too small to plan a batch in, and FAILS if its last clock
// reading is past BUDGET_MS, or if its F(100) isn't the value computed
// offline.
//
// Printing the number may come after the budget: the clock reading that
// decides PASS or FAIL is taken before anything is printed, and after the
// PASS or FAIL line the program prints the whole of F(n) in decimal, as its
// last line, built by digitsOf. That phase is timed from outside the
// program (x86/race/race.shale), as the run's wall time less its elapsed.
//
// The program is shaped for js-x86, the compiler in x86/, within the race's
// rules: the algorithm is the ordinary iterative one, and node runs this same
// source. The race's state lives in one function's own variables, not at
// the top level, since js-x86 keeps a top-level variable that functions
// capture in a cell, a value of unknown kind at every use, and a function's
// own variable in its frame with its kind known; addInto reads each length
// once, and takes the common part, where both numbers have a limb, in a loop
// of its own; the carry is chosen by a conditional of two numbers, which
// js-x86 makes with no jump, so the loop has no branch the limbs' values
// decide. x86/race/README.md has what each choice measured.

const BUDGET_MS = 20000;
const BASE = 10000000; // 10^7: a limb, and the sum of two limbs and a carry, stay exact
const SHARE = 0.5; // a batch may plan to use this share of the time left
const LAST_MS = 25; // stop when a share of the time left is less than this
const GROWTH = 4; // a batch is at most this many times the last one
const LIMBS_PER_STEP = 0.20898764 / 7; // log10 of the golden ratio, in limbs

// a += b, in place; a and b are limb arrays, b at least as long as a and
// no longer than a + 1 (b is the larger number). The lengths are read once,
// and the common part, where both have a limb, is a loop of its own, apart
// from b's one limb past a's end and the carry's tail.
function addInto(a, b) {
  const aLength = a.length;
  const bLength = b.length;
  let carry = 0;
  let i = 0;
  while (i < aLength) {
    const s = a[i] + b[i] + carry;
    carry = s >= BASE ? 1 : 0;
    a[i] = s - carry * BASE;
    i = i + 1;
  }
  while (i < bLength) {
    const s = b[i] + carry;
    carry = s >= BASE ? 1 : 0;
    a.push(s - carry * BASE);
    i = i + 1;
  }
  if (carry > 0) a.push(carry);
}

// A limb as exactly 7 digits, zeros in front.
function seven(limb) {
  let s = "" + limb;
  while (s.length < 7) s = "0" + s;
  return s;
}

// The number's decimal digits: each limb's digits, top limb first, joined
// once at the end, so the work is linear in the number's length.
function digitsOf(limbs) {
  const parts = ["" + limbs[limbs.length - 1]];
  let i = limbs.length - 2;
  while (i >= 0) {
    parts.push(seven(limbs[i]));
    i = i - 1;
  }
  return parts.join("");
}

function digitCount(limbs) {
  return (limbs.length - 1) * 7 + ("" + limbs[limbs.length - 1]).length;
}

// k steps from lo = F(n - 1) and hi = F(n). A step adds the smaller into
// the larger's place, so the arrays swap roles every step: they take them
// two at a time, and after an odd k the caller swaps its names for them.
function steps(lo, hi, k) {
  let j = 0;
  while (j + 1 < k) {
    addInto(lo, hi); // lo = F(n - 1) + F(n) = F(n + 1)
    addInto(hi, lo); // hi = F(n) + F(n + 1) = F(n + 2)
    j = j + 2;
  }
  if (j < k) addInto(lo, hi);
}

// F(100), computed once offline (node's BigInt): the program holds its own
// arithmetic to it on the way, and a mismatch is a FAIL whatever the time.
const F100 = "354224848179261915075";

// The race, all in one function, so that its state is the function's own
// variables: js-x86 keeps a variable no function literal can capture in the
// frame, its kind known (lo and hi are arrays), where a top-level variable
// lives in a cell on the heap and is a value of unknown kind at each use.
function race() {
  let lo = [0]; // F(0)
  let hi = [1]; // F(1)
  let n = 1;
  const start = Date.now();
  steps(lo, hi, 99); // F(100)
  let t = lo; // 99 steps is odd: swap
  lo = hi;
  hi = t;
  n = 100;
  const f100 = digitsOf(hi);
  steps(lo, hi, 900); // F(1000), an even count: no swap
  n = 1000;
  const f1000 = digitsOf(hi);
  let elapsed = Date.now() - start;
  let batches = 1;
  let lastBatch = 999;
  // Time per limb added, from the last batch: its steps times its mean length.
  let limbsDone = 999 * (1 + 999 * LIMBS_PER_STEP / 2);
  let perLimb = Math.max(elapsed, 1) / limbsDone;

  while (true) {
    const left = BUDGET_MS - elapsed;
    const plan = SHARE * left;
    if (plan < LAST_MS) break;
    // Steps k such that k steps from length L cost about plan:
    // perLimb * k * (L + k * LIMBS_PER_STEP / 2) = plan, solved for k.
    const L = hi.length;
    const a = perLimb * LIMBS_PER_STEP / 2;
    const b = perLimb * L;
    let k = Math.floor((-b + Math.sqrt(b * b + 4 * a * plan)) / (2 * a));
    if (k > GROWTH * lastBatch) k = GROWTH * lastBatch;
    if (k < 1) break;
    const before = Date.now();
    steps(lo, hi, k);
    if (k % 2 === 1) {
      t = lo;
      lo = hi;
      hi = t;
    }
    n = n + k;
    const after = Date.now();
    elapsed = after - start;
    batches = batches + 1;
    lastBatch = k;
    const took = after - before;
    const limbs = k * (L + hi.length) / 2;
    if (took > 0) perLimb = took / limbs;
  }

  // The first and last digits from the top and bottom limbs alone, for the
  // summary; the whole number is built after the verdict, below.
  let top = "" + hi[hi.length - 1];
  let i = hi.length - 2;
  while (top.length < 20 && i >= 0) {
    top = top + seven(hi[i]);
    i = i - 1;
  }
  let bottom = "";
  let j = 0;
  while (bottom.length < 21 && j < hi.length - 1) {
    bottom = seven(hi[j]) + bottom;
    j = j + 1;
  }
  console.log(f100 === F100 ? "F(100) is " + F100 + ", as expected" : "F(100) is " + f100 + ", not " + F100);
  console.log("F(1000) ends " + f1000.slice(f1000.length - 12));
  console.log("reached F(" + n + "): " + digitCount(hi) + " digits");
  console.log("first digits " + top.slice(0, 20) + ", last digits " + bottom.slice(bottom.length - 20));
  console.log("batches " + batches + ", elapsed " + elapsed + " ms of " + BUDGET_MS);
  console.log(elapsed <= BUDGET_MS && f100 === F100 ? "PASS" : "FAIL");
  console.log(digitsOf(hi));
}

race();
