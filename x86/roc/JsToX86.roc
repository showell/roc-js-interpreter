app [main!] { js: "../../js/roc/main.roc" }

# The JavaScript subset compiled to a static Linux x86-64 executable: the
# program is parsed and compiled to bytecode by js/roc's own front end, as
# js-vm compiles it, then lowered to machine code (Lowering.roc), assembled
# (Assembly.roc) and wrapped as an executable (Elf.roc), every byte here.
#
#   js-x86 "<program>"
#   js-x86 "<program>" inlined    # the sites Inlining put in line
#   js-x86 "<program>" versioned  # the loops Versioning placed twice
#   js-x86 "<program>" guardsflip # the executable, every side exit also taken often
#   js-x86 "<program>" labels     # each label's offset in the code
#   js-x86 "<program>" posts      # how the post-passes ran (RuntimePosts)
#   js-x86 "<program>" counted    # the executable, counting its blocks (Counter)
#   js-x86 "<program>" countmap   # each counter's place in the uncounted code
#
# It runs on Roc's default platform, whose one effect writes text to
# stdout, so it prints the executable's bytes as hex (X86.hex_text: two
# lowercase digits a byte, a space between) and nothing else; x86/fib.shale
# turns the hex back into the file. A program the parser refuses, one the
# bytecode compiler refuses, and one that uses what the lowering doesn't
# compile yet each end with a line `js-x86: <why>` and exit 1.
#
#   js-x86 "<program>" stop=<phase>
#
# runs the compile only as far as one phase and prints one number of what
# it made, for x86/buildtime.shale's phase profile (x86/buildrace/PROFILE.md):
# the time of each phase is the difference of two such runs. The phases are
# in `stopped_at`.
import js.Compile
import js.Parser
import Assembly
import Counter
import Elf
import Forwarding
import Jumps
import Lowering
import Moves
import RuntimeCode
import X86

main! = |arguments| {
	match (arguments.get(0), arguments.get(1)) {
		(Ok(src), Err(_)) => write_program!(src, { flip: False })
		(Ok(src), Ok("guardsflip")) => write_program!(src, { flip: True })
		(Ok(src), Ok("inlined")) => write_inlined!(src)
		(Ok(src), Ok("versioned")) => write_versioned!(src)
		(Ok(src), Ok("labels")) => write_labels!(src)
		(Ok(src), Ok("posts")) => write_posts!(src)
		(Ok(src), Ok("counted")) => write_counted!(src)
		(Ok(src), Ok("countmap")) => write_count_map!(src)

		(Ok(src), Ok(phase)) => write_stopped!(src, phase)
		_ => {
			lowerings = "inlined | versioned | guardsflip | labels | posts"
			modes = "${lowerings} | counted | countmap | stop=<phase>"
			echo!("usage: js-x86 \"<program>\" [${modes}]\n")
			Err(Exit(2))
		}
	}
}

## The line `<phase>: <number>` for a compile stopped after `phase`.
write_stopped! : Str, Str => Try({}, [Exit(I8)])
write_stopped! = |src, phase| {
	match stopped_at(src, phase) {
		Ok(number) => {
			echo!("${phase}: ${number.to_str()}\n")
			Ok({})
		}
		Err(why) => {
			echo!("js-x86: ${why}\n")
			Err(Exit(1))
		}
	}
}

