// Objects with many keys, whose keys are found by their table (ObjectTable):
// lookups of keys made at run time and of literals, keys missing, keys
// written again, keys of the same length and the same start (so their
// slots collide), the table grown past several doublings, an index key put
// in among the entries after the table is made, and the order of the keys,
// printed and listed.
const big = {};
let i = 0;
while (i < 300) {
  big["key-" + i] = i * 3;
  i = i + 1;
}
let sum = 0;
i = 0;
while (i < 300) {
  sum = sum + big["key-" + i];
  i = i + 1;
}
console.log(sum, big["key-0"], big["key-299"], big["key-300"], big.missing);

// Written again: the value changes, the place and the count don't.
big["key-7"] = "seven";
big["key-150"] = -1;
console.log(big["key-7"], big["key-150"], Object.keys(big).length);
console.log(Object.keys(big).slice(0, 5).join(","), Object.keys(big)[299]);

// An object that grows past the threshold one key at a time, read between
// every write.
const grown = {};
const seen = [];
for (const name of ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"]) {
  grown[name] = name + name;
  seen.push(grown.a + grown[name]);
}
console.log(seen.join(" "));
console.log(grown);

// Index keys put in among the entries after the table is made: node puts
// them first, ascending, and every key is still found.
grown[5] = "five";
grown["2"] = "two";
grown.z = "last";
console.log(Object.keys(grown).join(","));
console.log(grown[5], grown["2"], grown.a, grown.l, grown.z, grown[3]);
console.log(grown);

// Keys alike in all but their last byte.
const alike = {};
for (const c of ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]) alike["same-prefix-" + c] = c;
let found = "";
for (const c of ["j", "i", "h", "g", "f", "e", "d", "c", "b", "a", "z"]) found = found + alike["same-prefix-" + c];
console.log(found);

// A class instance with many fields, read and written by its methods.
class Wide {
  constructor() {
    this.f1 = 1;
    this.f2 = 2;
    this.f3 = 3;
    this.f4 = 4;
    this.f5 = 5;
    this.f6 = 6;
    this.f7 = 7;
    this.f8 = 8;
    this.f9 = 9;
  }

  total() {
    this.f9 = this.f9 + 1;
    return this.f1 + this.f2 + this.f3 + this.f4 + this.f5 + this.f6 + this.f7 + this.f8 + this.f9;
  }
}
const w = new Wide();
console.log(w.total(), w.total(), w.f9);

// A spread of a big object, and its entries.
const copy = { ...grown, extra: true };
console.log(copy.extra, copy.k, copy[5], Object.entries(copy).length);
console.log(Object.values(copy).slice(0, 4).join("|"));
