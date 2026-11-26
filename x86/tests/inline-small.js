// inlined: 23 sites, 324 instructions
// Inlining's small-leaf rule and its absolute cap (x86/roc/Inlining.roc's
// `always_leaf_instructions` and `most_growth_instructions`). In `fold`,
// `heavy` (more than 16 instructions) takes nearly all of the caller's
// share of 64, and `nudge` (at most 16) is inlined past it. In `spin`,
// a small caller, `nudge` is called 24 times in one loop: its sites are
// inlined while the caller grows by at most 256 instructions, and the
// rest are called as ever. All give what node gives.
function heavy(x) {
  let y = x;
  if (y > 64) y = y - 64;
  if (y > 32) y = y - 32;
  if (y > 16) y = y - 16;
  if (y > 8) y = y - 8;
  if (y > 4) y = y - 4;
  if (y > 2) y = y - 2;
  return y * 3;
}

function nudge(x) {
  if (x > 9) return x - 9;
  return x + 2;
}

function fold(k) {
  let t = 0;
  for (let i = 0; i < k; i = i + 1) {
    t = heavy(t + i);
    t = nudge(t);
  }
  return t;
}

function spin(k) {
  let n = 0;
  for (let i = 0; i < k; i = i + 1) {
    n = nudge(n);
    n = nudge(n);
    n = nudge(n);
    n = nudge(n);
    n = nudge(n);
    n = nudge(n);
    n = nudge(n);
    n = nudge(n);
    n = nudge(n);
    n = nudge(n);
    n = nudge(n);
    n = nudge(n);
    n = nudge(n);
    n = nudge(n);
    n = nudge(n);
    n = nudge(n);
    n = nudge(n);
    n = nudge(n);
    n = nudge(n);
    n = nudge(n);
    n = nudge(n);
    n = nudge(n);
    n = nudge(n);
    n = nudge(n + i);
  }
  return n;
}

function main() {
  console.log(fold(30), fold(7), spin(5), spin(13));
  console.log(heavy(100), nudge(3), nudge(12));
}

main();
