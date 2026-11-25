// Spreads into arrays, calls and objects, and an object pattern's rest.
const xs = [1, 2, 3];
console.log([...xs], [0, ...xs, 4], [..."hi", ...[]], [...xs, ...xs].length);
function sum(first, ...rest) {
  let total = first;
  for (const n of rest) total += n;
  return total;
}
const add3 = (a, b, c) => a + b + c;
console.log(sum(...xs), sum(10, ...xs), add3(...xs), add3(...[1, 2, 3, 4]), Math.max(...xs), Math.min(...xs, -5), Math.max(...[]));
console.log(...xs);
console.log(...["a", 1], ...[]);
const base = { a: 1, b: 2 };
const merged = { ...base, b: 20, c: 3, ...{ d: 4 } };
console.log(merged, base, { ...null, ...undefined, ...5, ...true }, { ...[] }, { ..."" });
const copy = { ...base };
copy.a = 100;
console.log(copy.a, base.a);
const counted = (o) => ({ ...o, count: (o.count ?? 0) + 1 });
console.log(counted(counted({ name: "n" })));
const { p, q: why = 2, ...others } = { p: 1, r: 3, s: 4 };
console.log(p, why, others);
const { a, ...noA } = merged;
console.log(a, noA);
const { ...all } = base;
console.log(all, all === base);
function pick({ name, ...rest }) {
  return [name, Object.keys(rest)];
}
console.log(pick({ name: "x", k: 1, j: 2 }));
