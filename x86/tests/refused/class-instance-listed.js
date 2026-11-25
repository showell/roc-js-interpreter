// stops: x86: a class's instance listed or spread is not compiled yet
class Point {
  constructor(x) {
    this.x = x;
  }
}
console.log(Object.keys(new Point(1)));
