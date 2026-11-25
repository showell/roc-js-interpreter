# The JavaScript subset's front end as a package: the parser (with the
# resolver it runs) and the compiler to bytecode, with the shapes they make.
# x86/ imports it to compile a program as js-vm compiles it, then lowers the
# bytecode to x86-64.
package [Ast, Bytecode, Compile, Parser, ValueRules] {}
