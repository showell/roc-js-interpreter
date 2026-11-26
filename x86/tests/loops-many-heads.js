// A function of twenty loops, each of whose heads widens once: a variable
// holds a number, then a string. The walks once had 16 widenings for the
// whole function; each loop's head now has its own, so this settles.
function day(n) {
  let out = "";
  let a = 0; for (let i = 0; i < n; i++) { if (i === 1) { a = "a"; } } out += a;
  let b = 0; for (let i = 0; i < n; i++) { if (i === 1) { b = "b"; } } out += b;
  let c = 0; for (let i = 0; i < n; i++) { if (i === 1) { c = "c"; } } out += c;
  let d = 0; for (let i = 0; i < n; i++) { if (i === 1) { d = "d"; } } out += d;
  let e = 0; for (let i = 0; i < n; i++) { if (i === 1) { e = "e"; } } out += e;
  let f = 0; for (let i = 0; i < n; i++) { if (i === 1) { f = "f"; } } out += f;
  let g = 0; for (let i = 0; i < n; i++) { if (i === 1) { g = "g"; } } out += g;
  let h = 0; for (let i = 0; i < n; i++) { if (i === 1) { h = "h"; } } out += h;
  let j = 0; for (let i = 0; i < n; i++) { if (i === 1) { j = "j"; } } out += j;
  let k = 0; for (let i = 0; i < n; i++) { if (i === 1) { k = "k"; } } out += k;
  let l = 0; for (let i = 0; i < n; i++) { if (i === 1) { l = "l"; } } out += l;
  let m = 0; for (let i = 0; i < n; i++) { if (i === 1) { m = "m"; } } out += m;
  let o = 0; for (let i = 0; i < n; i++) { if (i === 1) { o = "o"; } } out += o;
  let p = 0; for (let i = 0; i < n; i++) { if (i === 1) { p = "p"; } } out += p;
  let q = 0; for (let i = 0; i < n; i++) { if (i === 1) { q = "q"; } } out += q;
  let r = 0; for (let i = 0; i < n; i++) { if (i === 1) { r = "r"; } } out += r;
  let s = 0; for (let i = 0; i < n; i++) { if (i === 1) { s = "s"; } } out += s;
  let t = 0; for (let i = 0; i < n; i++) { if (i === 1) { t = "t"; } } out += t;
  let u = 0; for (let i = 0; i < n; i++) { if (i === 1) { u = "u"; } } out += u;
  let v = 0; for (let i = 0; i < n; i++) { if (i === 1) { v = "v"; } } out += v;
  return out;
}

console.log(day(1));
console.log(day(3));
