// The SAT race: rocsat's CDCL solver (github.com/showell/rocsat, src/), in
// the JavaScript subset. It is a transliteration of rocsat's one-shot solve
// path, function for function, so the race compares one algorithm in three
// runners: node, js-x86's executable and rocsat itself (Roc on LLVM).
//
// Kept from rocsat: literals as 2 * var + sign (lit ^ 1 negates); the flat
// clause arena, each clause [header, meta, lits...] (header bits 0..27 the
// size, bit 28 learnt, bit 29 deleted; meta bits 0..7 the saturating LBD,
// bits 8..9 the use age), cref 0 meaning none; pooled watch lists, each
// literal a block of two-word entries [blocker, cref] relocated to the end
// of the pool at twice the room when full, pool[0..7] a zero seed; the trail
// and its levels; EVSIDS with its heap (ties to the lower variable) and full
// phase saving; Luby restarts with a unit of 1,000 conflicts; first-UIP
// analysis with MiniSat's recursive minimisation and exact LBD; reduction
// every 2,000 conflicts, ranked by worse LBD then size; arena compaction
// past one sixth dead words; and root simplification.
//
// Left out: DRAT proofs, assumptions and incremental solving, and the brute
// checker. rocsat threads its lists through calls and returns them in tuples
// (its Core.roc header says why: Roc copies a list a record shares); here the
// arrays are shared by reference in one state object, `st`, and a function
// that rocsat gives a tuple of scalars writes them into `st` or returns an
// object. Where a value differs from rocsat's, a comment says so.
//
// One deliberate difference in shape: no list is built afresh where it can
// be reused. Analysis keeps its working lists in `st` (MiniSat's own
// analyze_stack and analyze_toclear) and empties them for each conflict;
// simplification and compaction move the live clauses down the arena in
// place, and a watch rebuild empties the pool and the block tables, where
// rocsat builds a new list each time. Each gives the same lists rocsat's
// does, so the search and every count are the same. js-x86's executables have
// no collector yet (x86/README.md, milestone 5), and the fresh lists filled
// their heap of 2 GiB before the race's large instances were half done.
//
// The instances are made here, since the subset reads no files: the
// pigeonhole formulas of rocsat's `hole` family (known UNSAT) and the
// Nibble++ search CNFs of cook-levin's `plus_sat search W K` (sat.c's gates
// and plus_sat.c's step, gate for gate, so the clauses are plus_sat's own).
// Each prints its verdict and its conflict, decision and propagation counts,
// which rocsat's `c conflicts=...` line prints too; a SAT model is checked
// against the instance's clauses. With MODE "dimacs" the program prints each
// instance as DIMACS instead, for rocsat to read (x86/satrace.shale).

const WORKLOAD = "race";
const ROUNDS = 1;
const MODE = "solve";

// ── Model (rocsat's Model.roc): a value per literal, or per variable ─────

const unassigned = 0;
const true_val = 1;
const false_val = 2;

// ── Core (rocsat's Core.roc) ───────────────────────────────────────────────

const none = 0;
const size_mask = 268435455;
const learnt_bit = 268435456;
const deleted_bit = 536870912;
const glue_mask = 255;
const used_mask = 768;

function filled(n, x) {
  const out = [];
  for (let i = 0; i < n; i++) out.push(x);
  return out;
}

// The array cut to its first n items, its room kept for the next pushes.
// (`a.length = n` would say it in one line; js-x86 doesn't compile a write
// of an array's length.)
function truncate(a, n) {
  while (a.length > n) a.pop();
}

function core_new(n) {
  const heap = [];
  const hpos = [];
  for (let v = 0; v < n; v++) {
    heap.push(v);
    hpos.push(v);
  }
  return {
    num_vars: n,
    arena: [0],
    pool: filled(8, 0),
    wofs: filled(2 * n, 0),
    wlen: filled(2 * n, 0),
    wcap: filled(2 * n, 0),
    value: filled(2 * n, unassigned),
    level: filled(n, 0),
    reason: filled(n, none),
    trail: filled(n, 0),
    trail_lim: filled(n, 0),
    seen: filled(n, 0),
    activity: filled(n, 0),
    heap: heap,
    hpos: hpos,
    phase: filled(n, 1),
    // Analysis's working lists, emptied for each conflict.
    learnt: [],
    kept: [],
    to_clear: [],
    used_clauses: [],
    min_clear: [],
    stack: [],
    trail_len: 0,
    dl: 0,
    qhead: 0,
    heap_len: n,
    var_inc: 1,
    simplified: 0,
    ok: true,
    conflicts: 0,
    decisions: 0,
    propagations: 0,
    restarts: 0,
    reductions: 0,
    collections: 0,
    simplifications: 0,
    simplified_clauses: 0,
    simplified_literals: 0,
    deleted_clauses: 0,
    learnt_literals_before: 0,
    learnt_literals_after: 0,
  };
}

function clause_size(header) {
  return header & size_mask;
}

// Assigns `lit` true at decision level `dl` with reason `from`.
function assign(st, lit, from, dl) {
  const v = lit >> 1;
  st.value[lit] = true_val;
  st.value[lit ^ 1] = false_val;
  st.level[v] = dl;
  st.reason[v] = from;
  st.trail[st.trail_len] = lit;
  st.trail_len = st.trail_len + 1;
}

