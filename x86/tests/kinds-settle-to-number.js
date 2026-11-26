// Results fed back into loops that stay numbers. `half` gives a number
// whatever it is passed, so its parameter settles to a number; `step`'s
// result and parameter go round between a number and a value as the passes
// guess, and rise to a value (Lowering's `KINDS ONLY RISE`), though every
// value they hold is a number.
function step(i) { return i + 1; }
function half(v) { return v / 2; }
let total = 0;
for (let i = 0; i < 10; i = step(i)) {
  total = total + i;
}
let h = 1024;
while (h > 1) h = half(h);
console.log(total, h);
