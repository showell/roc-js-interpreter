// versioned: 7 loops, 212 instructions
// Arrays held as values (in an object), read and written in loops that
// Versioning places twice with their arrays guarded: the fast copy reads
// their items as integers while each header says Int32, and leaves by a
// side exit into the generic copy when a read runs past the end, a store
// would lower the kind, a call may have lowered it, or the slot is given
// an array of another kind. Every line must be node's either way.

function sum_of(st) {
  const a = st.a;
  let t = 0;
  let i = 0;
  while (i < a.length) {
    t = t + a[i];
    i = i + 1;
  }
  return t;
}

// A read past the end gives undefined, in the generic copy.
function past_end(st) {
  const a = st.a;
  let seen = 0;
  let i = 0;
  while (i < 6) {
    const x = a[i];
    if (x === undefined) seen = seen + 1;
    i = i + 1;
  }
  return seen;
}

// A store of a fraction, of -0, of 2^31 and of a string lowers the kind:
// each leaves the fast copy before it stores.
function stores(st, v) {
  const a = st.a;
  let i = 0;
  while (i < a.length) {
    if (i === 2) a[i] = v;
    else a[i] = a[i] + 1;
    i = i + 1;
  }
  return a;
}

// A call in the loop that pushes a string into the array it reads.
function spoil(st) {
  st.a.push("x");
}
function called(st) {
  const a = st.a;
  let n = 0;
  let i = 0;
  while (i < a.length) {
    if (i === 1) spoil(st);
    if (typeof a[i] === "number") n = n + a[i];
    i = i + 1;
  }
  return n;
}

// Two names for one array: a store through the name the loop doesn't guard.
function aliased(st) {
  const a = st.a;
  const b = st.b;
  let t = 0;
  let i = 0;
  while (i < a.length) {
    if (i === 1) b[2] = 2.5;
    t = t + Math.floor(a[i] * 2);
    i = i + 1;
  }
  return t;
}

// The slot given another array mid-loop: of whole numbers, then of strings.
function swapped(st) {
  let a = st.a;
  let out = "";
  let i = 0;
  while (i < 3) {
    out = out + a[i] + ",";
    if (i === 0) a = st.b;
    if (i === 1) a = st.c;
    i = i + 1;
  }
  return out;
}

// A nested loop, the inner one copied with the outer, its items written.
function grid(st) {
  const rows = st.rows;
  const cells = st.cells;
  let r = 0;
  while (r < rows) {
    let c = 0;
    while (c < 4) {
      cells[r * 4 + c] = cells[r * 4 + c] + r * c;
      c = c + 1;
    }
    r = r + 1;
  }
  return sum_of({ a: cells });
}

console.log(sum_of({ a: [1, 2, 3, 4] }), sum_of({ a: [] }), sum_of({ a: [2147483647, 1] }));
console.log(sum_of({ a: [1, 2.5, 3.5] }), sum_of({ a: ["a", "b"] }));
console.log(past_end({ a: [1, 2, 3] }), past_end({ a: [1, 2, 3, 4, 5, 6, 7] }));
console.log(stores({ a: [1, 2, 3, 4] }, 7));
console.log(stores({ a: [1, 2, 3, 4] }, 2147483648));
console.log(stores({ a: [1, 2, 3, 4] }, "s"));
const halves = stores({ a: [1, 2, 3, 4] }, 0.5);
console.log(halves[0], halves[1], halves[2] * 2, halves[3]);
const zeros = stores({ a: [1, 2, 3, 4] }, -0);
console.log(zeros[0], zeros[1], zeros[2] === 0, zeros[3]);
console.log(called({ a: [1, 2, 3] }));
const shared = [1, 2, 3, 4];
console.log(aliased({ a: shared, b: shared }), aliased({ a: [1, 2, 3], b: [5, 6, 7] }));
console.log(swapped({ a: [1, 2, 3], b: [4, 5, 6], c: ["x", "y", "z"] }));
console.log(grid({ rows: 3, cells: [0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2] }));
