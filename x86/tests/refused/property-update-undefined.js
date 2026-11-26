// stops: x86: arithmetic on a value that is not a number is not compiled yet
// `o.k++` of a property the object lacks: node makes it NaN.
const o = { n: 1 };
console.log("before");
o.missing++;
console.log(o.missing);
