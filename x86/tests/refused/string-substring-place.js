// stops: x86: `substring` from a place that is not a number is not compiled yet
// A place that is a string, which node would make a number.
console.log("before");
console.log("abc".substring("1"));
