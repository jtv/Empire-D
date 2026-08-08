/*
 * ruler.d
 *
 * Map ruler labels shared by every frontend that draws a scrollable
 * map viewport (currently textmain.d's ncurses/termios renderers and
 * sdlmain.d). Factored out of textmain.d, which had this logic first,
 * so sdlmain.d doesn't have to duplicate it -- unlike the odd bit of
 * three-line boilerplate (e.g. getHuman()), this is substantial enough
 * that two copies would be a real maintenance hazard if Mrowmx/Mcolmx
 * or the label format ever changed.
 */

module ruler;

import std.conv : to;
import std.format : sformat;
import empire : Mrowmx, Mcolmx;

/*
 * Ruler line shown along the bottom row of the map display: every map
 * column (map x-coordinate 0..Mcolmx) that's divisible by 5 gets a
 * caret immediately followed by that column's x-coordinate, zero-padded
 * to RULER_DIGITS digits (so "^05" rather than "^5", lining up with the
 * two-digit labels); everything else is blank. Labels are a fixed width
 * (RULER_LABELWIDTH), so they never overlap.
 *
 * Mcolmx is fixed for the whole run, so this is the same string every
 * time -- built once, at startup, into fullRulerLine below, instead of
 * being reconstructed on every redraw. rulerLine() just slices it.
 *
 * One behavioural difference from the old per-call version: this is
 * now a single tape addressed by absolute map column, not something
 * that restarts its scan at each viewport's left edge. If a viewport's
 * left edge (c0) falls in the middle of a label -- e.g. c0 == 6, right
 * after "^05" occupies columns 5-7 -- the slice now starts with that
 * label's leftover digit(s) and no caret, whereas the old code (which
 * always started counting from c0) would have shown blank there
 * instead. A marker running past the right edge is still truncated
 * there, same as before.
 */
enum int RULER_DIGITS = cast(int) to!string(Mcolmx).length;
enum int RULER_LABELWIDTH = 1 + RULER_DIGITS;	// '^' + digits

private immutable string fullRulerLine;

private string buildFullRulerLine()
{
    // Headroom past Mcolmx for a label whose digits would otherwise
    // run past it, even though no slice ever reaches that far (c0 +
    // cols is always <= Mcolmx+1).
    char[] line = new char[Mcolmx + 1 + RULER_LABELWIDTH];
    line[] = ' ';

    int i = 0;
    while (i <= Mcolmx)
    {
	if (i % 5 == 0)
	{
	    sformat(line[i .. i + RULER_LABELWIDTH], "^%0*d", RULER_DIGITS, i);
	    i += RULER_LABELWIDTH;
	}
	else
	    i++;
    }
    return line.idup;
}

shared static this()
{
    fullRulerLine = buildFullRulerLine();
    rowRulerLabels = buildRowRulerLabels();
}

string rulerLine(int c0, int cols)
{
    return fullRulerLine[c0 .. c0 + cols];
}

/*
 * Vertical ruler shown along the left edge of the map display, in
 * place of its two leftmost columns: every map row (map y-coordinate
 * 0..Mrowmx) that's divisible by 5 gets its row number, zero-padded
 * to ROW_RULER_WIDTH digits (so "05" rather than "5"); every other
 * row is blank there instead. There's no room for a caret here the
 * way the column ruler has one -- two columns is only enough for the
 * digits themselves.
 *
 * As with fullRulerLine above, Mrowmx is fixed for the whole run, so
 * this is the same set of labels every time -- built once, at
 * startup, into rowRulerLabels, indexed by absolute map row.
 */
enum int ROW_RULER_DIGITS = cast(int) to!string(Mrowmx).length;
enum int ROW_RULER_WIDTH = ROW_RULER_DIGITS;

private immutable string[] rowRulerLabels;

private immutable(string)[] buildRowRulerLabels()
{
    char[] blank = new char[ROW_RULER_WIDTH];
    blank[] = ' ';

    string[] labels = new string[Mrowmx + 1];
    foreach (row; 0 .. Mrowmx + 1)
    {
	if (row % 5 == 0)
	{
	    char[] label = new char[ROW_RULER_WIDTH];
	    sformat(label, "%0*d", ROW_RULER_DIGITS, row);
	    labels[row] = label.idup;
	}
	else
	    labels[row] = blank.idup;
    }
    return labels.idup;
}

string rowRulerLabel(int row)
{
    return rowRulerLabels[row];
}
