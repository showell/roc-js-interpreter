// refused: `label` may be assigned before its declaration has run, which throws in node
function scoped(kind) {
  switch (kind) {
    case "x":
      let label = "ex";
      return label;
    case "y":
      label = "why";
      return label;
  }
  return "neither";
}
console.log(scoped("x"));
