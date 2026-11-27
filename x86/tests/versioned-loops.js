// Loops that Versioning places twice: each reads, as a number, a variable it
// never writes that holds a value (a property's), so its guard tests those
// for whole numbers of 32 bits and runs the fast copy when they are, the
// generic copy when one isn't. Every case runs both ways.

function sum_from(o) {
  const base = o.base;
  const count = o.count;
  const data = o.data;
  let total = 0;
  let i = 0;
  while (i < count) {
    total = total + data[base + i];
    i = i + 1;
  }
  return total + i * 1000;
}

const data = [];
for (let k = 0; k < 40; k++) data.push((k * 7) % 11);

// The guards hold: both are whole numbers of 32 bits.
console.log(sum_from({ base: 3, count: 10, data }));
console.log(sum_from({ base: 0, count: 0, data }));
// A guard fails at the entry: a fraction, -0, past 32 bits, NaN, an
// infinity. Each takes the generic copy, as node does.
console.log(sum_from({ base: 1.5, count: 3, data }));
console.log(sum_from({ base: -0, count: 4, data }));
console.log(sum_from({ base: 0, count: 2.5, data }));
console.log(sum_from({ base: 2147483648, count: 2, data }));
console.log(sum_from({ base: 2147483647, count: 1, data }));
console.log(sum_from({ base: -2147483648, count: 1, data }));
console.log(sum_from({ base: 0, count: NaN, data }));
console.log(sum_from({ base: 0, count: -Infinity, data }));
// Past the end, both copies read `undefined`.
console.log(sum_from({ base: 38, count: 3, data }));

// An array that changes kind before the loop: a string among its items.
const mixed = [1, 2, 3, 4];
mixed.push("x");
mixed[1] = -7;
console.log(sum_from({ base: 0, count: 5, data: mixed }));

// A counter that starts as a fraction, so its guard fails; one written in
// the loop and read after it; a `break`; a `return` from inside.
function counters(o) {
  const limit = o.limit;
  const step = o.step;
  let i = o.start;
  let hits = 0;
  while (i < limit) {
    if (Math.floor(i) % step === 0) hits = hits + 1;
    if (hits > 5) break;
    i = i + 1;
  }
  return [i * 2, hits];
}
console.log(counters({ start: 0, limit: 30, step: 4 }));
console.log(counters({ start: 0.5, limit: 6, step: 2 }));
console.log(counters({ start: -3, limit: 3, step: 3 }));
console.log(counters({ start: 0, limit: 1e10, step: 1 }));

function first_at_least(o) {
  const wanted = o.wanted;
  const items = o.items;
  for (let k = 0; k < items.length; k++) {
    if (items[k] >= wanted) return k;
  }
  return -1;
}
console.log(first_at_least({ wanted: 9, items: data }));
console.log(first_at_least({ wanted: 99, items: data }));
console.log(first_at_least({ wanted: 9.5, items: [1, 9, 10] }));

// A versioned loop with a loop inside it, which is copied with it.
function grid(o) {
  const rows = o.rows;
  const cols = o.cols;
  let out = 0;
  let r = 0;
  while (r < rows) {
    let c = 0;
    while (c < cols) {
      out = out + r * cols + c;
      c = c + 1;
    }
    r = r + 1;
  }
  return out;
}
console.log(grid({ rows: 4, cols: 5 }));
console.log(grid({ rows: 3, cols: 1.5 }));

// A call inside a versioned loop: the guarded variables are the frame's,
// which no call can write.
function bump(a, k) {
  a.push(k);
  return a.length;
}
function calls(o) {
  const n = o.n;
  const a = [];
  let i = 0;
  let last = 0;
  while (i < n) {
    last = bump(a, i * 2);
    i = i + 1;
  }
  return last + a[n - 1];
}
console.log(calls({ n: 6 }));
console.log(calls({ n: 6.0 }));
