// The bitwise operators on values whose kind is known only as the program
// runs: a function a value may hold takes values, so each operand goes
// through `runtime_word_of` (a number's ToInt32, NaN, the infinities and
// numbers past 2^63 included), and on doubles, each made a 32-bit integer
// in line by `cvttsd2si` but past 2^63.
const ops = [
  (a, b) => a & b,
  (a, b) => a | b,
  (a, b) => a ^ b,
  (a, b) => a << b,
  (a, b) => a >> b,
  (a, b) => a >>> b,
  (a, b) => ~a ^ ~b,
];
const values = [0, -0, 1, -1, 0.9, -0.9, 255.5, NaN, Infinity, -Infinity,
  2147483647, 2147483648, -2147483648, -2147483649, 4294967295, 4294967296, 4294967297,
  9007199254740991, 1e19, -1e19, 9223372036854777856, -9223372036854777856,
  1180591620717411565568, 1e300, -1e300, 5e-324];
const rows = [];
for (const op of ops) {
  let mixed = 0;
  for (const a of values) {
    for (const b of values) {
      mixed = (mixed * 31 + op(a, b)) | 0;
    }
  }
  rows.push(mixed);
}
console.log(rows);

// Doubles in a known array: `cvttsd2si` in line, and its -2^63 sends the
// rest to the runtime.
const doubles = [0.5, 3.75, -7.25, 1e10, -1e10, 1e20, 3e9];
let folded = 0;
for (let i = 0; i < doubles.length; i++) {
  const d = doubles[i];
  folded = folded ^ (d | 0) ^ (d >>> 1) ^ (d << 3) ^ (d >> 2) ^ ~d ^ (d & d);
  console.log(d | 0, d >>> 0, ~d, d >> 31);
}
console.log(folded);

// A value that may be a number or undefined: a missing argument's
// `undefined` would be a coercion, so it is only ever given numbers here.
function mask(x, bits) {
  return x & ((1 << bits) - 1);
}
console.log(mask(0xABCDEF, 8), mask(-1, 31), mask(-1, 32), mask(12345.678, 4));
