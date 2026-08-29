/*
 * The handful of libc functions nolibc does not have, for GMP's benefit.
 *
 * This is deliberately NOT a malloc shim. An earlier version was, and it was
 * wrong: ocaml-solo5 already redirects the allocator, by force-including
 * <_solo5/overrides.h> into every C compile through its ocaml-gcc wrapper, so
 * that a unikernel never exports malloc as a strong global symbol. Read that
 * header -- it explains why, and the reason is sharper than convenience: on
 * the sgx target a guest that exports malloc captures the allocator for the
 * whole enclave, including the SDK's own allocations, which fail before any
 * OCaml runs.
 *
 * GMP gets built through the plain Solo5 cc wrapper rather than the ocaml-gcc
 * one, so build.sh force-includes the same header for it. With that in place
 * GMP calls ocaml_solo5_malloc directly, like every other C file in the guest,
 * and there is nothing here to do about memory at all.
 *
 * What is left are real gaps: nolibc's ctype.h is partial and it has no
 * vsprintf. GMP's printf and scanf modules want both, and GCC 14 makes an
 * implicit declaration an error. zarith calls neither module -- it uses
 * mpn/mpz arithmetic -- but GMP builds them unconditionally and offers no
 * --disable-printf, so supplying the functions is smaller than forking GMP.
 */

#include <stddef.h>

/*
 * ctype. nolibc defines isalpha, isatty, isdigit, isprint, isspace and
 * isupper, and declares isalnum and tolower without defining them.
 * All ASCII-only, which is all the C locale ever promised.
 */
int islower(int c) { return c >= 'a' && c <= 'z'; }
int isascii(int c) { return (unsigned)c <= 127; }

int isxdigit(int c)
{
  return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

int iscntrl(int c) { return (c >= 0 && c < 32) || c == 127; }
int isblank(int c) { return c == ' ' || c == '\t'; }
int isgraph(int c) { return c > 32 && c < 127; }

int isalnum(int c)
{
  return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

int ispunct(int c) { return isgraph(c) && !isalnum(c); }
int toupper(int c) { return islower(c) ? c - 'a' + 'A' : c; }
int tolower(int c) { return (c >= 'A' && c <= 'Z') ? c - 'A' + 'a' : c; }

/*
 * vsprintf, which nolibc omits in favour of the bounded vsnprintf -- a
 * defensible omission, since the unbounded form cannot be used safely.
 *
 * This exists to make GMP's archive link, not to be called. A Tron guest that
 * reaches it has gone wrong somewhere upstream.
 */
#include <stdarg.h>
int vsnprintf(char *, size_t, const char *, va_list);

int vsprintf(char *s, const char *fmt, va_list ap)
{
  return vsnprintf(s, (size_t)-1, fmt, ap);
}
