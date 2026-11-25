// Arrays of more than six items, which node lays out in columns when they
// are alike in length: numbers padded on the left, anything else on the right.
const xs = [];
for (let i = 0; i < 10; i++) xs.push(i * 3);
console.log(xs);
const squares = [];
for (let i = 0; i < 100; i++) squares.push(i * i);
console.log(squares);
console.log([1, 2, 3, 4, 5, 6, 7]);
console.log([1, 2, 3, 4, 5, 6]);
console.log([-1, 20, -300, 4000, -5, 60, -7, 800]);
console.log(["apple", "banana", "cherry", "date", "elderberry", "fig", "grape", "honeydew"]);
console.log([1, "two", 3, "four", 5, "six", 7]);
console.log([true, false, true, false, true, false, true, null, undefined]);
console.log(["a", "bb", "ccc", "dddd", "eeeee", "a", "bb", "ccc", "dddd", "eeeee", "a", "bb"]);
console.log(["a very long item that is long", "b", "c", "d", "e", "f", "g"]);
console.log({ nested: [10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110], deeper: { more: [1, 2, 3, 4, 5, 6, 7, 8] } });
console.log([[1, 2], [3, 4], [5, 6], [7, 8], [9, 10], [11, 12], [13, 14]]);
const words = [];
for (let i = 0; i < 26; i++) words.push("word" + i);
console.log(words);
const big = [];
for (let i = 0; i < 40; i++) big.push(i * 7919 % 1000);
console.log(big);
console.log([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27]);
console.log(["x", "y", "z", "x", "y", "z", "x"], [100000, 2, 3, 4, 5, 6, 7]);
