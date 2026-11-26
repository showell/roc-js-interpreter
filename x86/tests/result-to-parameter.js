// A function whose result comes back to it as its own argument
// (Lowering's `KINDS ONLY RISE`): the first pass guesses each parameter a
// number, so `run = step(run, op)` settles with both known numbers. Beside
// it, a function no call reaches, one whose parameter is found a string
// after the guess, and one passed an array where the guess said a number.
function step(run, op) {
  if (run > 3) return run;
  if (op === 1 && run === 0) return 4;
  if (op === 2) return run - 1;
  return run % 2;
}

function walk(start, ops) {
  let run = start;
  for (const op of ops) run = step(run, op);
  return run;
}

function shout(text) {
  return text + "!";
}

function never(text) {
  return text.length;
}

let total = 0;
for (let start = 0; start < 4; start++) {
  total = total * 7 + walk(start, [2, 1, 0, 3]) + walk(start, [0, 2, 2, 1]);
}
console.log(total, shout("settled"), typeof never);
