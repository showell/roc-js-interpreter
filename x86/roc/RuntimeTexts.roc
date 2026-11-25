## This module holds the texts the runtime writes and stops with (every
## message and word, each under its `runtime_text_` label) and
## `text_statements`, which lays their bytes down after the routines.
##
## It stands apart from Runtime, its one caller being `RuntimeCode`,
## because the texts' labels come from Runtime's label functions
## (`error_name_label`, `new_required_text`, `text_label`), so it imports
## Runtime; Roc forbids an import cycle, so Runtime cannot list it in its
## own routines, and `RuntimeCode` puts the two together.
import Assembly
import Runtime
import RuntimeBuilders

RuntimeTexts :: [].{

	## The texts' bytes, each a string as the heap holds one: its length in
	## 8 bytes, then its bytes, and last the error's key.
	text_statements : List(Assembly.Statement)
	text_statements = {
		var $out = []
		for (label, text) in texts {
			$out = $out.concat([Mark(label), Data(Runtime.string_data(text))])
		}
		# The error's key: one byte, 0xFF, which no string a program writes
		# holds, since a string here is ASCII.
		# An instance's key, 0xFE, the same way.
		$out.concat([
			Mark(RuntimeBuilders.error_mark),
			Data([1, 0, 0, 0, 0, 0, 0, 0, 0xFF]),
			Mark(RuntimeBuilders.instance_mark),
			Data([1, 0, 0, 0, 0, 0, 0, 0, 0xFE]),
		])
	}
}

