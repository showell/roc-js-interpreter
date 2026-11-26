// stops: x86: `replace` or `replaceAll` other than of a string by a string without `$`, or `replaceAll` of the empty string, is not compiled yet
// `replaceAll` of the empty string, which node puts between every two characters.
console.log("before");
console.log("abc".replaceAll("", "-"));
