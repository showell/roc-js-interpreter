// `**`, `typeof`, `??` and `switch`.
console.log(2 ** 10, 2 ** 3 ** 2, -(2 ** 2), 3 ** 0, (-3) ** 3, 2 ** 53, (-0) ** 3, 0 ** 2);
let n = 1;
for (let i = 0; i < 5; i++) n = n * 2 ** i;
console.log(n);
const f = () => 1;
function g() {
  return 2;
}
console.log(typeof 1, typeof "s", typeof true, typeof null, typeof undefined, typeof {}, typeof [], typeof f, typeof g, typeof console, typeof console.log);
const kinds = [1, "two", false, null, undefined, [3], { four: 4 }, f];
for (const k of kinds) console.log(typeof k);
console.log(null ?? "d", 0 ?? "d", undefined ?? null, "" ?? "x", false ?? true);
const o = { a: null, b: 0 };
console.log(o.a ?? "a was null", o.b ?? "b was null", o.c ?? "c was missing");
function describe(v) {
  switch (v) {
    case 0:
      return "zero";
    case 1:
    case 2:
      return "small";
    case "1":
      return "a string";
    default:
      return "other";
    case null:
      return "null";
  }
}
console.log([0, 1, 2, "1"].map(describe), [3, null, undefined].map(describe));
function falls(start) {
  const seen = [];
  switch (start) {
    case "a":
      seen.push("a");
    case "b":
      seen.push("b");
      break;
    default:
      seen.push("default");
    case "d":
      seen.push("d");
  }
  return seen.join(",");
}
console.log(falls("a"), falls("b"), falls("d"), falls("z"));
for (let i = 0; i < 5; i++) {
  switch (i % 3) {
    case 0:
      continue;
    case 1: {
      const word = "one";
      console.log(i, word);
      break;
    }
    default:
      console.log(i, "two");
  }
}
switch (NaN) {
  case NaN:
    console.log("NaN matched");
    break;
  default:
    console.log("NaN never matches");
}
outer: for (const row of [[1, 2], [3, 4]]) {
  for (const cell of row) {
    if (cell === 3) break outer;
    console.log("cell", cell);
  }
}
let k = 0;
do {
  k++;
} while (k < 3);
console.log(k);
