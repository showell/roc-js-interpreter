// Loops whose arrays' facts LoopInvariants loads once before the loop (the
// record, the length and the items' address), and the near misses it must
// leave as they are: an array the loop resizes, one it reassigns, one a
// call inside the loop changes, a head a jump reaches from before, and
// versioned loops whose guards or side exits send them to the generic copy.

// Kept: no instruction of the loop can change the array.
function sum(a) {
  let s = 0;
  for (let i = 0; i < a.length; i++) s = s + a[i];
  return s;
}
console.log(sum([3, 1, 4, 1, 5, 9, 2, 6]), sum([]), sum([0.5, 0.25]) * 4, sum([-0]));

// Kept by the outer loop for both inner loops: two arrays, read together.
function dot(x, y) {
  let d = 0;
  for (let r = 0; r < 3; r++) {
    for (let i = 0; i < x.length; i++) d = d + x[i] * y[i];
    for (let i = 0; i < y.length; i++) d = d - y[i];
  }
  return d;
}
console.log(dot([1, 2, 3], [4, 5, 6]), dot([], []));

// Kept, and read past its end: the item read's slow way gives `undefined`.
function past(a) {
  let s = "";
  for (let i = 0; i <= a.length; i++) s = s + a[i] + ",";
  return s;
}
console.log(past(["x", "y"]), past([]));

// Nested: the outer loop keeps the matrix, and each inner loop keeps the
// row the outer one set before it, loaded again at each way in.
function total(m) {
  let s = 0;
  for (let r = 0; r < m.length; r++) {
    const row = m[r];
    for (let c = 0; c < row.length; c++) s = s + row[c] * (r + 1);
  }
  return s;
}
console.log(total([[1, 2], [], [3, 4, 5], [6]]));

// A `while` whose `continue` jumps back to its head, past the loads.
function evens(a) {
  let i = 0;
  let n = 0;
  while (i < a.length) {
    const x = a[i];
    i = i + 1;
    if (x % 2 === 1) continue;
    n = n + x;
  }
  return n;
}
console.log(evens([1, 2, 3, 4, 5, 6, 8]));

// Resized in the loop by a push: not kept, so each trip reads the length
// the push left.
function grow(a) {
  let n = 0;
  for (let i = 0; i < a.length; i++) {
    if (a[i] > 0) a.push(a[i] - 1);
    n = n + 1;
  }
  return n;
}
console.log(grow([3, 1]));

// Resized by a write one past the end, and shrunk by `pop` in a call.
function append(a) {
  for (let i = 0; i < 4; i++) a[a.length] = a.length * 10;
  return a;
}
function popped(a) {
  a.pop();
}
function shrink(a) {
  let s = 0;
  for (let i = 0; i < a.length; i++) {
    s = s + a[i];
    popped(a);
  }
  return s;
}
console.log(append([7]), shrink([1, 2, 3, 4, 5, 6]));

// Reassigned in the loop: the slot is written, so nothing is kept.
function swapping(a, b) {
  let s = 0;
  let x = a;
  for (let i = 0; i < 4; i++) {
    s = s + x.length * 10 + x[0];
    x = x === a ? b : a;
  }
  return s;
}
console.log(swapping([1, 2, 3], [9]));

// A loop whose head a jump from before reaches (the `&&`'s skip lands on
// the condition the loop tests again).
function guarded(a, go) {
  let s = 0;
  let i = 0;
  while (go && i < a.length) {
    s = s + a[i];
    i = i + 1;
  }
  return s;
}
console.log(guarded([5, 6, 7], true), guarded([5, 6, 7], false));

// Versioned loops: an array held in an object, guarded Int32 in the fast
// copy, which keeps its facts. A fraction fails the guard at the entry; a
// read past the end leaves by a side exit partway; a fraction or a write
// past 32 bits sends the writes to the generic copy too.
function held(st) {
  const a = st.a;
  let s = 0;
  for (let i = 0; i < st.n; i++) s = s + a[i];
  return s;
}
console.log(held({ a: [1, 2, 3, 4], n: 4 }), held({ a: [1, 2.5, 3.5], n: 3 }), held({ a: [1, 2], n: 4 }));
function scaled(st) {
  const a = st.a;
  for (let i = 0; i < st.n; i++) a[i] = a[i] * st.k;
  return a;
}
console.log(scaled({ a: [1, 2, 3], n: 3, k: 2 }), scaled({ a: [2, 4, 6], n: 3, k: 2.5 }));
console.log(scaled({ a: [1, 2, 3], n: 3, k: 2147483648 }));
