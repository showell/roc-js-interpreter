// Loops whose objects' field guards LoopInvariants tests once before the
// loop, keeping the address of each field's value, and the ways the guard
// must still answer as node does: a field added partway (by the loop's own
// write, or one to another name of the object), an object of another
// shape, a value that is no object, and a reassignment in the loop.

class Point {
  constructor(x, y) {
    this.x = x;
    this.y = y;
  }
}

// Kept: the two fields read and written, as in x86/kernels/fields.js.
function walk(p, n) {
  for (let i = 0; i < n; i++) {
    p.x = p.x + (i % 7);
    p.y = p.y + (p.x % 5);
  }
  return p.x + p.y;
}
console.log(walk(new Point(0, 0), 1000), walk(new Point(1, 2), 0));

// The guards miss: a plain object with its keys the other way round, and
// one with neither key, which the loop's own writes add on its first trip.
console.log(walk({ y: 5, x: 3 }, 10), walk({}, 3));

// A key added to the object partway, through another name for it: its
// entries grow and move, and each write after must reach the new ones.
function grown(p, q, n) {
  for (let i = 0; i < n; i++) {
    p.x = p.x + 1;
    if (i === 3) q["k" + i] = i;
    if (i === 5) q.extra = p.x;
    p.y = p.y + p.x;
  }
  return [p.x, p.y];
}
const shared = new Point(0, 0);
console.log(grown(shared, shared, 9), shared.extra, shared.k3);
console.log(grown(new Point(1, 1), {}, 7));

// Many keys added partway, so the entries move and the table is made.
function many(p, n) {
  for (let i = 0; i < n; i++) {
    p.x = p.x + i;
    p["f" + (i % 12)] = i;
  }
  return p.x + p.f11;
}
console.log(many(new Point(0, 0), 30));

// An array's item written in the loop beside the fields: one past its end
// appends, so its facts are found again.
function both(p, a, n) {
  for (let i = 0; i < n; i++) {
    p.x = p.x + a.length;
    a[a.length] = i;
    p.y = p.y + a[i];
  }
  return [p.x, p.y, a.length];
}
console.log(both(new Point(0, 0), [], 6));

// An object of another shape, which lacks `x`: every guess misses, and the
// runtime's read gives `undefined`.
function read(v, n) {
  let s = "";
  for (let i = 0; i < n; i++) s = s + v.x;
  return s;
}
console.log(read({ y: 1 }, 2), read(new Point(7, 8), 2), read({ x: "a" }, 3));

// The receiver reassigned in the loop: nothing kept.
function alternate(p, q, n) {
  let o = p;
  let s = 0;
  for (let i = 0; i < n; i++) {
    s = s + o.x;
    o.x = o.x + 1;
    o = o === p ? q : p;
  }
  return [s, p.x, q.x];
}
console.log(alternate(new Point(1, 0), new Point(10, 0), 5));

// A call in the loop that adds a field: not kept, every trip guarded.
function addField(p, i) {
  p["g" + i] = i;
}
function called(p, n) {
  let s = 0;
  for (let i = 0; i < n; i++) {
    s = s + p.x;
    addField(p, i);
    p.x = p.x + 2;
  }
  return [s, p.x, p.g9];
}
console.log(called(new Point(0, 0), 10));

// Nested loops: the outer keeps the object's guards, the inner reads them.
function nested(p, n) {
  for (let r = 0; r < n; r++) {
    for (let c = 0; c < n; c++) p.x = p.x + c * p.y;
    p.y = p.y + 1;
  }
  return p.x;
}
console.log(nested(new Point(0, 1), 5));
