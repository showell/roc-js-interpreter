// fib_race.js: compute F(N), the Nth Fibonacci number, and print it.
//
// The race is a fixed amount of work: each contestant computes the same
// F(N), and x86/race.shale times each one's whole run from outside. N is
// chosen so that the compiled program takes about a minute on our box.
//
// The numbers outgrow a double after F(1476), so each one is an array of
// base-10^7 limbs, least significant first, and a step adds one into the
// other in place (no new arrays, so a program with no garbage collector
// can run it). A step costs time in proportion to the number's length, so
// the work grows as N squared.
//
// On the way the program holds its own arithmetic to F(100), computed
// offline with node's BigInt, and prints whether it matched; x86/race.shale
// holds every line it prints to BigInt's (x86/race/verify.js). It prints a
// short summary (F(100), F(1000)'s last digits, F(N)'s digit count and its
// first and last 20 digits), then the whole of F(N) in decimal, as its last
// line, built by digitsOf.
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

const N = 740000; // at least 1000; x86/race.shale's n= writes a copy with another
const BASE = 10000000; // 10^7: a limb, and the sum of two limbs and a carry, stay exact

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
// arithmetic to it on the way.
const F100 = "354224848179261915075";

// The race, all in one function, so that its state is the function's own
// variables: js-x86 keeps a variable no function literal can capture in the
// frame, its kind known (lo and hi are arrays), where a top-level variable
// lives in a cell on the heap and is a value of unknown kind at each use.
function race() {
  let lo = [0]; // F(0)
  let hi = [1]; // F(1)
  steps(lo, hi, 99); // F(100)
  let t = lo; // 99 steps is odd: swap
  lo = hi;
  hi = t;
  const f100 = digitsOf(hi);
  steps(lo, hi, 900); // F(1000), an even count: no swap
  const f1000 = digitsOf(hi);
  const rest = N - 1000;
  steps(lo, hi, rest); // F(N)
  if (rest % 2 === 1) {
    t = lo;
    lo = hi;
    hi = t;
  }

  const digits = digitsOf(hi);
  console.log(f100 === F100 ? "F(100) is " + F100 + ", as expected" : "F(100) is " + f100 + ", not " + F100);
  console.log("F(1000) ends " + f1000.slice(f1000.length - 12));
  console.log("F(" + N + "): " + digitCount(hi) + " digits");
  console.log("first digits " + digits.slice(0, 20) + ", last digits " + digits.slice(digits.length - 20));
  console.log(digits);
}

race();
