// stops: x86: a string of more than 2^30 bytes is not compiled yet
// A string past the heap, which node makes.
console.log("before");
console.log("abcd".repeat(300000000).length);
