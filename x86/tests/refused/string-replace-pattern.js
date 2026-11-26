// stops: x86: `replace` or `replaceAll` other than of a string by a string without `$`, or `replaceAll` of the empty string, is not compiled yet
// A `$&` in the replacement, which node reads as the match.
console.log("before");
console.log("abc".replace("b", "$&$&"));
