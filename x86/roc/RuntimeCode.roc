## This module assembles the runtime's whole machine code, the list of
## statements every compiled program carries after its own: Runtime's
## routines, then the timers', then the texts.
##
## It stands apart from Runtime, its one caller being `Lowering`, because
## the parts it puts together import Runtime for the routines' names and
## labels (the texts and the timers now, and the groups bound for modules
## of their own later), and Roc forbids the import cycle Runtime would make
## by listing them itself: so the list of every part lives one module above
## them all.
import Assembly
import Runtime
import RuntimeTexts
import Timers

RuntimeCode :: [].{

	## Every routine, Runtime's then the timers', then every text under its
	## label.
	items : List(Assembly.Statement)
	items = Runtime.routine_items.concat(Timers.items).concat(RuntimeTexts.text_statements)
}
