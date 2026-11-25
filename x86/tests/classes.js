// Classes: instances, methods through `this`, inheritance and `super`,
// static methods, instanceof, and what console.log and String make of them.
class Point {
  constructor(x, y) {
    this.x = x;
    this.y = y;
  }
  plus(other) {
    return new Point(this.x + other.x, this.y + other.y);
  }
  toText() {
    return `(${this.x}, ${this.y})`;
  }
  static origin() {
    return new Point(0, 0);
  }
}
class Named extends Point {
  constructor(name, x, y) {
    super(x, y);
    this.name = name;
  }
  toText() {
    return `${this.name}${super.toText()}`;
  }
}
const p = new Point(1, 2);
const n = new Named("n", 3, 4);
console.log(p.toText(), n.toText(), n.plus(p).toText(), Point.origin().toText(), Named.origin().x);
console.log(p instanceof Point, p instanceof Named, n instanceof Point, n instanceof Named);
console.log({} instanceof Point, 3 instanceof Point, "s" instanceof Point, null instanceof Point);
console.log(typeof Point, typeof p, String(p), `${n}`, p === p, p === new Point(1, 2));
console.log(Point, Named, [Point], { c: Named });
p.z = [p.x, p.y];
console.log(p.z, p.missing, p["x"]);
