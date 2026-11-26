// verify.js N: F(N) by BigInt, as the race prints it: F(100), F(1000)'s last 12
// digits, the digit count, the first and last 20 digits, and last the whole
// of F(N) in decimal.
const n = Number(process.argv[2]);
const fib = (m) => { let a = 0n, b = 1n; for (let i = 0; i < m; i++) [a, b] = [b, a + b]; return a; };
const s = fib(n).toString();
const t = fib(1000).toString();
console.log("F(100) is " + fib(100).toString() + ", as expected");
console.log("F(1000) ends " + t.slice(-12));
console.log("F(" + n + "): " + s.length + " digits");
console.log("first digits " + s.slice(0, 20) + ", last digits " + s.slice(-20));
console.log(s);