// Undoes every assignment above level `lvl`. rocsat's returns the new trail
// length, level and qhead; here they are written into `st`.
function cancel_until(st, lvl) {
  const value = st.value;
  const trail = st.trail;
  const start = st.dl > lvl ? st.trail_lim[lvl] : st.trail_len;
  let i = st.trail_len;
  while (i > start) {
    i = i - 1;
    const lit = trail[i];
    value[lit] = unassigned;
    value[lit ^ 1] = unassigned;
  }
  st.trail_len = start;
  st.dl = Math.min(st.dl, lvl);
  st.qhead = start;
}

// Appends a clause of size >= 2 to the arena and gives its cref.
function alloc(arena, lits, learnt, glue) {
  const cref = arena.length;
  arena.push(learnt ? lits.length | learnt_bit : lits.length);
  arena.push(learnt ? Math.min(glue, 255) | 256 : 0);
  for (const q of lits) arena.push(q);
  return cref;
}

function clause_glue(meta) {
  return meta & glue_mask;
}

function clause_used(meta) {
  return (meta & used_mask) >> 8;
}

function mark_used(arena, cref) {
  if ((arena[cref] & learnt_bit) !== 0) arena[cref + 1] = (arena[cref + 1] & glue_mask) | used_mask;
}

function mark_used_all(arena, crefs) {
  for (const cref of crefs) mark_used(arena, cref);
}

function age_clause(arena, cref) {
  const meta = arena[cref + 1];
  const used = clause_used(meta);
  if (used !== 0) arena[cref + 1] = clause_glue(meta) | ((used - 1) << 8);
}

function mark_deleted(arena, cref) {
  arena[cref] = arena[cref] | deleted_bit;
}

function push_watch(st, lit, blocker, cref) {
  const pool = st.pool;
  const wofs = st.wofs;
  const n = st.wlen[lit];
  const cap = st.wcap[lit];
  if (n === cap) {
    const newcap = Math.max(2 * cap, 4);
    const newofs = pool.length;
    if (n > 0) {
      // rocsat appends the live entries, then fills the rest of the new
      // block by copying from it: the slack's contents are never read.
      const oldofs = wofs[lit];
      for (let i = 0; i < 2 * n; i++) pool.push(pool[oldofs + i]);
      for (let i = 0; i < 2 * (newcap - n); i++) pool.push(pool[newofs + i]);
    } else {
      for (let i = 0; i < 2 * newcap; i++) pool.push(pool[i]);
    }
    wofs[lit] = newofs;
    st.wcap[lit] = newcap;
  }
  const j = wofs[lit] + 2 * n;
  pool[j] = blocker;
  pool[j + 1] = cref;
  st.wlen[lit] = n + 1;
}

// Stores a clause of size >= 2 and watches its first two literals.
function learn(st, lits, learnt, glue) {
  const cref = alloc(st.arena, lits, learnt, glue);
  push_watch(st, lits[0] ^ 1, lits[1], cref);
  push_watch(st, lits[1] ^ 1, lits[0], cref);
  return cref;
}

// Every live clause's watches in fresh blocks: the slack and the watchers of
// deleted clauses dropped. rocsat makes a new pool and new tables; here the
// pool is cut back to its zero seed (which nothing writes) and the tables are
// zeroed, the same lists.
function rebuild_watches(st, num_lits) {
  truncate(st.pool, 8);
  for (let l = 0; l < num_lits; l++) {
    st.wofs[l] = 0;
    st.wlen[l] = 0;
    st.wcap[l] = 0;
  }
  const arena = st.arena;
  let c = 1;
  while (c < arena.length) {
    const header = arena[c];
    const size = clause_size(header);
    if ((header & deleted_bit) === 0) {
      const l0 = arena[c + 2];
      const l1 = arena[c + 3];
      push_watch(st, l0 ^ 1, l1, c);
      push_watch(st, l1 ^ 1, l0, c);
    }
    c = c + 2 + size;
  }
}

// ── Propagate (rocsat's Propagate.roc) ───────────────────────────────────

