// `===` and `!==` tested by an `if`, a loop or a `&&`, where a side is a
// value whose kind is known only as the program runs (Lowering's
// `fused_jump`): each value tested for a number in line, two numbers
// compared by `ucomisd`, and `runtime_strict_equal` asked when either isn't
// a number. Values of every kind against numbers and against each other:
// NaN (never equal, even to itself), -0 and 0 (equal), strings by their
// bytes, arrays and objects by identity, booleans, `undefined` and `null`.
const nan = 0 / 0;
const shared = [1, 2];
const thing = { k: 1 };
const values = [0, -0, 1, -1, 2.5, nan, Infinity, -Infinity, "1", "", "a", "ab",
  true, false, undefined, null, shared, [1, 2], thing, { k: 1 }];

// A function a value may hold takes values, so each side is a `Value`.
const tests = [
  (a, b) => {
    if (a === b) return 1;
    return 0;
  },
  (a, b) => {
    if (a !== b) return 1;
    return 0;
  },
  (a, b) => {
    if (a === b && b === a) return 1;
    return 0;
  },
];

const rows = [];
for (const test of tests) {
  let mixed = 0;
  for (const a of values) {
    for (const b of values) {
      mixed = (mixed * 3 + test(a, b)) % 1000003;
    }
  }
  rows.push(mixed);
}
console.log(rows);

// A value against a known number, either side: the SAT race's
// `value[blocker] === true_val`.
const one = 1;
function against(xs) {
  let hits = 0;
  for (let i = 0; i < xs.length; i++) {
    if (xs[i] === one) hits = hits + 1;
    if (0 === xs[i]) hits = hits + 10;
    if (xs[i] !== nan) hits = hits + 100;
    if (2.5 !== xs[i]) hits = hits + 1000;
  }
  return hits;
}
console.log(against(values), against([1, 1, 0, -0, nan]), against(["1", "0", null]));

// A loop that runs while a value differs from a number, and one while two
// values do.
const steps = [3, 2, 1, "end"];
let k = 0;
while (steps[k] !== "end") k = k + 1;
console.log(k);
const pairs = [[1, 1], ["x", "x"], [nan, nan], [shared, shared], [thing, { k: 1 }]];
for (const [a, b] of pairs) {
  let n = 0;
  while (a === b && n < 3) n = n + 1;
  console.log(n);
}
