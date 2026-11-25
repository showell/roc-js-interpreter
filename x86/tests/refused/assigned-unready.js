// refused: `label` may be assigned before its declaration has run, which throws in node
// The case "x" falls through to "y" with `label` declared, and the jump to
// "y" reaches it undeclared, so whether node throws is known only as it runs.
function scoped(kind) {
  switch (kind) {
    case "x":
      let label = "ex";
    case "y":
      label = "why";
      return label;
  }
  return "neither";
}
console.log(scoped("x"));
