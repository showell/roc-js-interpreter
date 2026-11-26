// refused: a loop's kinds don't settle within 16 widenings of its head
// One loop whose head widens once a walk, a variable at a time: the string
// in `a20` reaches `a19` on the next walk, `a18` on the one after, and so
// on down the chain. Kinds only rise, so it would settle after twenty, but
// a head may widen 16 times before it is refused, so that the walks end.
let a1 = 0, a2 = 0, a3 = 0, a4 = 0, a5 = 0, a6 = 0, a7 = 0, a8 = 0, a9 = 0, a10 = 0;
let a11 = 0, a12 = 0, a13 = 0, a14 = 0, a15 = 0, a16 = 0, a17 = 0, a18 = 0, a19 = 0, a20 = 0;
for (let i = 0; i < 25; i++) {
  a1 = a2; a2 = a3; a3 = a4; a4 = a5; a5 = a6; a6 = a7; a7 = a8; a8 = a9; a9 = a10; a10 = a11;
  a11 = a12; a12 = a13; a13 = a14; a14 = a15; a15 = a16; a16 = a17; a17 = a18; a18 = a19; a19 = a20;
  a20 = "s";
}
console.log(a1);
