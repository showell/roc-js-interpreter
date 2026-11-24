// stops: RangeError: Maximum call stack size exceeded
// node throws its RangeError here, uncaught: its stderr ends the same line
// after the source line and a caret, and node exits 1.
function forever(n) {
  return forever(n + 1) + 1;
}
console.log(1);
console.log(forever(0));
