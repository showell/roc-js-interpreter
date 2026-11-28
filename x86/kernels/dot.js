// dot.js: the dot product of two arrays of doubles, ROUNDS times. Two item
// reads a trip and double arithmetic. Every item is a multiple of 1/4 and
// every sum a multiple of 1/8 below 2^50, so the sums are exact and the
// checksum, the total times 8, is a whole number. dot.roc is its twin.
const SIZE = 1000;
const ROUNDS = 50000;

function main() {
  const x = [];
  const y = [];
  for (let i = 0; i < SIZE; i++) {
    x.push((i % 17) * 0.5);
    y.push((i % 13) * 0.25);
  }
  let d = 0;
  for (let r = 0; r < ROUNDS; r++) {
    for (let i = 0; i < x.length; i++) d = d + x[i] * y[i];
  }
  console.log(d * 8);
}

main();
