// `%`, `Math.floor` of `/` and `===` of integers (x86/README.md, "An
// integer kind"): a hot loop of locals whose remainders, floored quotients
// and equalities stay integers, by a constant divisor (a power of two and
// not) and by one known only to be at least 1. Each is held to node, with
// the cases that must not stay integers: a negative dividend's `%` (which
// may be -0), a divisor that may be 0 or is negative, and floors of
// negative quotients, which round down, not toward 0.

// The hot loop: `Math.floor(i / 16) % 4` as the fourteen race's op, `%`
// and `Math.floor` by a divisor that isn't a literal, and the equalities
// that test them.
function hot() {
  const sizes = [3, 5, 7];
  const width = sizes.length + 2;
  const limit = 200000;
  let threes = 0;
  let sum = 0;
  let same = 0;
  for (let i = 0; i < limit; i++) {
    const op = Math.floor(i / 16) % 4;
    const lane = i % width;
    const band = Math.floor(i / width);
    if (op === 3) threes++;
    if (lane !== 0) sum = sum + (band % 8);
    if (Math.floor(lane) === op) same++;
  }
  return [threes, sum, same];
}

// Floors of negative and positive quotients, by a power of two, by another
// constant and by a divisor that isn't one; remainders of dividends of
// both signs, where a negative one's is -0 when it divides evenly.
function signs() {
  const sizes = [1, 2];
  const width = sizes.length + 1;
  const floors = [];
  const rests = [];
  for (let k = -7; k <= 7; k++) {
    floors.push(Math.floor(k / 4), Math.floor(k / 3), Math.floor(k / width));
    rests.push(k % 4, k % width, k % 3);
  }
  return [floors, rests];
}

// Divisors that may not take the integer way: 0, one that may be 0, and a
// negative one (`n % -d` is `n % d`; a floor by a negative may be -0).
function divisors() {
  const empty = [];
  const zero = empty.length;
  let n = 7;
  const minus = -3;
  let z = 0;
  return [
    n % zero,
    Math.floor(n / zero),
    n % 0,
    Math.floor(n / 0),
    n % minus,
    Math.floor(n / minus),
    1 / Math.floor(z / minus),
    1 / (z % 5),
    n % 1,
    Math.floor(n / 1),
    Math.floor(n),
  ];
}

// Equalities of integers that jump, both operators, against literals and
// against each other, and one that is stored rather than jumped on.
function equalities() {
  const seen = [];
  for (let i = 0; i < 6; i++) {
    const half = Math.floor(i / 2);
    if (half === 1) seen.push("one");
    if (i % 3 !== 0) seen.push(i);
    if (half === i % 3) seen.push("same");
    const stored = half === 2;
    seen.push(stored);
  }
  return seen;
}

function main() {
  console.log(hot());
  console.log(signs());
  console.log(divisors());
  console.log(equalities());
}

main();