## A compile run as far as `phase`, and a number of what that phase made
## (so no phase's work can be left out as unused): `stop=start` does
## nothing, `parse`, `compile`, `lower` (Lowering with its post-passes),
## `assemble`, `elf` and `hex` each run the phases before them too. The
## rest measure one piece: `runtime-assemble` encodes the runtime's fixed
## statements alone, `runtime-posts` runs the post-passes over them alone,
## and `jumps-again`, `forwarding-again`, `moves-again` and `posts-again`
## lower the program and then run that post-pass (or all four, in
## Lowering's order) over its statements once more.
stopped_at : Str, Str -> Try(U64, Str)
stopped_at = |src, phase| {
	match phase {
		"stop=start" => Ok(0)
		"stop=parse" => {
			match Parser.program_of(src, Core) {
				Ok(_) => Ok(1)
				Err(fault) => Err(fault.why)
			}
		}
		"stop=compile" => {
			tree = Parser.program_of(src, Core).map_err(|fault| fault.why)?
			program = Compile.program(tree).map_err(|Unsupported(why)| why)?
			Ok(program.codes.len())
		}
		"stop=lower" => Ok(lowering_of(src, { flip: False })?.statements.len())
		"stop=assemble" => Ok(code_of(lowering_of(src, { flip: False })?.statements)?.len())
		"stop=elf" => Ok(
			Elf.executable(code_of(lowering_of(src, { flip: False })?.statements)?).len(),
		)
		"stop=hex" => Ok(X86.hex_text(executable_of(src)?).count_utf8_bytes())
		"stop=runtime-assemble" => Ok(code_of(RuntimeCode.items)?.len())
		"stop=runtime-posts" => Ok(posts(RuntimeCode.items).len())
		"stop=jumps-again" => Ok(
			Jumps.thread_jumps(lowering_of(src, { flip: False })?.statements).len(),
		)
		"stop=forwarding-again" => Ok(
			Forwarding.forward_loads(lowering_of(src, { flip: False })?.statements).len(),
		)
		"stop=moves-again" => Ok(
			Moves.trim_moves(lowering_of(src, { flip: False })?.statements).len(),
		)
		"stop=posts-again" => Ok(posts(lowering_of(src, { flip: False })?.statements).len())
		_ => Err("no phase ${phase}")
	}
}

## Lowering's post-passes, in its order.
posts : List(Assembly.Statement) -> List(Assembly.Statement)
posts = |statements| {
	forwarded = Forwarding.forward_loads(Jumps.thread_jumps(statements))
	Jumps.thread_jumps(Moves.trim_moves(forwarded))
}

## The code for `statements`, or why it has none.
code_of : List(Assembly.Statement) -> Try(List(U8), Str)
code_of = |statements|
	match Assembly.assemble(statements) {
		Ok(code) => Ok(code)
		Err(UnknownLabel(label)) => Err("no label ${label}")
		Err(DuplicateLabel(label)) => Err("the label ${label} is marked twice")
	}

## The executable's hex. With `flip`, js-x86's `guardsflip` torture mode,
## each side exit of a versioned loop's fast copy is also taken at every
## eighth of its tests the program makes (LoweringBasics.Versions' `flip`),
## so the exits run and the program must still print node's lines.
write_program! : Str, { flip : Bool } => Try({}, [Exit(I8)])
write_program! = |src, { flip }| {
	executable = match lowering_of(src, { flip: flip }) {
		Ok(lowered) => code_of(lowered.statements).map_ok(Elf.executable)
		Err(why) => Err(why)
	}
	match executable {
		Ok(file) => {
			echo!(X86.hex_text(file))
			Ok({})
		}
		Err(why) => {
			echo!("js-x86: ${why}\n")
			Err(Exit(1))
		}
	}
}

## The line `inlined: <sites> sites, <instructions> instructions` for a
## program that lowers:
## how many call sites Inlining put in line, and the instructions their
## bodies placed, for x86/programs.shale's held count.
write_inlined! : Str => Try({}, [Exit(I8)])
write_inlined! = |src| {
	match lowering_of(src, { flip: False }) {
		Ok(lowered) => {
			sites = lowered.inlined.sites.to_str()
			instructions = lowered.inlined.instructions.to_str()
			echo!("inlined: ${sites} sites, ${instructions} instructions\n")
			Ok({})
		}
		Err(why) => {
			echo!("js-x86: ${why}\n")
			Err(Exit(1))
		}
	}
}

## The line `versioned: <loops> loops, <instructions> instructions` for a
## program that lowers: how many loops Versioning placed twice, and the
## instructions their fast copies hold, for x86/programs.shale's held count.
write_versioned! : Str => Try({}, [Exit(I8)])
write_versioned! = |src| {
	match lowering_of(src, { flip: False }) {
		Ok(lowered) => {
			loops = lowered.versioned.loops.to_str()
			instructions = lowered.versioned.instructions.to_str()
			echo!("versioned: ${loops} loops, ${instructions} instructions\n")
			Ok({})
		}
		Err(why) => {
			echo!("js-x86: ${why}\n")
			Err(Exit(1))
		}
	}
}

