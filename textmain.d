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
 * Input Architecture:
 * -------------------
 * The text frontend uses a dedicated input thread that continuously
 * blocks on termGetKey() and feeds characters into the game engine via
 * TTunget(). This mirrors the Windows frontend's event-driven model
 * (where WM_CHAR messages call TTunget()) and provides a clean
 * separation between input handling and game logic.
 *
 * The main loop simply calls slice() repeatedly -- input arrives
 * asynchronously via the input thread, so there's no need to check
 * for pending input in the main loop. This architecture also makes it
 * straightforward to add future frontends (e.g., SDL2) that have their
 * own event models.
 */

module textmain;

import core.atomic : atomicLoad, atomicStore;
import core.thread : Thread;
import std.conv : to;
import std.stdio : writeln, stdout, write;
import empire : VERSION, DAtty, MTterm;
import init : gameSetup;
import move : slice;
import eplayer : Player;
import var : getPlynum;
import termio : termInit, termDone, termGetKey, termMessage;

enum int DEFAULT_ROWS = 24;
enum int DEFAULT_COLS = 80;

// Shared flag to signal the input thread to shut down
shared bool inputThreadShutdown = false;

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

/*
 * Input thread function: continuously blocks on termGetKey() and feeds
 * characters to the human player's input buffer via TTunget(). Runs
 * until inputThreadShutdown is set.
 */
void inputThreadFunc()
{
    while (!atomicLoad(inputThreadShutdown))
    {
	int c = termGetKey();		// blocking read
	if (c != -1)
	{
	    Player *human = Player.getHumanPlayer();
	    if (human)
	    {
	        // Feed character to the human player's input buffer
		human.display.text.TTunget(c);
            }
	}
    }
}

int main()
{
    termInit();
    termMessage("Empire (text frontend) -- VERSION=" ~ to!string(VERSION));

    // Start the input thread
    auto inputThread = new Thread(&inputThreadFunc);
    inputThread.start();

    // Hard-wired for now: 1 human player + 1 computer player.
    gameSetup(2, false, DAtty, MTterm, DEFAULT_ROWS, DEFAULT_COLS);

    // Main game loop: just call slice() repeatedly
    while (slice() == 0)
    {
	// slice() returns 0 to continue, non-zero when game is over
    }

    // Signal the input thread to shut down and wait for it
    atomicStore(inputThreadShutdown, true);
    inputThread.join();

    termDone();
    return 0;
}