// Propagates the trail from qhead at level `dl`; the conflicting clause, or
// none. On a conflict the queue is drained (qhead = trail_len).
function propagate(st, dl) {
  const arena = st.arena;
  const value = st.value;
  const level = st.level;
  const reason = st.reason;
  const trail = st.trail;
  let trail_len = st.trail_len;
  let qhead = st.qhead;
  let props = st.propagations;
  let confl = none;
  while (qhead < trail_len) {
    const p = trail[qhead];
    qhead = qhead + 1;
    props = props + 1;
    const false_lit = p ^ 1;
    // push_watch may move another literal's block to the pool's end, never
    // this one's, so `base` stays put; the pool itself is read through `st`
    // after each push, since rocsat's grows by appending.
    const base = st.wofs[p];
    const nw = st.wlen[p];
    let pool = st.pool;
    let i = 0;
    let j = 0;
    while (i < nw) {
      const blocker = pool[base + 2 * i];
      const c = pool[base + 2 * i + 1];
      i = i + 1;
      if (value[blocker] === true_val) {
        pool[base + 2 * j] = blocker;
        pool[base + 2 * j + 1] = c;
        j = j + 1;
      } else {
        const l0 = arena[c + 2];
        const l1 = arena[c + 3];
        let first = l0;
        if (l0 === false_lit) {
          arena[c + 2] = l1;
          arena[c + 3] = false_lit;
          first = l1;
        }
        if (first !== blocker && value[first] === true_val) {
          pool[base + 2 * j] = first;
          pool[base + 2 * j + 1] = c;
          j = j + 1;
        } else {
          const end = c + 2 + clause_size(arena[c]);
          let k = c + 4;
          while (k < end && value[arena[k]] === false_val) k = k + 1;
          if (k < end) {
            const lk = arena[k];
            arena[c + 3] = lk;
            arena[k] = false_lit;
            push_watch(st, lk ^ 1, first, c);
            pool = st.pool;
          } else {
            pool[base + 2 * j] = first;
            pool[base + 2 * j + 1] = c;
            j = j + 1;
            if (value[first] === false_val) {
              confl = c;
              qhead = trail_len;
              while (i < nw) {
                pool[base + 2 * j] = pool[base + 2 * i];
                pool[base + 2 * j + 1] = pool[base + 2 * i + 1];
                i = i + 1;
                j = j + 1;
              }
            } else {
              value[first] = true_val;
              value[first ^ 1] = false_val;
              level[first >> 1] = dl;
              reason[first >> 1] = c;
              trail[trail_len] = first;
              trail_len = trail_len + 1;
            }
          }
        }
      }
    }
    st.wlen[p] = j;
  }
  st.trail_len = trail_len;
  st.qhead = qhead;
  st.propagations = props;
  return confl;
}

// ── Analyze (rocsat's Analyze.roc) ───────────────────────────────────────

function abstract_level(lv) {
  return 1 << (lv & 31);
}

function level_of(level, lits, i) {
  return level[lits[i] >> 1];
}

// First-UIP analysis of `confl` at level `dl` > 0. Gives the minimised
// learnt clause (the asserting literal first and, past one literal, the
// highest remaining level second), the backjump level, every derivation
// variable (for the bump), the learnt clauses used, the length before
// minimisation and the LBD. `seen` is all zero again after.
function analyze(st, dl, confl) {
  const arena = st.arena;
  const trail = st.trail;
  const level = st.level;
  const reason = st.reason;
  const seen = st.seen;
  const learnt = st.learnt;
  const to_clear = st.to_clear;
  const used_clauses = st.used_clauses;
  truncate(learnt, 0);
  truncate(to_clear, 0);
  truncate(used_clauses, 0);
  learnt.push(0);
  let path = 0;
  let p = 0;
  let first = true;
  let idx = st.trail_len - 1;
  let c = confl;
  let go = true;
  while (go) {
    if ((arena[c] & learnt_bit) !== 0) used_clauses.push(c);
    const end = c + 2 + clause_size(arena[c]);
    let k = first ? c + 2 : c + 3;
    while (k < end) {
      const q = arena[k];
      const v = q >> 1;
      const lv = level[v];
      if (seen[v] === 0 && lv > 0) {
        seen[v] = 1;
        to_clear.push(v);
        if (lv === dl) {
          path = path + 1;
        } else {
          learnt.push(q);
        }
      }
      k = k + 1;
    }
    while (seen[trail[idx] >> 1] === 0) idx = idx - 1;
    p = trail[idx];
    const pv = p >> 1;
    seen[pv] = 0;
    c = reason[pv];
    path = path - 1;
    first = false;
    if (path === 0) {
      go = false;
    } else {
      idx = idx - 1;
    }
  }
  learnt[0] = p ^ 1;
  const before = learnt.length;
  const minimized = minimize(st, to_clear, learnt);
  const kept = minimized.kept;
  let bt = 0;
  if (kept.length > 1) {
    let best = 1;
    for (let i = 2; i < kept.length; i++) {
      if (level_of(level, kept, i) > level_of(level, kept, best)) best = i;
    }
    const swapped = kept[1];
    kept[1] = kept[best];
    kept[best] = swapped;
    bt = level_of(level, kept, 1);
  }
  return { learnt: kept, bt: bt, touched: to_clear, used_clauses: used_clauses, before: before, glue: minimized.glue };
}

