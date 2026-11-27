// versioned: 0 loops, 0 instructions
// Loops near those Versioning places twice, which it leaves as they are:
// each lacks a variable the loop never writes, holds as a value and reads
// as a number, or does what a copy can't (a closure, a `for ... of`).

// The bound is written in the loop.
function shrinking(o) {
  let n = o.n;
  let i = 0;
  while (i < n) {
    n = n - 1;
    i = i + 1;
  }
  return i;
}
console.log(shrinking({ n: 9 }));

// A closure made in the loop captures its variable.
function closures(o) {
  const n = o.n;
  const made = [];
  for (let i = 0; i < n; i++) made.push(() => i * 2);
  let total = 0;
  for (const f of made) total = total + f();
  return total;
}
console.log(closures({ n: 5 }));

// A `for ... of`, whose item is read as a number.
function walked(o) {
  const scale = o.scale;
  let total = 0;
  for (const item of o.items) total = total + item * scale;
  return total;
}
console.log(walked({ scale: 3, items: [1, 2, 3] }));

// The bound is a known number, not a value: a parameter every call passes
// a number.
function counted(n) {
  let total = 0;
  for (let i = 0; i < n; i++) total = total + i;
  return total;
}
console.log(counted(10));

// The value the loop never writes is read, but not as a number.
function named(o) {
  const label = o.label;
  const out = [];
  for (let i = 0; i < 3; i++) out.push(label);
  return out.join(",");
}
console.log(named({ label: "x" }));
