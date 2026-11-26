// The near misses of arrays of whole numbers: a write outside the literal's
// range, a fraction pushed, an array stored in an object, joined or asked
// its type, and two literals of different ranges given to one parameter.
// Each keeps the program's arrays doubles (or values), as before, and every
// line prints what node prints.

function squares(a) {
  let t = 0;
  for (let i = 0; i < a.length; i++) t = t + a[i] * a[i];
  return t;
}

function main() {
  const wide = [1, 2, 3];
  wide[1] = 100;
  console.log(wide, wide[1] % 7);
  const grown = [1, 2];
  grown[0] = grown[1] + 5;
  console.log(grown, Math.floor(grown[0] / grown[1]));
  const halves = [2, 4];
  halves.push(0.5);
  console.log(halves.length, halves[2] * 4, halves[0] + halves[1]);
  const kept = [9, 8, 7];
  const box = { kept };
  console.log(box.kept[2], kept.join("-"), typeof kept);
  console.log(squares([1, 2]) + squares([1000, 2000]));
}

main();
