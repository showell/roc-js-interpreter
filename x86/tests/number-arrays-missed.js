// Near misses of Lowering's NUMBER-ONLY ARRAYS: a string pushed, a write of
// a value of unknown kind, and an array that escapes into an object. Each
// keeps the program's arrays plain arrays, and the program prints what node
// prints, reads past the end included.
function main() {
  const a = [1, 2];
  a.push("three");
  const o = { k: [4, 5] };
  const b = [6];
  b[1] = o.k;
  console.log(a, a.length, o.k[0] + o.k[1], b, a[9]);
}
main();
