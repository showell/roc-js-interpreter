// Arrays whose items change kind every way: each store lowers the array's
// element kind (Int32, then Numbers, then Values; x86/roc/Heap.roc) when the
// item doesn't fit it, and the heap walk, at the exit and after every
// collection under the torture tier, holds each array's items to its kind.
// A fraction is printed four times over, since console.log of one isn't
// compiled.

// Literals: whole numbers, then a fraction, then a string, each written in
// line into an array the compiler knows.
const whole = [1, 2, 3];
whole[0] = 0.5;
console.log(whole[0] * 4, whole.length);
whole[1] = "two";
whole[0] = 1;
console.log(whole);

const empty = [];
console.log(empty, empty.length);

const fractions = [1.5, 2, 3];
const strings = ["a", 1];
const truths = [true, false];
const holes = [undefined, null];
console.log(fractions[0] * 4, strings, truths, holes);

// The edges of 32 bits, -0, NaN and the infinities, pushed.
const edges = [];
edges.push(2147483647);
edges.push(-2147483648);
console.log(edges);
const past = [0];
past.push(2147483648);
console.log(past);
const below = [0];
below.push(-2147483649);
console.log(below);
const zero = [1];
zero.push(-0);
console.log(zero, 1 / zero[1]);
const odd = [1];
odd.push(NaN);
odd.push(Infinity);
odd.push(-Infinity);
console.log(odd);
const pushed = [1, 2];
pushed.push("three");
pushed.push(undefined);
console.log(pushed);

// Arrays held in an object, so each store's item and array are values
// whose kinds are found as the program runs.
const held = { counts: [0, 0, 0], scores: [0, 0], names: [1] };
for (let i = 0; i < 3; i++) held.counts[i] = held.counts[i] + i * 2;
held.scores[0] = 0.25;
held.scores[1] = held.scores[0] * 8;
held.names[0] = "first";
console.log(held.counts, held.scores[0] * 4, held.scores[1], held.names);
const pick = [0, 1, 2];
const items = [7, -0, "x"];
for (let i = 0; i < 3; i++) {
  const slot = held.counts;
  slot[pick[i]] = items[i];
}
console.log(held.counts);

// Whole numbers stored as whole numbers keep an array Int32; a halving
// makes it Numbers.
const table = [];
for (let i = 0; i < 8; i++) table.push(0);
for (let i = 0; i < 8; i++) table[i] = i * i - 10;
console.log(table);
for (let i = 0; i < 8; i++) table[i] = table[i] / 2;
let total = 0;
for (let i = 0; i < 8; i++) total = total + table[i] * 4;
console.log(total);

// An append by an index one past the end.
const grown = [1];
grown[1] = 2.5;
grown[2] = "c";
console.log(grown[1] * 4, grown[2], grown.length);

// splice puts items in; sort and reverse only move them.
const spliced = [1, 2, 3, 4];
const removed = spliced.splice(1, 2, 4.5, "t", 6);
console.log(spliced[1] * 4, spliced[2], spliced.length, removed);
const whole_splice = [1, 2, 3];
whole_splice.splice(0, 1, 9, 8);
console.log(whole_splice);
const sorted = [3, 1, 2, 0.5];
sorted.sort((a, b) => a - b);
sorted.reverse();
console.log(sorted[0], sorted[3] * 4);
const texts_sorted = [3, 1, "2"];
texts_sorted.sort();
console.log(texts_sorted);

// Spreads append each item, and a concat its items or itself.
const spread = [...whole, ...[4, 5], 6.5];
const joined = [1, 2].concat([3, "four"], 5);
console.log(spread[5] * 4, spread.length, joined);

// The arrays routines make hold any values; stores into them keep that.
const mapped = [1, 2, 3].map((x) => x * 2);
mapped[0] = 0.5;
const kept = [1, 2, 3, 4].filter((x) => x % 2 === 0);
kept.push(-0);
console.log(mapped[0] * 4, mapped[1], kept);
const letters = "abc".split("");
letters[0] = 1;
console.log(letters);
