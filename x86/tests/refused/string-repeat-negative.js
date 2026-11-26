// stops: x86: `repeat` of a count that is not a whole number of at least 0 is not compiled yet
// A negative count, a RangeError in node.
console.log("before");
console.log("ab".repeat(-1));
