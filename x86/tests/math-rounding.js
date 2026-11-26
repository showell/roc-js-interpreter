// Math.floor, Math.ceil and Math.trunc in line (BuiltinLowering's header):
// whole numbers, fractions either side of 0, -0 and the -0 a rounding of a
// small negative number gives, numbers near and past 2^52 and 2^63, and
// what takes the routine instead: a NaN, the infinities, a number of 2^63
// or more in size. Each rounding printed is a whole number of at most 2^53,
// which console.log writes; a larger one is held to itself.
const numbers = [0, 1, -1, 0.5, -0.5, 0.25, -0.75, 1.5, -1.5, 2.999, -2.999, 7, -7, 4095.9, 16383, -16383.5, 4503599627370495.5, -4503599627370495.5, 4503599627370496, 9007199254740991, -9007199254740991, 5e-324, -5e-324];

function rounded(n) {
  return [Math.floor(n), Math.ceil(n), Math.trunc(n)];
}

for (const n of numbers) {
  console.log(rounded(n).join(" "));
}

// Past 2^53 a double is whole, so each rounding is the number itself: below
// 2^63 in line, at 2^63 and past it by the routine.
const whole = [9007199254740994, -9007199254740994, 9223372036854774784, -9223372036854774784, 9223372036854775808, -9223372036854775808, 1e300, -1e300];
for (const n of whole) {
  console.log(Math.floor(n) === n, Math.ceil(n) === n, Math.trunc(n) === n);
}

// A zero's sign, which join would hide.
console.log(Math.floor(-0), Math.ceil(-0), Math.trunc(-0));
console.log(Math.ceil(-0.5), Math.trunc(-0.5), Math.floor(-0.5));
console.log(Math.ceil(-5e-324), Math.trunc(-0.999), Math.floor(0.999));
console.log(1 / Math.ceil(-0.25) < 0, 1 / Math.floor(0.25) > 0, 1 / Math.trunc(-0.25) < 0);

// A NaN and the infinities take the routine, and are their own rounding.
const nan = 0 / 0;
const inf = 1 / 0;
console.log(Math.floor(nan) !== Math.floor(nan), Math.ceil(inf) === inf, Math.trunc(-inf) === -inf, Math.floor(-inf) === -inf);

// A number whose kind is known only as the program runs.
function first(xs) {
  return xs[0];
}
console.log(Math.floor(first([-2.5, "x"])), Math.ceil(first([2.5, "x"])), Math.trunc(first([-2.5, "x"])));

// The Nibble machine's line read from its program, a quotient floored.
let lines = 0;
for (let bits = 0; bits < 4096; bits++) {
  lines = lines + (Math.floor(bits / 1024) % 4) + Math.floor(bits / 4096) + Math.ceil(bits / 64) % 4;
}
console.log(lines);
