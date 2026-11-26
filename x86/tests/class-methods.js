// A class's methods, shared by its instances and called with the receiver
// first, and the near misses of a direct call: a method read as a value and
// called (its `this` undefined, so node's TypeError), a method replaced on
// one instance, a receiver that is sometimes another class, a method
// passed as a callback, `this` in an arrow inside a method, inherited and
// overridden methods, and `super`.
class Counter {
  constructor(start) {
    this.count = start;
  }

  add(n) {
    this.count = this.count + n;
    return this.count;
  }

  addAll(list) {
    list.forEach((n) => this.add(n));
    return this.count;
  }

  name() {
    return "counter";
  }
}

class Tally extends Counter {
  constructor(start, step) {
    super(start);
    this.step = step;
  }

  add(n) {
    return super.add(n * this.step);
  }

  name() {
    return "tally of " + super.name();
  }
}

const a = new Counter(1);
const b = new Counter(10);
console.log(a.add(2), b.add(3), a.add(4), b.count);
console.log(a.addAll([1, 2, 3]), a.name());

// Replaced on one instance only: the others keep the class's.
b.add = (n) => "replaced " + n;
console.log(b.add(5), a.add(5), new Counter(0).add(1));

// The receiver is a Counter, then a Tally, at the same call.
const t = new Tally(0, 10);
let names = "";
for (const who of [a, t, new Counter(3), new Tally(1, 2)]) {
  names = names + who.name() + ":" + who.add(1) + " ";
}
console.log(names);
console.log(t.addAll([1, 2]), t.count);

// A method read as a value is the class's one function.
const plain = new Counter(0);
console.log(plain.add === new Counter(5).add, plain.add === t.add);

// Called as a value, its `this` is undefined, as in node.
const loose = plain.add;
try {
  loose(1);
} catch (err) {
  console.log(err.name, err.message);
}

// Passed as a callback, the same.
try {
  [1, 2].map(plain.add);
} catch (err) {
  console.log(err.name, err.message);
}

// Copied onto a plain object, it takes that object as its receiver.
const holder = { count: 100, add: plain.add };
console.log(holder.add(1), holder.count, plain.count);
