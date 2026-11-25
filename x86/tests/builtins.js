// Math's functions of numbers, String(x), Object.keys, values and entries,
// and arrays and objects made strings.
console.log(Math.floor(3.7), Math.floor(-3.2), Math.ceil(3.2), Math.ceil(-3.7), Math.ceil(-0.5), Math.floor(-0));
console.log(Math.round(2.5), Math.round(-2.5), Math.round(0.49999999999999994), Math.round(-0.4), Math.round(7));
console.log(Math.trunc(-4.7), Math.trunc(-0.2), Math.abs(-5), Math.abs(-0), Math.sign(-3), Math.sign(0), Math.sign(-0), Math.sign(9));
console.log(Math.sqrt(16), Math.sqrt(-1), Math.pow(2, 10), Math.floor(), Math.floor(9007199254740992), Math.round(-4503599627370497));
console.log(Math.max(1, 5, 3), Math.min(4, -2, 8), Math.max(), Math.min(), Math.max(NaN, 1), Math.min(0, -0), Math.max(-0, 0));
console.log(Math.floor(Math.PI), Math.round(Math.E * 100), Math.floor(Math.sqrt(2) * 1000), Math.max(Infinity, 1));
console.log(typeof Math, typeof Math.floor, typeof String, typeof Object, typeof Object.keys);
const xs = [3, -1, 7];
let most = -Infinity;
for (const x of xs) most = Math.max(most, Math.abs(x));
console.log(most);
console.log(String(42), String([1, [2, 3]]), String(null), String(), String({}), String(true), String(undefined));
console.log(String(new Error("plain")), String(new TypeError()), String(new RangeError("r")), `${new Error("t")}`);
console.log("" + [1, 2], [1] + [2], 1 + [2], [] + 1, `${{}}`, `${[1, 2]}|${[]}`, { a: 1 } + "x", null + [3]);
console.log([[1, 2], [3]] + "", [null, undefined, 1] + "", String([{}]));
const o = { a: 1, b: "x", c: [1, 2] };
console.log(Object.keys(o), Object.values(o), Object.entries(o));
console.log(Object.keys({}), Object.entries({ k: { n: 1 } }));
for (const [k, v] of Object.entries({ one: 1, two: 2 })) console.log(k, v);
