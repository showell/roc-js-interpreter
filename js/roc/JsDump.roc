# The bytecode a JavaScript program compiles to, printed: the program is
# parsed (Parser.roc) and compiled (Compile.roc) as the VM's are, and each
# function's code is printed an instruction a line, nothing run.
#
#   js-dump "<program>"
#
# Each function's code starts with a line `code <n>: frame <slots>,
# arguments <how>, entry [<steps>]`, the program's own marked `(main)`,
# then one line an instruction, `<place>  <instruction>`, the place from 0.
# An instruction is written as Bytecode.Op's tag with its payload, but
# without the places in the source an instruction carries for its messages
# (`Ast.Where`), and with a function definition or an expression it carries
# for its messages named only by its kind, so a dump says what runs.
# js/dump.shale holds one program's dump exactly.
#
# A program the parser refuses ends with a line `js: <why>` and exits 1, as
# js-vm's does, and so does one the compiler refuses.
import Bytecode
import Compile
import Parser

main! = |arguments| {
	match arguments.get(0) {
		Ok(src) => print_program!(src)
		Err(_) => {
			echo!("usage: js-dump \"<program>\"\n")
			Err(Exit(2))
		}
	}
}

print_program! : Str => Try({}, [Exit(I8)])
print_program! = |src| {
	match Parser.program_of(src, Core) {
		Ok(tree) => match Compile.program(tree) {
			Ok(program) => {
				echo!(program_text(program))
				Ok({})
			}
			Err(Unsupported(why)) => {
				echo!("js: ${why}\n")
				Err(Exit(1))
			}
		}
		Err(fault) => {
			place = "line ${fault.line.to_str()}, column ${fault.column.to_str()}"
			echo!("js: ${fault.why} (${place})\n")
			Err(Exit(1))
		}
	}
}

## Every function's code, in the order of `program.codes`.
program_text : Bytecode.Program -> Str
program_text = |program| {
	var $out = ""
	for index in 0..<program.codes.len() {
		code = program.codes.get(index) ?? crash "JsDump.program_text: an index below the length"
		name = if index == program.main {
			"code ${index.to_str()} (main)"
		} else {
			"code ${index.to_str()}"
		}
		parts = [
			"frame ${code.frame_size.to_str()}",
			"arguments ${arguments_text(code.arguments)}",
			"entry [${Str.join_with(code.entry.map(entry_step_text), ", ")}]",
		]
		$out = Str.concat($out, "${name}: ${Str.join_with(parts, ", ")}\n")
		for place in 0..<code.ops.len() {
			instruction = code.ops.get(place) ?? crash "JsDump.program_text: a place in the code"
			$out = Str.concat($out, "${place.to_str()}  ${instruction_text(instruction)}\n")
		}
	}
	$out
}

## How a call's arguments reach the frame, as the code line writes it.
arguments_text : Bytecode.Arguments -> Str
arguments_text = |arguments|
	match arguments {
		Each(count) => "Each(${count.to_str()})"
		Packed(slot) => "Packed(${slot.to_str()})"
	}

entry_step_text : Bytecode.Entry -> Str
entry_step_text = |step|
	match step {
		FreshBox(slot) => "FreshBox(${slot.to_str()})"
		FilledBox(slot) => "FilledBox(${slot.to_str()})"
		CapturedBox({ slot, capture }) => "CapturedBox(${slot.to_str()}, ${capture.to_str()})"
	}

