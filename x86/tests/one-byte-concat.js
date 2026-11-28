// Concatenations of one-byte strings: built a character at a time, from the
// table's strings (x86/roc/RuntimeBuilders.roc's `one_byte_texts`) and from
// literals, and a string and the empty string, which `runtime_concat`
// answers with the string itself.
let s = "";
for (let i = 0; i < 200; i++) s = s + "abcdefghij"[i % 10];
console.log(s.length, s.slice(0, 25), s[199]);

let t = "";
for (const ch of s) t = ch + t;
console.log(t.slice(0, 12), t.length);

const pairs = [];
for (let i = 0; i < 26; i++) pairs.push(String.fromCharCode(97 + i) + String.fromCharCode(65 + i));
console.log(pairs.join(" "));

console.log("" + "x" === "x", "x" + "" === "x", "" + "" === "", ("" + "").length);
let e = "";
for (let i = 0; i < 5; i++) e += "";
console.log(e === "", e.length, `${e}${"z"}${e}`);

let word = "";
for (const ch of "reverse") word = word + ch.toUpperCase();
console.log(word, word.length);

let joined = "";
for (const piece of "a-b-c-d".split("-")) joined += piece + piece;
console.log(joined);

let numbers = "";
for (let i = 0; i < 12; i++) numbers += i;
console.log(numbers, numbers.length);
