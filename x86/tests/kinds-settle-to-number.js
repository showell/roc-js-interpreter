// A result fed back that stays a number: the loop's counter is the
// function's result, and its parameter's kind settles to a number.
function step(i) { return i + 1; }
function half(v) { return v / 2; }
let total = 0;
for (let i = 0; i < 10; i = step(i)) {
  total = total + i;
}
let h = 1024;
while (h > 1) h = half(h);
console.log(total, h);
