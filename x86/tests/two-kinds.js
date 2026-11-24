// A function that returns a number or a boolean.
function f(n) {
  if (n) return 1;
  return false;
}
console.log(f(1), f(0), f(1) === 1, f(0) === false);
