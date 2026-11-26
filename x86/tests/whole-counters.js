// A loop's counter is known to hold no fraction (IndexLowering's A LOOP'S
// COUNTER IS KNOWN TO HOLD NO FRACTION): counters stepped by 1, by 2 and
// multiplied by 3 index arrays of numbers with no whole-number test, and a
// counter that takes a fraction on the way round is doubted at the loop's
// head, so its reads are tested again and find nothing (node's undefined).
function sums(a) {
  let total = 0;
  let i = 0;
  while (i < a.length) {
    total = total + a[i];
    i = i + 1;
  }
  let j = 1;
  while (j < a.length) {
    total = total + a[j] * 10;
    j = j + 2;
  }
  let k = 1;
  while (k < a.length) {
    total = total + a[k] * 100;
    k = k * 3;
  }
  return total;
}

function halves(words) {
  const seen = [];
  let i = 0;
  while (i < 3) {
    seen.push(words[i]);
    i = i + 0.5;
  }
  return seen;
}

function run() {
  const a = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
  console.log(sums(a));
  console.log(halves(["zero", "one", "two", "three"]));
}

run();
