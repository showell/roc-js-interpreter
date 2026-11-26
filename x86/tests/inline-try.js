// inlined: 0 sites, 0 instructions
// A program with a `try` is not inlined at all (Inlining's header): here
// a small leaf called in a loop, and a leaf whose own body has a `try`.
function twice(x) {
  return x * 2;
}

function safe(x) {
  try {
    if (x > 3) throw new Error("big");
    return x;
  } catch (e) {
    return 0;
  }
}

function main() {
  let total = 0;
  for (let i = 0; i < 6; i = i + 1) {
    total = total + twice(i);
    total = total + safe(i);
  }
  console.log(total);
}

main();
