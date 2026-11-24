// Parameters with defaults, a rest and patterns, and destructuring.
function greet(name, greeting = "hello", punctuation = greeting === "hello" ? "!" : ".") {
  return `${greeting}, ${name}${punctuation}`;
}
console.log(greet("ann"));
console.log(greet("bob", "bye"));
console.log(greet("cy", undefined, "?"));
function sum(first, ...rest) {
  let total = first;
  for (const n of rest) total += n;
  return total;
}
console.log(sum(1), sum(1, 2, 3, 4));
const tail = (...items) => items.slice(1);
console.log(tail(), tail(1), tail(1, 2, 3));
function area({ width, height = width }) {
  return width * height;
}
console.log(area({ width: 3 }), area({ width: 3, height: 4 }));
function point([x, y] = [0, 0], { scale = 1 } = {}) {
  return [x * scale, y * scale];
}
console.log(point(), point([1, 2]), point([1, 2], { scale: 3 }));
const swap = ([m, n]) => [n, m];
console.log(swap([1, 2]));
const [a, , b, ...more] = [1, 2, 3, 4, 5];
console.log(a, b, more);
const [x = 10, y = 20, z = x + y] = [1];
console.log(x, y, z);
const [h, ...letters] = "hey";
console.log(h, letters);
const { p, q: why = 2 } = { p: 1, r: 3 };
console.log(p, why);
for (const [key, value] of [["a", 1], ["b", 2]]) console.log(key, value);
for (const { id, size = "m" } of [{ id: 1 }, { id: 2, size: "l" }]) console.log(id, size);
const callers = [sum, greet];
console.log(callers[0](5, 6), callers[1]("di"));
for (const c of "hi!") console.log(c);