## The line `posts: beside` for a program whose post-passes took the
## runtime's as done when js-x86 was built, or `posts: <why>` naming why
## the whole was passed (RuntimePosts), for x86/programs.shale's check.
write_posts! : Str => Try({}, [Exit(I8)])
write_posts! = |src| {
	match lowering_of(src, { flip: False }) {
		Ok(lowered) => {
			echo!("posts: ${lowered.posts}\n")
			Ok({})
		}
		Err(why) => {
			echo!("js-x86: ${why}\n")
			Err(Exit(1))
		}
	}
}

## A line `<offset> <label>` for each label of the program's code, the
## offset in bytes from the code's start (the executable's 0x400078), for
## reading the code back with a disassembler (x86/satrace/TRIAGE.md).
write_labels! : Str => Try({}, [Exit(I8)])
write_labels! = |src| {
	laid = match lowering_of(src, { flip: False }) {
		Ok(lowered) =>
			match Assembly.laid_out(lowered.statements) {
				Ok(it) => it
				Err(_) => {
					echo!("js-x86: the code does not assemble\n")
					return Err(Exit(1))
				}
			}
		Err(why) => {
			echo!("js-x86: ${why}\n")
			return Err(Exit(1))
		}
	}
	var $text = ""
	for (label, at) in laid.marks.to_list() {
		$text = $text.concat("${at.to_str()} ${label}\n")
	}
	echo!($text)
	Ok({})
}

## The executable of js-x86's `counted` mode (Counter): the program's code
## with a counter at each block's start, which writes `x86.counts` in its
## working folder.
write_counted! : Str => Try({}, [Exit(I8)])
write_counted! = |src| {
	made = match lowering_of(src, { flip: False }) {
		Ok(lowered) => code_of(Counter.plan(lowered.statements).counted).map_ok(Elf.executable)
		Err(why) => Err(why)
	}
	match made {
		Ok(file) => {
			echo!(X86.hex_text(file))
			Ok({})
		}
		Err(why) => {
			echo!("js-x86: ${why}\n")
			Err(Exit(1))
		}
	}
}

## Counter's map of the program's counters, for x86/cost.shale.
write_count_map! : Str => Try({}, [Exit(I8)])
write_count_map! = |src| {
	made = match lowering_of(src, { flip: False }) {
		Ok(lowered) => Counter.map_text(Counter.plan(lowered.statements))
		Err(why) => Err(why)
	}
	match made {
		Ok(text) => {
			echo!(text)
			Ok({})
		}
		Err(why) => {
			echo!("js-x86: ${why}\n")
			Err(Exit(1))
		}
	}
}

## The executable a program compiles to, or why it doesn't.
executable_of : Str -> Try(List(U8), Str)
executable_of = |src| {
	lowered = lowering_of(src, { flip: False })?
	Ok(Elf.executable(code_of(lowered.statements)?))
}

## A program's lowering, its side exits taken often with `flip`
## (`write_program!`), or why it has none.
lowering_of : Str,
{ flip : Bool } -> Try(
	{
		statements : List(Assembly.Statement),
		inlined : { sites : U64, instructions : U64 },
		versioned : { loops : U64, instructions : U64 },
		posts : Str,
	},
	Str,
)
lowering_of = |src, { flip }| {
	tree = match Parser.program_of(src, Core) {
		Ok(parsed) => parsed
		Err(fault) => {
			place = "line ${fault.line.to_str()}, column ${fault.column.to_str()}"
			return Err("${fault.why} (${place})")
		}
	}
	program = match Compile.program(tree) {
		Ok(compiled) => compiled
		Err(Unsupported(why)) => return Err(why)
	}
	match Lowering.program_lowering_with(program, { flip: flip }) {
		Ok(lowered) => Ok(lowered)
		Err(Refused(why)) => Err("refused: ${why}")
	}
}
