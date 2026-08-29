/* Solo5 entry point and console bridge.

   The GC hooks (mirage_memory_*, mirage_trim_allocation) and the clock stub
   come from mirage-solo5's own C sources, compiled alongside -- the installed
   archive is empty, see the validation notes. Its main.c is deliberately not
   used: this guest wants its own entry point, and two definitions of
   solo5_app_main is one too many. */

#include <solo5.h>
#define CAML_NAME_SPACE
#include <caml/mlvalues.h>
#include <caml/memory.h>

extern void _nolibc_init(uintptr_t heap_start, size_t heap_size);
extern void caml_startup(char **argv);

static char *argv[] = { (char *)"tron-validation", NULL };

CAMLprim value tron_console_write(value s)
{
    solo5_console_write(String_val(s), caml_string_length(s));
    return Val_unit;
}

CAMLprim value tron_solo5_exit(value code)
{
    solo5_exit(Int_val(code));
    return Val_unit;  /* not reached */
}

int solo5_app_main(const struct solo5_start_info *si)
{
    /* Hands the guest's heap to the allocator. Without it the OCaml runtime
       dies in caml_lf_skiplist_init before reaching any OCaml code. */
    _nolibc_init(si->heap_start, si->heap_size);
    solo5_console_write("tron: guest starting\n", 21);
    caml_startup(argv);
    solo5_console_write("tron: guest finished\n", 21);
    solo5_exit(0);
    return 0;
}
