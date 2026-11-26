// Loop counters kept as integers (x86/README.md, "An integer kind"): whole
// literals stored to slots, `+ - *` of them with bounds, the orderings that
// narrow a counter on the way that stays in the loop, `.length`, and item
// reads and writes at an integer index. Each is held to node, with the
// cases that must not stay integers: a product that may be -0, sums past
// 2^53, a counter that takes a fraction or meets a number, a counter
// captured by a closure, and indexes past either end.

// Counters up, down, by `++` and `--` in both fixities, over an array of
// numbers read and written in place.
function counted(a) {
  const n = a.length;
  let sum = 0;
  for (let i = 0; i < n; i++) sum = sum + a[i];
  for (let i = n - 1; i >= 0; i--) a[i] = a[i] * 2;
  let up = 0;
  let pre = 0;
  while (up < n) pre = ++up;
  let down = n;
  let post = 0;
  while (down > 0) post = down--;
  let k = 0;
  while (k <= n - 1) k = k + 3;
  return [sum, a, up, pre, down, post, k];
}

// A grid walked by two counters, its place `r * width + c`.
function grid(width, height) {
  const cells = [];
  for (let r = 0; r < height; r++) {
    for (let c = 0; c < width; c++) cells.push(r * 10 + c);
  }
  const w = 4;
  let sum = 0;
  let r = 0;
  while (r < 3) {
    let c = 0;
    while (c < w) {
      sum = sum + cells[r * w + c];
      c = c + 1;
    }
    r = r + 1;
  }
  return sum;
}

// Integers at the edges: 2^53 exactly, a step past it (a double from then
// on), products that are -0 in JavaScript, and a product past 2^53.
function edges() {
  let big = 9007199254740991;
  big = big + 1;
  const past = big + 1;
  let zero = 0;
  let minus = -1;
  const negativeZero = zero * minus;
  const otherZero = minus * zero;
  let q = 94906267;
  const square = q * q;
  let small = -5;
  const product = small * 3;
  return [big, past === big, 1 / negativeZero, 1 / otherZero, square === 9007199326062756, product, 0 - 0];
}

// Counters that stop being integers: one that takes a fraction, one that
// meets a number where two ways join, one stepped past every bound, and one
// a closure captures.
function demoted(flag) {
  let half = 0;
  let steps = 0;
  while (half < 3) {
    half = half + 0.5;
    steps = steps + 1;
  }
  let met = 0;
  if (flag) met = 1.5;
  let far = 1;
  let times = 0;
  while (times < 60) {
    far = far * 2;
    times = times + 1;
  }
  const fns = [];
  for (let i = 0; i < 3; i++) fns.push(() => i);
  return [half, steps, met * 2, far === 1152921504606846976, fns.map((f) => f())];
}

// Indexes an integer can't reach in line: past the end, before the start,
// one past the end written (an append), and an index of a string.
function edgesOfArrays(words) {
  const a = [1, 2, 3];
  const read = [];
  for (let i = -1; i <= 3; i++) read.push(a[i]);
  let last = a.length;
  a[last] = 4;
  let j = 0;
  let letters = "";
  while (j < words.length) {
    letters = letters + words[j][0];
    j = j + 1;
  }
  const text = "abc";
  let t = 1;
  return [read, a, letters, text[t], "" + t + j, t < 2.5, j === 2];
}

function main() {
  console.log(counted([1, 2, 3, 4, 5]));
  console.log(grid(4, 3));
  console.log(edges());
  console.log(demoted(true), demoted(false));
  console.log(edgesOfArrays(["xy", "zw"]));
}

main();
