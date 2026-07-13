/*
 * Empire, the Wargame of the Century (tm)
 * Copyright (C) 1978-2004 by Walter Bright
 * All Rights Reserved
 *
 * You may use this source for personal use only. To use it commercially
 * or to distribute source or binaries of Empire, please contact
 * www.digitalmars.com.
 *
 * Written by Walter Bright.
 * This source is written in the D Programming Language.
 * See www.digitalmars.com/d/ for the D specification and compiler.
 *
 * Use entirely at your own risk. There is no warranty, expressed or implied.
 */


/* This file implements printf for GUI apps that sends the output
 * to logfile rather than stdout.
 * The file is closed after each printf, so that it is complete even
 * if the program subsequently crashes.
 */

import core.stdc.stdarg : va_list, va_start, va_end, va_arg;
import core.stdc.stdlib : exit;
import std.array : Appender;
import std.conv : to;
import std.file : append;
import std.stdio : stdout;



enum int LOG = 1;		// disable logging by setting this to 0

version (Windows)
{
    immutable string logfile = r"\empire.log";
}
version (linux)
{
    immutable string logfile = "/var/log/empire.log";
}

/*********************************************
 * Route printf() to a log file rather than stdio.
 */

enum Plog
{
	TOBITBUCKET,
	TOLOGFILE,
	TOSTDOUT,
}

Plog printf_logging = Plog.TOLOGFILE;

void printf_tologfile()
{
    printf_logging = Plog.TOLOGFILE;
}

void printf_tostdout()
{
    printf_logging = Plog.TOSTDOUT;
}

void printf_tobitbucket()
{
    printf_logging = Plog.TOBITBUCKET;
}

void LogfileAppend(const(char)[] msg)
{
    if (printf_logging == Plog.TOLOGFILE)
	append(logfile, msg);
    else
    {
	stdout.rawWrite(msg);
	stdout.flush();
    }
}

/*********************************************
 * Minimal printf()-style formatter that pulls arguments directly out of
 * a C-ABI va_list, using core.stdc.stdarg.va_arg (which already handles
 * the per-platform calling-convention details). This replaces the C
 * library's vsnprintf/_vsnprintf, while keeping VPRINTF's/PRINTF's
 * C-compatible signatures unchanged, so no caller needs to change.
 *
 * Only the specifiers actually used anywhere in this codebase are
 * supported: %d, %i, %u, %s, %%. Anything else asserts immediately,
 * so a missing specifier is caught loudly rather than silently
 * misformatted or (worse) misreading the va_list.
 */
private char[] formatMessage(const(char)* format, ref va_list args)
{
    Appender!(char[]) sink;
    const(char)* f = format;

    while (*f)
    {
	char c = *f++;
	if (c != '%')
	{
	    sink.put(c);
	    continue;
	}

	char spec = *f;
	if (spec)
	    f++;

	switch (spec)
	{
	    case '%':
		sink.put('%');
		break;

	    case 'd':
	    case 'i':
		sink.put(to!string(va_arg!int(args)));
		break;

	    case 'u':
		sink.put(to!string(va_arg!uint(args)));
		break;

	    case 's':
	    {
		char* s = va_arg!(char*)(args);
		while (*s)
		    sink.put(*s++);
		break;
	    }

	    default:
		assert(0, "printf.d: unsupported format specifier");
	}
    }
    return sink.data;
}

extern (C)
{

int VPRINTF(immutable scope char* format, va_list args)
{
    if (printf_logging != Plog.TOBITBUCKET)
	LogfileAppend(formatMessage(format, args));
    return 0;
}

int PRINTF(immutable scope char* format, ...)
{
    int result = 0;

    if (printf_logging != Plog.TOBITBUCKET)
    {
	va_list ap;
	va_start(ap, format);
	result = VPRINTF(format,ap);
	va_end(ap);
	
    }
    return result;
}

}

void _printf_assert(immutable scope char* file, uint line)
{
    PRINTF(("assert fail: %s(%d)\n").ptr, file, line);
    *cast(char *)0 = 0;	// seg fault to ensure it isn't overlooked
    exit(0);
}