// MiniSat 2.2's recursive minimisation. `source_clear` holds the derivation
// marks already in `seen`; a traversal that succeeds stays marked for later
// candidates. Before the marks are cleared, values 2 and 3 mark each learnt
// level through its decision variable, which counts the exact LBD.
function minimize(st, source_clear, learnt) {
  const trail = st.trail;
  const trail_lim = st.trail_lim;
  const level = st.level;
  const reason = st.reason;
  const seen = st.seen;
  const min_clear = st.min_clear;
  truncate(min_clear, 0);
  let levels = 0;
  for (let i = 1; i < learnt.length; i++) levels = levels | abstract_level(level_of(level, learnt, i));
  const kept = st.kept;
  truncate(kept, 0);
  kept.push(learnt[0]);
  for (let i = 1; i < learnt.length; i++) {
    const q = learnt[i];
    if (reason[q >> 1] === none) {
      kept.push(q);
    } else if (!lit_redundant(st, min_clear, q, levels)) {
      kept.push(q);
    }
  }
  let glue = 0;
  for (let i = 0; i < kept.length; i++) {
    const lv = level_of(level, kept, i);
    const marker = trail[trail_lim[lv - 1]] >> 1;
    const state = seen[marker];
    if (state < 2) {
      seen[marker] = state + 2;
      glue = glue + 1;
    }
  }
  for (const v of source_clear) seen[v] = 0;
  for (const v of min_clear) seen[v] = 0;
  for (let i = 0; i < kept.length; i++) {
    const lv = level_of(level, kept, i);
    seen[trail[trail_lim[lv - 1]] >> 1] = 0;
  }
  return { kept: kept, glue: Math.min(glue, 255) };
}

// Whether the closure of the candidate's reason holds only marked
// variables, root assignments, or reasoned variables of the clause's levels.
// rocsat's returns `seen` and `min_clear` with the verdict; here both are
// changed in place.
function lit_redundant(st, min_clear, candidate, abstract_levels) {
  const arena = st.arena;
  const level = st.level;
  const reason = st.reason;
  const seen = st.seen;
  const top = min_clear.length;
  const stack = st.stack;
  truncate(stack, 0);
  stack.push(candidate);
  let i = 0;
  let redundant = true;
  while (i < stack.length && redundant) {
    const p = stack[i];
    i = i + 1;
    const c = reason[p >> 1];
    const end = c + 2 + clause_size(arena[c]);
    let k = c + 3;
    while (k < end && redundant) {
      const q = arena[k];
      const v = q >> 1;
      const lv = level[v];
      if (seen[v] === 0 && lv > 0) {
        const r = reason[v];
        if (r !== none && (abstract_level(lv) & abstract_levels) !== 0) {
          seen[v] = 1;
          min_clear.push(v);
          stack.push(q);
        } else {
          redundant = false;
        }
      }
      k = k + 1;
    }
  }
  if (!redundant) {
    for (let j = top; j < min_clear.length; j++) seen[min_clear[j]] = 0;
  }
  return redundant;
}

// ── Branch (rocsat's Branch.roc) ─────────────────────────────────────────

// rocsat's absent is 0xFFFFFFFF, a U32; here -1, which no position is.
const absent = -1;

// Bumps every variable analysis visited, sifts it up the heap, rescales past
// 1e100, and decays by raising the next bump by 1 / 0.95.
function bump_all(st, touched) {
  const activity = st.activity;
  const heap = st.heap;
  const hpos = st.hpos;
  const var_inc = st.var_inc;
  let rescale = false;
  for (const v of touched) {
    const score = activity[v] + var_inc;
    activity[v] = score;
    if (score > 1e100) rescale = true;
    let i = hpos[v];
    if (i !== absent) {
      while (i > 0) {
        const parent = (i - 1) >> 1;
        const pv = heap[parent];
        const pscore = activity[pv];
        if (score > pscore || (score === pscore && v < pv)) {
          heap[i] = pv;
          heap[parent] = v;
          hpos[pv] = i;
          hpos[v] = parent;
          i = parent;
        } else {
          i = 0;
        }
      }
    }
  }
  const next_inc = var_inc / 0.95;
  if (rescale) {
    for (let v = 0; v < activity.length; v++) activity[v] = activity[v] * 1e-100;
    st.var_inc = next_inc * 1e-100;
  } else {
    st.var_inc = next_inc;
  }
}

// Takes heap maxima off until one is unassigned, and gives it; num_vars
// when none is left.
function pick(st) {
  const activity = st.activity;
  const heap = st.heap;
  const hpos = st.hpos;
  const value = st.value;
  const num_vars = st.num_vars;
  let len = st.heap_len;
  let picked = num_vars;
  while (picked === num_vars && len > 0) {
    const root = heap[0];
    len = len - 1;
    hpos[root] = absent;
    if (len > 0) {
      const moved = heap[len];
      heap[0] = moved;
      hpos[moved] = 0;
      let i = 0;
      let down = true;
      while (down) {
        const left = 2 * i + 1;
        if (left >= len) {
          down = false;
        } else {
          const right = left + 1;
          const lv = heap[left];
          let best = left;
          if (right < len) {
            const rv = heap[right];
            const ls = activity[lv];
            const rs = activity[rv];
            if (rs > ls || (rs === ls && rv < lv)) best = right;
          }
          const bv = heap[best];
          const bs = activity[bv];
          const ms = activity[moved];
          if (bs > ms || (bs === ms && bv < moved)) {
            heap[i] = bv;
            heap[best] = moved;
            hpos[bv] = i;
            hpos[moved] = best;
            i = best;
          } else {
            down = false;
          }
        }
      }
    }
    if (value[2 * root] === unassigned) picked = root;
  }
  st.heap_len = len;
  return picked;
}

