## This module holds the methods of JavaScript's strings, which the VM
## (`Vm`) calls by name (`text_method`): what each gives, and each refusal
## and its text, read and audited here as the string methods' one home.
##
## The subset has the methods that count or cut by position for ASCII text
## alone (`positional_methods`): JavaScript counts UTF-16 units, where the
## interpreter's strings are UTF-8.
##
## A method follows ValueRules' rules (its module doc): it takes the machine
## the VM lends it first, then the rest, and answers a `ValueRules.Got`. A
## string method writes nothing but the allocations its answer needs.
import Ast
import Heap
import ValueRules

StringRules :: [].{
	# The string methods that count or cut by position, which the subset has
	# for ASCII text alone: JavaScript counts UTF-16 units, where the
	# interpreter's strings are UTF-8.
	positional_methods : List(Str)
	positional_methods = [
		"charAt",
		"charCodeAt",
		"slice",
		"substring",
		"indexOf",
		"lastIndexOf",
		"at",
		"toUpperCase",
		"toLowerCase",
		"trim",
		"trimStart",
		"trimEnd",
	]

	text_method : ValueRules.Machine, Str, Str, List(Heap.Value), Ast.Where -> ValueRules.Got
	text_method = |machine, text, name, arguments, site|
		if StringRules.positional_methods.contains(name) and !ValueRules.is_ascii(text) {
			ValueRules.fault_got(
				machine,
				"unsupported: `${name}` on a string with non-ASCII text${ValueRules.line_note(site)}",
			)
		} else if name == "split" and arguments.first() == Ok(Text("")) and !ValueRules.is_ascii(text) {
			ValueRules.fault_got(
				machine,
				"unsupported: `split` into characters of a string with non-ASCII text${ValueRules.line_note(site)}",
			)
		} else {
			StringRules.text_method_of(machine, text, name, arguments, site)
		}

	text_method_of : ValueRules.Machine, Str, Str, List(Heap.Value), Ast.Where -> ValueRules.Got
	text_method_of = |machine, text, name, arguments, site| {
		text_argument = |position| match arguments.get(position) {
			Ok(Text(phrase)) => Ok(phrase)
			_ => Err(NotText)
		}
		bytes = text.to_utf8()
		count = bytes.len()
		sliced = |from, to|
			if to > from {
				Text(
					Str.from_utf8(
						bytes.sublist({ start: from, len: to - from }),
					) ?? crash "StringRules.text_method: an ASCII cut",
				)
			} else {
				Text("")
			}
		match name {
			"charAt" => match ValueRules.index_of(arguments.first() ?? Number(0.0)) {
				Ok(position) => {
					got = ValueRules.char_at(machine, text, position, site)
					match got.value {
						Undefined => { machine: machine, value: Text("") }
						_ => got
					}
				}
				Err(NotIndex) => { machine: machine, value: Text("") }
			}
			"charCodeAt" => match ValueRules.index_of(arguments.first() ?? Number(0.0)) {
				Ok(position) => match bytes.get(position) {
					Ok(byte) => { machine: machine, value: Number(byte.to_f64()) }
					Err(OutOfBounds) => { machine: machine, value: Number(0.0 / 0.0) }
				}
				Err(NotIndex) => { machine: machine, value: Number(0.0 / 0.0) }
			}
			"slice" => {
				from = ValueRules.relative_index(arguments.get(0) ?? Undefined, count, 0)
				to = ValueRules.relative_index(arguments.get(1) ?? Undefined, count, count)
				{ machine: machine, value: sliced(from, to) }
			}
			"substring" => {
				clamp = |subject, otherwise| match subject {
					Number(x) => if x.is_nan() or x < 0.0 {
						0
					} else if x >= count.to_f64() {
						count
					} else {
						x.div_trunc_by(1.0).to_u64_try() ?? 0
					}
					_ => otherwise
				}
				one_end = clamp(arguments.get(0) ?? Undefined, 0)
				other_end = clamp(arguments.get(1) ?? Undefined, count)
				{
					machine: machine,
					value: sliced(U64.min(one_end, other_end), U64.max(one_end, other_end)),
				}
			}
			"indexOf" => match text_argument(0) {
				Ok(phrase) => {
					from = StringRules.clamped_index(arguments.get(1) ?? Undefined, count)
					{ machine: machine, value: Number(StringRules.text_index_from(text, phrase, from)) }
				}
				Err(NotText) => ValueRules.fault_got(
					machine,
					"unsupported: `indexOf` of anything but a string${ValueRules.line_note(site)}",
				)
			}
			"lastIndexOf" => match (text_argument(0), arguments.len()) {
				(Ok(phrase), 1) => { machine: machine, value: Number(StringRules.text_last_index(text, phrase)) }
				_ => ValueRules.fault_got(
					machine,
					"unsupported: `lastIndexOf` of anything but a string, or from a position${ValueRules.line_note(site)}",
				)
			}
			"includes" => match text_argument(0) {
				Ok(phrase) => {
					from = StringRules.clamped_index(arguments.get(1) ?? Undefined, count)
					{ machine: machine, value: Boolean(StringRules.text_index_from(text, phrase, from) >= 0.0) }
				}
				Err(NotText) => ValueRules.fault_got(
					machine,
					"unsupported: `includes` of anything but a string${ValueRules.line_note(site)}",
				)
			}
			"startsWith" => match (text_argument(0), arguments.len()) {
				(Ok(phrase), 1) => { machine: machine, value: Boolean(text.starts_with(phrase)) }
				_ => ValueRules.fault_got(
					machine,
					"unsupported: `startsWith` of anything but a string, or from a position${ValueRules.line_note(site)}",
				)
			}
			"endsWith" => match (text_argument(0), arguments.len()) {
				(Ok(phrase), 1) => { machine: machine, value: Boolean(text.ends_with(phrase)) }
				_ => ValueRules.fault_got(
					machine,
					"unsupported: `endsWith` of anything but a string, or to a position${ValueRules.line_note(site)}",
				)
			}
			"at" => match ValueRules.at_index(arguments.first() ?? Undefined, count) {
				Ok(position) => { machine: machine, value: sliced(position, position + 1) }
				Err(OutOfRange) => { machine: machine, value: Undefined }
			}
			"trimStart" => { machine: machine, value: Text(StringRules.ascii_trimmed_at(text, Start)) }
			"trimEnd" => { machine: machine, value: Text(StringRules.ascii_trimmed_at(text, End)) }
			"replace" | "replaceAll" => match (text_argument(0), text_argument(1)) {
				(Ok(phrase), Ok(replacement)) if !replacement.contains("$") and (name == "replace" or !phrase.is_empty()) => {
					replaced = if name == "replaceAll" {
						Str.join_with(text.split_on(phrase), replacement)
					} else {
						StringRules.text_replaced_once(text, phrase, replacement)
					}
					{ machine: machine, value: Text(replaced) }
				}
				_ => ValueRules.fault_got(
					machine,
					"unsupported: `${name}` but of a string by a string without `$`, or `replaceAll` of the empty string${ValueRules.line_note(site)}",
				)
			}
			"toUpperCase" => { machine: machine, value: Text(text.with_ascii_uppercased()) }
			"toLowerCase" => { machine: machine, value: Text(text.with_ascii_lowercased()) }
			"trim" => { machine: machine, value: Text(StringRules.ascii_trimmed(text)) }
			"repeat" => match arguments.first() {
				Ok(Number(times)) if times >= 0.0 and times.div_trunc_by(1.0) == times and times < 100000000.0 => {
					{ machine: machine, value: Text(text.repeat(times.to_u64_try() ?? 0)) }
				}
				_ => ValueRules.fault_got(
					machine,
					"unsupported: `repeat` of anything but a whole number of times${ValueRules.line_note(site)}",
				)
			}
			"split" => {
				limit = match arguments.get(1) {
					Ok(Number(most)) if most >= 0.0 and most.div_trunc_by(1.0) == most => Ok(Limited(most.to_u64_try() ?? 0))
					Ok(Undefined) | Err(OutOfBounds) => Ok(Unlimited)
					_ => Err(NotLimit)
				}
				pieces = match text_argument(0) {
					Ok("") => Ok(ValueRules.characters(text))
					Ok(phrase) => Ok(text.split_on(phrase))
					Err(NotText) => Err(NotText)
				}
				match (pieces, limit) {
					(Ok(all), Ok(Unlimited)) => ValueRules.alloc(machine, Array(all.map(|piece| Text(piece))))
					(Ok(all), Ok(Limited(most))) => ValueRules.alloc(
						machine,
						Array(all.take_first(most).map(|piece| Text(piece))),
					)
					_ => ValueRules.fault_got(
						machine,
						"unsupported: `split` by anything but a string, or to a limit that is not a whole number${ValueRules.line_note(site)}",
					)
				}
			}
			"padStart" => StringRules.text_padded(machine, text, arguments, PadStart, site)
			"padEnd" => StringRules.text_padded(machine, text, arguments, PadEnd, site)
			"concat" => {
				var $out = text
				var $why = ""
				for argument in arguments {
					match ValueRules.text_of(machine.cells, argument) {
						Ok(phrase) => {
							$out = Str.concat($out, phrase)
						}
						Err(Unsupported(why)) => {
							$why = why
						}
					}
				}
				if $why == "" {
					{ machine: machine, value: Text($out) }
				} else {
					ValueRules.fault_got(machine, "${$why}${ValueRules.line_note(site)}")
				}
			}
			_ => ValueRules.fault_got(
				machine,
				"unsupported: the string method `${name}`${ValueRules.line_note(site)}",
			)
		}
	}

	# Where `phrase` first starts in `text` at `from` or after, in bytes, or
	# -1.
	text_index_from : Str, Str, U64 -> F64
	text_index_from = |text, phrase, from| {
		text_bytes = text.to_utf8()
		phrase_bytes = phrase.to_utf8()
		if phrase_bytes.len() > text_bytes.len() {
			-1.0
		} else {
			var $i = from
			var $found = -1.0
			while $found < 0.0 and $i + phrase_bytes.len() <= text_bytes.len() {
				if text_bytes.sublist({ start: $i, len: phrase_bytes.len() }) == phrase_bytes {
					$found = $i.to_f64()
				}
				$i = $i + 1
			}
			$found
		}
	}

	# Where `phrase` last starts in `text`, in bytes, or -1.
	text_last_index : Str, Str -> F64
	text_last_index = |text, phrase| {
		text_bytes = text.to_utf8()
		phrase_bytes = phrase.to_utf8()
		if phrase_bytes.len() > text_bytes.len() {
			-1.0
		} else {
			var $i = text_bytes.len() - phrase_bytes.len() + 1
			var $found = -1.0
			while $found < 0.0 and $i > 0 {
				$i = $i - 1
				if text_bytes.sublist({ start: $i, len: phrase_bytes.len() }) == phrase_bytes {
					$found = $i.to_f64()
				}
			}
			$found
		}
	}

	# A position argument as a string method clamps it, within 0 and `count`.
	clamped_index : Heap.Value, U64 -> U64
	clamped_index = |subject, count|
		match subject {
			Number(x) => if x.is_nan() or x <= 0.0 {
				0
			} else if x >= count.to_f64() {
				count
			} else {
				x.div_trunc_by(1.0).to_u64_try() ?? 0
			}
			_ => 0
		}

	# `text` with the first `phrase` in it replaced, as `replace` does.
	text_replaced_once : Str, Str, Str -> Str
	text_replaced_once = |text, phrase, replacement| {
		found = StringRules.text_index_from(text, phrase, 0)
		if found < 0.0 {
			text
		} else {
			bytes = text.to_utf8()
			at = found.to_u64_try() ?? 0
			before = bytes.sublist({ start: 0, len: at })
			after = bytes.drop_first(at + phrase.count_utf8_bytes())
			Str.from_utf8(
				List.concat(List.concat(before, replacement.to_utf8()), after),
			) ?? crash "StringRules.text_replaced_once: whole characters around a whole phrase"
		}
	}

	ascii_trimmed : Str -> Str
	ascii_trimmed = |text| StringRules.ascii_trimmed_at(text, Both)

	ascii_trimmed_at : Str, [Start, End, Both] -> Str
	ascii_trimmed_at = |text, ends| {
		bytes = text.to_utf8()
		is_space = |byte| byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 11 or byte == 12
		var $from = 0
		while ends != End and $from < bytes.len() and is_space(bytes.get($from) ?? crash "StringRules.ascii_trimmed: inside the text") {
			$from = $from + 1
		}
		var $to = bytes.len()
		while ends != Start and $to > $from and is_space(bytes.get($to - 1) ?? crash "StringRules.ascii_trimmed: inside the text") {
			$to = $to - 1
		}
		Str.from_utf8(
			bytes.sublist({ start: $from, len: $to - $from }),
		) ?? crash "StringRules.ascii_trimmed: an ASCII cut"
	}

	Side : [PadStart, PadEnd]

	text_padded : ValueRules.Machine, Str, List(Heap.Value), StringRules.Side, Ast.Where -> ValueRules.Got
	text_padded = |machine, text, arguments, side, site| {
		fill_given = match arguments.get(1) {
			Ok(Text(given)) => Ok(given)
			Err(OutOfBounds) => Ok(" ")
			_ => Err(NotText)
		}
		match (arguments.first(), fill_given) {
			(Ok(Number(wanted)), Ok(pad_text)) if ValueRules.is_ascii(text) and ValueRules.is_ascii(pad_text) and wanted.div_trunc_by(1.0) == wanted and wanted < 100000000.0 => {
				count = text.count_utf8_bytes()
				target = if wanted < 0.0 {
					0
				} else {
					wanted.to_u64_try() ?? 0
				}
				if target <= count or pad_text.is_empty() {
					{ machine: machine, value: Text(text) }
				} else {
					need = target - count
					fill_bytes = pad_text.to_utf8()
					copies = need // fill_bytes.len() + 1
					pad = Str.from_utf8(
						pad_text.repeat(copies).to_utf8().sublist({ start: 0, len: need }),
					) ?? crash "StringRules.text_padded: an ASCII cut"
					match side {
						PadStart => { machine: machine, value: Text(Str.concat(pad, text)) }
						PadEnd => { machine: machine, value: Text(Str.concat(text, pad)) }
					}
				}
			}
			_ => ValueRules.fault_got(
				machine,
				"unsupported: `padStart` or `padEnd` other than to a whole length with ASCII text${ValueRules.line_note(site)}",
			)
		}
	}
}
