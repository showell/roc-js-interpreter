// inlined: 3 sites, 15 instructions
// A leaf inlined at three sites whose arguments have different kinds: at
// one an `Integer` from a counter, at another a string, at a third a
// fraction. Each inlined body is lowered with its own site's kinds, and
// the leaf's own code with what its other calls pass.
function pair(a, b) {
  return a + b;
}

function main() {
  let count = 0;
  let text = "";
  let half = 0;
  for (let i = 0; i < 40; i = i + 1) {
    count = pair(count, i % 4);
    text = pair(text, "ab");
    half = pair(half, 0.25);
  }
  const all = [count, text.length, half * 4, pair(3, 3), pair("x", "y")];
  console.log(all);
  console.log(all.length, count + 1, text.slice(0, 5), half > 1, half < 100);
  console.log(pair(count, half * 4), pair(text.length, 1), pair("z", count));
}

main();
