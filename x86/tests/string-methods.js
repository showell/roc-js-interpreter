// The string methods of StringMethods' table on strings known before the
// program runs, each with its edge cases, held to node.
const show = (s) => `[${s}]`;

console.log(show("  pad  ".trim()), show("  pad  ".trimStart()), show("  pad  ".trimEnd()));
console.log(show("".trim()), show("   ".trim()), show(" \t\n\r ".trimStart()), show("\t\n x \r\n".trimEnd()));
console.log(show("none".trim()), show("a b".trim()), show("\tx".trim()), show("x\n".trim()));

console.log("Hello, World 42!".toUpperCase(), "Hello, World 42!".toLowerCase());
console.log(show("".toUpperCase()), show("".toLowerCase()), "@[`{az AZ}".toUpperCase(), "@[`{az AZ}".toLowerCase());

const s = "Hello, World";
console.log(s.substring(5, 0), s.substring(7), s.substring(), s.substring(3, 3), s.substring(-4, 2));
console.log(s.substring(2, 100), s.substring(100), s.substring(NaN, 4), s.substring(4, NaN), s.substring(0, Infinity));
console.log(s.substring(2.7, 5.2), show("".substring(0, 1)), s.substring(undefined, 5));

console.log("ab".repeat(3), show("ab".repeat(0)), show("".repeat(5)), "-".repeat(10), show("x".repeat()));

console.log("7".padStart(3, "0"), "x".padEnd(4, "-.") + "|", show("abc".padStart(2)), show("abc".padEnd(3, "z")));
console.log(show("abc".padStart(6)), show("abc".padEnd(6)), show("abc".padStart(8, "12")), show("abc".padEnd(8, "12")));
console.log(show("abc".padStart(6, "")), show("".padEnd(3, "ab")), show("abc".padEnd(-1)), show("abc".padStart()));
console.log(`${"headline:".padEnd(12)}rest`);

console.log(s.startsWith("Hell"), s.startsWith("hell"), s.startsWith(""), s.startsWith(s), s.startsWith(s + "!"));
console.log(s.endsWith("ld"), s.endsWith("Wor"), s.endsWith(""), s.endsWith(s), s.endsWith("!" + s), "".endsWith(""));

const t = "the cat and the hat";
console.log(t.replace("the", "a"), t.replaceAll("the", "a"), t.replace("dog", "x"), t.replaceAll("dog", "x"));
console.log("a-b-c".replaceAll("-", ""), "aaa".replace("a", "b"), "x".replaceAll("x", "xx"), "aaaa".replaceAll("aa", "b"));
console.log(show("abc".replace("", "-")), show("".replace("", "-")), show("abc".replace("abc", "")), "abc".replaceAll("c", "[c]"));

console.log("a".concat("b", 1), "x".concat(), "n".concat(null, undefined, true, [1, 2]));
console.log("a,b".split(), "a,b,,c".split(","), "abc".split(""), "".split(","), "".split(""));
console.log(show("abc".charAt()), "abc".charCodeAt(), "abc".charAt(2), "abc".charCodeAt(5));
