// inlined: 2 sites, 26 instructions
// A leaf function called in a loop is put in line (x86/roc/Inlining.roc),
// and the same leaf called outside a loop is called as ever. Each call
// must give what node gives: the inlined bodies' returns, their captured
// constant, their own variables kept apart from the caller's, and a call
// whose result is a value of another kind than the arguments'.
const LIMIT = 50;

function clamp(x) {
  if (x > LIMIT) return LIMIT;
  if (x < 0) return 0;
  return x;
}

function scaled(n, by) {
  let out = n * by;
  out = out + 1;
  return out;
}

function sign(n) {
  if (n > 0) return "plus";
  if (n < 0) return "minus";
  return "zero";
}

function main() {
  console.log(clamp(70), clamp(-3), clamp(12));
  let total = 0;
  let out = 1000;
  const signs = [];
  for (let i = -30; i < 90; i = i + 7) {
    total = total + clamp(i);
    total = total + scaled(i, 2) - scaled(i, 3);
    if (i % 3 === 0) signs.push(sign(i));
    let words = 0;
    while (words < 2) {
      out = out - clamp(words + i);
      words = words + 1;
    }
  }
  console.log(total, out, signs);
  let half = 0;
  for (const x of [0.5, -1.5, 99, 6.5]) half = half + clamp(x);
  console.log(half);
}

main();
