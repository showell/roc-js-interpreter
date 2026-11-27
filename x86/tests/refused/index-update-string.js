// refused: `++` or `--` of an item of a string
// `s[i]++` of a string: node makes the item NaN and leaves the string alone.
const s = "abc";
console.log(s[0]++, s);
