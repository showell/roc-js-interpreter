// An index an item read proved keeps its proof in the branch one jump alone
// reaches (IndexLowering's header): `bump`'s `else` writes a[i] with no
// test. Where the index changed before the jump, the branch tests again:
// `moved`'s `else` writes past the end, which the slow way appends.
function bump(a) {
  let i = 0;
  while (i < a.length) {
    const s = a[i] + 1;
    if (s > 3) {
      a[i] = s - 3;
    } else {
      a[i] = s;
    }
    i = i + 1;
  }
}

function moved(a) {
  let i = 0;
  let total = 0;
  while (i < 3) {
    const s = a[i];
    i = i + 3;
    if (s > 1) {
      total = total + 1;
    } else {
      a[i] = 9;
    }
  }
  return total;
}

function run() {
  const a = [1, 2, 3, 4];
  bump(a);
  console.log(a);
  const b = [0, 0, 0];
  console.log(moved(b), b.length, b);
}

run();
