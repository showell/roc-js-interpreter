// A method call's near misses: each must call what node calls, whether the
// compiled call reads the class's table in line and calls the method
// directly, or takes the runtime's way.

class Account {
  constructor(name, balance) {
    this.name = name;
    this.balance = balance;
  }

  deposit(amount) {
    this.balance += amount;
    return this.balance;
  }

  describe() {
    return "an account";
  }

  pair(a, b) {
    return [a, b];
  }
}

class Savings extends Account {
  constructor(name, balance, rate) {
    super(name, balance);
    this.rate = rate;
  }

  // An override: a Savings takes its own deposit, never Account's.
  deposit(amount) {
    return super.deposit(amount * 2);
  }
}

// A subclass that keeps its parent's methods.
class Checking extends Account {}

const a = new Account("a", 10);
const s = new Savings("s", 100, 3);
const c = new Checking("c", 1000);
let total = 0;
for (let i = 0; i < 3; i++) {
  total += a.deposit(1) + s.deposit(1) + c.deposit(1);
}
console.log(total, a.balance, s.balance, c.balance);
console.log(a.describe(), s.describe(), c.describe());

// A plain object with a function of the same name.
const plain = { deposit: (amount) => amount * 100, describe: () => "plain" };
console.log(plain.deposit(5), plain.describe());

// A receiver whose kind is not known: each of them in turn.
const receivers = [a, s, c, plain];
for (const r of receivers) console.log(r.deposit(1), r.describe());

// Fewer and more arguments than the method's parameters.
console.log(a.pair(1), a.pair(1, 2, 3), a.pair());

// A method taken out and called through a value: `this` is undefined.
const describe = a.describe;
console.log(describe());
const pair = s.pair;
console.log(pair("x", "y"));

// A class declared each time a function runs: each table's method closes
// over that run's own variable.
function counterClass(step) {
  class Counter {
    constructor() {
      this.n = 0;
    }
    bump() {
      this.n += step;
      return this.n;
    }
  }
  return new Counter();
}
const byOne = counterClass(1);
const byTen = counterClass(10);
byOne.bump();
byTen.bump();
console.log(byOne.bump(), byTen.bump());

// A method overwritten on one instance: that instance's own property wins,
// for it alone.
a.deposit = (amount) => "overwritten " + amount;
console.log(a.deposit(7), s.deposit(7), c.deposit(7));
for (const r of receivers) console.log(r.deposit(2));
console.log(byOne.bump(), a.describe());
