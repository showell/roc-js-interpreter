## This module writes what KavaScript's counted mode adds to a checked
## build: a counter of the work the program does, run by node, which the
## cost runner (kava/cost.shale) reads at several sizes to check each
## function's `cost O(...)` claim.
##
## **THE COUNT IS ONE NUMBER, AND EACH PLACE THAT ADDS TO IT IS A SITE:**
##
## - a trip of a loop of ordinary code counts one;
## - a call of a builtin the cost table names (`builtins`) counts its cost
##   at run time: `xs.includes(x)` counts `xs.length`, `m.get(k)` one;
## - a spread `...v` counts `v`'s length;
## - a string grown by name, `s += e` as a statement or `s = s + e`, counts
##   `s`'s length before it grows.
##
## A function with a cost claim is framed: from its entry to its every way
## out (a `try` and its `finally`), the count it adds is its own, so the
## work of every call it makes is in it, an unannotated helper's and a
## costed one's alike, and a costed helper is measured again on its own,
## with its own claim. A recursive call is inside the outermost one's frame,
## and only the outermost is measured. Each site's own count is kept too, so
## a claim that fails can say where the count grows.
##
## Ghosts and clauses are no work: their loops and calls count nothing.
## Every edit is written on one line, so the program's lines stay where
## they were.
import Edits
import KavaChecks
import KavaState

