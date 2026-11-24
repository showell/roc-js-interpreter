// stops: x86: an object pattern of null or undefined, which throws in node, is not compiled yet
function f({ a }) {
  return a;
}
console.log(f({ a: 1 }));
console.log(f(null));
