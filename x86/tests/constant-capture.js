// A function that captures only a constant number is known before the
// program runs (KnownFunctions.statics_of): called directly, through a
// value, and by a method that takes a function, it reads the number.
const K = 5;
function plusK(x) {
  return x + K;
}
function twice(x) {
  return plusK(plusK(x));
}
const f = plusK;
console.log(plusK(1), twice(1), f(2));
console.log([1, 2, 3].map(plusK));
console.log(typeof plusK, plusK, [plusK]);
