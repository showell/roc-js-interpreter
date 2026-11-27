// The bitwise operators on `Integer`s (x86/README.md, "The bitwise
// operators"): a loop's counter and the answers it makes are integers in
// registers, each answer's range narrowed (`i & 7` is 0 to 7, `>>> 0` 0 to
// 2^32 - 1, `>> 2` a quarter), and fed on to `+`, `%`, an index and an
// ordering. The near misses: a shift that leaves 32 bits wraps, a product of
// two unsigned words passes 2^53 and is a double, and a count past 31 is
// taken modulo 32.

const table = [3, 1, 4, 1, 5, 9, 2, 6];
let sum = 0;
let folded = 0;
let wrapped = 0;
let product = 0;
for (let i = 0; i < 1000; i++) {
  const low = i & 7;
  sum = sum + table[low] + (i >> 2) % 5 + (i >>> 3);
  folded = folded ^ (i << (i & 15));
  wrapped = (wrapped + (i << 24)) | 0;
  product = product + (((i * 2654435761) >>> 0) & 0xFFFF);
}
console.log(sum, folded, wrapped, product);

// The classic string hash: `h << 5` of any 32-bit integer, less `h`, plus
// a code, made 32 bits again by `| 0`.
function hash(text) {
  let h = 0;
  for (let i = 0; i < text.length; i++) {
    h = (h << 5) - h + text.charCodeAt(i);
    h = h | 0;
  }
  return h;
}
console.log(hash("hello"), hash("the quick brown fox jumps over the lazy dog"), hash("") >>> 0);

// Unsigned words whose product passes 2^53: a double, rounded as node rounds.
let words = 0;
for (let i = 1; i < 6; i++) {
  const a = (i * 0x9E3779B9) >>> 0;
  const b = (a ^ (a >>> 16)) >>> 0;
  words = words + (a & 0xFF) * (b & 0xFF);
  console.log(a, b, a >>> 16, b >> 3, ~b, (a * b) | 0, (a * b * 4096) >>> 0);
}
console.log(words);

// Counts that change: past 31 and negative, modulo 32.
const shifted = [];
for (let k = -2; k < 70; k += 9) {
  shifted.push([k, 1 << k, -1 >>> k, -2147483648 >> k, 12345 << k]);
}
console.log(shifted);

// `~` of an integer, and `~~` as the truncation it is.
let flips = 0;
for (let i = -5; i < 5; i++) {
  flips = flips + ~i + ~~(i / 2);
}
console.log(flips, ~~2147483648, ~~-2147483649, ~~4294967297);

// A bitset over a loop: set every third bit, clear every fifth, count.
const set = [0, 0, 0, 0];
for (let v = 0; v < 128; v += 3) {
  set[v >> 5] = set[v >> 5] | (1 << (v & 31));
}
for (let v = 0; v < 128; v += 5) {
  set[v >>> 5] &= ~(1 << (v & 31));
}
let count = 0;
for (let v = 0; v < 128; v++) {
  if ((set[v >> 5] >>> (v & 31)) & 1) count++;
}
console.log(set, count);
