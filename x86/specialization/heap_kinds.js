// heap_kinds.js: the SAT race's watch loop in miniature, its arrays held in
// an object, as sat.js's `st` holds them (x86/SPECIALIZATION.md). Every
// array read from `st` is a `Value` to js-x86, so every item read from one
// is too. local_kinds.js is the same program with the arrays in the
// frame, where js-x86 keeps them `Integers`; the two print the same lines,
// and the gap between their times bounds what kinds through the heap buy
// this loop.

const SIZE = 4096;
const REPS = 4000; // x86/profile.shale's size= sets it

function fill(st) {
  for (let i = 0; i < SIZE; i++) {
    st.pool.push((i * 7 + 3) & 4095);
    st.value.push(i % 3);
    st.arena.push((i * 13 + 5) & 4095);
  }
}

// One pass over the pool's pairs, as propagate's watch loop: a blocker
// tested true, else the clause's first literal read, flipped and tested.
function sweep(st) {
  const pool = st.pool;
  const value = st.value;
  const arena = st.arena;
  let hits = 0;
  let j = 0;
  for (let i = 0; i < SIZE; i = i + 2) {
    const blocker = pool[i];
    const c = pool[i + 1];
    if (value[blocker] === 1) {
      pool[j] = blocker;
      pool[j + 1] = c;
      j = j + 2;
      hits = hits + 1;
    } else {
      const lk = arena[c] ^ 1;
      if (value[lk] === 0) hits = hits + 2;
      arena[c] = lk;
    }
  }
  return hits;
}

function race() {
  const st = { pool: [0, 4095], value: [0, 2], arena: [0, 4095] };
  fill(st);
  let total = 0;
  for (let r = 0; r < REPS; r++) total = (total + sweep(st)) % 1000003;
  console.log("hits " + total);
  console.log("pool " + st.pool[5] + " arena " + st.arena[7]);
}

race();
