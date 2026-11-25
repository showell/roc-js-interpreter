// Numbers: the Collatz steps of every start from 1 to n, summed; a while
// loop of %, / and * on doubles.
function work(n) {
  let steps = 0;
  for (let s = 1; s <= n; s++) {
    let x = s;
    while (x !== 1) {
      if (x % 2 === 0) x = x / 2;
      else x = 3 * x + 1;
      steps++;
    }
  }
  return steps;
}
