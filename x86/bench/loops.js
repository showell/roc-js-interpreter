// The statement path: nested loops over local variables and an array of
// 100 numbers, k passes of the outer loop, the total kept below a million.
function work(k) {
  const a = [];
  for (let i = 0; i < 100; i++) a.push(i);
  let total = 0;
  for (let j = 0; j < k; j++) {
    for (let i = 0; i < 100; i++) {
      total = (total + a[i] * j) % 1000003;
    }
  }
  return total;
}
