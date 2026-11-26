// inlined: 2 sites, 8 instructions
// A leaf that is also used as a value (passed to `map`, stored in an
// object, printed) is inlined where it is called directly in a loop, and
// its closure record serves the other uses.
function inc(x) {
  return x + 1;
}

function main() {
  let n = 0;
  for (let i = 0; i < 10; i = i + 1) n = inc(n) + inc(i);
  const holder = { f: inc };
  console.log(n, [1, 2, 3].map(inc), holder.f(41), inc);
}

main();
