// The bitwise operators: each operand made a 32-bit integer (ECMAScript's
// ToInt32, or ToUint32 for `>>>`), a shift's count taken modulo 32, and the
// answer a signed 32-bit integer (an unsigned one for `>>>`).

console.log("and, or, xor:", 12 & 10, 12 | 10, 12 ^ 10, -1 & 255, -256 | 15, -1 ^ 1);
console.log("not:", ~0, ~1, ~-1, ~255, ~2147483647, ~-2147483648);
console.log("shifts:", 1 << 4, 1 << 31, 1 << 32, 1 << 33, 1 << -1, 5 << 30);
console.log("signed right:", 256 >> 4, -256 >> 4, -1 >> 31, -2147483648 >> 31, 7 >> 32, 7 >> 33, -9 >> -1);
console.log("unsigned right:", 256 >>> 4, -1 >>> 0, -1 >>> 28, -256 >>> 4, -1 >>> 32, -1 >>> 33, 1 >>> -1);

// ToInt32 of what isn't already a 32-bit integer: fractions toward 0,
// NaN and the infinities 0, -0 0, and the rest modulo 2^32.
const edges = [0.5, -0.5, 1.9, -1.9, NaN, Infinity, -Infinity, -0,
  2147483647, 2147483648, -2147483648, -2147483649,
  4294967295, 4294967296, 4294967297, -4294967297,
  9007199254740991, -9007199254740991, 1e20, -1e20, 9223372036854775808,
  9223372036854777856, -9223372036854777856, 1180591620717411565568, 1e300];
for (const x of edges) {
  console.log(x | 0, x >>> 0, ~x, x & 65535, x >> 1, x << 1, 1 << x);
}

// -0 in, 0 out: `-0 | 0` is 0, which `Object.is` would tell apart; 1 / it
// is Infinity, not -Infinity.
console.log(1 / (-0 | 0), 1 / (-0 >> 0), 1 / (-0 >>> 0), 1 / (0 & -1));

// Precedence: `|` below `^` below `&` below `===`, shifts between `<` and
// `+`, and every bitwise operator above `&&` (`6 & 3 === 3` is `6 & true`, a
// coercion: refused/bitwise-precedence.js).
console.log(1 | 2 ^ 3 & 5);
console.log((1 | 2) ^ (3 & 5));
console.log(1 << 2 + 3, (1 << 2) + 3);
console.log(16 >> 1 < 9, 16 >> 1 > 9, 1 + 2 >> 1, 1 < 2 << 1);
console.log((6 & 3) === 2, 6 & 3 + 1, 6 | 1 - 1);
console.log(1 & 1 && 2 | 0, 0 || 4 ^ 4);
console.log(-1 >>> 28 >> 1, 1 << 2 << 3, ~~7.9, -~5, ~-~5, !~-1);
console.log(2 ** 3 << 1, 7 % 4 << 2, 3 * 2 >> 1);

// The compound assignments.
let a = 0xF0;
a &= 0x3C;
console.log(a);
a |= 0x101;
console.log(a);
a ^= 0xFF;
console.log(a);
a <<= 24;
console.log(a);
a >>= 4;
console.log(a);
a >>>= 8;
console.log(a);
const o = { bits: 5 };
o.bits <<= 2;
o.bits |= 1;
const list = [1, 2, 3];
list[1] ^= 7;
list[2] >>>= 1;
console.log(o.bits, list);

// In a loop, with the count and the value both changing.
let mixed = 0;
for (let i = 0; i < 40; i++) {
  mixed = (mixed << 3) ^ (mixed >>> 29) ^ i;
  mixed = mixed | 0;
}
console.log(mixed, mixed >>> 0);

// Through a function, so its parameters are values, and through an array.
function bits(x, y) {
  return [x & y, x | y, x ^ y, x << y, x >> y, x >>> y, ~x];
}
console.log(bits(-7, 3), bits(123456789, 35), bits(0.75, -0.75));
const words = [0xDEADBEEF, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF];
console.log(words.map((w) => w | 0), words.map((w) => w >>> 16), words.map((w) => w & 0xFFFF));
