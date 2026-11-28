// call.js: a small function called in a loop, N times. Inlining and calls.
// call.roc is its twin.
const N = 50000000;

function mix(x, k) {
  return (x * 31 + k) % 65536;
}

function main() {
  let s = 0;
  for (let i = 0; i < N; i++) s = mix(s, i);
  console.log(s);
}

main();
