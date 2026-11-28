// fib_mod.js: Fibonacci numbers modulo a prime, N steps. The plain
// integer path: three locals, an add and a remainder by a constant a trip.
// fib_mod.roc is its twin.
const N = 50000000;
const M = 1000000007;

function main() {
  let a = 0;
  let b = 1;
  for (let i = 0; i < N; i++) {
    const t = (a + b) % M;
    a = b;
    b = t;
  }
  console.log(a);
}

main();
