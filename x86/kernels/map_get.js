// map_get.js: a Map of KEYS whole-number keys, read N times. The hashed
// Map's lookup. map_get.roc is its twin, a Dict.
const KEYS = 1000;
const N = 10000000;

function main() {
  const m = new Map();
  for (let k = 0; k < KEYS; k++) m.set(k, k * 3);
  let s = 0;
  for (let i = 0; i < N; i++) s = s + m.get(i % KEYS);
  console.log(s);
}

main();
