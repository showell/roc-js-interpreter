// Counters bounded by `.length` in their own loop's condition (x86/README.md,
// "A loop's head"): the length read anew each trip keeps the counter's slot,
// so the ordering narrows it and the counter stays an integer. Held to node
// over arrays that grow and shrink in the loop, a string, a bound of `<=`
// that reads one past the end, and steps that pass the length.

// The sum of an array, read through its length each trip.
function summed(a) {
  let s = 0;
  for (let i = 0; i < a.length; i++) s = s + a[i];
  return s;
}

// An array that grows while it is walked: each item under 3 pushes one more.
function grown() {
  const a = [0, 1, 2, 5];
  let seen = 0;
  for (let i = 0; i < a.length; i++) {
    if (a[i] < 3) a.push(a[i] + 10);
    seen = seen + 1;
  }
  return [seen, a];
}

// An array that shrinks while it is walked: a pop each trip meets the
// counter halfway.
function shrunk() {
  const a = [1, 2, 3, 4, 5, 6, 7];
  let last = -1;
  let trips = 0;
  for (let i = 0; i < a.length; i++) {
    a.pop();
    last = i;
    trips++;
  }
  return [trips, last, a];
}

// `shift` and `splice` in the loop, and a `while` over the length.
function spliced() {
  const a = [9, 8, 7, 6, 5, 4, 3, 2, 1];
  const out = [];
  let i = 0;
  while (i < a.length) {
    out.push(a[i]);
    if (i % 2 === 0) a.splice(i, 1);
    i = i + 1;
  }
  const b = [1, 2, 3, 4];
  let j = 0;
  while (j < b.length) {
    out.push(b.shift() * 100 + j);
    j++;
  }
  return [out, a, b];
}

// `<=` reads one past the end: `undefined` there, as node.
function past() {
  const a = [3, 4, 5];
  const out = [];
  for (let i = 0; i <= a.length; i++) out.push(a[i]);
  return out;
}

// A string's length bounds a counter, and steps of 3 pass it.
function letters(s) {
  let codes = 0;
  for (let i = 0; i < s.length; i++) codes = codes + s.charCodeAt(i);
  let k = 0;
  let steps = 0;
  while (k < s.length) {
    k = k + 3;
    steps++;
  }
  return [codes, k, steps];
}

// Two counters, the inner bounded by the length of the outer's item.
function rows(grid) {
  let s = 0;
  for (let r = 0; r < grid.length; r++) {
    const row = grid[r];
    for (let c = 0; c < row.length; c++) s = s + row[c] * (r + 1);
  }
  return s;
}

// A counter whose last trip ends past the length it grows toward.
function chase() {
  const a = [];
  let i = 0;
  while (i <= a.length) {
    if (a.length < 5) a.push(i * i);
    i = i + 1;
  }
  return [i, a];
}

const big = [];
for (let i = 0; i < 1000; i++) big.push((i * 7) % 1000);
console.log(summed(big), summed([]), summed([0.5, 2.5, -3]));
console.log(grown());
console.log(shrunk());
console.log(spliced());
console.log(past());
console.log(letters("hello, world"), letters(""));
console.log(rows([[1, 2, 3], [], [4, 5], [6]]));
console.log(chase());
