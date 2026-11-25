// Arrays that hold only numbers (Lowering's NUMBER-ONLY ARRAYS): made empty
// or of number literals, grown by `push` and writes, passed to functions,
// copied to other variables, and printed.
function sum(a) {
  let t = 0;
  let i = 0;
  while (i < a.length) {
    t = t + a[i];
    i = i + 1;
  }
  return t;
}

function grow(a, n) {
  let i = 0;
  while (i < n) {
    a.push(i * i);
    i = i + 1;
  }
}

function numbers() {
  const a = [];
  grow(a, 5);
  a[0] = 10;
  a[a.length] = 7;
  let b = [1.5, 2.5];
  const c = a;
  b = c;
  c[1] = c[1] + b[2];
  console.log(sum(a), a.length, a, b[1]);
}


numbers();
