// Integer `Math.floor(a / b)` and `a % b` at the edges of the 32-bit
// divide (x86/README.md, "An integer kind"): a dividend in [0, 2^32) and a
// divisor in [1, 2^32) take `div r32`, and the near misses keep the 64-bit
// `idiv` or the guarded way. Each is held to node. The divisors are an
// array's items, passed down as the fourteen race's places are, so their
// range is known but is not one value; each dividend is a loop's counter,
// whose range its bounds give; each answer is printed where it is made, so
// no array of results holds it.

// Dividends up to 2^32 - 1, divisors up to 2^32 - 1: the 32-bit way.
function near_top(divisors) {
  for (let n = 4294967292; n < 4294967296; n++) {
    for (const d of divisors) console.log(n, d, Math.floor(n / d), n % d);
  }
}

// A dividend that may reach 2^32, one past the 32-bit way's top: it must
// stay a 64-bit divide, and 2^32 itself must divide right.
function past_top(divisors) {
  for (let n = 4294967294; n < 4294967298; n++) {
    for (const d of divisors) console.log(n, d, Math.floor(n / d), n % d);
  }
}

// A divisor past 2^32 - 1, with a dividend that fits: 64-bit too.
function wide_divisor(divisors) {
  for (let n = 4294967290; n < 4294967296; n++) {
    for (const d of divisors) console.log(n, d, Math.floor(n / d), n % d);
  }
}

// A divisor whose range holds 0: `n % 0` is NaN and a floor by 0 an
// infinity, so neither is an `Integer`, and both take the guarded way.
function zero_divisor(divisors) {
  for (let n = 0; n < 6; n++) {
    for (const d of divisors) console.log(n, d, n % d, Math.floor(n / d));
  }
}

// A dividend that may be negative keeps the signed divide: floors round
// down, and remainders keep the dividend's sign (and may be -0).
function negative_dividend(divisors) {
  for (let n = -7; n <= 7; n++) {
    for (const d of divisors) console.log(n, d, Math.floor(n / d), n % d);
  }
}

// The fourteen race's shape: a program in [0, 4096) taken apart by places.
function places(steps) {
  let sum = 0;
  for (let program = 0; program < 4096; program++) {
    for (const place of steps) {
      sum = sum + (Math.floor(program / place) % 4) + (program % place);
    }
  }
  return sum;
}

function main() {
  near_top([1, 3, 7, 65536, 2147483647, 2147483648, 4294967295]);
  past_top([3, 7, 4294967295]);
  wide_divisor([5, 4294967296]);
  zero_divisor([0, 1, 5]);
  negative_dividend([3, 7]);
  console.log(places([1024, 256, 64, 16, 4, 1]));
}

main();