## Every text, with its label.
texts : List((Str, Str))
texts = [
	(Runtime.text_label(Space), " "),
	(Runtime.text_label(Newline), "\n"),
	("runtime_text_undefined", "undefined"),
	("runtime_text_null", "null"),
	("runtime_text_false", "false"),
	("runtime_text_true", "true"),
	("runtime_text_infinity", "Infinity"),
	("runtime_text_negative_infinity", "-Infinity"),
	("runtime_text_not_a_number", "NaN"),
	("runtime_text_negative_zero", "-0"),
	(
		"runtime_text_not_written",
		Str.concat(
			"x86: console.log of a number that is not an integer",
			" of at most 2^53 is not compiled yet\n",
		),
	),
	("runtime_text_stack_overflow", "RangeError: Maximum call stack size exceeded\n"),
	("runtime_text_call_stack", "Maximum call stack size exceeded"),
	("runtime_text_name", "name"),
	("runtime_text_size", "size"),
	("runtime_text_entry_before", "Iterator value "),
	("runtime_text_entry_after", " is not an entry object"),
	("runtime_text_object_map", "[object Map]"),
	("runtime_text_object_set", "[object Set]"),
	("runtime_text_map_open", "Map("),
	("runtime_text_set_open", "Set("),
	("runtime_text_size_close", ") "),
	("runtime_text_empty_map", "Map(0) {}"),
	("runtime_text_empty_set", "Set(0) {}"),
	("runtime_text_deep_map", "[Map]"),
	("runtime_text_deep_set", "[Set]"),
	("runtime_text_arrow", " => "),
	(Runtime.new_required_text("Map"), "Constructor Map requires 'new'"),
	(Runtime.new_required_text("Set"), "Constructor Set requires 'new'"),
	(
		"runtime_text_callbacks_most",
		Str.concat(
			"x86: 100,000 timer callbacks have run,",
			" and an interval never cleared runs for good in node\n",
		),
	),
	(
		"runtime_text_collection_method",
		"x86: this method of a Map, a Set or an iterator is not compiled yet\n",
	),
	(
		"runtime_text_iterator_written",
		Str.concat(
			"x86: console.log of an iterator or a timer,",
			" or a string made of one, is not compiled yet\n",
		),
	),
	("runtime_text_cannot_read", "Cannot read properties of "),
	(Runtime.constant_assigned_text, "Assignment to constant variable."),
	("runtime_text_cannot_set", "Cannot set properties of "),
	("runtime_text_reading", " (reading '"),
	("runtime_text_setting", " (setting '"),
	("runtime_text_quote_closed", "')"),
	("runtime_text_message", "message"),
	(Runtime.error_name_label("Error"), "Error"),
	(Runtime.error_name_label("TypeError"), "TypeError"),
	(Runtime.error_name_label("RangeError"), "RangeError"),
	(Runtime.error_name_label("ReferenceError"), "ReferenceError"),
	(Runtime.error_name_label("SyntaxError"), "SyntaxError"),
	(
		"runtime_text_uncaught",
		Str.concat(
			"x86: a throw that nothing catches, which node reports with its source line,",
			" is not compiled yet\n",
		),
	),
	(
		"runtime_text_error_written",
		"x86: console.log of an error, which node writes with its stack, is not compiled yet\n",
	),
	(
		"runtime_text_instance_written",
		Str.concat(
			"x86: console.log of a class's instance, which node writes with its class's name,",
			" is not compiled yet\n",
		),
	),
	(
		"runtime_text_instance_listed",
		"x86: a class's instance listed or spread is not compiled yet\n",
	),
	(
		"runtime_text_out_of_memory",
		"x86: out of memory: the heap of 1 GiB is full, and no collector runs yet\n",
	),
	("runtime_text_no_heap", "x86: the heap could not be mapped\n"),
	("runtime_text_length", "length"),
	("runtime_text_zero", "0"),
	(
		"runtime_text_remainder",
		"x86: `%` of numbers that are not whole numbers of at most 2^53 is not compiled yet\n",
	),
	(
		"runtime_text_not_iterable",
		Str.concat(
			"x86: a `for ... of` or an array pattern over a value that is neither",
			" an array nor a string is not compiled yet\n",
		),
	),
	("runtime_text_empty_array", "[]"),
	("runtime_text_comma", ","),
	("runtime_text_empty", ""),
	(
		"runtime_text_empty_reduce",
		Str.concat(
			"x86: `reduce` of an empty array with no first value,",
			" which throws in node, is not compiled yet\n",
		),
	),
	(
		"runtime_text_slice_place",
		"x86: `slice` from a place that is not a number is not compiled yet\n",
	),
	("runtime_text_empty_object", "{}"),
	(
		"runtime_text_wide_char",
		"x86: `String.fromCharCode` of a code past ASCII is not compiled yet\n",
	),
	(
		"runtime_text_not_destructurable",
		"x86: an object pattern of null or undefined, which throws in node, is not compiled yet\n",
	),
	("runtime_text_clock", "x86: the kernel's clock could not be read for `Date.now()`\n"),
	("runtime_text_type_number", "number"),
	("runtime_text_type_string", "string"),
	("runtime_text_type_boolean", "boolean"),
	("runtime_text_type_object", "object"),
	("runtime_text_type_function", "function"),
	(
		"runtime_text_power",
		Str.concat(
			"x86: `**` of numbers that are not whole, with a negative exponent,",
			" or past 2^53 in size, is not compiled yet\n",
		),
	),
	("runtime_text_deep_array", "[Array]"),
	("runtime_text_deep_object", "[Object]"),
	("runtime_text_colon", ": "),
	(
		"runtime_text_not_an_object",
		"x86: a property written on a value that is not an object is not compiled yet\n",
	),
	(
		"runtime_text_integer_key",
		"x86: an object with an integer key of ten digits or more is not compiled yet\n",
	),
	(
		"runtime_text_index_not_compiled",
		"x86: an index of this kind of value, or of this kind, is not compiled yet\n",
	),
	(
		"runtime_text_numbers_read_not_compiled",
		"x86: an array of numbers read where it has no item is not compiled yet\n",
	),
	(
		"runtime_text_array_hole",
		"x86: an array written past its end, leaving holes, is not compiled yet\n",
	),
	(
		"runtime_text_not_an_array",
		"x86: an array method called on a value that is not an array is not compiled yet\n",
	),
	(
		"runtime_text_many",
		"x86: console.log of an array or object of more than 100 items is not compiled yet\n",
	),
	(
		"runtime_text_object_keys",
		Str.concat(
			"x86: `Object.keys`, `values` or `entries` of a value that is not a plain object",
			" is not compiled yet\n",
		),
	),
	("runtime_text_object_object", "[object Object]"),
	(
		"runtime_text_rest_listed",
		"x86: an object pattern's rest of an array or a string is not compiled yet\n",
	),
	(
		"runtime_text_spread_error",
		"x86: an error's properties spread or taken by a pattern's rest are not compiled yet\n",
	),
	(
		"runtime_text_index_of_place",
		"x86: `indexOf` or `includes` from a place that is not a number is not compiled yet\n",
	),
	(
		"runtime_text_index_of_sought",
		Str.concat(
			"x86: a string's `indexOf` or `includes` of a value that is not a string",
			" is not compiled yet\n",
		),
	),
	(
		"runtime_text_sort_answer",
		Str.concat(
			"x86: a `sort` whose function gives a value that is not a number, a boolean",
			" or undefined is not compiled yet\n",
		),
	),
	(
		"runtime_text_split_separator",
		"x86: `split` at a value that is not a string is not compiled yet\n",
	),
	(
		"runtime_text_text_of_function",
		"x86: a string made of a function, its source's text, is not compiled yet\n",
	),
	(
		"runtime_text_not_a_function",
		Str.concat(
			"x86: a call of a value that is not a function,",
			" which throws in node, is not compiled yet\n",
		),
	),
	(
		"runtime_text_add_not_compiled",
		"x86: `+` of a function, which node makes its source's text, is not compiled yet\n",
	),
	(
		"runtime_text_arithmetic_not_compiled",
		"x86: arithmetic on a value that is not a number is not compiled yet\n",
	),
	(
		"runtime_text_compare_not_compiled",
		"x86: an order of values that are not two numbers or two strings is not compiled yet\n",
	),
	("runtime_text_property_not_compiled", "x86: this property read is not compiled yet\n"),
	(
		"runtime_text_value_not_written",
		"x86: console.log of this kind of value is not compiled yet\n",
	),
]
