// verify.js N: F(N) by BigInt, as the race prints it: digit count, first
// and last 20 digits, and F(1000)'s last 12.
const n = Number(process.argv[2]);
const fib = (m) => { let a = 0n, b = 1n; for (let i = 0; i < m; i++) [a, b] = [b, a + b]; return a; };
const s = fib(n).toString();
const t = fib(1000).toString();
console.log("F(1000) ends " + t.slice(-12));
console.log("reached F(" + n + "): " + s.length + " digits");
console.log("first digits " + s.slice(0, 20) + ", last digits " + s.slice(-20));
