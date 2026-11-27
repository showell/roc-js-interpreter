// A SAT solver's bit work, in the shape of rocsat's CDCL solver: a literal
// is twice its variable plus its sign, so `lit ^ 1` negates it and
// `lit >> 1` is its variable; a clause's header word holds its size in the
// low 28 bits and its flags above them, the mark in bit 31, the sign bit.

const SIZE_MASK = 0x0FFFFFFF;
const LEARNT = 1 << 28;
const DELETED = 1 << 29;
const MARK = 1 << 31;

function literal(variable, negative) {
  return (variable << 1) | (negative ? 1 : 0);
}

function header(size, flags) {
  return (size & SIZE_MASK) | flags;
}

function show(word) {
  const unsigned = word >>> 0;
  return `size ${word & SIZE_MASK}, learnt ${(word & LEARNT) !== 0}, deleted ${(word & DELETED) !== 0}, marked ${(word & MARK) !== 0}, word ${unsigned}`;
}

// Literals and their negations.
const lits = [];
for (let v = 0; v < 6; v++) {
  lits.push(literal(v, v % 2 === 1));
}
console.log(lits, lits.map((l) => l ^ 1), lits.map((l) => l >> 1), lits.map((l) => l & 1));

// A clause database: headers with flags set and cleared.
const db = [header(3, 0), header(7, LEARNT), header(200000, LEARNT | MARK), header(2, DELETED)];
for (const h of db) {
  console.log(show(h));
}
db[1] |= MARK;
db[2] &= ~MARK;
db[3] ^= DELETED | LEARNT;
for (let i = 0; i < db.length; i++) {
  console.log(i, show(db[i]));
}

// Assignments as a bitset of 32-bit words: set, test and clear.
const words = [0, 0, 0];
function assign(v) {
  words[v >> 5] |= 1 << (v & 31);
}
function assigned(v) {
  return (words[v >>> 5] >>> (v & 31) & 1) === 1;
}
function unassign(v) {
  words[v >> 5] &= ~(1 << (v & 31));
}
for (const v of [0, 5, 31, 32, 63, 64, 95]) {
  assign(v);
}
unassign(5);
console.log(words, words.map((w) => w >>> 0));
const seen = [];
for (let v = 0; v < 96; v++) {
  if (assigned(v)) seen.push(v);
}
console.log(seen);

// A literal's value under an assignment, by `^` of its sign: true, false or
// unassigned (2), as solvers keep it, and a watch's position by a hash.
const values = [2, 1, 0, 2, 1, 0];
function value(lit) {
  const v = values[lit >> 1];
  return v === 2 ? 2 : v ^ (lit & 1);
}
console.log(lits.map(value), lits.map((l) => value(l ^ 1)));
let hash = 2166136261;
for (const l of lits) {
  hash ^= l;
  hash = (hash * 16777619) >>> 0;
  hash ^= hash >>> 13;
}
console.log(hash, hash & 1023, hash | 0);

// Counting set bits and the lowest one, as a phase-saving or a heap code
// might.
function popcount(x) {
  let n = 0;
  let w = x >>> 0;
  while (w !== 0) {
    w &= w - 1;
    n++;
  }
  return n;
}
console.log([0, 1, 255, -1, 0x55555555, MARK].map(popcount), [12, 40, -8, MARK].map((x) => x & -x));
