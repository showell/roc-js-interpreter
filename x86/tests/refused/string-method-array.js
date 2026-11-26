// stops: x86: this property read is not compiled yet
// A string's method called on an array, which has no property of that name
// (node throws a TypeError, as the method is undefined).
const values = [[1, 2], "a"];
console.log("before");
console.log(values[0].trim());
