// stops: x86: an array method called on a value that is not an array is not compiled yet
// `concat` of a value whose kind isn't known is an array's, and a string is
// no array: the method stops rather than treat the string as one.
const values = [[1, 2], "a"];
console.log(values[0].concat([3]));
console.log(values[1].concat("b"));
