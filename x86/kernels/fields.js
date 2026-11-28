// fields.js: two fields of one object read and written N times. Property
// access on a class's instance (FieldSlots). fields.roc is its twin, a
// record.
const N = 20000000;

class Point {
  constructor(x, y) {
    this.x = x;
    this.y = y;
  }
}

function main() {
  const p = new Point(0, 0);
  for (let i = 0; i < N; i++) {
    p.x = p.x + (i % 7);
    p.y = p.y + (p.x % 5);
  }
  console.log(p.x + p.y);
}

main();
