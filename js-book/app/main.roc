## This app builds the JavaScript book, JavaScript in Roc: A Compiler and an
## Interpreter, on the book platform with roc-apps' book builder, from the
## roc-apps checkout beside this one. Its folder is the roc-js-interpreter checkout's root, so an include quotes the interpreter's code in js/ by its
## path in the repository. Its pre-step, book.shale, draws the diagrams with
## Graphviz into `js-book/build/prepared/`, and this app reads the drawings
## through the platform, and a missing one stops the build, named. The
## pre-step also writes the appendix's listings there, which this app puts in
## the manuscript before the builder reads it. A ```shot fence is a picture
## of the playground from js-book/shots/, which the pre-step puts beside the
## pages.
app [main!] {
	bb: "../../../roc-apps/book_builder/builder/main.roc",
	pf: platform "../../../roc-apps/book_builder/platform/main.roc",
	sc: "../../../roc-syntax-color/package/main.roc",
}

import pf.Book
import bb.BookText
import bb.Builder
import bb.Diagrams
import bb.Fences
import bb.Includes
import bb.Pages
import sc.SyntaxColor

main! : Str => Try(Str, Str)
main! = |_folder| {
	found = Diagrams.found({
		name: manuscript_path,
		text: read_text!(manuscript_path)?,
	}) ? |problems| Str.join_with(problems.map(|problem| "${problem}\n"), "")
	drawn = Diagrams.drawn_diagrams!(
		{
			diagrams: found.diagrams,
			folder: prepared_folder,
			manuscript: manuscript_path,
		},
		read_text!,
	)?
	manuscript = insert_listings!(found.manuscript)?
	Builder.build!(
		{ ..settings, fence_hooks: [Diagrams.hook(drawn), shot_hook] },
		|path|
			if path == manuscript_path {
				Ok(manuscript)
			} else {
				Book.read_file!(path)
			},
	)
}

manuscript_path : Str
manuscript_path = "js-book/book.md"

## The book's pictures of the playground. A fence ```shot NAME, its body the
## picture's caption, is `NAME.png` of js-book/shots/ (js-book/canvas_shots.mjs
## takes them), which book.shale copies beside the pages and holds to the
## manuscript: every shot named has its file, and every file is named.
shot_hook : Fences.Hook
shot_hook = { language: "shot", html_of: shot_html }

## A shot's figure, or why the build stops.
shot_html : Fences.Fence -> [Html(Str), Refused(Str)]
shot_html = |{ words, body }| {
	caption = BookText.escaped_text(body.trim())
	if !is_shot_name(words) {
		Refused("a shot is named by lowercase letters, digits and dashes, not `${words}`")
	} else if caption.is_empty() {
		Refused("the shot `${words}` needs its caption as the fence's body")
	} else {
		Html("<figure class=\"shot\"><img src=\"shots/${words}.png\" alt=\"${caption}\" style=\"display: block; max-width: 100%; height: auto; margin: 0 auto;\"><figcaption>${caption}</figcaption></figure>")
	}
}

