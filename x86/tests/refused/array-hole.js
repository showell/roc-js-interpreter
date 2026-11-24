// stops: x86: an array written past its end, leaving holes, is not compiled yet
const xs = [1];
xs[3] = 4;
console.log(xs);
