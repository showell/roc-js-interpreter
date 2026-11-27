// FrameValues (x86/roc/FrameValues.roc): a load of a place a register holds
// is a move, and a store nothing loads back is dropped. Each function here
// leans on one of its edges: a value copied before its register is written
// again, two ways meeting with different values in one place, a place a loop
// carries round, a place kept across a call (a recursive one too, whose
// frame lies below), a store only a side exit reads, and a guarded loop
// whose fast copy leaves for the generic copy halfway. Every line must be
// node's.

// A copy's value outlives its register: `t` is read after `rax` is spent on
// the other operands.
function copies(a, b) {
  const t = a;
  const u = b * 2;
  const v = t + u;
  return t * 100 + v;
}

// Two ways meet with different values in one place: neither way's value
// may be forwarded past the meeting.
function meets(flag, x) {
  let y = 0;
  if (flag) {
    y = x + 1;
  } else {
    y = x - 1;
  }
  const z = flag ? y * 2 : y * 3;
  return y + z;
}

// A place a loop carries round, and one written on every pass but read only
// after the loop.
function carried(n) {
  let s = 0;
  let last = -1;
  for (let i = 0; i < n; i++) {
    s = s + i * i;
    last = i;
  }
  return s + last;
}

// A place kept across a call: the callee's frame lies below this one.
function depth(n) {
  if (n === 0) return 0;
  const here = n * 3;
  const below = depth(n - 1);
  return here + below;
}

function twice(f, x) {
  const kept = x + 7;
  const got = f(x);
  return kept * 10 + got;
}

// A guarded loop over an array of whole numbers, whose fast copy leaves by
// a side exit at a read past the end: the exit copies back what the fast
// copy holds, so the stores it reads stay.
function sums(st) {
  const a = st.a;
  let t = 0;
  let k = 0;
  let i = 0;
  while (i < 8) {
    const x = a[i];
    if (x === undefined) {
      k = k + 1;
    } else {
      t = t + x * 2 + i;
    }
    i = i + 1;
  }
  return t * 100 + k;
}

// A store and a load of the same place on both sides of a branch that
// jumps back: the loop's head is reached from below, so nothing is
// forwarded into it.
function backward(n) {
  let a = 1;
  let b = 2;
  let i = 0;
  while (i < n) {
    const c = a + b;
    a = b;
    b = c;
    i = i + 1;
  }
  return a * 1000 + b;
}

console.log(copies(3, 4), copies(-5, 0.5));
console.log(meets(true, 10), meets(false, 10));
console.log(carried(0), carried(1), carried(10));
console.log(depth(0), depth(5), depth(100));
console.log(twice((v) => v * v, 3), twice((v) => -v, 9));
console.log(sums({ a: [1, 2, 3] }), sums({ a: [1, 2, 3, 4, 5, 6, 7, 8, 9] }), sums({ a: [] }));
console.log(sums({ a: [1, 2.5, 3] }), sums({ a: [7] }));
console.log(backward(0), backward(1), backward(20));