KavaCost :: [].{

	## How a builtin's cost is measured at the call, before the call (the
	## receiver's length, as `shift` finds it) or after it (the result's).
	Measure : [
		ReceiverLength,
		ReceiverAndArgumentLengths,
		ReceiverAndArgumentCount,
		ResultLength,
		One,
	]

	## A method, the classes whose method of that name it is, and its cost.
	Builtin : {
		method : Str,
		owners : List(Str),
		measure : KavaCost.Measure,
	}

	## **THE COST TABLE.** A length is an array's or a string's `length`, a
	## Map's or a Set's `size`, and an object's count of keys.
	##
	## - `includes`, `indexOf` and `lastIndexOf` walk the receiver;
	## - `shift` moves every item down, and `join` writes every item;
	## - `unshift` and `splice` move the receiver's items and add their
	##   arguments;
	## - `concat` copies the receiver and every argument;
	## - `slice` copies what it returns;
	## - `map`, `filter`, `forEach` and `reduce` visit every item (and the
	##   callback's own work counts where it is done);
	## - a Map's `get`, `set`, `has` and `delete`, and a Set's `has`, `add`
	##   and `delete`, are hashed: one each.
	builtins : List(KavaCost.Builtin)
	builtins = [
		{
			method: "includes",
			owners: ["Array", "String"],
			measure: ReceiverLength,
		},
		{
			method: "indexOf",
			owners: ["Array", "String"],
			measure: ReceiverLength,
		},
		{
			method: "lastIndexOf",
			owners: ["Array", "String"],
			measure: ReceiverLength,
		},
		{
			method: "shift",
			owners: ["Array"],
			measure: ReceiverLength,
		},
		{
			method: "join",
			owners: ["Array"],
			measure: ReceiverLength,
		},
		{
			method: "unshift",
			owners: ["Array"],
			measure: ReceiverAndArgumentCount,
		},
		{
			method: "splice",
			owners: ["Array"],
			measure: ReceiverAndArgumentCount,
		},
		{
			method: "concat",
			owners: ["Array", "String"],
			measure: ReceiverAndArgumentLengths,
		},
		{
			method: "slice",
			owners: ["Array", "String"],
			measure: ResultLength,
		},
		{
			method: "map",
			owners: ["Array"],
			measure: ReceiverLength,
		},
		{
			method: "filter",
			owners: ["Array"],
			measure: ReceiverLength,
		},
		{
			method: "forEach",
			owners: ["Array"],
			measure: ReceiverLength,
		},
		{
			method: "reduce",
			owners: ["Array"],
			measure: ReceiverLength,
		},
		{
			method: "get",
			owners: ["Map"],
			measure: One,
		},
		{
			method: "set",
			owners: ["Map"],
			measure: One,
		},
		{
			method: "has",
			owners: ["Map", "Set"],
			measure: One,
		},
		{
			method: "add",
			owners: ["Set"],
			measure: One,
		},
		{
			method: "delete",
			owners: ["Map", "Set"],
			measure: One,
		},
	]

	## A measure as the counter's JavaScript names it.
	measure_word : KavaCost.Measure -> Str
	measure_word = |measure| match measure {
		ReceiverLength => "receiver"
		ReceiverAndArgumentLengths => "receiver and argument lengths"
		ReceiverAndArgumentCount => "receiver and argument count"
		ResultLength => "result"
		One => "one"
	}

	## Whether the cost table names a method.
	is_costed_method : Str -> Bool
	is_costed_method = |method| KavaCost.builtins.any(|builtin| builtin.method == method)

	## The cost table as the counter's JavaScript holds it: a
	## `[method, owner, measure]` an owner.
	table_literal : Str
	table_literal = {
		var $rows = []
		for builtin in KavaCost.builtins {
			for owner in builtin.owners {
				word = KavaCost.measure_word(builtin.measure)
				$rows = $rows.append("[\"${builtin.method}\", \"${owner}\", \"${word}\"]")
			}
		}
		"[${Str.join_with($rows, ", ")}]"
	}

	# ---- sites -----------------------------------------------------------------

	## A site as the counter's table describes it, and what is counted
	## there: a loop's trips, or a site the reader recorded.
	Charge : {
		line : U64,
		what : Str,
		method : Str,
		loop_line : U64,
		counted : [Trips(KavaState.LoopBody), Charged(KavaState.Site)],
	}

	## The line of the innermost loop holding a token, 0 for none.
	loop_line_of : KavaState.State, U64 -> U64
	loop_line_of = |reader, index| {
		var $line = 0
		var $first = 0
		for body in reader.loop_bodies {
			if body.first <= index and index < body.past and body.first >= $first {
				$line = body.line
				$first = body.first
			}
		}
		$line
	}

	## The charge of a site the reader recorded, when it is one the counter
	## charges: a method the table doesn't name is no site.
	site_charge : KavaState.State, KavaState.Site -> Try(KavaCost.Charge, [Uncharged])
	site_charge = |reader, site| {
		what = match site.kind {
			Called(method) if KavaCost.is_costed_method(method) => Ok("`${method}`")
			Called(_) => Err(Uncharged)
			Spread => Ok("a spread `...`")
			Grown(name) => Ok("the string `${name}` grown")
			GrownBy(name) => Ok("the string `${name}` grown")
		}?
		method = match site.kind {
			Called(name) => name
			_ => ""
		}
		Ok({
			line: KavaState.token_at(reader, site.index).line,
			what: what,
			method: method,
			loop_line: KavaCost.loop_line_of(reader, site.index),
			counted: Charged(site),
		})
	}

	## Every site the program has, loops first, numbered from 1 in this
	## order.
	charges : KavaState.State -> List(KavaCost.Charge)
	charges = |reader| {
		var $found = reader.loop_bodies.map(
			|body| {
				line: body.line,
				what: "a trip of the loop",
				method: "",
				loop_line: body.line,
				counted: Trips(body),
			},
		)
		for site in reader.sites {
			match KavaCost.site_charge(reader, site) {
				Ok(charge) => {
					$found = $found.append(charge)
				}
				Err(Uncharged) => {}
			}
		}
		$found
	}

	## The edits that count at a site, numbered `number`: a loop's tick at
	## the head of its body, inside its block or in a block made for it; a
	## method's call by the site's key (`xs[$kava_key[3]](x)`, which finds
	## the counted builtin, or the receiver's own method of that name); a
	## spread's value through the counter (`...$kava_spread[3] = v`); and a
	## string's length counted before it grows.
	charge_edits : KavaState.State, { charge : KavaCost.Charge, number : U64 } -> List(Edits.Edit)
	charge_edits = |reader, numbered| {
		site = numbered.number.to_str()
		match numbered.charge.counted {
			Trips(body) => {
				first = KavaState.token_at(reader, body.first)
				last = KavaState.token_at(reader, body.past - 1)
				tick = "$kava_tick(${site});"
				if first.kind == Punct("{") {
					[Edits.insertion(first.end, " ${tick}")]
				} else {
					[Edits.insertion(first.start, "{ ${tick} "), Edits.insertion(last.end, " }")]
				}
			}
			Charged(recorded) => {
				here = KavaState.token_at(reader, recorded.index)
				before = KavaState.token_at(reader, recorded.index.minus_saturated(1))
				match recorded.kind {
					Called(_) => {
						start = if before.kind == Punct(".") {
							before.start
						} else {
							here.start
						}
						[
							{
								start: start,
								end: here.end,
								text: "[$kava_key[${site}]]",
							},
						]
					}
					Spread => [Edits.insertion(here.end, "$kava_spread[${site}] = ")]
					Grown(name) => [Edits.insertion(here.start, "$kava_grow(${site}, ${name}), ")]
					GrownBy(name) => [
						{
							start: here.start,
							end: here.end,
							text: "$kava_grow(${site}, ${name})",
						},
					]
				}
			}
		}
	}

	# ---- the edits ---------------------------------------------------------------

	## What counted mode adds to a checked build's edits: the counter started
	## at the program's first byte, a count at every site, and a frame round
	## each costed function's body. They come after the checked edits, so at
	## one place a check is written first.
	edits : KavaState.State -> List(Edits.Edit)
	edits = |reader| {
		var $edits = [Edits.insertion(0, "$kava_cost_start(); ")]
		var $number = 1
		for charge in KavaCost.charges(reader) {
			$edits = List.concat(
				$edits,
				KavaCost.charge_edits(reader, { charge: charge, number: $number }),
			)
			$number = $number + 1
		}
		var $id = 0
		for costed in reader.cost_claims {
			$edits = List.concat($edits, KavaCost.frame_edits(costed, $id))
			$id = $id + 1
		}
		$edits
	}

	## The frame round a costed function's body, the function `id` of the
	## counter's table: entered after its `{`, with its sizes as its `where`
	## gives them, and left at its every way out.
	frame_edits : KavaState.Costed, U64 -> List(Edits.Edit)
	frame_edits = |costed, id| match costed.body {
		Framed(body) => {
			number = id.to_str()
			sizes = costed.claim.wheres.map(|given| "${given.name}: (${given.code})")
			frame = "$kava_frame_${number}"
			given = Str.join_with(sizes, ", ")
			entered = "const ${frame} = $kava_enter(${number}, { ${given} });"
			left = "} finally { $kava_leave(${number}, ${frame}); } "
			[Edits.insertion(body.open, " ${entered} try {"), Edits.insertion(body.close, left)]
		}
		Unframed => []
	}

	# ---- the counter -----------------------------------------------------------

	## The counter's tables for this program: its sites, its costed
	## functions and its loops' claims, each a function, hoisted.
	tables : KavaState.State -> Str
	tables = |reader| {
		var $sites = ["null"]
		for charge in KavaCost.charges(reader) {
			method = if charge.method == "" {
				"undefined"
			} else {
				KavaChecks.string_literal(charge.method)
			}
			fields = [
				"line: ${charge.line.to_str()}",
				"what: ${KavaChecks.string_literal(charge.what)}",
				"method: ${method}",
				"loop: ${charge.loop_line.to_str()}",
			]
			$sites = $sites.append("{ ${Str.join_with(fields, ", ")} }")
		}
		var $functions = []
		var $id = 0
		for costed in reader.cost_claims {
			$functions = $functions.append(KavaCost.function_row(costed, $id))
			$id = $id + 1
		}
		loop_claims = reader.loop_claims.map(|line| line.to_str())
		Str.join_with(
			[
				"function $kava_cost_table() {",
				"  return ${KavaCost.table_literal};",
				"}",
				"function $kava_cost_sites() {",
				"  return [${Str.join_with($sites, ", ")}];",
				"}",
				"function $kava_cost_functions() {",
				"  return [",
				Str.join_with($functions, "\n"),
				"  ];",
				"}",
				"function $kava_cost_loop_claims() {",
				"  return [${Str.join_with(loop_claims, ", ")}];",
				"}",
				"",
			],
			"\n",
		)
	}

	## A costed function as the counter's table holds it, the function `id`:
	## its claim, and the function and its `size` generator found by name
	## when the measurement runs, after the program.
	function_row : KavaState.Costed, U64 -> Str
	function_row = |costed, id| {
		name = costed.name
		wheres = costed.claim.wheres.map(|given| "${given.name} = ${given.code}")
		run = if name == "" {
			"null"
		} else {
			"typeof ${name} === \"function\" ? ${name} : null"
		}
		size = if name == "" {
			"null"
		} else {
			"typeof $kava_size_${name} === \"function\" ? $kava_size_${name} : null"
		}
		framed = match costed.body {
			Framed(_) => "true"
			Unframed => "false"
		}
		fields = [
			"id: ${id.to_str()}",
			"name: ${KavaChecks.string_literal(name)}",
			"line: ${costed.claim.line.to_str()}",
			"claim: ${KavaChecks.string_literal(costed.claim.claim)}",
			"where: ${KavaChecks.string_literal(Str.join_with(wheres, ", "))}",
			"framed: ${framed}",
			"run: ${run}",
			"size: ${size}",
		]
		"    { ${Str.join_with(fields, ", ")} },"
	}

	## What counted mode writes after the checked build's helpers: the
	## program's tables, the counter, and the measurement the cost runner
	## asks for with `node <file> --kava-cost <n>`, which runs each costed
	## function on its `size` generator's arguments at n, 2n, 4n and 8n and
	## prints a line `kava-cost <json>` for each, with its counts and each
	## site's.
	helpers : KavaState.State -> Str
	helpers = |reader| Str.concat(KavaCost.tables(reader), KavaCost.counter)

	## The counter itself: the functions every counted build calls, after
	## its tables. A method's site is a key (a Symbol) on each class whose
	## method of that name the table counts, which gives the counted
	## builtin, or the receiver's own method when it has another; on any other
	## receiver the key gives its method of that name, uncounted.
	counter : Str
	counter = Str.join_with(
		[
			"function $kava_cost_start() {",
			"  const sites = $kava_cost_sites();",
			"  globalThis.$kava_cost = {",
			"    total: 0, counts: new Array(sites.length).fill(0), depth: [], measured: [],",
			"  };",
			"  globalThis.$kava_key = sites.map((site, i) => Symbol(\"kava site \" + i));",
			"  globalThis.$kava_key_names = new Map();",
			"  globalThis.$kava_spread = new Proxy({}, {",
			"    set(target, key, value) {",
			"      $kava_charge(Number(key), $kava_size_of(value));",
			"      return true;",
			"    },",
			"  });",
			"  const owners = {",
			"    Array: Array.prototype, String: String.prototype,",
			"    Map: Map.prototype, Set: Set.prototype,",
			"  };",
			"  const table = $kava_cost_table();",
			"  sites.forEach((site, i) => {",
			"    if (site === null || site.method === undefined) { return; }",
			"    const key = $kava_key[i];",
			"    $kava_key_names.set(key, site.method);",
			"    Object.defineProperty(Object.prototype, key, {",
			"      get() { return this[site.method]; },",
			"    });",
			"    for (const [method, owner, measure] of table) {",
			"      if (method !== site.method) { continue; }",
			"      const original = owners[owner][method];",
			"      const charged = function (...args) {",
			"        const before = $kava_measured(measure, this, args);",
			"        const result = original.apply(this, args);",
			"        const after = measure === \"result\" ? $kava_size_of(result) : before;",
			"        $kava_charge(i, after);",
			"        return result;",
			"      };",
			"      Object.defineProperty(owners[owner], key, {",
			"        get() {",
			"          const f = this[method];",
			"          return f === original ? charged : f;",
			"        },",
			"      });",
			"    }",
			"  });",
			"}",
			"function $kava_charge(site, cost) {",
			"  $kava_cost.total += cost;",
			"  $kava_cost.counts[site] += cost;",
			"}",
			"function $kava_tick(site) {",
			"  $kava_charge(site, 1);",
			"}",
			"function $kava_grow(site, s) {",
			"  if (typeof s === \"string\") { $kava_charge(site, s.length); }",
			"  return s;",
			"}",
			"function $kava_size_of(v) {",
			"  if (v === null || v === undefined) { return 0; }",
			"  if (typeof v === \"string\" || v instanceof String) { return v.length; }",
			"  if (Array.isArray(v)) { return v.length; }",
			"  if (v instanceof Map || v instanceof Set) { return v.size; }",
			"  if (typeof v === \"object\") { return Object.keys(v).length; }",
			"  return 1;",
			"}",
			"function $kava_measured(measure, self, args) {",
			"  if (measure === \"one\") { return 1; }",
			"  if (measure === \"result\") { return 0; }",
			"  let cost = $kava_size_of(self);",
			"  if (measure === \"receiver and argument count\") { cost += args.length; }",
			"  if (measure === \"receiver and argument lengths\") {",
			"    for (const a of args) { cost += $kava_size_of(a); }",
			"  }",
			"  return cost;",
			"}",
			"function $kava_enter(id, sizes) {",
			"  const depth = $kava_cost.depth[id] || 0;",
			"  $kava_cost.depth[id] = depth + 1;",
			"  if (depth > 0) { return null; }",
			"  const counts = Array.from($kava_cost.counts);",
			"  return { sizes: sizes, total: $kava_cost.total, counts: counts };",
			"}",
			"function $kava_leave(id, frame) {",
			"  $kava_cost.depth[id] -= 1;",
			"  if (frame === null) { return; }",
			"  const counts = Array.from($kava_cost.counts, (c, i) => c - frame.counts[i]);",
			"  const count = $kava_cost.total - frame.total;",
			"  $kava_cost.measured[id] = { sizes: frame.sizes, count: count, counts: counts };",
			"}",
			"function $kava_cost_fault(f) {",
			"  if (f.name === \"\") {",
			"    return \"it has no name, which its `size` generator would name\";",
			"  }",
			"  if (!f.framed) {",
			"    return \"its body is an expression: give it a block to be measured\";",
			"  }",
			"  if (f.run === null) { return \"it is no top-level function\"; }",
			"  if (f.size === null) {",
			"    return \"it has no `size \" + f.name + \"(n) { ... }` generator\";",
			"  }",
			"  return null;",
			"}",
			"function $kava_cost_report(f, base) {",
			"  const report = {",
			"    name: f.name, line: f.line, claim: f.claim, where: f.where,",
			"    sizes: [], ns: [], counts: [], sites: [],",
			"  };",
			"  const fault = $kava_cost_fault(f);",
			"  if (fault !== null) { throw new Error(fault); }",
			"  const per = [];",
			"  for (let k = 0, n = base; k < 4; k += 1, n *= 2) {",
			"    const args = f.size(n);",
			"    if (!Array.isArray(args)) {",
			"      throw new Error(\"size(\" + n + \") gave no array\");",
			"    }",
			"    $kava_cost.measured[f.id] = null;",
			"    f.run(...args);",
			"    const m = $kava_cost.measured[f.id];",
			"    if (m === null) {",
			"      throw new Error(\"its call at size \" + n + \" wasn't measured\");",
			"    }",
			"    report.sizes.push(n);",
			"    report.ns.push(m.sizes.n === undefined ? null : m.sizes.n);",
			"    report.counts.push(m.count);",
			"    per.push(m.counts);",
			"  }",
			"  const sites = $kava_cost_sites();",
			"  for (let i = 1; i < sites.length; i += 1) {",
			"    const counts = per.map((c) => c[i]);",
			"    if (counts.some((c) => c > 0)) {",
			"      const site = sites[i];",
			"      const loop = site.loop;",
			"      report.sites.push({ line: site.line, what: site.what, loop, counts });",
			"    }",
			"  }",
			"  return report;",
			"}",
			"function $kava_cost_measure(base) {",
			"  for (const f of $kava_cost_functions()) {",
			"    let report;",
			"    try {",
			"      report = $kava_cost_report(f, base);",
			"    } catch (e) {",
			"      const said = String(e && e.message);",
			"      const { name, line, claim, where } = f;",
			"      report = { name, line, claim, where, fault: said };",
			"    }",
			"    console.log(\"kava-cost \" + JSON.stringify(report));",
			"  }",
			"  for (const line of $kava_cost_loop_claims()) {",
			"    console.log(\"kava-cost \" + JSON.stringify({ loop: line }));",
			"  }",
			"}",
			"if (typeof process === \"object\" && process.argv[2] === \"--kava-cost\") {",
			"  $kava_cost_measure(Number(process.argv[3]));",
			"}",
			"",
		],
		"\n",
	)

	expect KavaCost.builtins.map(|builtin| builtin.method).len() == 18

	expect {
		methods = KavaCost.builtins.map(|builtin| builtin.method)
		methods.all(|method| methods.keep_if(|other| other == method).len() == 1)
	}

	expect {
		known = ["Array", "String", "Map", "Set"]
		is_known = |owner| known.contains(owner)
		KavaCost.builtins.all(|builtin| !builtin.owners.is_empty() and builtin.owners.all(is_known))
	}

	expect {
		is_hashed = |owner| owner == "Map" or owner == "Set"
		hashed = KavaCost.builtins.keep_if(|builtin| builtin.owners.any(is_hashed))
		hashed.map(|builtin| builtin.method) == [
			"get",
			"set",
			"has",
			"add",
			"delete",
		] and hashed.all(|builtin| builtin.measure == One)
	}

	expect {
		first = "[\"includes\", \"Array\", \"receiver\"]"
		second = "[\"includes\", \"String\", \"receiver\"]"
		KavaCost.table_literal.starts_with("[${first}, ${second}, ")
	}

}
