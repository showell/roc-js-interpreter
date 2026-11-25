// stops: x86: 100,000 timer callbacks have run, and an interval never cleared runs for good in node
let ticks = 0;
setInterval(() => {
  ticks++;
}, 1);
