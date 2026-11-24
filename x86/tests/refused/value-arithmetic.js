// stops: x86: arithmetic on a value that is not a number is not compiled yet
// `f` returns a number or a string, so its result's kind is known only as
// it runs, and `*` of a string is JavaScript's coercion, not compiled yet.
function f(n) {
  if (n > 1) return "two";
  return n;
}
console.log(f(1) * 2);
console.log(f(2) * 2);
