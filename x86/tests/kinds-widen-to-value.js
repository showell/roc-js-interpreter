// A result fed back that must hold a value of another kind: a number,
// then a string, so the parameter and the result widen to a value.
function grow(v) { return v + "!"; }
let w = 0;
for (let i = 0; i < 3; i++) {
  w = grow(w);
}
console.log(w);
