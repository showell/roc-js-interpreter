// refused: a variable holds values of two kinds
let x = 0;
for (let i = 0; i < 2; i++) {
  if (i === 1) {
    x = true;
  }
}
console.log(x);
