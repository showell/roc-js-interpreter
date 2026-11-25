// Timers run after the program on a virtual clock, earliest first, two at
// one time in the order set; an interval runs until it is cleared, and a
// callback may set and clear timers.
setTimeout(() => console.log("at 300"), 300);
setTimeout(() => console.log("at 100"), 100);
setTimeout(() => console.log("at 200, set first"), 200);
setTimeout(() => console.log("at 200, set second"), 200);
setTimeout(() => console.log("at 1, its delay 0"), 0);
setTimeout(() => console.log("at 1, its delay left out"));
setTimeout(() => console.log("at 1, its delay negative"), -5);
setTimeout(() => console.log("at 1, its delay NaN"), NaN);
setTimeout(() => console.log("at 12, its delay 12.9"), 12.9);
const never = setTimeout(() => console.log("never: cleared"), 150);
clearTimeout(never);
clearTimeout(undefined);
clearInterval(null);
console.log("the program's end comes first;", typeof never, typeof setTimeout);

let ticks = 0;
const id = setInterval(() => {
  ticks++;
  console.log("tick", ticks);
  if (ticks === 4) {
    clearInterval(id);
    console.log("cleared after", ticks, "ticks");
  }
}, 100);
setTimeout(() => console.log("between ticks 2 and 3"), 250);
setTimeout(() => console.log("long after the last tick:", ticks), 700);

const seen = [];
function link(depth) {
  seen.push(depth);
  if (depth < 3) setTimeout(() => link(depth + 1), 200);
  else console.log("the chain:", seen);
}
setTimeout(() => link(1), 10);
const inner = setInterval(() => {
  console.log("inner once, then cleared by a timeout it sets");
  setTimeout(() => clearInterval(inner), 0);
}, 1000);
