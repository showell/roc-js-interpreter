// The compound assignments of a member, `o.k += e` and `a[i] -= e` and the
// rest: the new value as the expression's, and the member written, on whole
// and fractional numbers, by a name and by a computed key.
const o = { n: 6, f: 0.5, s: "a" };
o.n += 4;
o.n -= 1;
o.n *= 3;
console.log(o.n, (o.n /= 9), o.n, (o.n %= 2), o.n);
o.n = 3;
console.log((o.n **= 2), (o.n |= 6), (o.n &= 12), (o.n ^= 5), (o.n <<= 2), (o.n >>= 1));
o.f += 1;
console.log(o.f === 1.5, (o.f *= 2) === 3, o.f, (o.f -= 0.25) === 2.75);
o.s += "b";
console.log((o.s += 1), o.n, o.s);

const a = [1, 2, 0.5];
const i = 1;
a[0] += 10;
a[i] *= 7;
a[2] += a[2];
console.log(a, (a[i] -= 4), (a[0] %= 4), a);
a[2] -= 0.25;
console.log(a[2] === 0.75, (a[2] += 0.25) === 1);

const totals = { red: 0, blue: 0 };
for (const [colour, n] of [["red", 2], ["blue", 3], ["red", 5]]) totals[colour] += n;
console.log(totals);

const counter = { hits: 0 };
for (let k = 0; k < 5; k++) counter.hits += k;
console.log(counter.hits, (counter.hits += counter.hits));
