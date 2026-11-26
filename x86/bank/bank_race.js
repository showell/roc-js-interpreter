// bank_race.js: how many transfers can a bank ledger make in BUDGET_MS?
//
// The bank has COUNT accounts, each an Account (a class: a name, a balance
// in whole cents and three counters, with deposit and withdraw methods),
// kept in a plain object used as a dictionary, keyed by the account's name
// ("acct-217"). The names are made once, at the start, and kept in an array
// too, so the transfers make no new strings or objects: the compiled
// program has no garbage collector, so a step that allocated would fill
// its heap.
//
// A transfer draws three numbers from a seeded pseudo-random generator, a
// Random (a class too), the Park-Miller one (seed * 48271 mod 2^31 - 1,
// every product below 2^47, so exact in a double): the payer, the payee and the amount. It looks both
// accounts up by name in the dictionary, and when the payer has the funds,
// moves the money; otherwise the payer's withdraw counts a decline. Every
// AUDIT_EVERY transfers, an audit walks Object.keys of the dictionary and
// sums the balances: money only moves, so the total must be the opening
// total, and an audit that finds another counts as unbalanced.
//
// The race is timed as the fib race is (x86/race/fib_race.js): the program
// reads its own clock between batches and sizes each batch from the time a
// transfer has cost so far, planning each to use at most a share of the
// time left, and stops when that share is too small to plan in. Before the
// clock starts, WARMUP transfers run untimed (none when WARMUP is 0), so
// node's compiler has warmed up before it is timed. The first CHECK_AT
// transfers are always run first, warm-up or not, and the checksum of every
// account after them is held to CHECKSUM_AT, computed offline with node
// (x86/bank/verify.js): a mismatch is a FAIL whatever the time. So is an
// unbalanced audit, and a last clock reading past BUDGET_MS. After the
// PASS or FAIL line, the program prints how many transfers it reached and
// the checksum of every account then, which verify.js reproduces.
//
// The arithmetic is whole numbers: cents, counts, and the checksum kept
// below a prime. Only the batch planning uses fractions, and none is
// printed.

const BUDGET_MS = 20000;
const WARMUP = 2000000; // untimed transfers before the clock starts; 0 or at least CHECK_AT
const COUNT = 500; // accounts
const SEED = 20261126;
const MULTIPLIER = 48271;
const MODULUS = 2147483647; // 2^31 - 1
const MAX_AMOUNT = 50000; // cents: a transfer is 1 to 50000 of them
const AUDIT_EVERY = 10000;
const CHECK_AT = 100000;
const CHECKSUM_AT = 401234543; // computed offline: node x86/bank/verify.js 100000
const PRIME = 1000000007;
const SHARE = 0.5; // a batch may plan to use this share of the time left
const LAST_MS = 25; // stop when a share of the time left is less than this
const GROWTH = 4; // a batch is at most this many times the last one

class Account {
  constructor(name, balance) {
    this.name = name;
    this.balance = balance;
    this.deposits = 0;
    this.withdrawals = 0;
    this.declined = 0;
  }

  deposit(amount) {
    this.balance += amount;
    this.deposits += 1;
  }

  // Whether the money left: false, and a decline counted, when the balance
  // is short.
  withdraw(amount) {
    if (amount > this.balance) {
      this.declined += 1;
      return false;
    }
    this.balance -= amount;
    this.withdrawals += 1;
    return true;
  }
}

// The generator keeps its seed in itself, so no function's result is
// passed back to it as its argument: js-x86 doesn't yet settle the kinds of
// a function whose result reaches its own parameter (t(t(1)) is refused).
class Random {
  constructor(seed) {
    this.seed = seed;
  }

  next() {
    this.seed = (this.seed * MULTIPLIER) % MODULUS;
    return this.seed;
  }
}

// An account's opening balance, in cents: 100.00 to 999.99 dollars.
function opening(i) {
  return 10000 + (i * 7919) % 90000;
}

