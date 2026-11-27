// In a program with a `try` no `Integer` is made, so the bitwise operators'
// answers are doubles, made so from the integer they compute.
let acc = 0;
try {
  for (let i = 0; i < 100; i++) {
    acc = (acc << 1) ^ (i >>> 1) ^ ~(i & 3);
    if (acc > 1000000) acc = acc >> 7;
  }
  if (acc === 0) throw new Error("none");
} catch (e) {
  console.log("caught", e.message);
}
console.log(acc, acc | 0, acc >>> 0, -1 >>> 0, 1 << 31);
