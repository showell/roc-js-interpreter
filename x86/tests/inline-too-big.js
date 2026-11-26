// inlined: 2 sites, 32 instructions
// Inlining's budget, at its edges: a leaf called in a loop that is over
// the size limit (`most_leaf_instructions`, `big`) is called as ever; so
// is a small function that is no leaf, since it calls the function it is
// handed (`outer`). `wide`, whose literal of 420 numbers gives it room to
// grow, meets `big` and `outer`, so the size limit and the leaf rule each
// keep a site out alone. `medium` in `climb` is put in line by the floor
// (`least_growth_instructions`): a quarter of `climb`, a small caller,
// would be too little for it. `small` in `main` is put in line too. All
// give what node gives.
function big(x) {
  let y = x;
  if (y > 100) y = y - 100;
  if (y > 50) y = y - 50;
  if (y > 25) y = y - 25;
  if (y > 12) y = y - 12;
  if (y > 6) y = y - 6;
  if (y > 3) y = y - 3;
  if (y > 1) y = y - 1;
  return y + 1;
}

function medium(x) {
  if (x > 10) return x + 3;
  if (x > 5) return x + 2;
  if (x > 1) return x * 2;
  return x + 1;
}

function climb(k) {
  let n = 0;
  while (n < k) n = medium(n);
  return n;
}

function small(x) {
  return x + 1;
}

function outer(f, x) {
  return f(x) + 1;
}

function wide() {
  const digits = [
    1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0,
    1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0,
    1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0,
    1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0,
    1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0,
    1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0,
    1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0,
    1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0,
    1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0,
    1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0,
    1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0,
    1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0,
    1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0,
    1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0,
  ];
  let total = 0;
  for (const d of digits) total = total + big(d * 30) + outer(small, d);
  return total;
}

function main() {
  let total = 0;
  for (let i = 0; i < 300; i = i + 1) total = total + big(i);
  console.log(total, climb(9), climb(30));
  let n = 0;
  while (n < 5) n = small(n);
  for (let k = 0; k < 3; k = k + 1) n = outer(small, n);
  console.log(n, wide());
}

main();
