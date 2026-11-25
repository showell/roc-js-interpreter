## This module lays out a scope for the JavaScript parser: the names a
## function's, a block's or a `for`'s scope holds (`scope_names`,
## `scoping_of`), and the redeclarations that would make that layout
## ambiguous, which JavaScript refuses (`redeclared_message`,
## `repeated_name`). It also names the function literals a binding gives a
## name to (`with_name_given`, `named_for`), as `const f = () => 1` is "f".
##
## It stands apart from Parser because it is the rule `Resolve` leans on:
## what a scope's `names` hold, and what counts as a name declared twice, is
## read and audited here alone. Every function is pure over Ast; only the
## faults come from ParserBasics.
import Ast
import Lexer
import ParserBasics

ScopeLayout :: [].{
	# The names a scope holds, in order: `first` (a call's parameters), then
	# each function and each `let` and `const` that `statements` declare. A
	# function may share its name with a parameter or another function, the
	# later made winning; a `let` or a `const` shares its name with nothing,
	# as JavaScript refuses.
	scope_names : List(Str), List(Ast.Statement) -> Try(List(Str), Lexer.Fault)
	scope_names = |leading_names, statements| {
		var $names = leading_names
		var $lexical = []
		for listed in statements {
			match listed {
				FunctionDeclaration(boxed, _) => {
					definition = boxed.unbox()
					if $lexical.contains(definition.name) {
						return Err(
							ParserBasics.fault_at(
								definition.at,
								ScopeLayout.redeclared_message(definition.name),
							),
						)
					}
					if !$names.contains(definition.name) {
						$names = $names.append(definition.name)
					}
				}
				Declare(_, declarations) => {
					for d in declarations {
						for name in Ast.pattern_names(d.pattern) {
							if $names.contains(name) {
								return Err(
									ParserBasics.fault_at(d.at, ScopeLayout.redeclared_message(name)),
								)
							}
							$names = $names.append(name)
							$lexical = $lexical.append(name)
						}
					}
				}
				_ => {}
			}
		}
		Ok($names)
	}

	redeclared_message : Str -> Str
	redeclared_message = |name| "SyntaxError: Identifier '${name}' has already been declared"

	# The first name `names` holds twice, if one is.
	repeated_name : List(Str) -> Try(Str, [NoneRepeated])
	repeated_name = |names| {
		var $seen = []
		for name in names {
			if $seen.contains(name) {
				return Ok(name)
			}
			$seen = $seen.append(name)
		}
		Err(NoneRepeated)
	}

	scoping_of : List(Ast.Statement) -> Try(Ast.Scoping, Lexer.Fault)
	scoping_of = |statements| {
		declares = statements.any(
			|listed| match listed {
				Declare(_, _) => True
				FunctionDeclaration(_, _) => True
				_ => False
			},
		)
		if declares {
			Ok(Scoped(ScopeLayout.scope_names([], statements)?))
		} else {
			Ok(Unscoped)
		}
	}

	# A function literal written with no name of its own takes the name it is
	# bound to, as JavaScript names `const f = () => 1` "f".
	with_name_given : Ast.Expression, Str -> Ast.Expression
	with_name_given = |tree, name| match tree {
		Function(boxed) => {
			definition = boxed.unbox()
			if definition.name == "" {
				Function(Box.box({ ..definition, name: name }))
			} else {
				tree
			}
		}
		_ => tree
	}

	# A function literal bound by a pattern that is a plain name takes the
	# name, as `with_name_given` gives it.
	named_for : Ast.Expression, Ast.Pattern -> Ast.Expression
	named_for = |tree, bound| match bound {
		Leaf(ToName(name, _, _)) => ScopeLayout.with_name_given(tree, name)
		_ => tree
	}

	is_leaf : Ast.Pattern -> Bool
	is_leaf = |bound| match bound {
		Leaf(_) => True
		_ => False
	}
}
