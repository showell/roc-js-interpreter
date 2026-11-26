// A function's result that flows back into its own parameter: the kinds
// of the parameter and the result rise together until they settle
// (Lowering's `KINDS ONLY RISE`).
function t(s) { return s + 1; }
let x = t(1);
x = t(x);
console.log(x);
