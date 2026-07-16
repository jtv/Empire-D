/*
 * textmain.d
 *
 * Placeholder entry point for the text frontend.
 *
 * Its job right now is to prove two things: that the platform-neutral
 * game engine -- empire.d, display.d, eplayer.d, feedback.d, init.d,
 * maps.d, mapdata.d, move.d, path.d, printf.d, sub2.d, text.d, var.d --
 * compiles and links cleanly on a non-Windows platform with no Win32
 * dependency anywhere in the chain, and that termio.d's blocking key
 * read actually works end to end for whichever backend was selected
 * (see dub.sdl's text-ncurses / text-termios configurations).
 *
 * This is NOT a playable game yet: there is no board setup, no real
 * input handling loop, no game loop tying input to slice()/tslice().
 * That's the real text-frontend work still to be done, and this file
 * is meant as its starting point.
 */

module textmain;

import std.stdio : writeln, stdout, write;
import empire : VERSION;
import termio : termInit, termDone, termGetKey;

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
    writeln("Empire (text frontend placeholder) -- engine build OK, VERSION=", VERSION);

    writeln("Press any key (a real blocking read -- no polling)...");
    stdout.flush();	// make sure the above is actually on screen before
			// termInit() reconfigures (or, for ncurses, takes
			// over) the terminal
    termInit();
    int c = termGetKey();
    termDone();
    writeln("Got key: ", c);

    return 0;
}