// Saves the signs of trail[start..end), whose assignments were just erased,
// and puts back in the heap each variable a pick took out.
function backtrack(st, start, end) {
  const activity = st.activity;
  const heap = st.heap;
  const hpos = st.hpos;
  const phase = st.phase;
  const trail = st.trail;
  let len = st.heap_len;
  for (let k = start; k < end; k++) {
    const lit = trail[k];
    const v = lit >> 1;
    phase[v] = lit & 1;
    if (hpos[v] === absent) {
      heap[len] = v;
      hpos[v] = len;
      const score = activity[v];
      let i = len;
      len = len + 1;
      while (i > 0) {
        const parent = (i - 1) >> 1;
        const pv = heap[parent];
        const pscore = activity[pv];
        if (score > pscore || (score === pscore && v < pv)) {
          heap[i] = pv;
          heap[parent] = v;
          hpos[pv] = i;
          hpos[v] = parent;
          i = parent;
        } else {
          i = 0;
        }
      }
    }
  }
  st.heap_len = len;
}

// ── Reduce (rocsat's Reduce.roc) ─────────────────────────────────────────

function counts(arena) {
  let original = 0;
  let learnt = 0;
  let live_words = 1;
  let dead_words = 0;
  let c = 1;
  while (c < arena.length) {
    const header = arena[c];
    const words = 2 + clause_size(header);
    if ((header & deleted_bit) !== 0) {
      dead_words = dead_words + words;
    } else {
      live_words = live_words + words;
      if ((header & learnt_bit) === 0) {
        original = original + 1;
      } else {
        learnt = learnt + 1;
      }
    }
    c = c + words;
  }
  return { original: original, learnt: learnt, live_words: live_words, dead_words: dead_words };
}

function locked(st, cref) {
  const implied = st.arena[cref + 2];
  return st.value[implied] === true_val && st.reason[implied >> 1] === cref;
}

// Ages every live learnt clause and deletes half of those eligible, worst
// LBD first, then the longest, then the oldest; compacts the arena past one
// sixth dead words, and rebuilds the watches. Binaries, reasons, glue-2
// clauses, glue 3..6 used twice of late and any other used once survive.
// Gives the count deleted, the live learnt clauses and whether it compacted.
function reduce(st) {
  const arena = st.arena;
  const candidates = [];
  let live_learnts = 0;
  let c = 1;
  while (c < arena.length) {
    const header = arena[c];
    const size = clause_size(header);
    if ((header & deleted_bit) === 0 && (header & learnt_bit) !== 0) {
      live_learnts = live_learnts + 1;
      const meta = arena[c + 1];
      const glue = clause_glue(meta);
      const used = clause_used(meta);
      let removable = used === 0;
      if (glue <= 2) {
        removable = false;
      } else if (glue <= 6) {
        removable = used < 2;
      }
      if (size > 2 && !locked(st, c) && removable) candidates.push(c);
      age_clause(arena, c);
    }
    c = c + 2 + size;
  }
  const ranked = candidates.sort((a, b) => worse_first(arena, a, b));
  const target = ranked.length === 0 ? 0 : Math.max(Math.floor(ranked.length / 2), 1);
  for (let i = 0; i < target; i++) {
    mark_deleted(arena, ranked[i]);
    live_learnts = live_learnts - 1;
  }
  const db = counts(arena);
  // One sixth dead is the exact line for an arena of at most 1.2 times its
  // live words.
  const collect = db.dead_words * 6 > arena.length;
  if (collect) compact(st);
  rebuild_watches(st, st.value.length);
  return { deleted: target, live_learnts: live_learnts, collected: collect ? 1 : 0 };
}

// Copies the live clauses and moves each assigned variable's reason.
// Unassigned variables' stale reasons are left: an assignment overwrites
// them before any use. rocsat copies into a new arena; here each live clause
// moves down the arena to where the new one would hold it (never past where
// it was, so nothing is written before it is read), and the arena is cut.
function compact(st) {
  const arena = st.arena;
  const reason = st.reason;
  const value = st.value;
  const reloc = filled(arena.length, none);
  let w = 1;
  let c = 1;
  while (c < arena.length) {
    const header = arena[c];
    const words = 2 + clause_size(header);
    if ((header & deleted_bit) === 0) {
      reloc[c] = w;
      for (let k = 0; k < words; k++) arena[w + k] = arena[c + k];
      w = w + words;
    }
    c = c + words;
  }
  truncate(arena, w);
  for (let v = 0; v < reason.length; v++) {
    const old = reason[v];
    if (old !== none && value[2 * v] !== unassigned) reason[v] = reloc[old];
  }
}

function worse_first(arena, a, b) {
  const ag = clause_glue(arena[a + 1]);
  const bg = clause_glue(arena[b + 1]);
  if (ag !== bg) return bg - ag;
  const asize = clause_size(arena[a]);
  const bsize = clause_size(arena[b]);
  if (asize !== bsize) return bsize - asize;
  return a - b;
}

// ── Simplify (rocsat's Simplify.roc) ─────────────────────────────────────

