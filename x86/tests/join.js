// Array join: the separators, the items that give the empty text, numbers,
// booleans, objects, nested and empty arrays, one item, and joins long
// enough that copying the text so far for each item would fill the heap.
const xs = [1, 2, 3];
console.log(xs.join(), xs.join(""), xs.join(", "), xs.join("--"), [].join(), [].join("-"));
console.log(["solo"].join(), [7].join("-"), [undefined].join(), [null].join("+"), [""].join("x"));
console.log([undefined, null, undefined].join(), [null, "a", undefined, "b", null].join("|"));
console.log([0, -0, 42, -7, 1000000, -9007199254740992].join(" "));
console.log([true, false, "t", {}, [], [[]]].join(";"));
console.log([1, [2, [3, [4, null, undefined]]], [], 5].join("/"), [[], [], []].join(), [[1, 2], [3]].join("+"));
console.log([new Error("e"), new TypeError("t")].join(" & "));
const strings = ["alpha", "beta", "", "gamma"];
console.log(strings.join(), strings.join(""), strings.join("..."), strings.join().length);
// A long join, its length and a few slices.
const parts = [];
for (let i = 0; i < 20000; i++) {
  parts.push(String(1000000 + i));
}
const long = parts.join();
console.log(long.length, long.slice(0, 23), long.slice(-23), long.slice(70000, 70015));
const glued = parts.join("");
console.log(glued.length, glued.slice(0, 14), glued.slice(-14), glued === parts.join(""));
// Ten times as many: a join of 200,000 items.
const many = [];
for (let i = 0; i < 200000; i++) {
  many.push(i % 10);
}
const joined = many.join();
console.log(joined.length, joined.slice(0, 19), joined.slice(-19), [many, many].join("|").length);
