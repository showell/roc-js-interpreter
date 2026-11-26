// `o.k++`, `o.k--`, `++o.k` and `--o.k`: the old number or the new, and the
// property stepped, on a plain object, a class's field, a value whose kind
// isn't known, and an object with many keys.
const o = { n: 1, m: 10 };
console.log(o.n++, o.n, ++o.n, o.n, o.m--, o.m, --o.m, o.m);
console.log(o.n++ + o.n++, o);

class Tally {
  constructor() {
    this.count = 0;
    this.total = 0;
  }
  add(n) {
    this.count++;
    this.total += n;
    return ++this.count;
  }
}
const t = new Tally();
console.log(t.add(5), t.add(7), t.count, t.total);

const entries = new Map();
for (const district of ["north", "south", "north", "east", "north", "south"]) {
  const entry = entries.get(district);
  if (entry === undefined) entries.set(district, { people: 1 });
  else entry.people++;
}
console.log(entries);

const big = {};
for (let i = 0; i < 12; i++) big[`k${i}`] = i;
for (let i = 0; i < 3; i++) big.k11++;
big.k0--;
console.log(big.k11, big.k0, Object.keys(big).length);

const either = (i) => (i % 2 === 0 ? { v: i } : t);
for (let i = 0; i < 4; i++) {
  const x = either(i);
  x.v === undefined ? x.count++ : x.v++;
  console.log(x.v === undefined ? x.count : x.v);
}

let f = { x: 0.5 };
f.x++;
console.log(f.x === 1.5, -f.x++ === -1.5, f.x === 2.5);
