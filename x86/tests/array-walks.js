// `for ... of` over a known array, stepped in line (IndexLowering's
// header): an array of numbers, whose items are known numbers, an array of
// anything, empty arrays, nested walks, a walk that `break`s, and one that
// grows as it is walked, whose pushed items are walked too, as in node.
function sum(xs) {
  let total = 0;
  for (const x of xs) total = total + x;
  return total;
}
const places = [1024, 256, 64, 16, 4, 1];
console.log(sum(places), sum([]), sum([-0]), sum([0.5, 0.25]) * 4);

const mixed = [1, "two", true, null, undefined, [3], { four: 4 }];
for (const item of mixed) console.log(typeof item, item);
for (const item of []) console.log("never", item);

// Nested walks of the same array.
let pairs = 0;
for (const a of places) {
  for (const b of places) {
    if (a < b) pairs = pairs + 1;
  }
}
console.log(pairs);

// A walk that stops early.
let seen = 0;
for (const p of places) {
  if (p === 16) break;
  seen = seen + p;
}
console.log(seen);

// A walk of an array that grows as it is walked.
const growing = [1, 2, 3];
let steps = 0;
for (const g of growing) {
  steps = steps + 1;
  if (g < 6) growing.push(g + 3);
}
console.log(steps, growing.length, growing.join(","));

// The Nibble machine's lines read with a walk.
function lines(program, at) {
  let out = 0;
  for (const place of at) out = out * 4 + (Math.floor(program / place) % 4);
  return out;
}
console.log(lines(2730, places), lines(4095, places), lines(0, places));
