// stops: x86: a call of a value that is not a function, which throws in node, is not compiled yet
const o = { f: 1 };
console.log("before");
o.f();
