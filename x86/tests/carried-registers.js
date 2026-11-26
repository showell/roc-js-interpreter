// A loop's carried places come first in Registers (LOOP-CARRIED PLACES
// FIRST): `mix` carries five variables round its loop, more than there are
// spare registers, besides the bytecode's stack places, so the choice of
// which to keep in registers is made, and every one must still come out
// right. Moves takes out a second `cvttsd2si` of the same index (a WHOLE
// NUMBER MADE ONCE): `sum3` reads three arrays at one `i`, past the range
// tests' jumps, and `shifted` reads at `i` and then at `i + 1` and `i - 1`,
// whose conversions must not be taken for `i`'s.
function mix(n) {
  let a = 1;
  let b = 2;
  let c = 3;
  let d = 4;
  let e = 5;
  let i = 0;
  while (i < n) {
    const t = a + b * 2 - c;
    a = b;
    b = c;
    c = d + (t >= 50 ? 1 : 0);
    d = e - 1;
    e = t % 97;
    i = i + 1;
  }
  return [a, b, c, d, e];
}

function sum3(x, y, z) {
  const n = x.length;
  let total = 0;
  let i = 0;
  while (i < n) {
    total = total + x[i] * 100 + y[i] * 10 + z[i];
    i = i + 1;
  }
  return total;
}

function shifted(x) {
  let total = 0;
  let i = 1;
  while (i < x.length - 1) {
    total = total + x[i] * 100 + x[i + 1] * 10 + x[i - 1];
    i = i + 1;
  }
  return total;
}

function run() {
  console.log(mix(1000));
  const x = [1, 2, 3, 4, 5];
  const y = [6, 7, 8, 9, 0];
  const z = [5, 4, 3, 2, 1];
  console.log(sum3(x, y, z));
  console.log(shifted(x));
}

run();
