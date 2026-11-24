// refused: the function `f`: it returns values of two kinds
function f(n) {
  if (n) return 1;
  return false;
}
console.log(f(1));
