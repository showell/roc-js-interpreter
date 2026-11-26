// carries.js: what the fib race's carry costs, as a branch and as a select.
// The in-place addition of fib_race.js's first loop, run over 10,000 limbs
// 1,500 times, once on numbers that never carry (a branch on the carry
// always goes one way) and once on pseudo-random limbs (it goes each way
// about as often, so it is mispredicted about half the time). `addInto`
// decides the carry with an `if`, as the race once did; `addIntoChosen`
// with `s >= BASE ? 1 : 0`, as the race does now, which js-x86 makes with
// no jump. The difference between the two columns is what mispredicting a
// branch costs, for js-x86's executable and for node; x86/race/README.md has
// the numbers. The arrays are made in `main` and filled in place, so js-x86
// keeps them arrays of numbers, as the race's are. It prints only times, so no gate runs it.
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
function addIntoChosen(a, b) {
  const aLength = a.length;
  let carry = 0;
  let i = 0;
  while (i < aLength) {
    const s = a[i] + b[i] + carry;
    carry = s >= BASE ? 1 : 0;
    a[i] = s - carry * BASE;
    i = i + 1;
  }
  return carry;
}
function fill(a, n, step) {
  let x = 12345;
  let i = 0;
  while (i < n) {
    x = (x * 1103 + 4847) % BASE;
    a.push(step * x);
    i = i + 1;
  }
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
function timedChosen(a, b, passes) {
  const start = Date.now();
  let k = 0;
  let carries = 0;
  while (k < passes) {
    carries = carries + addIntoChosen(a, b);
    k = k + 1;
  }
  return Date.now() - start;
}
function main() {
  const n = 10000;
  const passes = 1500;
  const zeros = [];
  const small = [];
  const randomA = [];
  const randomB = [];
  const smallChosen = [];
  const randomChosenA = [];
  const randomChosenB = [];
  fill(zeros, n, 0);
  fill(small, n, 0);
  fill(randomA, n, 1);
  fill(randomB, n, 1);
  fill(smallChosen, n, 0);
  fill(randomChosenA, n, 1);
  fill(randomChosenB, n, 1);
  const never = timed(small, zeros, passes);
  const half = timed(randomA, randomB, passes);
  console.log("if: never " + never + " ms, random " + half + " ms");
  const neverChosen = timedChosen(smallChosen, zeros, passes);
  const halfChosen = timedChosen(randomChosenA, randomChosenB, passes);
  console.log("select: never " + neverChosen + " ms, random " + halfChosen + " ms");
}
main();
