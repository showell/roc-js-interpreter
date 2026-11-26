// Two functions in a cycle, each fed the other's result in a loop, with no
// recursion: f's result is g's argument, and g's is f's.
function f(n) { return n * 2; }
function g(n) { return n + 3; }
let y = 1;
for (let i = 0; i < 5; i++) {
  y = g(f(y));
}
console.log(y);
