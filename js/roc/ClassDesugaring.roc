## This module is where the JavaScript subset's classes become plain
## functions: the desugaring of a class declaration (`class_desugared`),
## every refusal a class meets and its text (`ClassRefusal`), and the class
## parts the grammar asks for that call nothing back into it (`class_parent`,
## `method_key`, `constructor_checked`, `this_expression`, `super_method`,
## `member_of`, `class_names_in`).
##
## A class is syntax sugar: the parser writes each class declaration as
## plain functions, so `Resolve`, `Compile` and the VM never meet a class,
## a `new` of one, `this` or `super`. `class C extends P { ... }` declares,
## in one `let`:
##
## - `#extends C`, P read, so P not yet declared throws as node throws;
## - `#methods C`, the class's table: a plain object holding P's table's
##   methods (a spread of `#methods P`), then each of C's own, which
##   replace P's of the same name, then, under `super_key(m)`, each method
##   of P's that C's methods call through `super`;
## - `#construct C`, the constructor as a function of the instance and
##   the constructor's parameters, its `super(...)` a call of `#construct
##   P(this, ...)`;
## - `C`, the function `new C(...)` calls: it makes the instance, marked
##   with the names of C and of the classes C extends and holding C's table
##   (`Ast`'s `Instance`), constructs it and answers it;
## - `C.s` for each static method, C's own and those it inherits, which
##   `C.s` written after the class reads.
##
## **A method is one function for the whole class**, made once, when the
## class's declaration runs, never once an instance: its first parameter is
## the receiver, `this`, and its form `Method`. An instance holds only its
## fields; a property it doesn't hold is read from its class's table, so
## `o.m` is the class's method unless the instance was given a property `m`
## of its own (`o.m = ...`), which then wins, as in JavaScript. A method
## call, `o.m(...)`, passes `o` before the arguments when what it calls is a
## `Method`; any other call of a method (`const f = o.m; f()`, a callback)
## passes `undefined` there, as node's `this` is then. `super.m` reads
## `this`'s property `super_key(m)`, the parent's method, from the table,
## and a call of it is a method call on `this`.
##
## This was chosen over closures made per instance (each over its own
## `this`, the form before 2026-11-26) so that a compiler can call a
## class's method directly when it knows the receiver's class, and so that
## an instance costs its fields alone. The VM and the compiler each keep the
## same three rules: an instance's table, read when its own properties lack
## a key; a method call's receiver passed first to a `Method`; `undefined`
## passed first by any other call of one.
##
## No program can write those names, nor `this` as a name, so no program
## meets them. A class's name is declared once in a program and never
## assigned, so `C`, `C.s` and `#methods C` name one class wherever they
## are written.
##
## The rest of the class knowledge lives in two places. Parser keeps the
## parts inside the grammar's cycle: a class's declaration and body, which
## parse its methods as functions, and `super`, whose call parses its
## arguments. ParserBasics keeps the class records the parser's
## `State` holds (`ParsedClass`, `Receiver`, `Parent`, `ClassCode`).
import Ast
import Lexer
import ParserBasics

