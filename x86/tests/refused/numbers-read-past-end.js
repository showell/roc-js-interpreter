// stops: x86: an array of numbers read where it has no item is not compiled yet
// An array of numbers (Lowering's NUMBER-ONLY ARRAYS) reads its items as
// numbers, so a read past its end, `undefined` in node, stops.
function main() {
  const xs = [1, 2];
  console.log(xs[0] + xs[1]);
  console.log(xs[2]);
}
main();
