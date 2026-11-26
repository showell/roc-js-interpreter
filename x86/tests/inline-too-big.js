// inlined: 1 sites, 4 instructions
// Inlining's budget, at its edges: a leaf called in a loop that is over
// the size limit (`most_leaf_ops`) is called as ever, and so is one under
// it whose inlining would grow its caller past `most_growth_percent`; a
// small leaf called in a loop of a large enough caller is the one site put
// in line. All give what node gives.
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

function main() {
  let total = 0;
  for (let i = 0; i < 300; i = i + 1) total = total + big(i);
  console.log(total, climb(9), climb(30));
  let n = 0;
  while (n < 5) n = small(n);
  console.log(n);
}

main();
