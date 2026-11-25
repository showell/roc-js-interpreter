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
// reading is past BUDGET_MS.

const BUDGET_MS = 20000;
const BASE = 10000000; // 10^7: a limb, and the sum of two limbs and a carry, stay exact
const SHARE = 0.5; // a batch may plan to use this share of the time left
const LAST_MS = 25; // stop when a share of the time left is less than this
const GROWTH = 4; // a batch is at most this many times the last one
const LIMBS_PER_STEP = 0.20898764 / 7; // log10 of the golden ratio, in limbs

// a += b, in place; a and b are limb arrays, b no longer than a + 1.
function addInto(a, b) {
  let carry = 0;
  let i = 0;
  while (i < b.length) {
    let s = (i < a.length ? a[i] : 0) + b[i] + carry;
    if (s >= BASE) {
      s = s - BASE;
      carry = 1;
    } else {
      carry = 0;
    }
    if (i < a.length) {
      a[i] = s;
    } else {
      a.push(s);
    }
    i = i + 1;
  }
  while (carry > 0) {
    if (i < a.length) {
      let s = a[i] + carry;
      if (s >= BASE) {
        a[i] = s - BASE;
      } else {
        a[i] = s;
        carry = 0;
      }
    } else {
      a.push(carry);
      carry = 0;
    }
    i = i + 1;
  }
}

// A limb as exactly 7 digits, zeros in front.
function seven(limb) {
  let s = "" + limb;
  while (s.length < 7) s = "0" + s;
  return s;
}

// The number's decimal digits.
function digitsOf(limbs) {
  let s = "" + limbs[limbs.length - 1];
  let i = limbs.length - 2;
  while (i >= 0) {
    s = s + seven(limbs[i]);
    i = i - 1;
  }
  return s;
}

function digitCount(limbs) {
  return (limbs.length - 1) * 7 + ("" + limbs[limbs.length - 1]).length;
}

// The state: lo is F(n - 1) and hi is F(n), but each step adds the smaller
// into the larger's place, so which array holds which swaps every step.
let x = [0]; // F(0)
let y = [1]; // F(1)
let n = 1;
let hiIsY = true;

function steps(k) {
  let j = 0;
  while (j < k) {
    if (hiIsY) {
      addInto(x, y); // x = F(n - 1) + F(n) = F(n + 1)
    } else {
      addInto(y, x);
    }
    hiIsY = !hiIsY;
    n = n + 1;
    j = j + 1;
  }
}

function hi() {
  return hiIsY ? y : x;
}

const start = Date.now();
steps(999); // F(1000)
const f1000 = digitsOf(hi());
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
  const L = hi().length;
  const a = perLimb * LIMBS_PER_STEP / 2;
  const b = perLimb * L;
  let k = Math.floor((-b + Math.sqrt(b * b + 4 * a * plan)) / (2 * a));
  if (k > GROWTH * lastBatch) k = GROWTH * lastBatch;
  if (k < 1) break;
  const before = Date.now();
  const lengthBefore = hi().length;
  steps(k);
  const after = Date.now();
  elapsed = after - start;
  batches = batches + 1;
  lastBatch = k;
  const took = after - before;
  const limbs = k * (lengthBefore + hi().length) / 2;
  if (took > 0) perLimb = took / limbs;
}

// The first and last digits from the top and bottom limbs alone: the whole
// number as text would be long, and slow to build where strings copy.
const h = hi();
let top = "" + h[h.length - 1];
let i = h.length - 2;
while (top.length < 20 && i >= 0) {
  top = top + seven(h[i]);
  i = i - 1;
}
let bottom = "";
let j = 0;
while (bottom.length < 21 && j < h.length - 1) {
  bottom = seven(h[j]) + bottom;
  j = j + 1;
}
console.log("F(1000) ends " + f1000.slice(f1000.length - 12));
console.log("reached F(" + n + "): " + digitCount(h) + " digits");
console.log("first digits " + top.slice(0, 20) + ", last digits " + bottom.slice(bottom.length - 20));
console.log("batches " + batches + ", elapsed " + elapsed + " ms of " + BUDGET_MS);
console.log(elapsed <= BUDGET_MS ? "PASS" : "FAIL");
