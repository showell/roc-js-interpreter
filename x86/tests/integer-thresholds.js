// A loop's head widens an `Integer` through the function's own thresholds
// before ±2^53 (Lowering's `integer_thresholds`): `(a + b) % M` and
// `(x * 31 + k) % 65536` stay integers. Held to node at the edges where they
// must not: sums and products that pass 2^53 and round as doubles, `%` and
// `&` chains near 2^31, 2^32 and 2^53, negative moduli and dividends, -0
// from a remainder and from a product, and values that pass a threshold on
// the last trip.

// Fibonacci numbers modulo a prime, and modulo 2^31 - 1, 2^32 and 2^32 - 5.
function fibonacci(n, m) {
  let a = 0;
  let b = 1;
  for (let i = 0; i < n; i++) {
    const t = (a + b) % m;
    a = b;
    b = t;
  }
  return a;
}

function fibonacci_words(n) {
  let a = 0;
  let b = 1;
  let c = 0;
  let d = 1;
  let e = 0;
  let f = 1;
  for (let i = 0; i < n; i++) {
    const t = (a + b) % 2147483647;
    a = b;
    b = t;
    const u = (c + d) % 4294967296;
    c = d;
    d = u;
    const v = (e + f) % 4294967291;
    e = f;
    f = v;
  }
  return [a, b, c, d, e, f];
}

// A hash kept within 16 bits, by `%` and by `&`, and within 31 and 32.
function hashes(text) {
  let h16 = 0;
  let m16 = 0;
  let h31 = 7;
  let h32 = 7;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    h16 = (h16 * 31 + c) % 65536;
    m16 = (m16 * 31 + c) & 65535;
    h31 = (h31 * 131 + c) & 2147483647;
    h32 = (h32 * 33 + c) % 4294967296;
  }
  return [h16, m16, h31, h32];
}

// Remainders by 2^52 - 1, whose sums and doublings reach just below 2^53,
// and a sum and a product with no remainder, which pass 2^53 and round as
// doubles: those must stay doubles.
function near_limit(n) {
  const M = 4503599627370495;
  let a = 1;
  let b = 2;
  let p = 3;
  let f = 0;
  let g = 1;
  let q = 1;
  for (let i = 0; i < n; i++) {
    const t = (a + b) % M;
    a = b;
    b = t;
    p = (p * 2) % M;
    const h = f + g;
    f = g;
    g = h;
  }
  for (let i = 0; i < 34; i++) q = q * 3;
  // console.log writes no number past 2^53 yet, so those are compared.
  return [
    a,
    b,
    p,
    Math.floor(f / 1000000),
    Math.floor(g / 1000000),
    g === 37889062373143900,
    g - f === 14472334024676220,
    q === 16677181699666568,
    q - 1 === q,
  ];
}

// Negative moduli and negative dividends: the remainder takes the dividend's
// sign, and a dividend of -k * m gives -0.
function negatives() {
  let a = 0;
  let b = 1;
  for (let i = 0; i < 20; i++) {
    const t = (a + b) % -7;
    a = b;
    b = t;
  }
  let d = 0;
  const seen = [];
  for (let i = 0; i < 12; i++) {
    d = (d - 3) % 5;
    seen.push(d);
  }
  let z = 10;
  for (let i = 0; i < 2; i++) z = (z - 5) % 5;
  return [a, b, seen, z, 1 / z];
}

// -0 from a product: zero times a negative factor, kept through `%`.
function products() {
  let p = 0;
  for (let i = 0; i < 3; i++) p = (p * -2) % 9;
  let q = 1;
  for (let i = 0; i < 5; i++) q = (q * -3) % 1000;
  let r = 5;
  for (let i = 0; i < 4; i++) r = r * 0 - 0;
  return [p, 1 / p, q, r, 1 / r];
}

// Values that pass a threshold on the last trip.
function crossings() {
  let x = 0;
  while (x < 65536) x = x + 1000;
  let y = 1;
  for (let i = 0; i < 31; i++) y = y * 2;
  let w = 1;
  for (let i = 0; i < 32; i++) w = (w * 2) % 4294967296;
  let z = 1;
  for (let i = 0; i < 54; i++) z = z * 2;
  let s = 0;
  for (let i = 0; i < 70; i++) s = (s + 1000) % 65536;
  return [x, y, y | 0, y >>> 0, w, z === 18014398509481984, z + 1 === z, Math.floor(z / 1024), s];
}

console.log(fibonacci(100000, 1000000007), fibonacci(1000, 65536), fibonacci(50, 1));
console.log(fibonacci_words(5000));
console.log(hashes("the quick brown fox jumps over the lazy dog"), hashes(""));
console.log(near_limit(80));
console.log(negatives());
console.log(products());
console.log(crossings());