// At a propagation fixed point on level 0: satisfied clauses go, false
// literals past the two watches go, and the arena is built afresh (which
// also drops reduction's tombstones) once every root reason is cleared.
// Gives the clauses removed, the literals trimmed and the live learnts.
// rocsat builds the new arena as a new list; here, as in `compact`, each kept
// clause is written down the arena at the new one's place, its literals
// after the watches only those not false, and the arena is cut.
function simplify(st) {
  const arena = st.arena;
  const value = st.value;
  const reason = st.reason;
  const trail = st.trail;
  for (let i = 0; i < st.trail_len; i++) reason[trail[i] >> 1] = none;
  let w = 1;
  let removed = 0;
  let trimmed = 0;
  let live_learnts = 0;
  let c = 1;
  while (c < arena.length) {
    const header = arena[c];
    const size = clause_size(header);
    if ((header & deleted_bit) === 0) {
      let satisfied = false;
      let k = 0;
      while (k < size && !satisfied) {
        if (value[arena[c + 2 + k]] === true_val) satisfied = true;
        k = k + 1;
      }
      if (satisfied) {
        removed = removed + 1;
      } else {
        const meta = arena[c + 1];
        arena[w + 2] = arena[c + 2];
        arena[w + 3] = arena[c + 3];
        let n = 2;
        for (k = 2; k < size; k++) {
          const lit = arena[c + 2 + k];
          if (value[lit] !== false_val) {
            arena[w + 2 + n] = lit;
            n = n + 1;
          }
        }
        if (n < size) trimmed = trimmed + size - n;
        arena[w] = n | (header & learnt_bit);
        arena[w + 1] = meta;
        w = w + 2 + n;
        if ((header & learnt_bit) !== 0) live_learnts = live_learnts + 1;
      }
    }
    c = c + 2 + size;
  }
  truncate(arena, w);
  rebuild_watches(st, value.length);
  return { removed: removed, trimmed: trimmed, live_learnts: live_learnts };
}

// ── Solver (rocsat's Solver.roc) ─────────────────────────────────────────

const restart_first = 1000;

// The clause as it stands at level 0: sorted, without duplicates and false
// literals; null when it is a tautology or already satisfied. rocsat's
// `simplify`, renamed here beside Simplify's.
function simplify_clause(value, lits) {
  const sorted = lits.slice().sort((a, b) => a - b);
  const kept = [];
  // rocsat's undef_lit is 0xFFFFFFFF; -2 is as far from every literal, and
  // its `^ 1` (-1) too.
  let prev = -2;
  for (const q of sorted) {
    const val = value[q];
    if (q === (prev ^ 1) || val === true_val) return null;
    if (q !== prev && val === unassigned) kept.push(q);
    prev = q;
  }
  return kept;
}

// Adds clauses at level 0: units propagated at once, nothing added once a
// conflict is found. rocsat's add_clauses with its owner loop, add_all.
function add_clauses(st, clauses) {
  for (const lits of clauses) {
    if (st.ok) {
      const kept = simplify_clause(st.value, lits);
      if (kept !== null) {
        if (kept.length === 0) {
          st.ok = false;
        } else if (kept.length === 1) {
          assign(st, kept[0], none, 0);
          if (propagate(st, 0) !== none) st.ok = false;
        } else {
          learn(st, kept, false, 0);
        }
      }
    }
  }
}

// `1, 1, 2, 1, 1, 2, 4, ...` for y = 2.
function luby(y, x0) {
  let size = 1;
  let seq = 0;
  while (size < x0 + 1) {
    seq = seq + 1;
    size = 2 * size + 1;
  }
  let x = x0;
  while (size - 1 !== x) {
    size = (size - 1) >> 1;
    seq = seq - 1;
    x = x % size;
  }
  let result = 1;
  for (let i = 0; i < seq; i++) result = result * y;
  return result;
}

// The CDCL loop, rocsat's search_loop without assumptions: "SAT" or "UNSAT".
function solve(st) {
  let live_learnts = counts(st.arena).learnt;
  let next_reduce = (Math.floor(st.conflicts / 2000) + 1) * 2000;
  let restart_conflicts = 0;
  let restart_limit = restart_first * luby(2, st.restarts);
  let status = st.ok ? "UNKNOWN" : "UNSAT";
  while (status === "UNKNOWN") {
    const dl = st.dl;
    const confl = propagate(st, dl);
    if (confl !== none) {
      st.conflicts = st.conflicts + 1;
      restart_conflicts = restart_conflicts + 1;
      if (st.dl === 0) {
        st.ok = false;
        status = "UNSAT";
      } else {
        const found = analyze(st, dl, confl);
        const learnt = found.learnt;
        mark_used_all(st.arena, found.used_clauses);
        st.learnt_literals_before = st.learnt_literals_before + found.before;
        st.learnt_literals_after = st.learnt_literals_after + learnt.length;
        bump_all(st, found.touched);
        const old_trail_len = st.trail_len;
        cancel_until(st, found.bt);
        backtrack(st, st.trail_len, old_trail_len);
        if (learnt.length === 1) {
          assign(st, learnt[0], none, 0);
        } else {
          const cref = learn(st, learnt, true, found.glue);
          live_learnts = live_learnts + 1;
          assign(st, learnt[0], cref, found.bt);
        }
      }
    } else if (restart_conflicts >= restart_limit) {
      const old_trail_len = st.trail_len;
      cancel_until(st, 0);
      backtrack(st, st.trail_len, old_trail_len);
      st.restarts = st.restarts + 1;
      restart_conflicts = 0;
      restart_limit = restart_first * luby(2, st.restarts);
    } else {
      if (st.dl === 0 && st.trail_len > st.simplified) {
        const s = simplify(st);
        live_learnts = s.live_learnts;
        st.simplified = st.trail_len;
        st.simplifications = st.simplifications + 1;
        st.simplified_clauses = st.simplified_clauses + s.removed;
        st.simplified_literals = st.simplified_literals + s.trimmed;
      }
      if (st.conflicts >= next_reduce) {
        const r = reduce(st);
        live_learnts = r.live_learnts;
        st.reductions = st.reductions + 1;
        st.collections = st.collections + r.collected;
        st.deleted_clauses = st.deleted_clauses + r.deleted;
        next_reduce = next_reduce + 2000;
      }
      const v = pick(st);
      if (v < st.num_vars) {
        st.trail_lim[st.dl] = st.trail_len;
        st.dl = st.dl + 1;
        st.decisions = st.decisions + 1;
        assign(st, 2 * v + st.phase[v], none, st.dl);
      } else {
        status = "SAT";
      }
    }
  }
  return status;
}

