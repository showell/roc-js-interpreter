// A method's name is looked up in the class's table first until some
// instance is given an own property of that name. Here the only shadowing
// is through a computed key, set after the method has been called through
// the table, and every read after it must find the instance's own.
class Greeter {
  constructor(name) {
    this.name = name;
  }

  greet() {
    return "hello " + this.name;
  }
}

const a = new Greeter("ada");
const b = new Greeter("bob");
console.log(a.greet(), b.greet());

const key = "gre" + "et";
b[key] = () => "own greet";
console.log(a.greet(), b.greet(), b[key](), a[key]());

// A new instance after the shadowing still reads its class's method.
console.log(new Greeter("cy").greet());
