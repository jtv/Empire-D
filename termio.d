/*
 * termio.d
 *
 * A minimal terminal I/O abstraction for the text frontend: put the
 * terminal into raw, unbuffered, non-echoing mode, block for exactly
 * one keystroke at a time, and restore the terminal afterwards.
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
 * Both are real blocking reads -- no polling, no busy-waiting.
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
    }

    void termDone()
    {
	endwin();
    }

    int termGetKey()
    {
	return getch();	// blocks until a key is available
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
}
else version (Posix)
{
    import core.sys.posix.termios;
    import core.sys.posix.unistd : read, STDIN_FILENO;

    private termios origTermios;

    void termInit()
    {
	termios raw;

	tcgetattr(STDIN_FILENO, &origTermios);
	raw = origTermios;

	raw.c_lflag &= ~(ICANON | ECHO);	// no line buffering, no echo
	raw.c_cc[VMIN] = 1;			// block until >=1 byte is read
	raw.c_cc[VTIME] = 0;			// no timeout

	tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);
    }

    void termDone()
    {
	tcsetattr(STDIN_FILENO, TCSAFLUSH, &origTermios);
    }

    int termGetKey()
    {
	ubyte c;
	auto n = read(STDIN_FILENO, &c, 1);	// blocks for one byte
	return (n == 1) ? cast(int) c : -1;
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
}
else
{
    static assert(0, "termio.d: no terminal backend for this platform");
}
