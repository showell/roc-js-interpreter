# The JS book: a new title and a compiler-first order (proposal)

A survey of `js-book/book.md` at master `5ef49e2`, and a proposal. Nothing
in the book is moved yet; this file is for Steve to agree or change first.
Word counts are the builder's own ("words of prose", from the last build's
`js-book/build/report.txt`, whose manuscript is byte-for-byte master's). The
builder holds every numbered chapter to 900 words (`Builder.default_settings`,
`word_limit: 900`).

## 1. What the book covers today

The book covers one repository: a bytecode VM for a JavaScript subset written
in Roc (the interpreter, `js/`), its browser playground, and an ahead-of-time
compiler of the same subset to static x86-64 executables (`js-x86`, `x86/`),
both sharing one front end. It also covers what building them taught about
Roc: the copy rule, the two backends, and the build times. The interpreter
gets 9 chapters (about 5,600 words), the compiler 5 (about 3,300), and the
Roc lessons and the rest are spread among them. The compiler arrived last
and sits at the back, after Limitations.

Today's order (the title is *A JavaScript Interpreter in Roc*):

1. **Introduction** (446): the interpreter, the subset, node as oracle, where the numbers come from, a map of the book.
2. **Motivation** (193): push Roc on performance, test its toolchain, teach what copies.
3. **How it got here** (586): the history: the tree-walker, the VM in three rounds, the page, the walker deleted, classes, "Garbage you can watch".
4. **The pipeline and the machine** (348): Lexer → Parser → Resolve → Compile → Vm; the dispatch loop; the heap as one value; the `Machine` record.
5. **Memory strategy** (896): a reference is an index, the free list, slots and boxes, the cost table, one line of JavaScript as bytecode.
6. **The garbage collector** (478): mark and sweep, shaped around the copy cliff, its roots and schedule.
7. **JavaScript's rules for values** (887): inline common cases, `ValueRules`, lending the cells, the four rules modules.
8. **A canvas in the browser** (733): the playground's API, the page, the host and its effects, the event queue and virtual clock.
9. **What copies** (559): Roc's copy rule (8 shapes), then three habits: handed on, box what is rarely written, stay under 256 bytes.
10. **Dev and release builds disagree** (825): allocation controls, dev-only copies, timings, step budgets, which build is for what.
11. **Build times** (307): RC1's slow release builds, the walker's and VM's, Jack Scully's SpecConstr pull requests.
12. **How it is tested** (267): the oracle, the controls, golden canvas logs, page_check, planted faults.
13. **Limitations** (585): runtime, language, other.
14. **The compiler to x86-64** (899, one word under the limit): its pipeline, NaN-boxing, the runtime, what it compiles.
15. **Why a compiler suits Roc** (653): the interpreter's effects against the compiler as one pure function.
16. **The compiler against node** (788): `x86/BENCH.md`'s table; start-up wins small, warm node wins large.
17. **Three compilers, one race** (424): the fib race against node and Roc-on-LLVM.
18. **What the compiler leaves to an optimizer** (554): the four ways it makes code cheaper, the plain parts, what comes next.
- **Appendix A: The playground's samples** (92) and **Appendix B: The tested programs** (35): listings, unnumbered.

## 2. The title

**Recommended: *JavaScript in Roc: A Compiler and an Interpreter*.** It names
both programs, in the book's new order, and keeps "JavaScript in Roc", the
phrase `js/README.md`'s title already uses.

Alternatives:

- *Two Ways to Run JavaScript in Roc*: plain and short, but "ways" is vaguer than the two names.
- *A JavaScript Subset in Roc, Compiled and Interpreted*: the most exact, and the longest.

The title lives in four places: `js-book/book.md` line 1, the headers of
`js-book/book.shale` and `js-book/app/main.roc`, and this repo's `README.md`
(line 10). roc-apps' `README.md` (line 32) names it too, and the live pages
take it from the front page's heading.