ClassDesugaring :: [].{
	# The members of a class's body, parsed.
	ClassBody : {
		constructor : [Default, Written(Ast.FunctionDefinition)],
		methods : List(Ast.FunctionDefinition),
		statics : List(Ast.FunctionDefinition),
		supers : List(Str),
	}

	# What the parser refuses of a class, each in one place.
	ClassRefusal : [
		TwoClassesNamed(Str),
		ExtendsOther,
		NeverEnds,
		TwoConstructors,
		TwoStatics(Str),
		Accessors,
		Fields,
		Private,
		ComputedNames,
		Generators,
		StaticBlocks,
		NamedByLiteral,
		ReturnsValue,
		NoSuper,
		NestedSuper,
		SuperMethodInConstructor,
		SuperTwice,
		ThisBeforeSuper,
		NoSuchSuper(Str),
		SuperInStatic,
		SuperUnexpected,
		ThisInStatic,
		ThisOutside,
		AssignsClass(Str),
		AssignsStatic,
		InstanceofOther,
	]

	class_refusal : ClassDesugaring.ClassRefusal -> Str
	class_refusal = |refusal| match refusal {
		TwoClassesNamed(name) => "unsupported: two classes named `${name}`"
		ExtendsOther => "unsupported: `extends` of anything but a class declared above"
		NeverEnds => "a class that never ends (expected `}`)"
		TwoConstructors => "SyntaxError: A class may only have one constructor"
		TwoStatics(name) => "unsupported: two static methods named `${name}`"
		Accessors => ParserBasics.refusal_text(Accessors)
		Fields => "unsupported: class fields (set them on `this` in the constructor)"
		Private => "unsupported: private fields and methods (`#`)"
		ComputedNames => "unsupported: computed method names"
		Generators => ParserBasics.refusal_text(Generators)
		StaticBlocks => "unsupported: static blocks"
		NamedByLiteral => "unsupported: a method named by anything but a name"
		ReturnsValue => "unsupported: a constructor that returns a value"
		NoSuper => "unsupported: a derived class's constructor without `super(...)`"
		NestedSuper => "unsupported: `super(...)` inside a block or an expression"
		SuperMethodInConstructor => "unsupported: `super.method` in a constructor"
		SuperTwice => "unsupported: `super(...)` called twice"
		ThisBeforeSuper => "unsupported: `this` before `super(...)`"
		NoSuchSuper(method) => "unsupported: `super.${method}`, which no parent class has"
		SuperInStatic => "unsupported: `super` in a static method"
		SuperUnexpected => "SyntaxError: 'super' keyword unexpected here"
		ThisInStatic => "unsupported: `this` in a static method"
		ThisOutside => "unsupported: `this` outside a class's constructor and methods"
		AssignsClass(name) => "unsupported: assigning to `${name}`, a class's name"
		AssignsStatic => "unsupported: assigning to a class's static method or to `super`'s"
		InstanceofOther => "unsupported: `instanceof` of anything but a class's name"
	}

	class_refused : ParserBasics.State, ClassDesugaring.ClassRefusal -> Try(a, Lexer.Fault)
	class_refused = |parser, refusal| Err(
		ParserBasics.fault_here(parser, ClassDesugaring.class_refusal(refusal)),
	)

	# Every name written after `class`, each declared once.
	class_names_in : List(Lexer.Token) -> Try(List(Str), Lexer.Fault)
	class_names_in = |tokens| {
		var $names = []
		var $after_class = False
		for current in tokens {
			match current.kind {
				Name(text) if $after_class => {
					if $names.contains(text) {
						return Err({
							why: ClassDesugaring.class_refusal(TwoClassesNamed(text)),
							line: current.line,
							column: current.column,
						})
					}
					$names = $names.append(text)
				}
				_ => {}
			}
			$after_class = current.kind == Name("class")
		}
		Ok($names)
	}

	class_parent : ParserBasics.State -> Try(ParserBasics.Parsed(ParserBasics.Parent), Lexer.Fault)
	class_parent = |parser|
		if ParserBasics.is_word(parser, "extends") {
			onward = ParserBasics.advance(parser)
			match ParserBasics.token(onward).kind {
				Name(text) => match parser.classes.find_first(|parsed| parsed.name == text) {
					Ok(parent) => Ok({
						parser: ParserBasics.advance(onward),
						value: Extends(parent),
					})
					Err(NotFound) => ClassDesugaring.class_refused(onward, ExtendsOther)
				}
				_ => ClassDesugaring.class_refused(onward, ExtendsOther)
			}
		} else {
			Ok({ parser: parser, value: Base })
		}

	# A method's name, before its parameters.
	method_key : ParserBasics.State -> Try(Str, Lexer.Fault)
	method_key = |parser| {
		after = ParserBasics.token_after(parser)
		refuse = |refusal| ClassDesugaring.class_refused(parser, refusal)
		ends_a_field = after.kind == Punct("=") or after.kind == Punct(";") or after.kind == Punct("}")
		match ParserBasics.token(parser).kind {
			Name(text) if after.kind == Punct("(") => Ok(text)
			Name(text) if text == "get" or text == "set" or text == "async" => refuse(Accessors)
			Name(_) => {
				if ends_a_field or after.before == NewLine {
					refuse(Fields)
				} else {
					name_end = ParserBasics.advance(parser)
					Err(ParserBasics.fault_here(name_end, "expected `(` after a method's name"))
				}
			}
			Punct("#") => refuse(Private)
			Punct("[") => refuse(ComputedNames)
			Punct("*") => refuse(Generators)
			Punct("{") => refuse(StaticBlocks)
			Text(_) | Number(_) => refuse(NamedByLiteral)
			other => {
				found = ParserBasics.token_text(other)
				Err(ParserBasics.fault_here(parser, "expected a method's name, found ${found}"))
			}
		}
	}

	# A constructor held to what its desugaring keeps: no value returned, and
	# a derived class's `super(...)` called once, as a statement of its own in
	# the constructor's body, before any `this`. `at` is where its name is.
	ConstructorCheck : {
		definition : Ast.FunctionDefinition,
		made : ParserBasics.ClassCode,
		at : ParserBasics.State,
	}

	constructor_checked : ClassDesugaring.ConstructorCheck -> Try({}, Lexer.Fault)
	constructor_checked = |{ definition, made, at }|
		if ClassDesugaring.returns_a_value(definition.statements) {
			ClassDesugaring.class_refused(at, ReturnsValue)
		} else {
			match made.parent {
				Base => Ok({})
				Extends(_) => {
					if made.super_calls == 0 {
						ClassDesugaring.class_refused(at, NoSuper)
					} else if !definition.statements.any(ClassDesugaring.is_super_statement) {
						ClassDesugaring.class_refused(at, NestedSuper)
					} else {
						Ok({})
					}
				}
			}
		}

	is_super_statement : Ast.Statement -> Bool
	is_super_statement = |listed| match listed {
		Expression(Call(callee, _, _)) => match callee {
			Name(called, _, _) => called.starts_with("#construct ")
			_ => False
		}
		_ => False
	}

	# Whether a `return` with a value is written in the statements, outside
	# the functions inside them.
	returns_a_value : List(Ast.Statement) -> Bool
	returns_a_value = |statements| statements.any(ClassDesugaring.statement_returns_a_value)

	statement_returns_a_value : Ast.Statement -> Bool
	statement_returns_a_value = |listed| match listed {
		Return(Undefined) => False
		Return(_) => True
		If(_, yes, no) => ClassDesugaring.returns_a_value([yes, no])
		While(loop) => ClassDesugaring.statement_returns_a_value(loop.body)
		For(loop) => ClassDesugaring.statement_returns_a_value(loop.body)
		ForOf(loop) => ClassDesugaring.statement_returns_a_value(loop.body)
		BlockStatement(inner) => ClassDesugaring.returns_a_value(inner.statements)
		Try(tried) => {
			caught = match tried.handler {
				Caught(clause) => ClassDesugaring.returns_a_value(clause.body.statements)
				Uncaught => False
			}
			finally = match tried.finalizer {
				Finally(final_block) => ClassDesugaring.returns_a_value(final_block.statements)
				NoFinally => False
			}
			ClassDesugaring.returns_a_value(tried.block.statements) or caught or finally
		}
		Switch(switched) => {
			returns = |case| ClassDesugaring.returns_a_value(case.statements)
			switched.cases.any(returns)
		}
		Labelled(_, inner) => ClassDesugaring.statement_returns_a_value(inner)
		_ => False
	}

	# A method's class so far, and the class it extends.
	SuperMethod : { code : ParserBasics.ClassCode, parent : ParserBasics.ParsedClass }

	# The key under which a class's table holds its parent's method `method`,
	# for `super.method`: `þ` (bytes 0xC3 0xBE, as the compiler's class keys
	# start) and `super `, which no ASCII text is.
	super_key : Str -> Str
	super_key = |method| "þsuper ${method}"

	# `super.m` at `super`: the receiver's property under `super_key`, which
	# its class's table holds, the parent's method.
	super_method : ParserBasics.State, ClassDesugaring.SuperMethod -> ParserBasics.ParsedExpression
	super_method = |parser, { code, parent }| {
		site = ParserBasics.here(parser)
		method = ParserBasics.name_after_dot(ParserBasics.advance(ParserBasics.advance(parser)))?
		if parent.methods.contains(method.value) {
			named = { ..code, supers: code.supers.append(method.value) }
			receiver = Name("this", Unresolved, site)
			Ok({
				parser: { ..method.parser, receiver: InMethod(named) },
				value: Member(receiver, ClassDesugaring.super_key(method.value), site),
			})
		} else {
			ClassDesugaring.class_refused(parser, NoSuchSuper(method.value))
		}
	}

	# `this` in a constructor, a method or an arrow inside them.
	this_expression : ParserBasics.State -> ParserBasics.ParsedExpression
	this_expression = |parser| {
		this = Name("this", Unresolved, ParserBasics.here(parser))
		after = ParserBasics.advance(parser)
		match parser.receiver {
			Constructing(code) => {
				counted = { ..code, this_uses: code.this_uses + 1 }
				Ok({ parser: { ..after, receiver: Constructing(counted) }, value: this })
			}
			InMethod(_) => Ok({ parser: after, value: this })
			InStatic => ClassDesugaring.class_refused(parser, ThisInStatic)
			NoReceiver => ClassDesugaring.class_refused(parser, ThisOutside)
		}
	}

	# A class declaration's parts, for its desugaring.
	ClassDeclaration : {
		name : Str,
		parent : ParserBasics.Parent,
		body : ClassDesugaring.ClassBody,
		at : Ast.Where,
	}

	# A class declaration written as plain code: its declarators, and the
	# class's record for the classes after it.
	ClassDesugared : { parsed_class : ParserBasics.ParsedClass, declarators : List(Ast.Declarator) }

	# The declarators a class declaration is written as (the module's
	# doc), and the class's record for the classes after it.
	class_desugared : ClassDesugaring.ClassDeclaration -> Try(
		ClassDesugaring.ClassDesugared,
		Lexer.Fault,
	)
	class_desugared = |{ name, parent, body, at }| {
		named = |text| Name(text, Unresolved, at)
		bound = |text| Leaf(ToName(text, Unresolved, at))
		declared = |text, init| {
			pattern: bound(text),
			init: Initialized(init),
			at: at,
		}
		this = named("this")
		inherited = match parent {
			Extends(parent_class) => parent_class
			Base => { name: "", class_names: [], methods: [], statics: [] }
		}
		var $supers = []
		for each in body.supers {
			if !$supers.contains(each) {
				$supers = $supers.append(each)
			}
		}
		passed_on = Patterned({ items: [], rest: RestOf(bound("#arguments")) })
		constructor = match body.constructor {
			Written(written) => written
			Default => match parent {
				Base => {
					name: "",
					parameters: [],
					binding: Plain,
					names: [],
					statements: [],
					capture: CapturesNothing,
					form: Ordinary,
					at: at,
				}
				Extends(parent_class) => {
					name: "",
					parameters: ["#arguments"],
					binding: passed_on,
					names: ["#arguments"],
					statements: [
						Expression(
							Call(
								named("#construct ${parent_class.name}"),
								[Single(this), Spread(named("#arguments"), at)],
								at,
							),
						),
					],
					capture: CapturesNothing,
					form: Ordinary,
					at: at,
				}
			}
		}
		instance_parameter = { pattern: bound("this"), default: NoDefault }
		# A method of the class's table: the receiver its first parameter.
		as_method = |method| {
			..method,
			parameters: List.concat(["this"], method.parameters),
			binding: match method.binding {
				Plain => Plain
				Patterned({ items, rest }) => {
					with_instance = List.concat([instance_parameter], items)
					Patterned({ items: with_instance, rest: rest })
				}
			},
			names: List.concat(["this"], method.names),
			form: Method,
		}
		# The parent's methods first, so the class's own replace them, then
		# each parent method the class's methods call through `super`.
		{ inherited_parts, super_parts } = match parent {
			Extends(parent_class) => {
				parents = named("#methods ${parent_class.name}")
				{
					inherited_parts: [Spread(parents, at)],
					super_parts: $supers.map(
						|method| {
							parent_method = Member(parents, method, at)
							Field({ key: ClassDesugaring.super_key(method), value: parent_method })
						},
					),
				}
			}
			Base => { inherited_parts: [], super_parts: [] }
		}
		own_parts = body.methods.map(
			|method| Field({ key: method.name, value: Function(Box.box(as_method(method))) }),
		)
		methods_table = ObjectLit(List.concat(List.concat(inherited_parts, own_parts), super_parts))
		construct = {
			..constructor,
			name: "",
			parameters: List.concat(["this"], constructor.parameters),
			binding: match constructor.binding {
				Plain => Plain
				Patterned({ items, rest }) => {
					with_instance = List.concat([instance_parameter], items)
					Patterned({ items: with_instance, rest: rest })
				}
			},
			names: List.concat(["this"], constructor.names),
		}
		{ parameters, binding, forwarded } = match constructor.binding {
			Plain => {
				parameters: constructor.parameters,
				binding: Plain,
				forwarded: constructor.parameters.map(|parameter| Single(named(parameter))),
			}
			Patterned(_) => {
				parameters: ["#arguments"],
				binding: passed_on,
				forwarded: [Spread(named("#arguments"), at)],
			}
		}
		class_names = List.concat([name], inherited.class_names)
		constructs = Call(
			named("#construct ${name}"),
			List.concat([Single(this)], forwarded),
			at,
		)
		own_table = named("#methods ${name}")
		maker = {
			name: name,
			parameters: parameters,
			binding: binding,
			names: parameters.append("this"),
			statements: [
				Declare(Const, [declared("this", Instance(class_names, own_table))]),
				Expression(constructs),
				Return(this),
			],
			capture: CapturesNothing,
			form: MakesInstances,
			at: at,
		}
		own_statics = body.statics.map(|method| method.name)
		statics = body.statics.map(
			|method| declared("${name}.${method.name}", Function(Box.box(method))),
		)
		kept_statics = inherited.statics.drop_if(|each| own_statics.contains(each))
		inherited_statics = kept_statics.map(
			|each| declared("${name}.${each}", named("${inherited.name}.${each}")),
		)
		extends = match parent {
			Extends(parent_class) => [declared("#extends ${name}", named(parent_class.name))]
			Base => []
		}
		var $methods = inherited.methods
		for method in body.methods {
			if !$methods.contains(method.name) {
				$methods = $methods.append(method.name)
			}
		}
		functions = [
			declared("#methods ${name}", methods_table),
			declared("#construct ${name}", Function(Box.box(construct))),
			declared(name, Function(Box.box(maker))),
		]
		Ok({
			parsed_class: {
				name: name,
				class_names: class_names,
				methods: $methods,
				statics: List.concat(own_statics, kept_statics),
			},
			declarators: List.concat(
				List.concat(extends, functions),
				List.concat(statics, inherited_statics),
			),
		})
	}

	# `object.key`, or a class's static method, `C.s`, which the class
	# declares as a variable of its own (the module's doc).
	MemberRead : {
		object : Ast.Expression,
		key : Str,
		at : Ast.Where,
	}

	member_of : ParserBasics.State, ClassDesugaring.MemberRead -> Ast.Expression
	member_of = |parser, { object, key, at }| {
		static_name = match object {
			Name(class_name, _, _) => {
				declared = parser.classes.find_first(|parsed| parsed.name == class_name)
				match declared {
					Ok(parsed) if parsed.statics.contains(key) => Ok("${class_name}.${key}")
					_ => Err(NotStatic)
				}
			}
			_ => Err(NotStatic)
		}
		match static_name {
			Ok(name) => Name(name, Unresolved, at)
			Err(NotStatic) => Member(object, key, at)
		}
	}
}
