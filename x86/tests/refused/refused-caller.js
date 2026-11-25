// refused: the method `fill` of an array is not compiled yet
// The program's own code is refused after its call of `wrap`, and that call
// still gives `wrap` its parameter's kind, an array, so the refusal is the
// program's `fill`, not a `push` of a number in `wrap`.
function wrap(xs) {
  xs.push(1);
  return xs;
}
console.log(wrap([]).fill(0));
