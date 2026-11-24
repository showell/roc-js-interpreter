// Strings: literals, `+` with strings and numbers, templates, `.length`,
// `===` and the orderings, and console.log of strings.
const greeting = "Hello";
const name = "Roc";
console.log(greeting + ", " + name + "!");
console.log("a" + 1 + 2, 1 + 2 + "a", "n" + -0, "x" + true + null + undefined);
console.log(`${greeting} has ${greeting.length} letters, ${1 + 1} ${null} ${undefined} ${false}`);
console.log(`nested ${`inner ${3 * 4}`} done`, `multi
line`);
let s = "";
for (let i = 0; i < 5; i++) {
  s += i + ",";
}
console.log(s, s.length, s === "0,1,2,3,4,", s !== "0,1,2,3,4,");
console.log("abc" === "abc", "abc" === "abd", "ab" === "abc", "" === "", "1" === 1);
console.log("apple" < "banana", "b" > "a", "abc" < "ab", "Z" < "a", "ab" <= "ab", "b" >= "c");
console.log("", "empty first", "", 7);
let t = "x";
if (t) console.log("a non-empty string is truthy");
if (!"") console.log("the empty string is falsy");
console.log(!t, !!t, !null, !undefined);
function shout(text) {
  return text + "!";
}
console.log(shout("hey"), shout(shout("hi")), shout(3));
function pick(n) {
  if (n > 1) return "big";
  return n;
}
console.log(pick(5), pick(0), pick(1) === 1, pick(2) === "big");
let mixed = 1;
for (let i = 0; i < 3; i++) {
  mixed = mixed + "+";
}
console.log(mixed, mixed.length);
