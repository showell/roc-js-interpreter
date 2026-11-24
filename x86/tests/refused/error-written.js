// stops: x86: console.log of an error, which node writes with its stack, is not compiled yet
console.log({ message: "plain" });
console.log(new Error("e"));
