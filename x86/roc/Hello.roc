# The first program Roc compiles to x86-64: a static Linux executable that
# prints a text by Linux's `write` system call and exits with status 0,
# every byte of it written here (Assembly.roc, X86.roc, Elf.roc).
# x86/hello.shale hands it "Hello, world!" and a newline.
#
#   x86-hello "<text>"
#
# It runs on Roc's default platform, whose one effect writes text to
# stdout, so it prints the executable's bytes as hex (X86.hex_text: two
# lowercase digits a byte, a space between) and nothing else.
# x86/hello.shale turns the hex back into the file, marks it executable,
# runs it and checks what it printed.
import Assembly
import Elf
import X86

main! = |arguments| {
	match arguments.get(0) {
		Ok(text) => write_program!(text.to_utf8())
		Err(_) => {
			echo!("usage: x86-hello \"<text>\"\n")
			Err(Exit(2))
		}
	}
}

write_program! : List(U8) => Try({}, [Exit(I8)])
write_program! = |message| {
	match Assembly.assemble(printing_items(message)) {
		Ok(code) => {
			echo!(X86.hex_text(Elf.executable(code)))
			Ok({})
		}
		Err(UnknownLabel(label)) => {
			echo!("x86-hello: no label ${label}\n")
			Err(Exit(1))
		}
		Err(DuplicateLabel(label)) => {
			echo!("x86-hello: the label ${label} is marked twice\n")
			Err(Exit(1))
		}
	}
}

# write(1, message, its length), then an exit of the whole process with
# status 0: Linux's x86-64 system calls 1 and 231, the number in rax and the
# arguments in rdi, rsi and rdx.
printing_items : List(U8) -> List(Assembly.Statement)
printing_items = |message| [
	Instruction(MovRegImm({ to: Rax, value: 1 })),
	Instruction(MovRegImm({ to: Rdi, value: 1 })),
	LeaTo({ to: Rsi, label: "message" }),
	Instruction(MovRegImm({ to: Rdx, value: message.len().to_i64_wrap() })),
	Instruction(Syscall),
	Instruction(MovRegImm({ to: Rax, value: 231 })),
	Instruction(
		Alu({
			operation: Xor,
			to: Rdi,
			from: Rdi,
		}),
	),
	Instruction(Syscall),
	Mark("message"),
	Data(message),
]
