function fact(n) {
  let r = 1;
  for (let i = 2; i <= n; i++) {
    r = r * i;
  }
  return r;
}
function count(n) {
  let k = 0;
  let s = 0;
  while (k < n) {
    k = k + 1;
    if (k === 3 || k === 5) {
      continue;
    }
    s += k;
  }
  return s;
}
function both(a, b) {
  return a > 0 && b > 0;
}
function quiet(x) {
  x = x + 1;
}
const big = 9007199254740992;
let t = true;
console.log(fact(10), fact(18), count(10));
console.log(both(1, 2), both(1, -2), !t, !0, !7);
console.log(-0, 0 - 0, -5, 3 - 10, NaN, Infinity, -Infinity, 1 / 0, 0 / 0);
console.log(big, -big, quiet(1), undefined);
console.log();
console.log(2 >= 2, 2 <= 1, NaN === NaN, NaN !== NaN, 1 === 1, true === false);
let x = 10;
x++;
++x;
x--;
console.log(x, x++, ++x, x);
console.log(fact(25) > 0, 100 / 4);