// The sum of every balance, walking the dictionary's own keys.
function audit(accounts) {
  let total = 0;
  for (const name of Object.keys(accounts)) total += accounts[name].balance;
  return total;
}

// Every account's balance and counters, in the names' order, folded below
// PRIME.
function checksum(accounts, names) {
  let h = 0;
  for (const name of names) {
    const account = accounts[name];
    h = (h * 31 + account.balance) % PRIME;
    h = (h * 31 + account.deposits) % PRIME;
    h = (h * 31 + account.withdrawals) % PRIME;
    h = (h * 31 + account.declined) % PRIME;
  }
  return h;
}

// The transfers numbered from + 1 to `to`, drawn from `random`. An audit
// follows every AUDIT_EVERY-th transfer.
function transfers(accounts, names, ledger, random, from, to) {
  let step = from;
  while (step < to) {
    const payer = accounts[names[random.next() % COUNT]];
    const payee = accounts[names[random.next() % COUNT]];
    const amount = random.next() % MAX_AMOUNT + 1;
    if (payer !== payee && payer.withdraw(amount)) payee.deposit(amount);
    step = step + 1;
    if (step % AUDIT_EVERY === 0) {
      ledger.audits += 1;
      if (audit(accounts) !== ledger.total) ledger.unbalanced += 1;
    }
  }
}

// The race, all in one function, so that its state is the function's own
// variables (x86/race/fib_race.js's header says why).
function race() {
  const names = [];
  const accounts = {};
  let i = 0;
  while (i < COUNT) {
    const name = "acct-" + i;
    names.push(name);
    accounts[name] = new Account(name, opening(i));
    i = i + 1;
  }
  const ledger = { total: audit(accounts), audits: 0, unbalanced: 0 };

  const opened = Date.now();
  const random = new Random(SEED);
  transfers(accounts, names, ledger, random, 0, CHECK_AT);
  const early = checksum(accounts, names);
  let step = CHECK_AT;
  if (WARMUP > CHECK_AT) {
    transfers(accounts, names, ledger, random, CHECK_AT, WARMUP);
    step = WARMUP;
  }
  // With a warm-up the clock starts after it; without one, the first
  // CHECK_AT transfers were the first batch.
  const start = WARMUP > 0 ? Date.now() : opened;
  let elapsed = Date.now() - start;
  let batches = WARMUP > 0 ? 0 : 1;
  let lastBatch = step;
  let perTransfer = Math.max(Date.now() - opened, 1) / step;

  while (true) {
    const left = BUDGET_MS - elapsed;
    const plan = SHARE * left;
    if (plan < LAST_MS) break;
    let k = Math.floor(plan / perTransfer);
    if (k > GROWTH * lastBatch) k = GROWTH * lastBatch;
    if (k < 1) break;
    const before = Date.now();
    transfers(accounts, names, ledger, random, step, step + k);
    step = step + k;
    const after = Date.now();
    elapsed = after - start;
    batches = batches + 1;
    lastBatch = k;
    const took = after - before;
    if (took > 0) perTransfer = took / k;
  }

  const right = early === CHECKSUM_AT && ledger.unbalanced === 0;
  console.log(early === CHECKSUM_AT ? "checksum after " + CHECK_AT + " transfers " + early + ", as expected" : "checksum after " + CHECK_AT + " transfers " + early + ", not " + CHECKSUM_AT);
  console.log("audits " + ledger.audits + ", unbalanced " + ledger.unbalanced);
  console.log("batches " + batches + ", elapsed " + elapsed + " ms of " + BUDGET_MS + ", warm-up " + WARMUP + " transfers, timed " + (step - Math.max(WARMUP, 0)) + " transfers");
  console.log(elapsed <= BUDGET_MS && right ? "PASS" : "FAIL");
  console.log("reached " + step + " transfers, final checksum " + checksum(accounts, names));
}

race();
