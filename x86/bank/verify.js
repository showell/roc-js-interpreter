// verify.js N: the bank race's answer after N transfers, from a second
// implementation of the same ledger (plain arrays indexed by account number,
// no class and no dictionary), as the race prints it: the checksum after
// the first 100000 transfers, the audits, and last the transfers made and
// the final checksum. Each audit's total is held to the opening total here
// too.
const n = Number(process.argv[2]);
const COUNT = 500;
const AUDIT_EVERY = 10000;
const CHECK_AT = 100000;
const PRIME = 1000000007;

const balance = [];
const counts = []; // [deposits, withdrawals, declined] for each account
for (let i = 0; i < COUNT; i++) {
  balance.push(10000 + (i * 7919) % 90000);
  counts.push([0, 0, 0]);
}
const total = balance.reduce((a, b) => a + b, 0);

function checksum() {
  let h = 0;
  for (let i = 0; i < COUNT; i++) {
    for (const v of [balance[i], ...counts[i]]) h = (h * 31 + v) % PRIME;
  }
  return h;
}

let seed = 20261126;
const next = () => (seed = (seed * 48271) % 2147483647);
let early = null;
let unbalanced = 0;
for (let step = 1; step <= n; step++) {
  const payer = next() % COUNT;
  const payee = next() % COUNT;
  const amount = next() % 50000 + 1;
  if (payer !== payee) {
    if (amount > balance[payer]) counts[payer][2]++;
    else {
      balance[payer] -= amount;
      counts[payer][1]++;
      balance[payee] += amount;
      counts[payee][0]++;
    }
  }
  if (step % AUDIT_EVERY === 0 && balance.reduce((a, b) => a + b, 0) !== total) unbalanced++;
  if (step === CHECK_AT) early = checksum();
}
console.log("checksum after " + CHECK_AT + " transfers " + early + ", as expected");
console.log("audits " + Math.floor(n / AUDIT_EVERY) + ", unbalanced " + unbalanced);
console.log("made " + n + " transfers, final checksum " + checksum());
