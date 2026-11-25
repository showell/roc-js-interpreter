// stops: x86: console.log of a class's instance, which node writes with its class's name, is not compiled yet
class Point {
  constructor(x) {
    this.x = x;
  }
}
console.log(new Point(1).x);
console.log(new Point(1));
