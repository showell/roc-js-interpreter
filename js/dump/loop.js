const o = { total: 0 };
const a = [1, 2, 3];
for (let i = 0; i < a.length; i++) {
  o.total = o.total + a[i];
}
console.log(o.total);
