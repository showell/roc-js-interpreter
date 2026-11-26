// A class's fields read and written in line at the places its constructor
// gives them (x86/roc/FieldSlots.roc), and each near miss, which takes the
// runtime's way: a field added after construction, fields a constructor
// sets in another order on another way, a plain object with the same keys,
// a subclass whose fields come after its parent's, an index key that moves
// the entries, a key made as the program runs, and receivers that are no
// instance. The subset has no `delete`, so no field is ever taken away.

class Point {
  constructor(x, y) {
    this.x = x;
    this.y = y;
  }

  moved(dx) {
    this.x += dx;
    this.y = this.y * 2;
    return this.x + this.y;
  }
}

class Point3 extends Point {
  constructor(x, y, z) {
    super(x, y);
    this.z = z;
  }

  sum() {
    return this.x + this.y + this.z;
  }
}

// One way sets `a` first, the other `b`: the second's places differ.
class Either {
  constructor(flip) {
    if (flip) {
      this.b = 2;
      this.a = 1;
    } else {
      this.a = 1;
      this.b = 2;
    }
  }
}

function show(o) {
  return o.x + "," + o.y + "," + o.z;
}

const p = new Point(1, 2);
console.log(p.moved(3), p.x, p.y);
p.later = 7;
p.x = 10;
console.log(p.x, p.later, show(p));

const q = new Point3(1, 2, 3);
console.log(q.sum(), q.moved(1), q.z, show(q));
q.z = 30;
console.log(q.z, q.sum());

const plain = { x: 5, y: 6 };
plain.x = plain.x + 1;
console.log(show(plain), plain.x, plain.y);

const reversed = { y: 8, x: 9 };
reversed.x = reversed.x + 1;
console.log(show(reversed));

const marked = { a: 1, b: 2, c: 3, x: 4 };
marked.x = 40;
console.log(marked.x, show(marked));

const made = {};
made["x" + ""] = 11;
made.y = 12;
made.x = made.x + 1;
console.log(show(made));

const one = new Either(false);
const two = new Either(true);
one.a = one.a + 10;
two.a = two.a + 20;
two.b = two.b + 30;
console.log(one.a, one.b, two.a, two.b);

const indexed = new Point(3, 4);
indexed[0] = "zero";
indexed.x = indexed.x + 1;
console.log(indexed.x, indexed.y, indexed[0]);

const values = [p, q, plain, made, marked, one];
let total = "";
for (const v of values) total = total + v.x + ";";
console.log(total);
