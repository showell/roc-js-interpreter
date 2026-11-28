## This module reads a KavaScript program into tokens with the JavaScript
## subset's own lexer (js/roc/Lexer.roc), and keeps what that lexer's tokens
## leave out: the byte where each token starts and the byte after it ends.
## KavaScript's additions are spelled in tokens the subset already has, so
## one lexer serves both, and the places let the program's text be cut and
## patched at its tokens, every other byte left as it was written.
##
## The scan is the lexer's own (`Lexer.scan_one`, one token, run of space or
## comment a step), so a token's start is where the step began and its end
## is where the step stopped.
import js.Lexer

KavaTokens :: [].{
	Spanned : {
		kind : Lexer.TokenKind,
		line : U64,
		column : U64,
		before : Lexer.Break,
		start : U64,
		end : U64,
	}

	spanned_tokens_of : List(U8) -> Try(List(KavaTokens.Spanned), Lexer.Fault)
	spanned_tokens_of = |src| {
		if src.contains(0) {
			return Err({
				why: "a NUL byte in the source",
				line: 1,
				column: 1,
			})
		}
		var $scan = {
			at: 0,
			line: 1,
			line_start: 0,
			depth: 0,
			open_templates: [],
			tokens: [],
			before: NewLine,
		}
		var $spanned = []
		while $scan.at < src.len() {
			from = $scan.at
			stepped = Lexer.scan_one(src, $scan)?
			if stepped.tokens.len() > $scan.tokens.len() {
				why = "KavaTokens.spanned_tokens_of: a step that made a token has one"
				made = stepped.tokens.last() ?? crash why
				$spanned = $spanned.append({
					kind: made.kind,
					line: made.line,
					column: made.column,
					before: made.before,
					start: from,
					end: stepped.at,
				})
			}
			$scan = stepped
		}
		Ok(
			$spanned.append({
				kind: End,
				line: $scan.line,
				column: $scan.at - $scan.line_start + 1,
				before: NewLine,
				start: src.len(),
				end: src.len(),
			}),
		)
	}
}
