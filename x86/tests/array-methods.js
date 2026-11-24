// The array methods that take a function, and join, slice and charAt.
const xs = [1, 2, 3, 4, 5, 6];
console.log(xs.map((x) => x * 2));
console.log(xs.map((x, i) => x + i), xs.map((x, i, a) => a.length));
console.log(xs.filter((x) => x % 2 === 0), xs.filter(() => false));
console.log(xs.reduce((a, b) => a + b, 0), xs.reduce((a, b) => a * b));
console.log(xs.reduce((acc, x, i) => acc + x * i, 100));
let total = 0;
const seen = [];
xs.forEach((x, i) => {
  total += x;
  seen.push(i);
});
console.log(total, seen, xs.forEach(() => 1));
console.log(xs.join(), xs.join("-"), [].join(), ["a", null, undefined, 1].join("+"));
console.log(xs.slice(), xs.slice(2), xs.slice(1, 3), xs.slice(-2), xs.slice(2, -1), xs.slice(5, 2));
const words = ["pear", "fig", "apple"];
console.log(words.map((w) => w.charAt(0)).join(""), "abc".charAt(2), "abc".charAt(5) === "");
function square(n) {
  return n * n;
}
console.log(xs.map(square), [[1, 2], [3]].map((a) => a.length));
const nested = xs.map((x) => xs.filter((y) => y < x).length);
console.log(nested);
