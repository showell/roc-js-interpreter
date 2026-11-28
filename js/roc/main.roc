# The JavaScript subset's front end as a package: the lexer, the parser (with
# the resolver it runs) and the compiler to bytecode, with the shapes they
# make. x86/ imports it to compile a program as js-vm compiles it, then lowers
# the bytecode to x86-64; kava/ imports the lexer and the parser to read
# KavaScript, whose additions are spelled in the subset's own tokens.
package [Ast, Bytecode, Compile, Lexer, Parser, ValueRules] {}
