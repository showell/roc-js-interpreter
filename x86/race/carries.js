// carries.js: what the fib race's `s >= BASE` branch costs. The same
// in-place addition as fib_race.js's first loop, run over 10,000 limbs
// 1,500 times, once on numbers that never carry (the branch always goes one
// way) and once on pseudo-random limbs (it goes each way about as often, so
// it is mispredicted about half the time). The difference between the two
// times is what mispredicting the branch costs, for js-x86's executable and
// for node; x86/race/README.md has the numbers. It prints only times, so no
// gate runs it.
const BASE = 10000000;
function addInto(a, b) {
  const aLength = a.length;
  let carry = 0;
  let i = 0;
  while (i < aLength) {
    const s = a[i] + b[i] + carry;
    if (s >= BASE) {
      a[i] = s - BASE;
      carry = 1;
    } else {
      a[i] = s;
      carry = 0;
    }
    i = i + 1;
  }
  return carry;
}
function filled(n, step) {
  const a = [];
  let x = 12345;
  let i = 0;
  while (i < n) {
    x = (x * 1103 + 4847) % BASE;
    a.push(step * x);
    i = i + 1;
  }
  return a;
}
function timed(a, b, passes) {
  const start = Date.now();
  let k = 0;
  let carries = 0;
  while (k < passes) {
    carries = carries + addInto(a, b);
    k = k + 1;
  }
  return Date.now() - start;
}
function main() {
  const n = 10000;
  const passes = 1500;
  const zeros = filled(n, 0);
  const small = filled(n, 0);
  const randomA = filled(n, 1);
  const randomB = filled(n, 1);
  const never = timed(small, zeros, passes);
  const half = timed(randomA, randomB, passes);
  console.log("never " + never + " ms, random " + half + " ms");
}
main();
