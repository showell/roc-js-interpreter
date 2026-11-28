// push.js: an array built by SIZE pushes, ROUNDS times, each a new array.
// The append path and its growth. push.roc is its twin.
const SIZE = 1000;
const ROUNDS = 20000;

function main() {
  let total = 0;
  for (let r = 0; r < ROUNDS; r++) {
    const a = [];
    for (let i = 0; i < SIZE; i++) a.push(i + r);
    total = total + a.length + a[SIZE - 1];
  }
  console.log(total);
}

main();
