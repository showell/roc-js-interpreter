const twice = (x) => x * 2;
function first_over(limit) {
  let n = 1;
  while (true) {
    n = twice(n);
    if (n > limit) {
      break;
    }
  }
  return n;
}
function collatz_steps(start) {
  let n = start;
  let steps = 0;
  while (n !== 1) {
    const half = n / 2;
    if (half === Math_floor(half)) {
      n = half;
    } else {
      n = 3 * n + 1;
    }
    steps++;
  }
  return steps;
}
function Math_floor(x) {
  let whole = 0;
  if (x >= 0) {
    while (whole + 1 <= x) {
      whole += 1;
    }
  }
  return whole;
}
console.log(first_over(1000), twice(21), collatz_steps(27));
for (let i = 0; i < 3; i++) {
  console.log(i, i * i, i === 1 || i > 1);
}
