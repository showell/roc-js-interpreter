// Arrays of whole numbers: an array literal of whole number literals reads
// its items as Integers within their range, while every write is an Integer
// within it. Every array here stays one (x86/tests/integer-arrays-missed.js
// holds the near misses), and every line prints what node prints.

// The fourteen race's op: places walked, a floored quotient and its
// remainder.
function ops(program, places) {
  let s = 0;
  for (const place of places) s = s * 4 + Math.floor(program / place) % 4;
  return s;
}

// Items read by index, squared and summed.
function squares(a) {
  let t = 0;
  for (let i = 0; i < a.length; i++) t = t + a[i] * a[i];
  return t;
}

// A divisor whose range holds 0: the quotient is a double, and Infinity.
function divided(a, n) {
  return Math.floor(n / a[1]);
}

// A product of an item that may be 0 and a factor that may be negative.
function negatives(a, z) {
  return z * a[0];
}

// Writes within the literal's range: an Integer literal and an item.
function written(a) {
  a[0] = 3;
  a[1] = a[2];
  return a[0] + a[1];
}

// A push of items within the range.
function pushed(a) {
  a.push(a[0], a[1]);
  return a.length + a[a.length - 1];
}

function main() {
  const places = [1024, 256, 64, 16, 4, 1];
  let all = 0;
  for (let bits = 0; bits < 4096; bits += 7) all = all + ops(bits, places);
  console.log(all, ops(4095, places), places);
  const signed = [3, -4, 5];
  console.log(squares(signed), signed);
  const zero = [5, 0, 2];
  console.log(divided(zero, 9), divided(zero, -9));
  const low = [0, 2];
  console.log(negatives(low, -3), negatives(low, 3));
  const three = [1, 2, 3];
  console.log(written(three), three);
  const two = [7, 9];
  console.log(pushed(two), two);
  let sum = 0;
  for (const item of two) sum = sum + item % 4;
  console.log(sum, two.length);
}

main();
