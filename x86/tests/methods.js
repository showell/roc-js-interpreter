// The array methods some, every, find, findIndex, indexOf, includes, concat,
// sort and reverse, and a string's charCodeAt, indexOf, includes and split.
const xs = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
console.log(xs.some((x) => x > 9), xs.some((x) => x > 10), xs.every((x) => x > 0), xs.every((x) => x < 5));
console.log(xs.find((x) => x > 4), xs.find((x) => x > 40), xs.findIndex((x) => x > 4), xs.findIndex(() => false));
console.log([].some(() => true), [].every(() => false), xs.find((x, i, a) => a.length === 10 && i === 3));
console.log(xs.indexOf(4), xs.indexOf(42), xs.indexOf(4, 4), xs.indexOf(9, -2), xs.indexOf(1, -20), xs.indexOf(3, 100));
console.log(xs.includes(10), [NaN].includes(NaN), [NaN].indexOf(NaN), ["a", "b"].indexOf("b"), [0].includes(-0), ["x"].includes(1));
const nested = [1, [2, 3]];
console.log([1, 2].concat([3, 4], 5, [[6]]), [].concat(), nested.concat(nested).length, xs.concat().length);
const nums = [10, 9, 1, 100, 25, 3];
console.log(nums.slice().sort(), nums.slice().sort((a, b) => a - b), nums.slice().sort((a, b) => b - a), nums);
console.log(["b", "a", "c"].sort(), [3, 1, 2].reverse(), [].sort(), [1].reverse(), [undefined, 3, undefined, 1].sort());
const people = [
  { name: "Ann", age: 30 },
  { name: "Bob", age: 25 },
  { name: "Cy", age: 30 },
  { name: "Di", age: 25 },
  { name: "Ed", age: 41 },
];
people.sort((p, q) => p.age - q.age);
console.log(people.map((p) => p.name).join(","));
console.log([true, false, true].sort(), [5, 1, 4].sort((a, b) => (a < b ? 1 : -1)), [[2, 1], [1, 2]].sort());
const big = [];
let seed = 7;
for (let i = 0; i < 200; i++) {
  seed = (seed * 31 + 11) % 1000;
  big.push(seed);
}
const sorted = big.slice().sort((a, b) => a - b);
let ordered = true;
for (let i = 1; i < sorted.length; i++) if (sorted[i - 1] > sorted[i]) ordered = false;
console.log(ordered, sorted[0], sorted[199], sorted.length);
const s = "Hello, World";
console.log(s.charCodeAt(0), s.charCodeAt(), s.charCodeAt(99), s.charCodeAt(-1), s.indexOf("World"), s.indexOf("x"), s.indexOf("l", 4));
console.log(s.indexOf(""), s.indexOf("", 99), s.includes("lo, "), s.includes("lo, ", 5), "aaa".indexOf("aa", 1));
console.log("a,b,,c".split(","), "abc".split(""), "".split(","), "".split(""), "a, b, c".split(", "), "abc".split("abc"));
console.log("the quick brown fox".split(" ").map((w) => w.length));
