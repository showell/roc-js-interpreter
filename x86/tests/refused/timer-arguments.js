// refused: `setTimeout` with 3 arguments (a timer's arguments past its delay) is not compiled yet
setTimeout((x) => console.log(x), 10, "given");
