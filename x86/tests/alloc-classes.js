// Allocation-heavy loops over every size class of the heap (16 to 32768
// bytes, and the large blocks past it: x86/roc/Heap.roc), with the records
// whose sizes the runtime knows before the program runs, which it
// allocates in line (`Heap.allocate_known_items`): arrays of at most four
// items, objects and captured variables' cells. Most of it is garbage at
// once, so the free lists and the bump pages both serve it.
let total = 0;
const keep = [];
for (let round = 0; round < 3; round++) {
  for (let n = 0; n < 13; n++) {
    const size = 1 << n;
    const a = [];
    for (let i = 0; i < size; i++) a.push(i);
    total += a.length + a[size - 1];
    const text = "y".repeat(size * 8);
    total += text.length;
    if (round === 1) keep.push(a, text);
  }
  for (let i = 0; i < 400; i++) {
    const o = { i, j: i + 1 };
    const pair = [i, o];
    const four = [i, i, i, i];
    const five = [i, i, i, i, i];
    let c = i;
    const f = () => c + 1;
    total += pair[1].j + f() + four.length + five.length;
  }
}
console.log(total, keep.length, keep[0].length, keep[25].length);
