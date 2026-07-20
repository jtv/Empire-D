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
import core.stdc.time : time;
import core.thread : Thread;
import std.conv : to;
import std.getopt : getopt, defaultGetoptPrinter;
import std.stdio : writeln, stdout, write;
import std.string : toStringz;
import empire : VERSION, DAtty, MTterm, setran,
    X, MAPunknown, MAPcity, MAPsea, MAPland, Mrowmx, Mcolmx, ROW, COL;
import init : gameSetup;
import move : slice;
import eplayer : Player;
import termio : termInit, termDone, termGetKey, termMessage, termResized, termSize;
import text : vbuffer;
import var : typx, typ, own;

version (UseNcurses) import deimos.ncurses : mvprintw, refresh;

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
    version (UseNcurses)
    {
	for (int row=0; row < vbuffer.length; ++row)
	    mvprintw(row, 0, "%s", toStringz(vbuffer[row]));
    }
    else
    {
        // Clear screen, move to top left position.
	write("\033[2J\033[H");

        // Print text buffer. The last line doubles as a blank
        // separator before the map -- it's blank except when a unit
        // is active in Move mode, in which case it names the unit's
        // type (see Display.headng()).
        for (int row=0; row < vbuffer.length; ++row)
	    writeln(vbuffer[row]);

	// The current player's map view, using as much of the rest of
	// the terminal as will fit.
	drawPlayerMap();
    }
}

/*
 * Render the human player's known map underneath the vbuffer text area
 * (the same relative position the Windows frontend and the old PC/CGA
 * terminal frontend show their map in), sized to use as much of the
 * terminal as remains below the vbuffer display.
 *
 * Each map cell is shown as a single character -- var.d's typx[].unichr
 * for units ('A','F','D','T','S','R','C','B'), 'O' for an owned city,
 * '*' for an unowned one, '.' for sea, '+' for land, and a blank for
 * still-unexplored territory -- coloured with ANSI escapes chosen to
 * match the Windows frontend's per-player bitmap colours (red, yellow,
 * magenta, cyan, white, and green for players 1..6; blue sea, green
 * land).
 *
 * This only reflects what the player actually knows (human.map, the
 * fog-of-war copy of the reference map), not the true state of the
 * whole board.
 */
void drawPlayerMap()
{
    Player *human = Player.get(1);
    if (human is null || human.map is null || human.display is null)
	return;			// nothing to show yet

    int termRows, termCols;
    termSize(termRows, termCols);

    // The vbuffer text area above (its last line doubles as the
    // separator before the map -- see win_flush()).
    int availRows = termRows - cast(int) vbuffer.length;
    int availCols = termCols;
    if (availRows <= 0 || availCols <= 0)
	return;			// terminal too small to bother

    int mapRows = (availRows < Mrowmx + 1) ? availRows : Mrowmx + 1;
    int mapCols = (availCols < Mcolmx + 1) ? availCols : Mcolmx + 1;

    // Centre the viewport on the player's cursor, clamped to the map.
    int r0 = ROW(human.curloc) - mapRows / 2;
    if (r0 < 0) r0 = 0;
    if (r0 > Mrowmx + 1 - mapRows) r0 = Mrowmx + 1 - mapRows;

    int c0 = COL(human.curloc) - mapCols / 2;
    if (c0 < 0) c0 = 0;
    if (c0 > Mcolmx + 1 - mapCols) c0 = Mcolmx + 1 - mapCols;

    static immutable string[7] playerColour =
	[ "",		// no player 0
	  "\033[91m",	// player 1: red
	  "\033[93m",	// player 2: yellow
	  "\033[95m",	// player 3: magenta
	  "\033[96m",	// player 4: cyan
	  "\033[97m",	// player 5: white
	  "\033[92m" ];	// player 6: green
    enum string seaColour  = "\033[34m";
    enum string landColour = "\033[32m";
    enum string reverse    = "\033[7m";
    enum string reset      = "\033[0m";

    char[] line;
    for (int r = 0; r < mapRows; r++)
    {
	line.length = 0;
	for (int c = 0; c < mapCols; c++)
	{
	    int loc = (r0 + r) * (Mcolmx + 1) + (c0 + c);
	    int v = human.map[loc];
	    string colour;
	    char ch;

	    switch (v)
	    {
		case MAPunknown:
		    ch = ' ';
		    break;
		case MAPcity:
		    ch = '*';		// unowned city
		    break;
		case MAPsea:
		    ch = '.';
		    colour = seaColour;
		    break;
		case MAPland:
		    ch = '+';
		    colour = landColour;
		    break;
		default:
		    int t = typ[v];
		    ch = (t == X) ? 'O' : typx[t].unichr;
		    colour = playerColour[own[v]];
		    break;
	    }

	    bool atCursor = (loc == human.curloc);
	    if (colour.length)
		line ~= colour;
	    if (atCursor)
		line ~= reverse;
	    line ~= ch;
	    if (colour.length || atCursor)
		line ~= reset;
	}
	writeln(line);
    }
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
	int c = termGetKey();		// blocking read, times out at 500ms
	if (c != -1)
	{
	    // Deliver the input to the human player, if there is one.
	    // That's alwaays player 1 (although in demo mode, even that is
	    // not a human).
	    Player *human = Player.get(1);
	    if (human.display)
	    {
	        // TODO: Mutex-protect display as well.  It goes away.
	        human.display.text.TTunget(c);
	    }
	}

	// termGetKey()'s 500ms timeout doubles as a poll interval for
	// this: termResized() reports (and clears) whether SIGWINCH has
	// fired since we last asked, so a resize is noticed no more than
	// half a second late.
	if (termResized())
	{
	    int rows, cols;
	    termSize(rows, cols);

	    Player *human = Player.get(1);
	    if (human.display)
	        human.display.setdispsize(rows, cols);
	}
    }
}

int main(string[] args)
{
    uint seed = cast(uint) time(null);

    auto helpInfo = getopt(args,
        "seed|s", "Set fixed seed for randomizer.", &seed);
    if (helpInfo.helpWanted)
    {
        defaultGetoptPrinter("Empire (text frontend)\n\n" ~
	    "Usage: empire [--seed=N]\n",
	    helpInfo.options);
	return 0;
    }

    setran(seed);

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
