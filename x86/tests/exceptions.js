// throw, try, catch and finally, and the errors `new` makes.
function attempt(f) {
  try {
    return `ok ${f()}`;
  } catch (e) {
    return `caught ${typeof e}`;
  }
}
console.log(attempt(() => 1));
console.log(attempt(() => {
  throw 42;
}));
console.log(attempt(() => {
  throw "words";
}));
console.log(attempt(() => {
  throw null;
}));
try {
  throw { code: 7, why: "an object" };
} catch ({ code, why }) {
  console.log(code, why);
}
try {
  throw [1, 2, 3];
} catch (e) {
  console.log(e, e.length);
}
try {
  throw 1;
} catch {
  console.log("caught without a binding");
}
const order = [];
function withFinally(kind) {
  try {
    order.push(`try ${kind}`);
    if (kind === "throw") throw new TypeError("thrown");
    if (kind === "return") return "returned";
    return "fell through";
  } catch (e) {
    order.push(`catch ${e.message}`);
    return "from catch";
  } finally {
    order.push(`finally ${kind}`);
  }
}
console.log(withFinally("return"), withFinally("throw"), withFinally("plain"));
console.log(order.join("; "));
function finallyWins() {
  try {
    return "try";
  } finally {
    return "finally";
  }
}
console.log(finallyWins());
function finallySwallows() {
  for (let i = 0; i < 3; i++) {
    try {
      throw new Error(`pass ${i}`);
    } finally {
      if (i < 2) continue;
      break;
    }
  }
  return "swallowed";
}
console.log(finallySwallows());
function rethrows() {
  try {
    try {
      throw new Error("inner");
    } catch (e) {
      throw new Error(`${e.message}, again`);
    } finally {
      console.log("inner finally");
    }
  } catch (e) {
    return e.message;
  }
}
console.log(rethrows());
function deep(n) {
  if (n === 0) throw new RangeError("at the bottom");
  return deep(n - 1) + 1;
}
try {
  deep(50);
} catch (e) {
  console.log(e.name, e.message);
}
const total = [1, 2, 3].reduce((sum, n) => {
  try {
    if (n === 2) throw n;
    return sum + n;
  } catch (two) {
    return sum + two * 100;
  }
}, 0);
console.log(total);
try {
  [1, 2, 3].forEach((n) => {
    if (n === 2) throw new Error(`stopped at ${n}`);
    console.log("visited", n);
  });
} catch (e) {
  console.log(e.message);
}
let kind = 1;
try {
  kind = "changed";
  throw 0;
} catch (e) {
  console.log(kind, e);
}
console.log(new Error(5).message, new Error(undefined).message === "", new Error().message === "", new SyntaxError("s").name);
function forever(n) {
  return forever(n + 1) + 1;
}
for (let round = 0; round < 2; round++) {
  try {
    forever(0);
  } catch (e) {
    console.log(round, e.name, e.message);
  }
}
function inner() {
  try {
    return 1;
  } catch (e) {
    console.log("inner caught", e);
    return 2;
  }
}
try {
  inner();
  throw "outer";
} catch (e) {
  console.log("outer caught", e);
}
console.log("done");
