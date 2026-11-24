// Arrays and plain objects: literals, index and property reads and writes,
// `.length`, `push` and `pop`, shared references, and console.log's layout
// of them (node's util.inspect): one line when it fits, one item a line
// when it doesn't, `[Array]` and `[Object]` past depth 2, quoted strings.
const xs = [];
for (let i = 0; i < 6; i++) xs.push(i * 3);
console.log(xs, xs.length);
console.log(xs.pop(), xs.length, xs[0], xs[4], xs[99], xs[-1], xs[1.5]);
const ys = [1, 2];
console.log(ys.push(3, 4), ys);
ys[4] = 6;
ys[0] = "first";
console.log(ys, ys[0].length);
const empty = [];
console.log(empty.pop(), empty, [], {});
const o = { a: 1, b: "x", c: true, d: null, e: undefined };
console.log(o);
o.a = o.a + 41;
o.f = [1, 2];
o["g h"] = "spaced";
console.log(o.a, o.f, o.missing, o["b"]);
console.log(o);
const shared = { n: 0 };
const pair = [shared, shared];
shared.n = 7;
console.log(pair, pair[0] === pair[1], pair[0] === { n: 7 });
console.log({ a: { b: { c: { d: 1 } } } });
console.log([[1, [2, [3, [4]]]]]);
console.log({ list: [1, 2, 3], nested: { deep: [{ x: 1 }, { y: [2] }] } });
console.log([{}, [], { a: [] }, [{}]]);
const long = { alpha: "some longer string here", beta: [1, 2, 3], gamma: { delta: "more text to make it long", eps: 12345 } };
console.log(long);
console.log([long, long]);
console.log(["it's", 'say "hi"', "tab\there", "new\nline", "back\\slash"]);
console.log({ "key-with-dash": 1, valid_name: 2, $dollar: 3, _under: 4, "": 6 });
console.log(["a very long string that goes on and on and on, well past the line's width of eighty columns"]);
console.log({ text: "first line\nsecond line" });
const words = ["apple", "pear", "fig"];
const counts = {};
for (let i = 0; i < words.length; i++) {
  const w = words[i];
  if (counts[w] === undefined) counts[w] = 0;
  counts[w] = counts[w] + 1;
}
counts["pear"] = counts["pear"] + 10;
console.log(counts, words.length, "abc"[1], "abc"[5]);
let total = 0;
const grid = [[1, 2], [3, 4], [5, 6]];
for (let r = 0; r < grid.length; r++) {
  for (let c = 0; c < grid[r].length; c++) total = total + grid[r][c];
}
console.log(total, grid);
const big = [];
for (let i = 0; i < 6; i++) big.push({ id: i, name: "item" + i });
console.log(big);
