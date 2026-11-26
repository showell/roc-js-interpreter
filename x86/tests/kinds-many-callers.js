// One function called with different kinds from different places, and fed
// its own result.
function same(v) { return v; }
console.log(same(1), same("one"), same(true));
let z = same(2);
z = same(z);
console.log(z, same(z) + 1);
