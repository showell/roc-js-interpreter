// stops: x86: console.log of an array that node lays out in columns is not compiled yet
// Node writes an array of more than six short items in aligned columns.
const xs = [];
for (let i = 0; i < 10; i++) xs.push(i * 3);
console.log(xs.length);
console.log(xs);
