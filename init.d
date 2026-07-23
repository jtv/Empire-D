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


import core.stdc.string : memset;
import core.stdc.stdlib : calloc;
import empire;
import mapdata;
import var;
import eplayer;
import display;

/*****************************
 * Initialize city variables.
 */

void citini()
{ int loc,i,j,k;

  for (i = CITMAX; i--;)
  {	memset(&city[i],0,City.sizeof);
	city[i].loc = city[i].own = 0;
	city[i].phs = -1;			// no phase
  }
  for (i = 0, loc = MAPSIZE; loc--;)
	if (typ[map[loc]] == X)
	    city[i++].loc = loc;
  //printf("%d cities\n",i);
  assert(i <= CITMAX);

  /* shuffle cities around
   */

  for (i = CITMAX / 2; i--;)
  {	j = empire.random(CITMAX);
	k = empire.random(CITMAX);
	loc = city[j].loc;
	city[j].loc = city[k].loc;
	city[k].loc = loc;		// swap city locs
  }
}


/*****************************
 * Select a map.
 * Returns:
 *	0	success
 *	!=0	failure
 */

int selmap()
{
    // Use internal maps
    int j;
    ubyte *d;
    int i,n;
    ubyte a, c;

    j = empire.random(5);
    d = cast(ubyte *)(*mapdata.mapdata[j]);
    i = MAPSIZE - 1;
    while ((c = *d) != 0)		// 0 marks end of data
    {	n = (c >> 2) & 63;		// count of map values - 1
	a = c & 3;			// bottom 2 bits
	if (a == 0 ||			// a must be 1,2,3
	    c == -1 ||			// error reading file
	    i - n < 0)			// too much data
	{
	    assert(0);
	}
	while (n-- >= 0)
	    map[i--] = a;
	d++;
    }
    if (ranq() & 4) flip();
    if (ranq() & 4) klip();		// random map rotations
    return 0;
}


/***********************
 * Flip map corner to corner.
 */

void flip()
{ int i,j;
  ubyte c;

  i = j = MAPSIZE / 2;
  while (i--)
  {	c = map[j];
	map[j++] = map[i];
	map[i] = c;
  }
}


/************************
 * Flip map end to end.
 */

void klip()
{ int row,i,j;
  ubyte c;

  row = 0;
  while (row < MAPSIZE)
  {	i = j = (Mcolmx + 1) / 2;
	while (i--)
	{   c = map[row + j];
	    map[row + j++] = map[row + i];
	    map[row + i] = c;
	}
	row += Mcolmx + 1;
  }
}


/*****************************
 * Set up a fresh game: read in the map, init city variables, and
 * create/configure each player.
 *
 * This is the frontend-agnostic core of what used to be winmain.d's
 * winSetup() -- that function read numply/demo out of a Win32 dialog
 * box (via global.numplayers/global.demo) and hardcoded DAwindows/
 * MTcgacolor for the human player's display. Everything else it did
 * (selmap/citini, creating each Player's Display, citsel()) has no
 * GUI dependency at all, so it lives here instead, with the frontend-
 * specific bits taken as parameters:
 *
 *   numply_      how many players (including the human)
 *   demo         if true, nobody is human -- everyone's computer-run
 *   humanWatch   the human player's watch mode (e.g. DAwindows, DAtty)
 *   humanMaptab  the human player's maptab (e.g. MTcgacolor, MTterm)
 *   rows, cols   passed straight to Display.setdispsize() for the
 *                human player. Text.nrows/ncols (set by TTinit()) are
 *                NOT used for this -- they're always VBUFROWS/VBUFCOLS,
 *                the small message-buffer size, not a real screen size,
 *                in both the GUI and text builds; using them here
 *                produces a degenerate (empty) sector viewport. The
 *                GUI caller passes VBUFROWS/VBUFCOLS explicitly, which
 *                keeps its behavior exactly as it was before this
 *                function existed; the text frontend passes real
 *                terminal dimensions instead.
 *
 * winmain.d's winSetup() and textmain.d both call this; each just
 * supplies its own frontend's values.
 */

