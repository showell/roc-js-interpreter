// stops: x86: console.log of an array or object of more than 100 items is not compiled yet
// Node writes the first 100 items of an array, then how many more there are.
const xs = [];
for (let i = 0; i < 101; i++) xs.push(i);
console.log(xs.length);
console.log(xs);
