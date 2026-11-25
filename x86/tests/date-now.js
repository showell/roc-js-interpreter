// Date.now(): the milliseconds since the epoch, whole, from the kernel's
// clock. No time is printed, so the output is node's whatever the clock
// reads: the readings are whole, after 2020, and never go backwards.
const start = Date.now();
console.log(typeof start, typeof Date.now, Math.floor(start) === start);
console.log("after 2020:", start > 1577836800000);
let last = start;
let backwards = 0;
let i = 0;
while (i < 1000) {
  const t = Date.now();
  if (t < last) backwards = backwards + 1;
  last = t;
  i = i + 1;
}
const elapsed = Date.now() - start;
console.log("elapsed >= 0:", elapsed >= 0, "backwards:", backwards);
console.log("an argument is unread:", Date.now(5) >= start);
