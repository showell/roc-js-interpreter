// Big Maps and Sets: thousands of keys, so the index grows many times, its
// entries made as it grows (strings and arrays the collector may take
// mid-growth), deletes that leave many tombstones, and churn.
const big = new Map();
for (let i = 0; i < 3000; i++) big.set(`key-${i}-${i * 7}`, [i, `value${i}`]);
let sum = 0;
for (let i = 0; i < 3000; i++) sum = sum + big.get(`key-${i}-${i * 7}`)[0];
console.log(big.size, sum, big.get("key-2999-20993"), big.get("key-3000-21000"));
for (let i = 0; i < 3000; i++) {
  if (i % 3 !== 0) big.delete(`key-${i}-${i * 7}`);
}
let kept = 0;
for (let i = 0; i < 3000; i++) {
  if (big.has(`key-${i}-${i * 7}`)) kept = kept + 1;
}
console.log(big.size, kept, [...big.keys()].slice(0, 4), [...big.keys()].slice(-2));

const numbers = new Set();
for (let i = 0; i < 4000; i++) numbers.add((i * 37) % 1000);
let present = 0;
for (let i = -10; i < 1010; i++) {
  if (numbers.has(i)) present = present + 1;
}
console.log(numbers.size, present, numbers.has(999), numbers.has(1000), numbers.has(0.5));

// Churn: a window of 50 keys slides over 2000, set and deleted, so the
// entries used grow while the size stays small.
const window = new Map();
for (let i = 0; i < 2000; i++) {
  window.set(i, `w${i}`);
  if (i >= 50) window.delete(i - 50);
}
let windowSum = 0;
for (const k of window.keys()) windowSum = windowSum + k;
console.log(window.size, windowSum, window.get(1950), window.get(1949), window.get(1999));

const objects = new Map();
const held = [];
for (let i = 0; i < 1500; i++) {
  const o = { n: i };
  if (i % 10 === 0) held.push(o);
  objects.set(o, `${i}`);
}
console.log(objects.size, held.map((o) => objects.get(o)).slice(0, 6), objects.get({ n: 0 }));
