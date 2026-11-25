## This module assembles the runtime's whole machine code, the list of
## statements every compiled program carries after its own: Runtime's
## routines, then inspect's, then the collections', then the timers', then
## the texts.
##
## It stands apart from Runtime, its one caller being `Lowering`, because
## the parts it puts together import Runtime for the routines' names and
## labels (the texts, the timers, the collections and inspect now, and the
## array methods, bound for a module of their own, later), and Roc forbids
## the import cycle Runtime would make by listing them itself: so the list
## of every part lives one module above them all.
import Assembly
import Collections
import Inspect
import Runtime
import RuntimeTexts
import Timers

RuntimeCode :: [].{

	## Every routine, Runtime's, inspect's, the collections', then the
	## timers', then every text under its label.
	items : List(Assembly.Statement)
	items =
		Runtime.routine_items
			.concat(Inspect.items)
			.concat(Collections.items)
			.concat(Timers.items)
			.concat(RuntimeTexts.text_statements)
}
