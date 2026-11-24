// Closures over variables that hold values, and functions as values.
let n = 3;
function f() {
  return n;
}
n = 4;
console.log(f());
const g = (x) => x + 1;
console.log(g(n));

function makeCounter(start) {
  let count = start;
  return {
    up: () => ++count,
    down: () => count--,
    get: () => count,
  };
}
const c = makeCounter(10);
c.up();
c.up();
c.down();
console.log(c.get(), c);

function makeAdder(k) {
  return (x) => x + k;
}
const add2 = makeAdder(2);
const add5 = makeAdder(5);
console.log(add2(1), add5(1), add2(add5(0)));

const fs = [];
for (let i = 0; i < 4; i++) {
  fs.push(() => i * i);
}
console.log(fs[0](), fs[1](), fs[3](), fs.length);

function apply(h, v) {
  return h(v);
}
function double(x) {
  return x * 2;
}
console.log(apply(double, 21), apply(g, "a"), apply((s) => s + "!", "b"));

const twice = (h) => (x) => h(h(x));
console.log(twice(double)(3), twice(add2)(0));

function few(a, b, c) {
  return [a, b, c];
}
const loose = few;
console.log(loose(1), loose(1, 2, 3, 4));
console.log(double, g, [double, (() => 1)], { f: function () {} });
console.log(double === double, double === g, loose === few);
