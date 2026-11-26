// fourteen.js: the Nibble machine as one function, f : {0,1}^14 -> {0,1},
// written as cook-levin-riff's roc/Fourteen.roc is, and run over all 16,384
// points ROUNDS times. The 14 bits are a number below 2^14: the top 2 bits
// are the input, where AX starts, and the low 12 are the program, six lines
// of two bits, line 1 the highest pair (nada 00, zero 01, decr 10, mod2 11).
//
// A run is a number: 0 to 3 while it is going (the value of AX), ACCEPTED
// or REJECTED once it is done. Each round counts the points where f is 1,
// which is 5,596 (the C's cross-check, and Fourteen.roc's last expect), and
// a round that counts another number is a FAIL. The program prints the
// count once, and the total over all the rounds.
//
// Shaped for js-x86 within the races' rules (x86/race/README.md): the line
// places are an array made once in `main` and passed down, since js-x86
// keeps a top-level variable a function reads in a cell of unknown kind.

const ROUNDS = 1000; // x86/fourteen.shale's rounds= writes a copy with another
const ACCEPTED = 4;
const REJECTED = 5;
const POINTS = 16384;
const WANT = 5596;

// One line: zero accepts at 0, decr rejects at 0 or takes 1 from AX, mod2
// keeps AX's low bit, nada does nothing. A run that is done stays done.
function step(run, op) {
  if (run > 3) return run;
  if (op === 1 && run === 0) return ACCEPTED;
  if (op === 2 && run === 0) return REJECTED;
  if (op === 2) return run - 1;
  if (op === 3) return run % 2;
  return run;
}

// f itself: true when the program accepts the input. A run that gets past
// line 6 still going rejects. `places` is each line's place, line 1 first:
// 4^5, 4^4, ... 4^0.
function f(bits, places) {
  const input = Math.floor(bits / 4096);
  const program = bits % 4096;
  let run = input;
  for (const place of places) run = step(run, Math.floor(program / place) % 4);
  return run === ACCEPTED;
}

function main() {
  const places = [1024, 256, 64, 16, 4, 1];
  let total = 0;
  let wrong = 0;
  let first = 0;
  for (let r = 0; r < ROUNDS; r++) {
    let count = 0;
    for (let bits = 0; bits < POINTS; bits++) {
      if (f(bits, places)) count = count + 1;
    }
    if (r === 0) first = count;
    if (count !== WANT) wrong = wrong + 1;
    total = total + count;
  }
  console.log("f is 1 at " + first + " of " + POINTS + " points");
  console.log(ROUNDS + " rounds, " + total + " points where f is 1 in all");
  console.log(wrong === 0 ? "PASS" : "FAIL: " + wrong + " rounds counted another number");
}

main();