## Whether a shot's name is one word of lowercase letters, digits and dashes.
is_shot_name : Str -> Bool
is_shot_name = |name| {
	bytes = name.to_utf8()
	!bytes.is_empty() and bytes.all(|b| (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9') or b == '-')
}

## Where the pre-step leaves the drawings.
prepared_folder : Str
prepared_folder = "js-book/build/prepared"

## Everything this book chooses, but its fence hook, which needs the drawings.
## Every path is the roc-js-interpreter checkout's: the book's read root is the
## checkout itself, since the book quotes the interpreter's code in js/.
settings : Builder.Settings
settings = {
	..Builder.default_settings,
	manuscript: manuscript_path,
	negatives: Lint({ words: "js-book/negative_words.txt", table: "js-book/negatives.txt" }),
	colorer: colored_code,
	look: { ..Builder.default_settings.look, dividers: parts },
}

## The book's four parts, each named above its first chapter in the contents.
## A part's title lives here alone.
parts : List(Pages.Divider)
parts = [
	{
		before: "The front end",
		level: Part,
		title: "Part I: Shared machinery",
	},
	{
		before: "The compiler to x86-64",
		level: Part,
		title: "Part II: The compiler",
	},
	{
		before: "The interpreter",
		level: Part,
		title: "Part III: The interpreter",
	},
	{
		before: "Why a compiler suits Roc",
		level: Part,
		title: "Part IV: What Roc taught",
	},
]

## Roc, JavaScript and Shale colored by roc-syntax-color, and any other
## language left as escaped text.
colored_code : Fences.Colorer
colored_code = |{ language, code }|
	match syntax_of(language) {
		Ok(syntax) => Colored(SyntaxColor.html(syntax, code))
		Err(Uncolored) => Plain
	}

## The colorer of a fence's language, as an include names it.
syntax_of : Str -> Try(SyntaxColor.Language, [Uncolored])
syntax_of = |language| match language {
	"roc" => Ok(SyntaxColor.roc)
	"javascript" => Ok(SyntaxColor.js)
	"shale" => Ok(SyntaxColor.shale)
	_ => Err(Uncolored)
}

## The manuscript with each line `{{listing NAME}}` made the lines of
## `listing-NAME.md` in the prepared folder. The pre-step writes each listing
## from a folder of js/, as includes the builder expands, so the appendix
## quotes every file there. The listings stand after the manuscript's last
## diagram, so each diagram keeps its line.
insert_listings! : Str => Try(Str, Str)
insert_listings! = |text| {
	var $out = []
	for line in text.split_on("\n") {
		match listing_of(line) {
			Ok(name) => {
				listing = read_text!("${prepared_folder}/listing-${name}.md")?
				$out = $out.append(listing.drop_suffix("\n"))
			}
			Err(NotAListing) => {
				$out = $out.append(line)
			}
		}
	}
	Ok(Str.join_with($out, "\n"))
}

## The listing a line names, when the whole line is `{{listing NAME}}` and
## NAME is one word.
listing_of : Str -> Try(Str, [NotAListing])
listing_of = |line| {
	name = line.drop_prefix("{{listing ").drop_suffix("}}")
	is_whole_line = Str.count_utf8_bytes(name) + 12 == Str.count_utf8_bytes(line)
	if is_whole_line and !name.is_empty() and !name.contains(" ") {
		Ok(name)
	} else {
		Err(NotAListing)
	}
}

## A file of the book's folder, or the build's stop naming it.
read_text! : Str => Try(Str, Str)
read_text! = |path| {
	problem_line = |problem| "${path} ${Includes.read_problem_text(problem)}\n"
	Book.read_file!(path).map_err(problem_line)
}

## A sample that each of the three languages reads its own way: `#` opens a
## comment in Roc, `--` in Shale, and `//` in JavaScript.
sample : Str
sample = "x # a\n-- b\n// c\n"

expect
	[
		("roc", SyntaxColor.roc),
		("javascript", SyntaxColor.js),
		("shale", SyntaxColor.shale),
	].all(
		|(language, syntax)| colored_code({
			language,
			code: sample,
		}) == Colored(SyntaxColor.html(syntax, sample)),
	)
expect {
	answers = [
		SyntaxColor.roc,
		SyntaxColor.js,
		SyntaxColor.shale,
	].map(|syntax| SyntaxColor.html(syntax, sample))
	answers.all(|answer| answers.count_if(|other| other == answer) == 1)
}
expect [
	"text",
	"markdown",
	"dot",
	"js",
	"",
].all(|language| colored_code({ language, code: "a < b" }) == Plain)
expect shot_html({ words: "a-1", body: "A <b>\n" }) == Html("<figure class=\"shot\"><img src=\"shots/a-1.png\" alt=\"A &lt;b&gt;\" style=\"display: block; max-width: 100%; height: auto; margin: 0 auto;\"><figcaption>A &lt;b&gt;</figcaption></figure>")
expect
	[
		{ words: "", body: "x" },
		{ words: "A", body: "x" },
		{ words: "a b", body: "x" },
		{ words: "a/b", body: "x" },
		{ words: "a", body: " \n" },
	].all(
		|fence|
			match shot_html(fence) {
				Refused(_) => Bool.True
				Html(_) => Bool.False
			},
	)
expect listing_of("{{listing corpus}}") == Ok("corpus")
expect
	[
		"{{listing }}",
		"{{listing a b}}",
		" {{listing a}}",
		"{{listing a}} ",
		"{{listing a",
		"{{file a}}",
		"listing a",
	].all(|line| listing_of(line) == Err(NotAListing))