// Whether every clause has a literal the solver's assignment makes true:
// Model.satisfies over the variables' values, as Solver.model gives them.
function satisfies(st, clauses) {
  for (const clause of clauses) {
    let sat = false;
    for (const lit of clause) {
      const v = st.value[2 * (lit >> 1)];
      if ((lit & 1) === 0 ? v === true_val : v === false_val) sat = true;
    }
    if (!sat) return false;
  }
  return true;
}

// ── The instances ────────────────────────────────────────────────────────

// An instance is its name, its variable count and its clauses as DIMACS
// literals (signed, from 1), as the file rocsat reads would hold them.

// rocsat's `hole` family (SATLIB's holeN, hole6 to hole10 in its corpus,
// tests/edge/hole3.cnf and hole4.cnf in its tree): n + 1 pigeons in n holes,
// variable (p - 1) * n + h for pigeon p in hole h. Every pigeon is in a hole,
// and no hole holds two. UNSAT.
function hole(n) {
  const clauses = [];
  for (let p = 1; p <= n + 1; p++) {
    const c = [];
    for (let h = 1; h <= n; h++) c.push((p - 1) * n + h);
    clauses.push(c);
  }
  for (let h = 1; h <= n; h++) {
    for (let p = 1; p <= n + 1; p++) {
      for (let q = p + 1; q <= n + 1; q++) clauses.push([-((p - 1) * n + h), -((q - 1) * n + h)]);
    }
  }
  return { name: `hole${n}`, num_vars: n * (n + 1), clauses: clauses };
}

// cook-levin's src/sat.c gates: AND and OR with NOT a literal's sign,
// constants folded and a gate made twice reused, each new gate a Tseitin
// variable and its three clauses. sat.c finds a gate again by a hash table
// of its own; here a Map keyed by the gate's kind and inputs finds the same.
const SAT_TRUE = 2147483647;
const SAT_FALSE = -2147483647;
const GATE_AND = 0;
const GATE_OR = 1;

function sat_clause(c, lits) {
  for (const x of lits) if (x === SAT_TRUE) return;
  const kept = [];
  for (const x of lits) if (x !== SAT_FALSE) kept.push(x);
  if (kept.length === 0) {
    // The empty clause, as sat.c writes it: two that contradict.
    c.clauses.push([1]);
    c.clauses.push([-1]);
  } else {
    c.clauses.push(kept);
  }
}

function gate_key(kind, a, b) {
  return (kind * 2097152 + (a + 1048576)) * 2097152 + (b + 1048576);
}

function sat_gate(c, kind, x, y) {
  const a = x < y ? x : y;
  const b = x < y ? y : x;
  const key = gate_key(kind, a, b);
  const found = c.gates.get(key);
  if (found !== undefined) return found;
  c.num_vars = c.num_vars + 1;
  const out = c.num_vars;
  if (out >= 1048576) throw new Error("plus_sat: too many variables for gate_key");
  c.gates.set(key, out);
  c.num_gates = c.num_gates + 1;
  if (kind === GATE_AND) {
    sat_clause(c, [-out, a]);
    sat_clause(c, [-out, b]);
    sat_clause(c, [out, -a, -b]);
  } else {
    sat_clause(c, [out, -a]);
    sat_clause(c, [out, -b]);
    sat_clause(c, [-out, a, b]);
  }
  return out;
}

function sat_and(c, x, y) {
  if (x === SAT_FALSE || y === SAT_FALSE) return SAT_FALSE;
  if (x === SAT_TRUE) return y;
  if (y === SAT_TRUE) return x;
  if (x === y) return x;
  if (x === -y) return SAT_FALSE;
  return sat_gate(c, GATE_AND, x, y);
}

function sat_or(c, x, y) {
  if (x === SAT_TRUE || y === SAT_TRUE) return SAT_TRUE;
  if (x === SAT_FALSE) return y;
  if (y === SAT_FALSE) return x;
  if (x === y) return x;
  if (x === -y) return SAT_TRUE;
  return sat_gate(c, GATE_OR, x, y);
}

