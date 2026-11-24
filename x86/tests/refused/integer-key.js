// stops: x86: an object with an integer key, which node orders first, is not compiled yet
const byNumber = {};
byNumber.name = "numbers";
byNumber[10] = "ten";
console.log(byNumber);
