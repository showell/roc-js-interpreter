// stops: x86: arithmetic on a value that is not a number is not compiled yet
// `a[i]++` of an item past the end: node makes it NaN.
const a = [1, 2];
console.log("before");
a[5 - a.length]++;
console.log(a);
