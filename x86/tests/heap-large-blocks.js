// Blocks past the most a page of blocks holds (32768 bytes) take pages of
// their own (x86/roc/Heap.roc): an array grown past 4096 items, a string
// past 32 KiB, and one past several pages, among small blocks before and
// after them, so the heap walk that x86/programs.shale runs at the exit
// meets large blocks between pages of small ones.
const small = [];
for (let i = 0; i < 100; i++) small.push("s" + i);
const big = [];
for (let i = 0; i < 10000; i++) big.push(i * 2);
const text = "abcdefgh".repeat(5000);
const huge = "x".repeat(300000);
const after = [];
for (let i = 0; i < 100; i++) after.push({ i, name: "a" + i });
let sum = 0;
for (const n of big) sum += n;
console.log(small.length, small[99], big.length, sum);
console.log(text.length, text.slice(39990), huge.length);
console.log(after.length, after[99].name, big.slice(9997).join(","));
