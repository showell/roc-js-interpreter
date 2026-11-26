// `%` by a whole number known before the program runs, a literal or a
// const, worked out in line by a multiply (OperatorLowering's header): the
// dividend's sign, -0, dividends near and past 2^53, and what takes the
// routine instead: a NaN, an infinity, a variable divisor, a divisor two
// ways bring.
const MODULUS = 2147483647; // 2^31 - 1, the bank race's
const SEVEN = 7;
const BIG = 1099511627776; // 2^40
const LARGEST = 9007199254740992; // 2^53
const MINUS_TEN = -10;

const dividends = [0, 1, -1, 6, -6, 7, -7, 13, -13, 100, -100, 2147483646, 2147483647, -2147483648, 103723447396417, 9007199254740991, 9007199254740992, -9007199254740992];

// Past 2^53 a double still holds a whole number, which the multiply takes;
// the routine (a negative divisor here, or a const of the program's own
// code, which is no captured cell) stops at 2^53.
const beyond = [9007199254740994, -9007199254740994, 1152921504606846976, -1152921504606846976];

function byLiterals(n) {
  return [n % 1, n % 2, n % 3, n % 7, n % 10, n % 2147483647, n % 1099511627776, n % -3];
}

function byConstants(n) {
  return [n % SEVEN, n % MODULUS, n % BIG, n % LARGEST, n % MINUS_TEN];
}

for (const n of dividends) {
  console.log(byLiterals(n).join(" "), "|", byConstants(n).join(" "));
}
function pastLargest(n) {
  return [n % 1, n % 3, n % 7, n % 1099511627776, n % SEVEN, n % MODULUS, n % LARGEST];
}
for (const n of beyond) {
  console.log(pastLargest(n).join(" "));
}

// -0 stays -0, and so does a 0 remainder of a negative dividend.
console.log(-0 % 1, -0 % 7, -0 % MODULUS, -14 % 7, -14 % SEVEN, -8 % 1, 14 % 7);

// A dividend whose kind is known only as the program runs.
function first(xs) {
  return xs[0];
}
console.log(first([45, "x"]) % 7, first([-45, "x"]) % SEVEN);

// A NaN and the infinities take the routine, and are NaN.
const nan = 0 / 0;
const inf = 1 / 0;
console.log(nan % 7, inf % 7, -inf % SEVEN, nan % MODULUS);

// A variable divisor takes the routine.
function byVariable(n, d) {
  return n % d;
}
console.log(byVariable(100, 7), byVariable(-100, 7), byVariable(100, -7), byVariable(-0, 3), byVariable(5, 0));

// A divisor two ways bring is no known number.
function byEither(n, c) {
  return n % (c ? 3 : 4);
}
console.log(byEither(10, true), byEither(10, false), byEither(-10, false));

// A loop's counter, as the bank race's audit uses one.
let audits = 0;
for (let step = 1; step <= 100000; step++) {
  if (step % 10000 === 0) audits = audits + 1;
}
console.log(audits);

// The bank race's generator, a product below 2^47 kept below MODULUS.
let seed = 20261126;
let sum = 0;
for (let i = 0; i < 1000; i++) {
  seed = (seed * 48271) % MODULUS;
  sum = (sum + (seed % 500)) % 1000000007;
}
console.log(seed, sum);
