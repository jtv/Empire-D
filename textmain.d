/*
 * textmain.d
 *
 * Placeholder entry point for the text frontend.
 *
 * Its only job right now is to prove that the platform-neutral game
 * engine -- empire.d, display.d, eplayer.d, init.d, maps.d, mapdata.d,
 * move.d, path.d, printf.d, sub2.d, text.d, var.d -- compiles and links
 * cleanly on a non-Windows platform, with no Win32 dependency anywhere
 * in the chain.
 *
 * This is NOT a playable game yet: there is no board setup, no input
 * handling, no game loop. That's the real text-frontend work still to
 * be done, and this file is meant as its starting point.
 */

module textmain;

import std.stdio : writeln, stdout, write;
import empire : VERSION;

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
    return 0;
}
