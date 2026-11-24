// `%` of whole numbers, as JavaScript's: the dividend's sign, -0, NaN for
// `% 0`; and `for ... of` over an array, its items read as the loop comes
// to them.
console.log(7 % 3, -7 % 3, 7 % -3, -6 % 3, 0 % 5, 5 % 0, -0 % 4);
let sum = 0;
for (let i = 0; i < 100; i++) {
  if (i % 7 === 0) sum = sum + i;
}
console.log(sum);
const xs = [3, "four", 5, [6]];
for (const x of xs) console.log(x);
let product = 1;
for (const n of [1, 2, 3, 4, 5]) product = product * n;
console.log(product);
const grow = [1];
for (const g of grow) {
  if (g < 4) grow.push(g + 1);
}
console.log(grow);
for (const missing of []) console.log("never", missing);
