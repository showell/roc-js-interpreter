// concat.js: a string built by SIZE appends of "ab", ROUNDS times, each a
// new string. Concatenation and allocation. concat.roc is its twin.
const SIZE = 1000;
const ROUNDS = 2000;

function main() {
  let total = 0;
  for (let r = 0; r < ROUNDS; r++) {
    let s = "";
    for (let i = 0; i < SIZE; i++) s = s + "ab";
    total = total + s.length;
  }
  console.log(total);
}

main();
