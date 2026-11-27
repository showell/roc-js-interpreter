// refused: unsupported: an operator on a number and a boolean (a coercion)
// `&` binds looser than `===`, so this is `6 & (3 === 3)`.
console.log(6 & 3 === 3);
