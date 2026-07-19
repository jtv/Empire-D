/*
 * termio.d
 *
 * A minimal terminal I/O abstraction for the text frontend: put the
 * terminal into raw, unbuffered, non-echoing mode, wait for a keystroke
 * with timeout, and restore the terminal afterwards.
 *
 * Empire's own input scheme is already plain ASCII (a QWEASDZXC-style
 * keypad layout for the 8 directions -- see cmdcur() in eplayer.d),
 * not arrow-key escape sequences, so termGetKey() only needs to
 * return a single byte. Neither backend needs to solve the classic
 * "is this a lone ESC or the start of an escape sequence" problem.
 *
 * Two backends share this one file, selected by the "UseNcurses"
 * version flag (set per dub configuration -- see dub.sdl):
 *
 *   - ncurses (version UseNcurses): via the D-Programming-Deimos
 *     ncurses bindings.
 *   - raw POSIX termios (the default otherwise): no dependency
 *     beyond druntime's core.sys.posix bindings.
 *
 * Both use a half-second timeout: termGetKey() waits at most 500ms
 * for a keystroke, returning -1 if the timeout expires. This allows
 * the input thread to periodically check for shutdown requests, and
 * (see termResized()) for a pending terminal resize.
 */

module termio;

version (UseNcurses)
{
    import deimos.ncurses;
    import std.string : toStringz;

    void termInit()
    {
	initscr();
	cbreak();		// no line buffering
	noecho();		// don't echo typed characters
	timeout(500);		// wait at most 500ms (0.5 seconds) for input
    }

    void termDone()
    {
	endwin();
    }

    int termGetKey()
    {
	int c = getch();	// returns ERR (-1) if timeout expires
	return c;		// -1 on timeout, or the character otherwise
    }

    /*
     * Print a message so it's actually visible. initscr() switches
     * the terminal to curses' own screen buffer and clears it, so
     * plain stdout writes made after termInit() are invisible --
     * everything has to go through curses' own output calls instead.
     */
    void termMessage(string s)
    {
	printw("%s\n", toStringz(s));
	refresh();
    }

    // Terminal window size, in rows and columns.
    void termSize(out int rows, out int cols)
    {
        // LINES and COLS get set in initscr(), by querying ncurses.
        rows = LINES;
	cols = COLS;
    }

    /*
     * Always false here: no SIGWINCH handler is installed for this
     * backend. This is a stub, not a real check -- it exists only so
     * that callers (textmain.d's input loop) can call termResized()
     * unconditionally, without a version (UseNcurses) branch of their
     * own. ncurses builds don't currently react to a resized window at
     * all; wiring that up (e.g. via KEY_RESIZE from wgetch(), plus
     * resizeterm()) is a separate piece of work from the one this stub
     * is standing in for.
     */
    bool termResized()
    {
	return false;
    }
}
else version (Posix)
{
    import core.atomic : atomicStore, atomicExchange;
    import core.sys.posix.signal : sigaction, sigaction_t, sigemptyset;
    import core.sys.posix.sys.ioctl : ioctl, TIOCGWINSZ, winsize;
    import core.sys.posix.termios;
    import core.sys.posix.unistd : read, STDIN_FILENO;
    import textmain : DEFAULT_COLS, DEFAULT_ROWS;

    private termios origTermios;

    /*
     * SIGWINCH -- sent to the foreground process group whenever the
     * terminal window changes size -- isn't part of POSIX proper, just a
     * near-universal Unix extension, and druntime's core.sys.posix.signal
     * doesn't define it. Its value is supplied here directly: 28 holds
     * for Linux (all mainstream architectures), macOS/Darwin, and the
     * BSDs. A platform not listed here doesn't have a known value and
     * needs one added before it can use this backend.
     */
    version (linux)             private enum SIGWINCH = 28;
    else version (OSX)          private enum SIGWINCH = 28;
    else version (FreeBSD)      private enum SIGWINCH = 28;
    else version (OpenBSD)      private enum SIGWINCH = 28;
    else version (NetBSD)       private enum SIGWINCH = 28;
    else version (DragonFlyBSD) private enum SIGWINCH = 28;
    else
	static assert(0, "termio.d: SIGWINCH value unknown for this platform");

    // Set (from the signal handler) when SIGWINCH arrives, and cleared by
    // termResized() once the caller has picked it up.
    private shared bool termWasResized = false;

    extern (C) private void winchHandler(int sig) nothrow @nogc
    {
	// Signal handlers must stick to async-signal-safe operations --
	// no allocation, no locking, nothing that could reenter
	// non-reentrant code. Setting a flag for the input thread to
	// notice later is about all that's safe to do here; the actual
	// re-query of the terminal size (termSize()) happens afterwards,
	// on the input thread, not in the handler itself.
	atomicStore(termWasResized, true);
    }

    void termInit()
    {
	termios raw;

	tcgetattr(STDIN_FILENO, &origTermios);
	raw = origTermios;

	raw.c_lflag &= ~(ICANON | ECHO);	// no line buffering, no echo
	raw.c_cc[VMIN] = 0;			// don't require any bytes for read to return
	raw.c_cc[VTIME] = 5;			// timeout after 0.5 seconds (5 deciseconds)

	tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);

	// Get notified whenever the terminal window changes size.
	sigaction_t sa;
	sa.sa_handler = &winchHandler;
	sigemptyset(&sa.sa_mask);
	sa.sa_flags = 0;
	sigaction(SIGWINCH, &sa, null);
    }

    void termDone()
    {
	tcsetattr(STDIN_FILENO, TCSAFLUSH, &origTermios);
    }

    int termGetKey()
    {
	ubyte c;
	auto n = read(STDIN_FILENO, &c, 1);	// returns 0 on timeout, 1 on success
	return (n == 1) ? cast(int) c : -1;	// -1 on timeout or error
    }

    /*
     * termInit() only reconfigures input handling here (no line
     * buffering, no echo) -- it doesn't touch the screen the way
     * initscr() does, so plain stdout output works fine.
     */
    void termMessage(string s)
    {
	import std.stdio : writeln, stdout;

	writeln(s);
	stdout.flush();
    }

    // Terminal window size, in rows and columns.
    void termSize(out int rows, out int cols)
    {
        winsize ws;
        if (ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_row && ws.ws_col)
        {
            rows = ws.ws_row;
            cols = ws.ws_col;
	}
	else
	{
	    // Didn't work.  Fall back to defaults.
	    rows = DEFAULT_ROWS;
	    cols = DEFAULT_COLS;
	}
    }

    /*
     * True if the terminal has been resized (SIGWINCH) since the last
     * call to termResized() -- calling this clears the flag, so it's a
     * "were there any resizes since I last asked" check, not a snapshot
     * of some persistent "is resized" state. A caller that gets true
     * back should follow up with termSize() to get the new dimensions.
     */
    bool termResized()
    {
	return atomicExchange(&termWasResized, false);
    }
}
else
{
    static assert(0, "termio.d: no terminal backend for this platform");
}
