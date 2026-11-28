// sum_array.js: the sum of an integer array, read ROUNDS times. The item
// read, the integer kind and the bounds check. sum_array.roc is its twin.
const SIZE = 1000;
const ROUNDS = 50000;

function main() {
  const a = [];
  for (let i = 0; i < SIZE; i++) a.push((i * 7) % 1000);
  let s = 0;
  for (let r = 0; r < ROUNDS; r++) {
    for (let i = 0; i < a.length; i++) s = s + a[i];
  }
  console.log(s);
}

main();
