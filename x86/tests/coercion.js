// `+` makes undefined, null and the booleans numbers; objects order their
// index keys first; strings are quoted by node's rule inside an array.
console.log(true + 1, 1 + false, null + 1, undefined + 1, true + true, null + null, 2 + undefined);
function either(n) {
  return n > 1 ? true : null;
}
console.log(either(2) + 1, 1 + either(0), either(0) + either(2));

const byNumber = {};
byNumber[10] = "ten";
byNumber[2] = "two";
byNumber.name = "numbers";
byNumber["1"] = "one";
byNumber["01"] = "zero one";
byNumber[0] = "zero";
console.log(byNumber, Object.keys(byNumber));
console.log({ z: 0, 2: "two", ...{ 1: "one", y: 9 } }, { ...[10, 20] }, { ..."hi" });

console.log(["plain", "it's", 'say "hi"', `both ' and "`, "tab\there", "bell\x07", "del\x7f", "esc\x1b["]);
console.log(["all ' \" `", "a ' \" ${", "back`tick"], { "key-with-dash": 1, $dollar: 3, "": 6 });

const s = "Hello, World";
console.log(s.slice(7), s.slice(-5, -1), s.slice(3, 1), s.slice(), "abc".slice(-10));
console.log(s.lastIndexOf("o"), s.lastIndexOf("World"), s.lastIndexOf("x"), "aaa".lastIndexOf("a"), "".lastIndexOf(""));
const a = [5, 1, 4, 1, 5, 9];
console.log(a.lastIndexOf(5), a.lastIndexOf(1), a.lastIndexOf(8), [NaN].lastIndexOf(NaN));
console.log(String.fromCharCode(72, 105), String.fromCharCode(), String.fromCharCode(65.9, 97 + 65536));

const q = ["a", "b", "c", "d", "e"];
console.log(q.splice(1, 2), q);
console.log(q.splice(1, 0, "x", "y"), q);
console.log(q.splice(-2), q);
console.log(q.splice(), q.splice(0, 1, "z"), q);
console.log(q.splice(1, 100), q, q.splice(5, 1, "end"), q);

const user = { name: "ann", address: { city: "paris" }, tags: ["x"], greet() { return "hi"; } };
const nobody = null;
console.log(user?.name, user.address?.city, user.phone?.number, nobody?.name);
console.log(user?.["name"], nobody?.["name"], user.tags?.[0], user.tags?.[5]);
console.log(user.greet?.(), user.missing?.(), nobody?.greet(), user?.greet());
console.log(nobody?.a.b.c.d, user.phone?.a.b.c, (nobody?.a) ?? "fallback");

const cases = [
  () => {
    const o = null;
    return o.x;
  },
  () => {
    const o = undefined;
    return o.x.y;
  },
  () => {
    const o = null;
    o.x = 1;
  },
  () => {
    let o;
    o[3] = 1;
  },
  () => {
    const o = [null];
    return o[0].length;
  },
  () => {
    const o = {};
    return o.p["q"];
  },
];
for (const c of cases) {
  try {
    c();
    console.log("no error");
  } catch (e) {
    console.log(`${e.name} | ${e.message}`);
  }
}

// A constant assigned or stepped, and a variable used before its
// declaration has run on every way there, throw as node throws.
const thrown = [
  () => {
    const c = 1;
    c = 2;
  },
  () => {
    const c = 1;
    c++;
  },
  () => {
    const c = 1;
    c += 1;
  },
  (kind) => {
    switch (kind) {
      case "x":
        let label = "ex";
        return label;
      default:
        label = "why";
        return label;
    }
  },
  () => {
    let q = q + 1;
  },
];
for (const c of thrown) {
  try {
    c("y");
    console.log("no error");
  } catch (e) {
    console.log(e.name, e.message);
  }
}
console.log({ text: "first line\nsecond line\nthird line, which is long enough to make the whole thing wrap around" });
console.log([["short\nbreak", "a longer string\nwith a break in it that runs past the line's own width of eighty"]]);
