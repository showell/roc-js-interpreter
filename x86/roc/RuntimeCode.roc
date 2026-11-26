## This module assembles the runtime's whole machine code, the list of
## statements every compiled program carries after its own: Runtime's
## routines, then the object table's, then the language's, then the array methods', then inspect's,
## then the collections', then the timers', then the texts.
##
## It stands apart from Runtime, its one caller being `Lowering`, because
## the parts it puts together import Runtime for the routines' names and
## labels (the texts, the timers, the collections, inspect, the array
## methods and the language's routines), and Roc forbids the import cycle
## Runtime would make by listing them itself: so the list of every part
## lives one module above them all.
import ArrayMethods
import Assembly
import Collections
import Inspect
import LanguageRoutines
import ObjectTable
import Runtime
import RuntimeTexts
import Timers

RuntimeCode :: [].{

	## Every routine, Runtime's, the object table's, the language's, the array methods',
	## inspect's, the collections', then the timers', then every text under
	## its label.
	items : List(Assembly.Statement)
	items =
		Runtime.routine_items
			.concat(ObjectTable.items)
			.concat(LanguageRoutines.items)
			.concat(ArrayMethods.items)
			.concat(Inspect.items)
			.concat(Collections.items)
			.concat(Timers.items)
			.concat(RuntimeTexts.text_statements)
}
