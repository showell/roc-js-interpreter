// More output than the 64 KiB buffer holds, so it is written as it fills.
let total = 0;
for (let i = 0; i < 20000; i++) {
  console.log(i, i * 2, i === 19999);
  total = total + i;
}
console.log(total);