## 3. The proposed order

Kept means the chapter stays as it is, moved means it changes place only;
both get the light edits section 7 lists. The parts are the builder's own
dividers (`Pages.Divider`, level `Part`), set in `js-book/app/main.roc`'s
`look`.

**Front (no part)**

1. **Introduction**: kept, rewritten to name both programs (section 6).
2. **Motivation**: kept; one sentence on the compiler added, one reference repointed.
3. **How it got here**: kept, rewritten short (about 350 words), one dated line per step, both programs (section 5).

**Part I: Shared machinery**

4. **The front end** (new title): split from "The pipeline and the machine". The four shared stages (Lexer, Parser with `ClassDesugaring`, Resolve, Compile) and the `Bytecode` they make, with a new diagram of one front end feeding two back ends (Vm and Lowering, 7 nodes). It takes in the class-as-sugar paragraph from "How it got here" (a design fact, now in the history) and the frame's layout from Memory strategy's "Slots and boxes" (Compile lays out the frame, and both back ends use it). About 450 words.
5. **Roc's copy rule** (new title): split from "What copies": its first section, the eight shapes and the record and `Box` rules. Both programs lean on it (the VM's heap, the compiler's `Assembly` list), and four chapters after it cite it. About 330 words.

**Part II: The compiler**

6. **The compiler to x86-64**: moved, edited. Its second paragraph, the dated history (hello world at `c3ff721`, fib 47 minutes later, 45 then 47 of 61), moves to "How it got here", which frees about 60 words under the limit for the new framing.
7. **The compiler against node**: moved, kept.
8. **Three compilers, one race**: moved, kept.
9. **What the compiler leaves to an optimizer**: moved, kept.

**Part III: The interpreter**

10. **The VM and its machine** (renamed): the rest of "The pipeline and the machine": the Vm stage, `Inspect.roc` and `NumberText.roc`, the dispatch loop, the heap as one value, the `Machine` record. About 230 words.
11. **Memory strategy**: moved; "Slots and boxes" loses the frame's layout to chapter 4 and keeps the boxes.
12. **The garbage collector**: moved; takes in "Garbage you can watch" from the history (`55-garbage.js`, `onCollect`), which is the collector's design, not history. About 620 words.
13. **JavaScript's rules for values**: moved; its first paragraph reframed, since the compiler's runtime (`runtime_add` and kin) is already explained.
14. **A canvas in the browser**: moved, kept.
15. **Handing the machine on** (renamed): the rest of "What copies", its three habits (a value is copied when handed on, box what is rarely written, stay under 256 bytes). They are about the VM's machine, and they need the event queue (chapter 14) and the machine (chapter 10) first. About 260 words.

**Part IV: What Roc taught**

16. **Why a compiler suits Roc**: moved from after the compiler's first chapter. It is a comparison of the two programs, and it reads both (section 4).
17. **Dev and release builds disagree**: moved, kept.
18. **Build times**: moved, kept.
19. **How it is tested**: kept, with one new section on the compiler's checks (`x86/programs.shale` held to node, the encoder's `expect`s), about 100 words. Today it covers the interpreter alone.
20. **Limitations**: kept, last.

**Back matter**: Appendix A and Appendix B, kept.

## 4. The flow-breakers

