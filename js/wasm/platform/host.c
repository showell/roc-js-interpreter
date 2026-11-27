// host.c: the JavaScript subset's wasm host, the page's door onto the Roc
// interpreter (../../roc/JsApp.roc on main.roc), the page's effects the Roc
// calls (Host.roc), and the memory and crash functions.
//
// js/build.shale compiles it with clang (--target=wasm32-unknown-unknown) to
// an object, js/wasm/platform/targets/wasm32/host.wasm, and Roc links that
// with the app into js.wasm; main.roc's `exports:` names the page's exports
// below, which are otherwise not exports.
//
// The page writes a program's bytes where `sourcePtr(n)` says and calls
// `start()`, then `frame(t)` for each frame while the last line said `end
// frame`, and `click(x, y)` for each click between frames, which queues it
// for the next. While either call runs, each line the Roc emits reaches the
// page at once, through the page's import `js_emit`, and each read the Roc
// makes is answered by `js_pointer` or `js_key`: so the page sees a draw, a
// log and another draw in the order the program made them.
//
// The run is one boxed Roc value, kept here between calls: each call
// consumes it and answers the next, and `sourcePtr` drops it before a new
// run.
//
// Memory is a free list per power of two, from 16 bytes up, so what Roc
// frees is reused. Each block keeps its size class in the 16 bytes before
// what Roc is given, for `roc_dealloc` and `roc_realloc`; a freed block goes
// back on its class's list. New blocks are carved from the end of the heap,
// which grows by memory.grow as it needs. (cook-levin's web/platform/host.c
// is the same allocator.)

#include <stddef.h>
#include <stdint.h>

// Roc's `List(U8)`: its bytes, how many, and its capacity.
typedef struct {
    unsigned char *bytes;
    size_t length;
    size_t capacity_or_alloc_ptr;
} RocBytes;

// A boxed run: one pointer, which only the Roc reads.
typedef void *Model;

RocBytes roc_buffer(uint32_t n);
Model roc_start(RocBytes src);
Model roc_frame(Model model, double t);
Model roc_click(Model model, double x, double y);
void roc_drop_model(Model model);
void roc_drop_bytes(RocBytes bytes);

__attribute__((import_module("env"), import_name("js_emit"))) void js_emit(uint32_t ptr, uint32_t len);
__attribute__((import_module("env"), import_name("js_pointer"))) double js_pointer(uint32_t axis);
__attribute__((import_module("env"), import_name("js_key"))) uint32_t js_key(uint32_t ptr, uint32_t len);

static const RocBytes empty = {0, 0, 0};

static RocBytes source = {0, 0, 0};
static Model model = 0;

static uint32_t address(RocBytes b) {
    return (uint32_t)(uintptr_t)b.bytes;
}

// Where the page writes a program of `n` bytes. The last run is dropped
// first.
uint32_t sourcePtr(uint32_t n) {
    if (model) roc_drop_model(model);
    model = 0;
    source = roc_buffer(n);
    return address(source);
}

// Runs the program written at `sourcePtr` to its end.
void start(void) {
    model = roc_start(source);
    source = empty;
}

// Calls the program's `frame(t)` once.
void frame(double t) {
    if (!model) __builtin_trap();
    model = roc_frame(model, t);
}

// Queues a click at x and y for the next frame. With no run kept (none
// started, or one a crash lost), there is nothing to click.
void click(double x, double y) {
    if (!model) return;
    model = roc_click(model, x, y);
}

// ---- the effects the Roc calls (Host.roc) -----------------------------------

void host_emit(RocBytes line) {
    js_emit(address(line), (uint32_t)line.length);
    roc_drop_bytes(line);
}

double host_pointer(unsigned char axis) {
    return js_pointer(axis);
}

unsigned char host_key(RocBytes name) {
    uint32_t state = js_key(address(name), (uint32_t)name.length);
    roc_drop_bytes(name);
    return state == 0 ? 0 : 1;
}

// ---- memory and crashes -----------------------------------------------------

#define HEADER 16
#define CLASSES 32
#define PAGE 65536

extern unsigned char __heap_base;

static size_t top = 0;
static size_t limit = 0;
static void *free_list[CLASSES];

// The smallest class whose blocks hold `total` bytes: 1 << class. A size
// past the largest class traps.
static int class_of(size_t len) {
    if (len > ((size_t)1 << (CLASSES - 1)) - HEADER) __builtin_trap();
    size_t total = HEADER + len;
    int c = 4;
    while (((size_t)1 << c) < total) c++;
    return c;
}

// `bytes` fresh bytes from the end of the heap, grown as it needs.
static void *carve(size_t bytes) {
    if (top == 0) {
        top = ((size_t)&__heap_base + 15) & ~(size_t)15;
        limit = __builtin_wasm_memory_size(0) * PAGE;
    }
    while (bytes > limit - top) {
        size_t pages = (top + bytes - limit + PAGE - 1) / PAGE;
        if (__builtin_wasm_memory_grow(0, pages) == (size_t)-1) __builtin_trap();
        limit += pages * PAGE;
    }
    void *p = (void *)top;
    top += bytes;
    return p;
}

static unsigned char *allocate(size_t len, size_t alignment) {
    if (alignment > HEADER) __builtin_trap();
    int c = class_of(len);
    size_t *block = free_list[c];
    if (block) free_list[c] = *(void **)block;
    else block = carve((size_t)1 << c);
    block[0] = (size_t)c;
    return (unsigned char *)block + HEADER;
}

static void release(void *ptr) {
    size_t *block = (size_t *)((unsigned char *)ptr - HEADER);
    int c = (int)block[0];
    *(void **)block = free_list[c];
    free_list[c] = block;
}

void *roc_alloc(size_t len, size_t alignment) {
    return allocate(len, alignment);
}

// A block that already holds `len` bytes is kept as it is.
void *roc_realloc(void *ptr, size_t len, size_t alignment) {
    size_t *block = (size_t *)((unsigned char *)ptr - HEADER);
    size_t was = ((size_t)1 << block[0]) - HEADER;
    if (len <= was) return ptr;
    unsigned char *fresh = allocate(len, alignment);
    __builtin_memcpy(fresh, ptr, was);
    release(ptr);
    return fresh;
}

void roc_dealloc(void *ptr, size_t alignment) {
    (void)alignment;
    release(ptr);
}

// A Roc crash is the interpreter's bug. Its message is kept where `crashPtr`
// and `crashLen` say, and the call traps, so the page can say what the Roc
// said. The run is lost with it: the page starts afresh.
static unsigned char crash_message[512];
static size_t crash_length = 0;

void roc_crashed(const unsigned char *bytes, size_t len) {
    crash_length = len < sizeof crash_message ? len : sizeof crash_message;
    __builtin_memcpy(crash_message, bytes, crash_length);
    model = 0;
    __builtin_trap();
}

uint32_t crashPtr(void) {
    return (uint32_t)(uintptr_t)crash_message;
}

uint32_t crashLen(void) {
    return (uint32_t)crash_length;
}

void roc_dbg(const unsigned char *bytes, size_t len) {
    (void)bytes;
    (void)len;
}

void roc_expect_failed(const unsigned char *bytes, size_t len) {
    (void)bytes;
    (void)len;
}
