/*
 * textmain.d
 *
 * Entry point for the text frontend.
 *
 * Hard-wired for now to 1 human player + 1 computer player (see the
 * gameSetup() call below) -- a real player-count prompt, or a
 * command-line option, can replace that later without touching
 * anything else here.
 *
 * DEFAULT_ROWS/DEFAULT_COLS are passed to gameSetup() for the human
 * player's Display.setdispsize() call. These are deliberately real
 * terminal-ish dimensions, not Text.nrows/ncols (which are always
 * the small VBUFROWS/VBUFCOLS message-buffer size -- see the comment
 * on gameSetup() in init.d for why that distinction matters). A
 * later improvement here would be to query the actual terminal size
 * (ioctl TIOCGWINSZ, or ncurses' LINES/COLS) instead of a fixed
 * default.
 *
 * The main loop mirrors winmain.d's idle-processing loop (PeekMessage
 * + slice()), but without the busy-wait: since there's no message
 * pump to service here, we can just check whether the player whose
 * turn it logically is happens to be human and waiting on a key
 * (Text.inbuf == -1), and only then do a real *blocking* read via
 * termio.d -- fed in via TTunget() exactly the way winmain.d's
 * WM_CHAR handler already does for the GUI build. Computer players'
 * turns just run slice() at full speed, since there's nothing else
 * that needs the CPU meanwhile.
 */

module textmain;

import std.conv : to;
import std.stdio : writeln, stdout, write;
import empire : VERSION, DAtty, MTterm;
import init : gameSetup;
import move : slice;
import eplayer : Player;
import var : plynum;
import termio : termInit, termDone, termGetKey, termMessage;

enum int DEFAULT_ROWS = 24;
enum int DEFAULT_COLS = 80;

/*
 * text.d calls these two hooks (originally implemented only in
 * winmain.d, for the GUI build) to flush output and to signal the
 * terminal bell. Both have a straightforward, real meaning in a text
 * frontend, so these are genuine implementations, not stand-ins.
 */
extern (C) void win_flush()
{
    stdout.flush();
}

extern (C) void sound_click()
{
    write('\a');	// ASCII bell
}

int main()
{
    termInit();
    termMessage("Empire (text frontend placeholder) -- engine build OK, VERSION="
	~ to!string(VERSION));

    // Hard-wired for now: 1 human player + 1 computer player.
    gameSetup(2, false, DAtty, MTterm, DEFAULT_ROWS, DEFAULT_COLS);

    while (true)
    {
	Player *p = Player.get(plynum);

	if (p.human && p.display.text.inbuf == -1)
	{
	    int c = termGetKey();		// real blocking read
	    p.display.text.TTunget(c);
	}

	if (slice() != 0)
	    break;				// game over
    }

    termDone();
    return 0;
}
