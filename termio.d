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
}
else
{
    static assert(0, "termio.d: no terminal backend for this platform");
}
