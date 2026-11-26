// The string methods called on values whose kind isn't known before the
// program runs: the string's own routine when the value is a string, and the
// value's own property of that name when it is an object or an instance.
const fields = "  ada ;lovelace; 1815 ;;".split(";").map((field) => field.trim());
console.log(fields);

const shout = (x) => x.toUpperCase();
const mine = { toUpperCase: () => "an object's own", trim: () => "trimmed mine" };
console.log(shout("quiet"), shout(mine), shout("Mixed Case 9"));

class Loud {
  constructor(n) {
    this.n = n;
  }
  toUpperCase() {
    return `class ${this.n}`;
  }
  padEnd(width, fill) {
    return `${this.n} to ${width} with ${fill}`;
  }
}
console.log(shout(new Loud(3)), shout("z"));

const items = ["  a b  ", mine, "\tx\n", new Loud(4)];
for (const item of items) {
  const trimmed = typeof item === "string" ? item.trim() : item.n === undefined ? item.trim() : item.padEnd(9, ".");
  console.log(`[${trimmed}]`);
}

const all = [" x ", "AbC", "hello world", "aaa", "7", "Hello"];
for (const v of all) {
  console.log(
    `[${v.trim()}]`,
    `[${v.trimStart()}]`,
    `[${v.trimEnd()}]`,
    v.toUpperCase(),
    v.toLowerCase(),
    v.substring(1, 3),
    v.repeat(2),
    `[${v.padStart(5, "*")}]`,
    `[${v.padEnd(5)}]`,
    v.startsWith("a"),
    v.endsWith("o"),
    v.replace("a", "#"),
    v.replaceAll("a", "#"),
    v.split("l"),
    v.charAt(1),
    v.charCodeAt(0),
  );
}

// A method's name a class has, called on a string that meets an instance.
const pick = (i) => (i % 2 === 0 ? "pad" : new Loud(i));
for (let i = 0; i < 4; i++) console.log(`[${pick(i).padEnd(6, "-")}]`);

// The words of a newsletter, as the big-daddy race takes them apart.
const words = "Hello, World. The city; writes in!".split(" ");
const counts = new Map();
for (const raw of words) {
  let word = raw.toLowerCase();
  for (const mark of [",", ".", ";", "!"]) word = word.replaceAll(mark, "");
  counts.set(word, (counts.get(word) || 0) + 1);
}
console.log(counts);