## One instruction as its tag and payload, without its places in the source.
instruction_text : Bytecode.Op -> Str
instruction_text = |instruction|
	match instruction {
		PushNumber(number) => "PushNumber(${Str.inspect(number)})"
		PushText(text) => "PushText(${Str.inspect(text)})"
		PushBoolean(value) => "PushBoolean(${Str.inspect(value)})"
		PushNull => "PushNull"
		PushUndefined => "PushUndefined"
		Pop => "Pop"
		Duplicate => "Duplicate"
		DuplicatePair => "DuplicatePair"
		Nip => "Nip"
		Swap => "Swap"
		Rotate => "Rotate"
		LoadLocal(slot) => "LoadLocal(${slot.to_str()})"
		StoreLocal(slot) => "StoreLocal(${slot.to_str()})"
		SetLocal(slot) => "SetLocal(${slot.to_str()})"
		LoadBoxed(named) => "LoadBoxed(${named.slot.to_str()}, ${Str.inspect(named.name)})"
		PeekBoxed(slot) => "PeekBoxed(${slot.to_str()})"
		StoreBoxed(assigned) => tag_text(
			"StoreBoxed",
			[assigned.slot.to_str(), Str.inspect(assigned.name), kind_text(assigned.kind)],
		)
		SetBoxed(slot) => "SetBoxed(${slot.to_str()})"
		NewBox(slot) => "NewBox(${slot.to_str()})"
		CopyBox(slot) => "CopyBox(${slot.to_str()})"
		LoadBuiltin(place) => "LoadBuiltin(${place.to_str()})"
		MissingName({ name, at: _ }) => "MissingName(${Str.inspect(name)})"
		ThrowUnready({ name, at: _ }) => "ThrowUnready(${Str.inspect(name)})"
		ThrowConstant(_) => "ThrowConstant"
		Refuse(why) => "Refuse(${Str.inspect(why)})"
		AppendLocal({ slot, at: _ }) => "AppendLocal(${slot.to_str()})"
		UpdateLocal({ slot, step }) => "UpdateLocal(${slot.to_str()}, ${update_text(step)})"
		UpdateBoxed({ slot, name, kind, step }) => tag_text(
			"UpdateBoxed",
			[
				slot.to_str(),
				Str.inspect(name),
				kind_text(kind),
				update_text(step),
			],
		)
		UpdateFixed(_) => "UpdateFixed"
		UpdateProperty({ key, step }) => "UpdateProperty(${Str.inspect(key)}, ${update_text(step)})"
		UpdateIndex(step) => "UpdateIndex(${update_text(step)})"
		Unary(operator, _) => "Unary(${Str.inspect(operator)})"
		Binary(operator, _) => "Binary(${Str.inspect(operator)})"
		TemplatePart(text) => "TemplatePart(${Str.inspect(text)})"
		Jump(count) => "Jump(${count.to_str()})"
		Loop(count) => "Loop(${count.to_str()})"
		JumpIfFalse(count) => "JumpIfFalse(${count.to_str()})"
		SkipIfFalsy(count) => "SkipIfFalsy(${count.to_str()})"
		SkipIfTruthy(count) => "SkipIfTruthy(${count.to_str()})"
		SkipIfDefined(count) => "SkipIfDefined(${count.to_str()})"
		SkipIfNotUndefined(count) => "SkipIfNotUndefined(${count.to_str()})"
		JumpIfSame(count) => "JumpIfSame(${count.to_str()})"
		ShortIfNullish(count) => "ShortIfNullish(${count.to_str()})"
		MakeArray(count) => "MakeArray(${count.to_str()})"
		NewArray => "NewArray"
		AppendItem => "AppendItem"
		AppendSpread(_) => "AppendSpread"
		NewObject => "NewObject"
		NewInstance(names) => "NewInstance(${Str.inspect(names)})"
		InstanceOf(name) => "InstanceOf(${Str.inspect(name)})"
		SetField(key) => "SetField(${Str.inspect(key)})"
		SpreadFields(_) => "SpreadFields"
		GetProperty(key, _) => "GetProperty(${Str.inspect(key)})"
		GetIndex(_) => "GetIndex"
		SetProperty(key, _) => "SetProperty(${Str.inspect(key)})"
		SetIndex(_) => "SetIndex"
		MakeClosure({ code, captures, definition: _ }) => tag_text(
			"MakeClosure",
			[code.to_str(), Str.inspect(captures)],
		)
		Call(site) => "Call(${site.count.to_str()}, ${Str.inspect(site.written)})"
		CallSpread({ written, at: _ }) => "CallSpread(${Str.inspect(written)})"
		MethodLookup(name, _) => "MethodLookup(${Str.inspect(name)})"
		CallMethod({ name, site }) => "CallMethod(${Str.inspect(name)}, ${site.count.to_str()})"
		CallIndexed(site) => "CallIndexed(${site.count.to_str()})"
		CallMethodSpread({ name, written: _, at: _ }) => "CallMethodSpread(${Str.inspect(name)})"
		Construct({ count, callee: _, at: _ }) => "Construct(${count.to_str()})"
		IterStart(_) => "IterStart"
		IterNext({ slot, exit }) => "IterNext(${slot.to_str()}, ${exit.to_str()})"
		DestructureItems(_) => "DestructureItems"
		ItemOf(place) => "ItemOf(${place.to_str()})"
		ItemsFrom(place) => "ItemsFrom(${place.to_str()})"
		CheckDestructurable({ properties, origin: _, at: _ }) => tag_text(
			"CheckDestructurable",
			[Str.inspect(properties.map(|p| p.key))],
		)
		PropertiesLeft({ keys, at: _ }) => "PropertiesLeft(${Str.inspect(keys)})"
		EnterTry({ handler, kind }) => "EnterTry(${handler.to_str()}, ${handling_text(kind)})"
		LeaveTry => "LeaveTry"
		Rethrow => "Rethrow"
		Return => "Return"
		Throw(_) => "Throw"
		Finish => "Finish"
	}

## A tag and its payload's parts, as Roc writes a tag: `Name(a, b)`.
tag_text : Str, List(Str) -> Str
tag_text = |name, parts| "${name}(${Str.join_with(parts, ", ")})"

kind_text : Bytecode.Kind -> Str
kind_text = |kind|
	match kind {
		Mutable => "Mutable"
		Fixed => "Fixed"
	}

## What a `try`'s handler is for, as `EnterTry`'s line writes it.
handling_text : Bytecode.Handling -> Str
handling_text = |handling|
	match handling {
		Catching => "Catching"
		Finishing => "Finishing"
	}

update_text : Bytecode.Update -> Str
update_text = |{ delta, fixity, at: _ }| {
	fixity_text = match fixity {
		Prefix => "Prefix"
		Postfix => "Postfix"
	}
	"${Str.inspect(delta)}, ${fixity_text}"
}
