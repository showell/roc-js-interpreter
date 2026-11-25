// stops: x86: an object with an integer key of ten digits or more is not compiled yet
// node orders an index key (below 2^32 - 1) first and any other in the
// order it was set, and a key of ten digits may be either.
const byNumber = {};
byNumber.name = "numbers";
byNumber[4294967296] = "past the indexes";
console.log(byNumber);
