// Integer parameters: a parameter every call passes an Integer takes one,
// with a range that covers every call's; one a call passes a double, a
// fraction or a value stays as it was. Each line's numbers are node's.

// Every call passes a counter: `k` is an Integer, so `j < k` narrows `j`.
function steps(k) {
  let total = 0;
  for (let j = 0; j < k; j++) total = total + (j % 3);
  return total;
}

// One call passes an Integer, another a fraction: a double.
function half(x) {
  return Math.floor(x / 2) + x * 3;
}

// A recursion that steps its parameter: its range widens and settles.
function down(n) {
  if (n === 0) return 0;
  return 1 + down(n - 1);
}

// A parameter a closure captures holds a value in its cell.
function captured(n) {
  const get = () => n * 2;
  return get();
}

// A parameter given a fraction on one way: demoted, made a double at the
// entry.
function demoted(n) {
  for (let i = 0; i < 3; i++) {
    if (i === 1) n = n / 4;
  }
  return n;
}

// An index and a remainder of Integer parameters, and an equality.
function pick(a, i, m) {
  if (i % m === 0) return a[i];
  return a[i] * 10;
}

// Two Integer parameters of different ranges, multiplied to near 2^53.
function product(a, b) {
  return a * b;
}

// A parameter that is 0 from one call and negative from another: `0 * n`
// stays -0 where node makes it so.
function times(z, n) {
  return z * n;
}

function main() {
  let all = 0;
  for (let r = 0; r < 5; r++) all = all + steps(r * 4);
  console.log(all, steps(10));
  console.log(half(7), half(8), half(2.5) * 2);
  console.log(down(10), down(200));
  console.log(captured(21));
  console.log(demoted(8), demoted(16));
  const a = [5, 6, 7, 8, 9, 10];
  let picked = 0;
  for (let i = 0; i < a.length; i++) picked = picked + pick(a, i, 2);
  console.log(picked);
  console.log(product(4194304, 2147483647), product(-3, 7));
  console.log(times(0, -5), times(0, 5), times(3, -2));
  const big = 9007199254740991;
  console.log(product(big, 1), times(big, -1));
}

main();