import std.stdio:writeln;// XXX:
void gameSetup(int numply_, bool demo, ubyte humanWatch, uint humanMaptab,
    int rows, int cols)
{
    selmap();			// read in map
    citini();			// init city variables

    numply = numply_;
    numleft = numply;
    for (setPlynum(0); getPlynum() <= numply; setPlynum(getPlynum() + 1))
    {
	int currentPly = getPlynum();
	Player *p = &player[currentPly];
	p.display = new Display();
	Display *d = p.display;
	d.initialize();

	p.num = currentPly;
	p.map = (currentPly == 0) ? map.ptr : cast(ubyte *)calloc(MAPSIZE,1);
	p.human = (currentPly == 1 && !demo);
	p.watch = DAnone;

	if (p.human)
	{
	    d.timeinterval = 1;
	}

	if (currentPly == 1)
	{
	    p.secflg = 1;
	    p.watch = humanWatch;
	    d.text.TTinit();
	    d.text.watch = p.watch;
	    d.maptab = humanMaptab;
	    d.setdispsize(rows, cols);
	    d.text.clear();
	    d.text.block_cursor();
	}
	if (currentPly)
	    p.citsel();		// select city for each player
    }

    setPlynum(1);			// get the default player
}


/*****************************
 * Load a previously saved game from filename, and configure each
 * player's Display exactly as gameSetup() would have for a fresh
 * game.
 *
 * This is the frontend-agnostic core of what used to be winmain.d's
 * IDM_OPEN handler together with winRestore() -- opening the file and
 * calling resgam() to repopulate the saved variables (map, cities,
 * units, players -- including numply itself, which is part of the
 * saved block) is the same regardless of frontend; only the human
 * player's watch mode/maptab/screen size are frontend-specific, so
 * those are taken as parameters exactly like gameSetup()'s.
 *
 * Unlike gameSetup(), citsel() is deliberately NOT called here: the
 * whole point of a save file is that cities are already selected the
 * way the game was left, and citsel() picking a fresh city per player
 * would throw that away.
 *
 * Params:
 *   filename     path to the saved-game file (as written by
 *                var_savgam())
 *   humanWatch   the human player's watch mode (e.g. DAwindows, DAtty)
 *   humanMaptab  the human player's maptab (e.g. MTcgacolor, MTterm)
 *   rows, cols   passed straight to Display.setdispsize() for the
 *                human player -- see gameSetup()'s doc comment for
 *                why these can't just come from Text.nrows/ncols.
 *
 * Returns:
 *	0	success
 *	!=0	failure -- file could not be opened, or is corrupt/
 *		truncated
 */

int gameRestore(const(char)* filename, ubyte humanWatch, uint humanMaptab,
    int rows, int cols)
{
    import core.stdc.stdio : fopen, FILE;

    FILE *fp = fopen(filename, "rb");
    if (!fp)
	return 1;

    init_var();
    if (resgam(fp))		// resgam() closes fp on every path
	return 1;

    for (setPlynum(0); getPlynum() <= numply; setPlynum(getPlynum() + 1))
    {
	int currentPly = getPlynum();
	Player *p = &player[currentPly];
	p.display = new Display();
	Display *d = p.display;
	d.initialize();

	if (p.human)
	{
	    d.timeinterval = 1;
	}

	if (currentPly == 1)
	{
	    p.secflg = 1;
	    p.watch = humanWatch;
	    d.text.TTinit();
	    d.text.watch = p.watch;
	    d.maptab = humanMaptab;
	    d.setdispsize(rows, cols);
	    d.text.clear();
	    d.text.block_cursor();
	}
    }

    setPlynum(1);			// get the default player
    return 0;
}


