// `===` and `!==` of two known numbers tested by an `if`, a loop or a
// `&&`, lowered with the jump that follows them (Lowering's `fused_jump`):
// equal and unequal numbers, NaNs (never equal, even to themselves), -0
// and 0 (equal), and near misses: a test that another way reaches (`||`
// before it), and one of a value whose kind is known only as it runs.
const nan = 0 / 0;

function same(a, b) {
  if (a === b) return "same";
  return "apart";
}

function differ(a, b) {
  if (a !== b) return "differ";
  return "alike";
}

// Each call passes two known numbers, so the parameters are known numbers.
function both(a, b) {
  console.log(same(a, b), differ(a, b), a === b ? 1 : 0, a !== b ? 1 : 0);
}
both(1, 1);
both(1, 2);
both(0, -0);
both(-0, 0);
both(0 / 0, 0 / 0);
both(0 / 0, 1);
both(1, 0 / 0);
both(2.5, 2.5);
both(-3, 3);

// The Nibble machine's step: tests in a row, each a jump of its own, and
// one `&&` whose second test another way reaches.
function step(run, op) {
  if (run > 3) return run;
  if (op === 1 && run === 0) return 4;
  if (op === 2 && run === 0) return 5;
  if (op === 2) return run - 1;
  if (op === 3) return run % 2;
  return run;
}
let total = 0;
for (let run = 0; run < 6; run++) {
  for (let op = 0; op < 4; op++) total = total * 3 + step(run, op);
  total = total % 1000003;
}
console.log(total);

// A `||` before the test: the second test's jump is reached two ways.
function either(a, b) {
  if (a === 1 || b === 1) return "one";
  return "none";
}
console.log(either(1, 0), either(0, 1), either(0, 0), either(0 / 0, 0 / 0));

// A loop that runs while two numbers differ.
let i = 0;
while (i !== 10) i = i + 1;
console.log(i);

// A value of a kind known only as it runs takes the routine.
function first(xs) {
  return xs[0];
}
function sameValue(a, b) {
  if (a === b) return "same";
  return "apart";
}
console.log(sameValue(first([7, "x"]), 7), sameValue(first(["7", 7]), 7), sameValue(first([nan, "x"]), nan));
