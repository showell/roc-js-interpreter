// Arrays: the sieve of Eratosthenes over 0..n, an array of n + 1 flags
// built by push, and the primes counted.
function work(n) {
  const flags = [];
  for (let i = 0; i <= n; i++) flags.push(true);
  let count = 0;
  for (let p = 2; p <= n; p++) {
    if (flags[p]) {
      count++;
      for (let m = p * p; m <= n; m += p) flags[m] = false;
    }
  }
  return count;
}