| chapter | why it breaks the order | the choice |
|---|---|---|
| Why a compiler suits Roc | It explains the compiler by contrast with the interpreter's effects, machine, lending and 248 bytes, citing three interpreter chapters. In Part II every one of those is a forward reference. | Moved whole to Part IV, where every reference is backward. Splitting it would leave half a comparison in each part. |
| What copies | Its first half is Roc's rule, which both programs need; its second half is about the VM's machine. | Split: the rule to Part I, the habits to Part III. |
| The pipeline and the machine | Half shared front end, half the VM. | Split into "The front end" (Part I) and "The VM and its machine" (Part III). |
| JavaScript's rules for values | The meanings are shared (the compiler's runtime gives values the same ones), but every line of the chapter is `ValueRules`, `Instructions` and lending. | Kept whole in Part III; its opening says the compiler's runtime keeps the same meanings. |
| Dev and release builds disagree, Build times | Roc lessons, but every number in them is the walker's or the VM's. | Part IV, after both programs; "How it got here" introduces the walker they name. |
| How it is tested, Limitations | Each covers both programs (the oracle judges both; the limits are mostly the shared parser's). | Part IV, with a short compiler section added to "How it is tested". |
| The compiler against node | Its `vm` column and its paragraph "The interpreter is the slower comparison" mention the VM before Part III. | Kept in Part II; the paragraph points ahead to Part III in one clause. The numbers need no explanation of the VM. |

## 5. The history chapter

**Still needed, and shorter.** Three reasons:

- The compiler reuses an interpreter's front end. A reader meeting the compiler first needs one line saying the interpreter came first and the compiler was built on its front end.
- "Dev and release builds disagree" and "Build times" name the walker on 11 lines ("walker: variables read by slot", "the walker's release build"). Something has to say what the walker was.
- The dates explain the cited commits' order: the walker, the VM and the compiler overlap on 2026-11-24.

It runs in date order, one short paragraph a day, about 350 words (today 586):

- **2026-11-23:** the tree-walker, the oracle, the page, the controls, 50 of 50 programs.
- **2026-11-24:** the VM in three rounds, the collector, the page moved onto the VM, the walker deleted; the project moved to its own repository; the compiler's hello world (`c3ff721`) and fib 47 minutes later (`0c5ea7e`).
- **2026-11-25:** the compiler to 45 of 61 (`451306b`), then 47 with classes (`6ec8068`); the memory view, the speed fix, classes in the VM.
- **2026-11-26:** method tables and the receiver first; the fib race.

Out of it: the class-as-sugar design (to "The front end") and "Garbage you can watch" (to "The garbage collector"), both present-tense design.

## 6. What the introduction needs to say

- **One program's text, two ways to run it**: `js-vm`, the interpreter, and `js-x86`, the compiler, which share the lexer, parser, resolver and bytecode compiler.
- **The order of the book and why**: the shared front end first, then the compiler (the simpler program for Roc: one pure function), then the interpreter (effects, a heap, a collector, a page), then what Roc taught. It replaces today's line 27, the four-reference map.
- **What it runs**: unchanged, but it says the compiler runs 47 of the 61 corpus programs, beside the VM's 61.
- **Who judges it**: node judges both: `js/oracle.shale` for the VM and `x86/programs.shale` for the executables.
- **The playground** stays in it, but after both programs, since only the VM runs there.
- **The dates**: "over three days, 2026-11-23 to 2026-11-25" becomes four, through 2026-11-26 (the race and the method tables are dated 11-26).

## 7. The mechanical cost

**Chapter references (`{{chapter ...}}`), 28 today.** The builder stops on a reference to no chapter, so every rename shows up at build time.

- To split chapters: 9 references, 3 to "The pipeline and the machine" and 6 to "What copies", must be repointed by hand, each to the half it means. Two more mentions are plain prose, which the builder can't check: the garbage collector's `("What copies" lists the shapes)` and Dev and release's `"Roc's copy rule" lists three such shapes`.
- Forward that become backward: "Why a compiler suits Roc" → A canvas in the browser, JavaScript's rules for values and What copies twice (4, by its move); The compiler to x86-64 → the front end (already backward, now to Part I).
- Backward that become forward: How it got here → the pipeline and What copies stay forward, as today. No reference that is backward today becomes forward, apart from the compiler chapter's prose mentions of the VM, which carry no link.
- The introduction's map (line 27, four references) is rewritten.

**Held items in the build.**

- `js-book/book.shale` holds no chapter by name: the citations check (`check_citations`) reads the whole manuscript, and every cited hash still resolves wherever its sentence moves. The listings sit in the appendices, which stay last, as `insert_listings!` asks ("The listings stand after the manuscript's last diagram").
- `js-book/app/main.roc`: `APP_TESTS = 5` stays unless the dividers get an `expect`. Adding the parts is a `look` with four `Divider`s; the builder refuses a divider above no chapter, so a divider's `before` must name its first chapter exactly.
- The word limit: The compiler to x86-64 is at 899 and Memory strategy at 896. The first loses its history paragraph and the second the frame's layout, so both gain room. JavaScript's rules for values (887) must stay word-neutral.
- `js-book/negatives.txt`: its kept sentences are matched by text, so a moved sentence stays kept. The three `motivation` sentences stay as written. The `limitations` five stay in Limitations. The one `guarantee` sentence stays in the compiler's chapter.
- Diagrams are numbered by order (`diagram-N`), so a move renumbers them with no edit. The pipeline diagram becomes two: the new front-end diagram and the compiler's own, which is unchanged.
- Page names: a page is named for its chapter's title, so the 3 renamed chapters and the 2 new ones get new pages. The builder's `Slug` keeps an old page name for a retitled chapter (section 8, question 5).

**Text that would read wrong after the move** (it assumes the interpreter came first):

- The compiler to x86-64: "a second way to run the subset"; "The front end is the interpreter's own ... the same `Bytecode` the VM runs"; "A slot of the frame" (the frame is explained only in Memory strategy today); "the interpreter's 61 corpus programs".
- The compiler against node: the `vm` column and "The interpreter is the slower comparison" (one clause pointing ahead).
- What the compiler leaves to an optimizer: "the parser already writes each class as plain functions" (fine once Part I says so); "the `NewInstance` and `InstanceOf` instructions of the VM's bytecode" becomes "of the bytecode".
- JavaScript's rules for values: its first paragraph ("This chapter is about the interpreter ... The compiler ... gives values the same meanings").
- The VM and its machine: "The boxes in it are the subject of What copies" repointed.
- Motivation: "The three rules of What copies" repointed; "That is the interpreter's case; the compiler's chapters time the compiler against node" stays true.
- Limitations: none; it already names both.

**How much prose is rewritten.** About 1,200 to 1,400 words of about 10,400, roughly an eighth: the introduction (about 300), the history (about 350, mostly cut), the new front-end chapter's joins and opening (about 150), the compiler chapter's framing (about 100), the testing section (about 100), and about 15 one-sentence fixes elsewhere. The other seven eighths move as they stand.

## 8. Open questions for Steve

1. **The title: *JavaScript in Roc: A Compiler and an Interpreter*?** Lean: yes.
2. **Split "What copies", the rule to Part I and the VM's habits to Part III?** Lean: yes. Kept whole in Part III, the compiler's chapters would cite it forward, and the rule is the book's main lesson for any Roc user.
3. **Move "Why a compiler suits Roc" to Part IV?** Lean: yes. It is a comparison and needs both programs explained.
4. **Keep the history chapter, cut to about 350 words in date order, right after Motivation?** Lean: yes. The walker it introduces is cited in Part IV. As back matter it would come too late for those citations.
5. **Keep the old page names of renamed chapters with slugs?** Lean: no. The book is four days old and the split chapters have no single successor.
6. **Show the parts as the builder's dividers in the contents?** Lean: yes. It is four lines in `main.roc`, and it makes the order visible.
7. **Add a short compiler section to "How it is tested"?** Lean: yes, about 100 words from `x86/README.md`.
8. **Leave the repository and folder names (`roc-js-interpreter`, `js-book/`) as they are?** Lean: yes, for now. Renaming the repo is a separate decision, and the URL `roc.lynrummy.com/js-book/` stays.
9. **Part IV's name: "What Roc taught"?** Lean: yes. The alternative is "Building it in Roc".
