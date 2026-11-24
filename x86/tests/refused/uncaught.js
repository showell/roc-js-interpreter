// stops: x86: a throw that nothing catches, which node reports with its source line, is not compiled yet
try {
  console.log("tried");
} catch (e) {
  console.log("caught", e);
}
console.log("before");
throw 1;