// cook-levin's src/plus_sat.c, the Nibble++ step on a 4-bit AX.
const PLUS_AX_BITS = 4;

function plus_xor(c, x, y) {
  const left = sat_and(c, x, -y);
  const right = sat_and(c, -x, y);
  return sat_or(c, left, right);
}

function plus_mux2(c, s, in0, in1) {
  const left = sat_and(c, in0, -s);
  const right = sat_and(c, in1, s);
  return sat_or(c, left, right);
}

// in[op] for the op (h, l) spells: half 0, zero 1, decr 2, mod2 3.
function plus_mux4(c, h, l, half, zero, decr, mod2) {
  const low = plus_mux2(c, l, half, zero);
  const high = plus_mux2(c, l, decr, mod2);
  return plus_mux2(c, h, low, high);
}

function plus_sat_step(c, s, h, l) {
  const a = s.ax;
  const low_any = sat_or(c, a[0], a[1]);
  const high_any = sat_or(c, a[2], a[3]);
  const is_zero = -sat_or(c, low_any, high_any);
  const live = -s.halted;
  const op_zero = sat_and(c, -h, l);
  const op_stops = plus_xor(c, h, l);
  const accepts_now = sat_and(c, sat_and(c, live, op_zero), is_zero);
  const halts_now = sat_and(c, sat_and(c, live, op_stops), is_zero);
  const decr = [];
  let borrow = SAT_TRUE;
  for (let j = 0; j < PLUS_AX_BITS; j++) {
    decr.push(plus_xor(c, a[j], borrow));
    borrow = sat_and(c, borrow, -a[j]);
  }
  const ax = [];
  for (let j = 0; j < PLUS_AX_BITS; j++) {
    const half = j + 1 < PLUS_AX_BITS ? a[j + 1] : SAT_FALSE;
    const mod2 = j === 0 ? a[0] : SAT_FALSE;
    ax.push(plus_mux4(c, h, l, half, a[j], decr[j], mod2));
  }
  const accepted = sat_or(c, s.accepted, accepts_now);
  const halted = sat_or(c, s.halted, halts_now);
  return { ax: ax, halted: halted, accepted: accepted };
}

// plus_sat_search: a k-line program (line i's bits variables 2i - 1 and 2i)
// that decides `lang` (bit n for input n), one run for each of the 16 inputs.
function plus_search(lang, k) {
  const c = { num_vars: k > 0 ? 2 * k : 1, clauses: [], gates: new Map(), num_gates: 0 };
  const outs = [];
  for (let n = 0; n < 16; n++) {
    const ax = [];
    for (let j = 0; j < PLUS_AX_BITS; j++) ax.push(((n >> j) & 1) === 1 ? SAT_TRUE : SAT_FALSE);
    let s = { ax: ax, halted: SAT_FALSE, accepted: SAT_FALSE };
    for (let i = 1; i <= k; i++) s = plus_sat_step(c, s, 2 * i - 1, 2 * i);
    outs.push(s.accepted);
  }
  for (let n = 0; n < 16; n++) sat_clause(c, [((lang >> n) & 1) === 1 ? outs[n] : -outs[n]]);
  return { name: `plus${lang}-${k}`, num_vars: c.num_vars, clauses: c.clauses };
}

// Each workload's instances, made in this order.
function instances() {
  if (WORKLOAD === "tiny") return [hole(4), plus_search(11, 5), plus_search(11, 6)];
  if (WORKLOAD === "small") return [hole(5), hole(7), plus_search(11, 5), plus_search(11, 6), plus_search(47, 9)];
  return [hole(8), plus_search(191, 13), plus_search(191, 14), plus_search(49151, 27), plus_search(49151, 28)];
}

// ── The run ──────────────────────────────────────────────────────────────

// rocsat's Dimacs.parse encoding: 2 * (var - 1), plus 1 when negative.
function internal(clauses) {
  const out = [];
  for (const clause of clauses) {
    const lits = [];
    for (const x of clause) lits.push(x > 0 ? 2 * (x - 1) : 2 * (-x - 1) + 1);
    out.push(lits);
  }
  return out;
}

function solved(inst) {
  const clauses = internal(inst.clauses);
  const st = core_new(inst.num_vars);
  add_clauses(st, clauses);
  const status = solve(st);
  let check = "";
  if (status === "SAT") check = satisfies(st, clauses) ? ", model checked" : ", MODEL WRONG";
  return `${inst.name}: ${status}, conflicts ${st.conflicts}, decisions ${st.decisions}, propagations ${st.propagations}${check}`;
}

function dimacs(inst) {
  console.log(`c instance ${inst.name}`);
  console.log(`p cnf ${inst.num_vars} ${inst.clauses.length}`);
  for (const clause of inst.clauses) console.log(`${clause.join(" ")} 0`);
}

function main() {
  const made = instances();
  if (MODE === "dimacs") {
    for (const inst of made) dimacs(inst);
    return;
  }
  for (let round = 1; round <= ROUNDS; round++) {
    for (const inst of made) {
      const line = solved(inst);
      if (round === 1) console.log(line);
    }
  }
  console.log(`${ROUNDS} rounds of ${made.length} instances`);
}

main();
