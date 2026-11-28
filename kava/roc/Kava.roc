app [main!] { js: "../../js/roc/main.roc" }

# KavaScript as a command: a program's text in, JavaScript out. KavaScript
# is the subset's JavaScript with additions (contracts, ghosts, types,
# ownership, costs and laws: KavaReader.roc's header), and every JavaScript
# program the subset accepts is a KavaScript program, unchanged.
#
#   kava strip <file> "<program>"
#   kava checked <file> "<program>"
#   kava counted <file> "<program>"
#
# `strip` writes the program with every addition taken out, each line where
# it was; a program with none comes out byte for byte the same. `checked`
# writes it with the checks written in (KavaChecks.roc), each failure an
# Error whose message names the clause, `<file>` and the line, and the
# functions the checks call after it. `counted` writes the checked build
# with a counter of its work (KavaCost.roc), which kava/cost.shale reads to
# check each `cost` claim. Each writes JavaScript for node, which is the
# oracle and gives the benchmarks.
#
# The program is read (KavaReader.roc), its static rules judged
# (KavaRules.roc), and its strip mode's text read by the subset's own parser,
# so what isn't an addition is held to the subset. A program refused at any
# of these ends with a line `kava: <why> (line <n>, column <n>)` and exit 1.
# It runs on Roc's default platform, whose one effect writes text to
# stdout, so the program comes as an argument (kava/kava.shale reads the
# file and writes the output).
import js.Lexer
import js.Parser
import Edits
import KavaChecks
import KavaCost
import KavaReader
import KavaRules
import KavaTokens

main! = |arguments| {
	match (
		arguments.get(0),
		arguments.get(1),
		arguments.get(2),
	) {
		(
			Ok("strip"),
			Ok(file),
			Ok(src),
		) => write_output!({
			file: file,
			text: src,
			mode: Strip,
		})
		(
			Ok("checked"),
			Ok(file),
			Ok(src),
		) => write_output!({
			file: file,
			text: src,
			mode: Check,
		})
		(
			Ok("counted"),
			Ok(file),
			Ok(src),
		) => write_output!({
			file: file,
			text: src,
			mode: Count,
		})
		_ => {
			echo!("usage: kava strip|checked|counted <file> \"<program>\"\n")
			Err(Exit(2))
		}
	}
}

Mode : [Strip, Check, Count]

## A program's text, the file it came from, and the mode to write it in.
Request : {
	file : Str,
	text : Str,
	mode : Mode,
}

write_output! : Request => Try({}, [Exit(I8)])
write_output! = |request| {
	match output_of(request) {
		Ok(text) => {
			echo!(text)
			Ok({})
		}
		Err(fault) => {
			place = "line ${fault.line.to_str()}, column ${fault.column.to_str()}"
			echo!("kava: ${fault.why} (${place})\n")
			Err(Exit(1))
		}
	}
}

## The program as `mode` writes it, or why it is refused.
output_of : Request -> Try(Str, Lexer.Fault)
output_of = |request| {
	text = request.text
	file = request.file
	src = text.to_utf8()
	tokens = KavaTokens.spanned_tokens_of(src)?
	reader = KavaReader.program({
		src: src,
		tokens: tokens,
		file: file,
	})?
	KavaRules.ghosts_kept_apart(reader)?
	KavaRules.handovers_held(reader)?
	stripped = applied_or_fault(src, reader.strip_edits)?
	match Parser.program_of(stripped, Core) {
		Ok(_) => {}
		Err(fault) => {
			return Err({ ..fault, why: "${not_in_subset}: ${fault.why}" })
		}
	}
	match request.mode {
		Strip => Ok(stripped)
		Check => {
			edits = List.concat(reader.checked_edits, KavaRules.live_reads(reader))
			if edits.is_empty() {
				Ok(text)
			} else {
				checked = applied_or_fault(src, edits)?
				ended = if checked.ends_with("\n") {
					checked
				} else {
					"${checked}\n"
				}
				Ok("${ended}${KavaChecks.helpers}")
			}
		}
		Count => {
			edits = List.concat(
				List.concat(reader.checked_edits, KavaRules.live_reads(reader)),
				KavaCost.edits(reader),
			)
			counted = applied_or_fault(src, edits)?
			ended = if counted.ends_with("\n") {
				counted
			} else {
				"${counted}\n"
			}
			Ok("${ended}${KavaChecks.helpers}${KavaCost.helpers(reader)}")
		}
	}
}

## The refusal of a program whose text without its additions the subset's
## parser refuses.
not_in_subset : Str
not_in_subset = "the program without its additions is not in the JavaScript subset"

applied_or_fault : List(U8), List(Edits.Edit) -> Try(Str, Lexer.Fault)
applied_or_fault = |src, edits| match Edits.text_with(src, edits) {
	Ok(text) => Ok(text)
	Err(Overlapping(at)) => Err({
		why: "two of KavaScript's edits overlap at byte ${at.to_str()}, a fault of kava's own",
		line: 0,
		column: 0,
	})
}
