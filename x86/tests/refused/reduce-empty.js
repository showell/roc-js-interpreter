// stops: x86: `reduce` of an empty array with no first value, which throws in node, is not compiled yet
console.log([1].reduce((a, b) => a + b));
console.log([].reduce((a, b) => a + b));
