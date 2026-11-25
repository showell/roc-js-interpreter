// The call path: a recursive fib, every call a real call.
function fib(n) {
  if (n < 2) return n;
  return fib(n - 1) + fib(n - 2);
}
function work(n) {
  return fib(n);
}
