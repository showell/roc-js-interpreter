// A variable that holds a number, then a boolean: the loop's head widens
// it to a value of a kind not known before it runs.
let x = 0;
for (let i = 0; i < 2; i++) {
  if (i === 1) {
    x = true;
  }
}
console.log(x);
