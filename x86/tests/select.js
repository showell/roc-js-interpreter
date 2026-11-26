// A conditional of two known numbers after an ordering of two known numbers
// is made with no jump (Lowering's fused_jump, A SELECT OF TWO KNOWN NUMBERS
// HAS NO JUMP): each of the four orderings, a NaN (every ordering false),
// arms that are variables, an equal pair, and near misses the rule leaves
// to the jumps (an arm that is a string, an arm that is an expression).
function picks(a, b) {
  const low = 10;
  const high = 20;
  const lt = a < b ? 1 : 0;
  const le = a <= b ? 1 : 0;
  const gt = a > b ? low : high;
  const ge = a >= b ? high : low;
  return [lt, le, gt, ge];
}

function near(a, b) {
  const word = a < b ? "less" : "not less";
  const sum = a < b ? a + b : a - b;
  return word + " " + sum;
}

function carries(limbs) {
  let carry = 0;
  let total = 0;
  let i = 0;
  while (i < limbs.length) {
    const s = limbs[i] + carry;
    carry = s >= 10 ? 1 : 0;
    total = total + (s - carry * 10);
    i = i + 1;
  }
  return total * 10 + carry;
}

function run() {
  console.log(picks(1, 2), picks(2, 2), picks(3, 2));
  console.log(picks(0 / 0, 2), picks(2, 0 / 0));
  console.log(picks(-0, 0), picks(-1.5, -2.5));
  console.log(near(1, 2), near(4, 3));
  console.log(carries([9, 9, 3, 7, 5]));
}

run();
