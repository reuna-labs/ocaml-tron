/*
 * Force-included into every GMP translation unit, alongside the platform's own
 * <_solo5/overrides.h>.
 *
 * nolibc's <ctype.h> declares only isalnum, isalpha, isdigit, isprint,
 * isspace, isupper and tolower, and it has no vsprintf. GMP's printf and scanf
 * modules use more, and GCC 14 makes an implicit declaration an error rather
 * than a warning.
 *
 * The blunt alternative would be -Wno-implicit-function-declaration, which
 * would also hide a genuinely missing function across the whole GMP build.
 *
 * Definitions are in nolibc_gaps.c. Nothing here concerns memory: the
 * allocator is redirected by <_solo5/overrides.h>, which build.sh
 * force-includes for GMP exactly as ocaml-solo5's ocaml-gcc wrapper does for
 * everything else.
 */
#ifndef GMP_SOLO5_COMPAT_H
#define GMP_SOLO5_COMPAT_H

#include <stdarg.h>
#include <stddef.h>

int islower(int);
int isascii(int);
int isxdigit(int);
int iscntrl(int);
int isblank(int);
int isgraph(int);
int ispunct(int);
int toupper(int);
int vsprintf(char *, const char *, va_list);

#endif /* GMP_SOLO5_COMPAT_H */
