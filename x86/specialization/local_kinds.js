// local_kinds.js: heap_kinds.js with its arrays in the frame and passed to
// directly called functions, where js-x86 keeps them `Integers` (Lowering's
// INTEGER ARRAYS): each item read is an `Integer`, each index an integer,
// each `===` a `cmp`. The same lines as heap_kinds.js
// (x86/SPECIALIZATION.md).

const SIZE = 4096;
const REPS = 4000; // x86/profile.shale's size= sets it

function fill(pool, value, arena) {
  for (let i = 0; i < SIZE; i++) {
    pool.push((i * 7 + 3) & 4095);
    value.push(i % 3);
    arena.push((i * 13 + 5) & 4095);
  }
}

function sweep(pool, value, arena) {
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
  const pool = [0, 4095];
  const value = [0, 2];
  const arena = [0, 4095];
  fill(pool, value, arena);
  let total = 0;
  for (let r = 0; r < REPS; r++) total = (total + sweep(pool, value, arena)) % 1000003;
  console.log("hits " + total);
  console.log("pool " + pool[5] + " arena " + arena[7]);
}

race();
