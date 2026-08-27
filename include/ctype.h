#ifndef _CTYPE_H
#define _CTYPE_H

/* C only, and deliberately: there is no locale here, so these answer for
 * ASCII and leave everything above it alone. UTF-8 passes through unharmed. */
int isalpha(int c);
int isdigit(int c);
int isalnum(int c);
int isspace(int c);
int isupper(int c);
int islower(int c);
int isprint(int c);
int isgraph(int c);
int iscntrl(int c);
int ispunct(int c);
int isxdigit(int c);
int toupper(int c);
int tolower(int c);
#endif
