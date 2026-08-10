/*
 * sdlmain.d
 *
 * Entry point for the SDL2 frontend.
 *
 * Wired up to the frontend-agnostic engine (init.d/move.d/eplayer.d/
 * text.d), the same way textmain.d and winmain.d are: it calls
 * gameSetup(), drives the game with slice() from the main loop, and
 * implements the two extern(C) hooks text.d expects a frontend to
 * provide (win_flush(), sound_click()).
 *
 * What's still missing:
 *   - win_flush() draws the vbuffer text area (via SDL_ttf) and, below
 *     it, the map viewport itself -- terrain, units, cities, cursor
 *     highlight, and the horizontal/vertical rulers (see drawMap()) --
 *     an SDL_Renderer-based equivalent of textmain.d's
 *     drawPlayerMapNcurses(), though not yet of winmain.d's tile/sprite
 *     GDI blitting (this draws single characters, the same as the text
 *     frontends, not the *.bmp tile art).
 *   - The vbuffer text only actually appears if a monospace TTF font
 *     was found at one of openMonoFont()'s hardcoded candidate paths.
 *     There's no bundled fallback font and no way to configure the
 *     path -- see that function's doc comment.
 *   - sound_click() is a no-op, same status as textmain.d's version.
 *     winmain.d's plays click.wav; doing that here needs an SDL audio
 *     device (SDL_mixer, or SDL_LoadWAV + SDL_QueueAudio) that hasn't
 *     been set up.
 *   - Keyboard input only forwards ASCII-range SDLK_* keydowns
 *     (letters, digits, space, enter, ...) straight to TTunget(), the
 *     way winmain.d's WM_CHAR handler does. Arrow/function keys and
 *     text-input-with-modifiers (SDL_TEXTINPUT) aren't mapped to
 *     anything.
 *   - No mouse handling. The window is resizable and SDL_WINDOWEVENT
 *     is handled well enough to keep it repainted while dragging, and
 *     to keep Display.setdispsize() in sync with the new size (see
 *     computeDispSize()) -- but there's still no equivalent of
 *     textmain.d's narrow-terminal (Text.narrow) formatting choices
 *     reacting to a shrink, since that's driven by the vbuffer text
 *     layout, which win_flush() draws at a fixed width regardless.
 *
 * The *.bmp tiles and *.wav sounds this configuration already copies
 * next to the executable are still unused until the above is written.
 */

module sdlmain;

import bindbc.sdl;
import std.conv : to;
import std.stdio : stderr, writeln, writefln;
import std.string : toStringz, fromStringz;
import std.format : format;
import std.math : abs;

import core.stdc.time : time;
import core.time : MonoTime;

import empire : DAtty, MTterm, setran, TYPMAX, Mrowmx, Mcolmx, ROW, COL,
    X, MAPunknown, MAPcity, MAPsea, MAPland, mdMOVE;
import init : gameSetup;
import move : slice;
import eplayer : Player;
import display : Display;
import maps : revealUnderneath, RevealKind;
import ruler : rulerLine, rowRulerLabel, ROW_RULER_WIDTH;
import text : VBUFROWS, vbuffer;
import var : typx, typ, own, findTypeByChar;

// Hard-wired for now: 1 human player + 1 computer player. Same as
// textmain.d -- see that file's module comment for why this should
// eventually become a real player-count prompt or command-line option
// instead.
enum int NUMPLY = 2;

// Fallback/minimum Display.setdispsize() row/col size -- see
// computeDispSize()'s doc comment for why VBUFROWS/VBUFCOLS (used
// here in an earlier version of this file) doesn't work. Same values
// textmain.d hardcodes as its own starting point (DEFAULT_ROWS/
// DEFAULT_COLS there), before a real terminal resize replaces them.
enum int DEFAULT_ROWS = 24;
enum int DEFAULT_COLS = 80;

// Set once in main() before the game engine can call win_flush() or
// dialogCitySelect(); read only from the main thread, same one
// that set them.
private __gshared SDL_Renderer* renderer;
private __gshared SDL_Window* mainWindow;

// Set once in main(), after trying openMonoFont()'s candidate paths;
// stays null (and win_flush() just skips the text) if none of them
// panned out. Same read-only-after-startup, main-thread-only
// discipline as renderer/mainWindow above.
private __gshared TTF_Font* font;

// A cached, rendered glyph.  We don't render each glyph we need
// individually; instead we keep a cache of them ready for reuse.
private struct CachedGlyph
{
    SDL_Texture* texture;
    int width;
    int height;
}
private __gshared CachedGlyph[ulong] glyphCache;

// Horizontal scroll bias, in map columns, applied on top of drawMap()'s
// normal cursor-centring. Zero except while dialogModalCitySelect() is
// up, which sets it so the city the dialog is about (and its immediate
// neighbours) land beside the dialog's horizontally-centred box rather
// than underneath it -- see that function. Main-thread-only, same as
// the above.
private __gshared int mapColBias = 0;

// Overrides drawMap()'s usual curloc-centred column-0 (see its "Centre
// the viewport" comment) whenever it's >= 0. Set by
// scrollMapAwayFromDialog() just before the production dialog goes up,
// so the map underneath is scrolled clear of the dialog box instead of
// centred on the city the dialog is about to obscure; reset to -1 by
// dialogCitySelect() once the dialog closes. Main-thread-only, same as
// the rest of this module's __gshared state.
private __gshared int columnOriginOverride = -1;

// Candidate monospace font files to try, in order, until one opens.
// This repo doesn't bundle a font (c.f. dub.sdl's gui-sdl2 comment on
// libSDL2 itself needing to already be on the target system -- same
// idea, just for libSDL2_ttf's job of finding a .ttf); these are
// common install paths on Debian/Ubuntu and Fedora/RHEL. There's no
// config file or command-line option yet to make this a real setting
// instead of a guess list -- TODO.
private immutable string[] monoFontCandidates = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",	// Debian/Ubuntu
    "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",		// Fedora/RHEL
    "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
    "/usr/share/fonts/liberation-mono/LiberationMono-Regular.ttf",
    "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf",
];

private TTF_Font* openMonoFont(int ptsize)
{
    import std.string : toStringz;

    foreach (path; monoFontCandidates)
    {
        TTF_Font* f = TTF_OpenFont(toStringz(path), ptsize);
        if (f !is null)
            return f;
    }
    return null;
}

/*
 * Work out a row/col size for Display.setdispsize(), in character
 * cells, from the window's current pixel size and the loaded font's
 * metrics -- analogous to termSize() feeding textmain.d's
 * setdispsize() calls with the real terminal size.
 *
 * This fixes a real bug: main() used to pass VBUFROWS/VBUFCOLS (5,80)
 * straight through to gameSetup(), copying the pattern winmain.d uses
 * for its own setdispsize() call (see init.d's gameSetup() doc
 * comment). That's fine on Windows, where Display.pcur() has its own
 * version(Windows) branch that never touches Text.curs()/Tmax at all
 * -- but SDL2 isn't version(Windows), so pcur() falls into the same
 * branch textmain.d uses, which does bounds-check against Tmax via
 * Text.curs()'s assert. With only 5 rows (3 of them usable once
 * setdispsize() reserves 2 for borders -- see its Smax calculation),
 * moving the cursor almost anywhere on a 60-row map immediately blew
 * that assert. A real, generously-sized row/col count avoids it, the
 * same way textmain.d's DEFAULT_ROWS/DEFAULT_COLS (or a real terminal
 * size once one's known) always have.
 *
 * Falls back to DEFAULT_ROWS/DEFAULT_COLS if the font (and therefore
 * its metrics) isn't available, and never returns anything smaller
 * than that floor even when the font is available, in case the window
 * is very small -- setdispsize() already clamps the upper end itself
 * (see its "Scale back if display is bigger than we can use" comment
 * in display.d).
 */
private void computeDispSize(out int rows, out int cols)
{
    int charWidth, charHeight;
    int lineSkip;
    if (font is null || renderer is null ||
        (lineSkip = TTF_FontLineSkip(font)) <= 0 ||
        TTF_SizeUTF8(font, "0", &charWidth, &charHeight) != 0 ||
        charWidth <= 0)
    {
        rows = DEFAULT_ROWS;
        cols = DEFAULT_COLS;
        return;
    }

    int pixelWidth, pixelHeight;
    SDL_GetRendererOutputSize(renderer, &pixelWidth, &pixelHeight);

    rows = pixelHeight / lineSkip;
    cols = pixelWidth / charWidth;
    if (rows < DEFAULT_ROWS) rows = DEFAULT_ROWS;
    if (cols < DEFAULT_COLS) cols = DEFAULT_COLS;
}

// Map cell colours, chosen to match the RGB values the termios
// frontend's ANSI escapes (textmain.d's drawPlayerMap()) resolve to on
// a typical terminal -- bright red/yellow/magenta/cyan/white/green for
// players 1..6, plain blue sea and green land, the same mapping
// termio.d's ncurses colour pairs use (COLOR_RED, COLOR_BLUE, ...).
private immutable SDL_Color COLOUR_BLACK = SDL_Color(0, 0, 0, 255);
private immutable SDL_Color COLOUR_WHITE = SDL_Color(255, 255, 255, 255);
private immutable SDL_Color COLOUR_SEA   = SDL_Color(0, 0, 170, 255);
private immutable SDL_Color COLOUR_LAND  = SDL_Color(0, 170, 0, 255);
private immutable SDL_Color[7] playerColour = [
    COLOUR_WHITE,				// no player 0 (unused)
    SDL_Color(255, 85, 85, 255),		// player 1: red
    SDL_Color(255, 255, 85, 255),		// player 2: yellow
    SDL_Color(255, 85, 255, 255),		// player 3: magenta
    SDL_Color(85, 255, 255, 255),		// player 4: cyan
    SDL_Color(255, 255, 255, 255),		// player 5: white
    SDL_Color(85, 255, 85, 255),		// player 6: green
];


/*
 * Render one line of text (nul-terminated, as vbuffer[] rows and the
 * ruler strings below both are once passed through toStringz()) at
 * the given pixel position. Shared by the vbuffer text area and the
 * map rulers in win_flush() -- both are just rows of text at some
 * (x, y), differing only in what string and column they start at.
 *
 * font is assumed non-null; callers only reach this from within
 * win_flush()'s "if (font !is null)" block.
 */
private void drawText(int x, int y, const(char)* str, SDL_Color color)
{
    SDL_Surface* surface = TTF_RenderText_Solid(font, str, color);
    if (surface is null)
        return;	// e.g. a blank line, on some SDL_ttf versions

    SDL_Texture* texture = SDL_CreateTextureFromSurface(renderer, surface);
    SDL_Rect dst;
    dst.x = x;
    dst.y = y;
    dst.w = surface.w;
    dst.h = surface.h;
    SDL_FreeSurface(surface);

    if (texture !is null)
    {
        SDL_RenderCopy(renderer, texture, null, &dst);
        SDL_DestroyTexture(texture);
    }
}

private SDL_Texture* getGlyphTexture(char ch, SDL_Color colour,
    out int width, out int height)
{
    ulong key = cast(ulong) ch;
    key |= cast(ulong) colour.r << 8;
    key |= cast(ulong) colour.g << 16;
    key |= cast(ulong) colour.b << 24;
    key |= cast(ulong) colour.a << 32;

    if (auto cached = key in glyphCache)
    {
        width = (*cached).width;
        height = (*cached).height;
        return (*cached).texture;
    }

    char[2] buf;
    buf[0] = ch;
    buf[1] = '\0';

    SDL_Surface* surface =
        TTF_RenderText_Solid(font, buf.ptr, colour);
    if (surface is null)
    {
        width = height = 0;
        return null;
    }

    SDL_Texture* texture =
        SDL_CreateTextureFromSurface(renderer, surface);
    width = surface.w;
    height = surface.h;
    SDL_FreeSurface(surface);

    if (texture is null)
        return null;

    glyphCache[key] = CachedGlyph(texture, width, height);
    return texture;
}

private void clearGlyphCache()
{
    foreach (glyph; glyphCache.values)
    {
	if (glyph.texture !is null)
	    SDL_DestroyTexture(glyph.texture);
    }
    glyphCache.clear();
}

/*
 * Draw one map cell's glyph at the given screen position, in colour,
 * with an optional reverse-video style highlight (used for the cursor
 * cell) -- the SDL equivalent of the ncurses version's color_set()
 * plus attron(A_REVERSE)/attroff(A_REVERSE) around mvaddch(). SDL has
 * no terminal-style "reverse video" attribute, so it's faked here:
 * fill the cell with its own colour, then draw the glyph over that in
 * the background colour instead of drawing the glyph in its colour
 * over the (already black) background.
 */
private void drawCell(int x, int y, int cellWidth, int cellHeight,
    char ch, SDL_Color colour, bool highlighted)
{
    if (highlighted)
    {
        SDL_Rect rect;
        rect.x = x;
        rect.y = y;
        rect.w = cellWidth;
        rect.h = cellHeight;
        SDL_SetRenderDrawColor(renderer, colour.r, colour.g, colour.b, 255);
        SDL_RenderFillRect(renderer, &rect);
    }

    SDL_Colour glyphColour = highlighted
    	? COLOUR_BLACK
	: colour;
    int glyphWidth;
    int glyphHeight;
    SDL_Texture* texture =
    	getGlyphTexture(ch, glyphColour, glyphWidth, glyphHeight);
    if (texture is null)
    	return;

    SDL_Rect dst;
    dst.x = x;
    dst.y = y;
    dst.w = glyphWidth;
    dst.h = glyphHeight;
    SDL_RenderCopy(renderer, texture, null, &dst);
}

/*
 * Render the human player's known map, and its horizontal/vertical
 * rulers, below the vbuffer text area -- the SDL2 counterpart to
 * textmain.d's drawPlayerMapNcurses(). The viewport sizing, centring
 * on the cursor, and ruler placement all mirror that function
 * exactly; only the pixel-vs-character-cell bookkeeping and the
 * colour representation (RGB SDL_Color instead of an ncurses colour
 * pair) differ, since there's no character grid to work with here.
 *
 * Each map cell is shown as a single character -- var.d's typx[].unichr
 * for units, 'O' for an owned city, '*' for an unowned one, '~' for
 * sea, '+' for land, and a blank for still-unexplored territory. This
 * only reflects what the player actually knows (human.map, the
 * fog-of-war copy of the reference map), not the true state of the
 * whole board.
 *
 * One difference from drawPlayerMapNcurses(): that function's "blink"
 * for a unit in move mode is driven by textmain.d's main loop toggling
 * a shared blinkOn flag on a wall-clock timer, forcing a redraw every
 * 500ms even when nothing else changed. sdlmain.d's main loop has no
 * such timer yet (TODO), so blinkOn here is instead derived directly
 * from MonoTime on every call -- it'll show the right phase whenever a
 * redraw does happen, but (unlike the ncurses version) won't animate
 * on its own while the display is otherwise idle.
 */
/*
 * Horizontal geometry of the map viewport, in character cells, for
 * the window's current size: how wide a cell is, how many columns
 * the row ruler takes up, and how many columns of terrain are left
 * over. Shared by drawMap() (which used to compute this inline) and
 * dialogModalCitySelect() (which needs it to work out how far it can
 * shift the viewport before running out of map -- see mapColBias).
 *
 * Returns false, leaving the out params unset, if there's no font
 * loaded or the window's too narrow to bother -- same bail-out
 * conditions drawMap() already had inline.
 */
private bool mapHGeometry(out int charWidth, out int rowRulerWidth,
    out int terrainCols)
{
    if (font is null)
        return false;

    int charHeight;
    if (TTF_SizeUTF8(font, "0", &charWidth, &charHeight) != 0 || charWidth <= 0)
        return false;

    int pixelWidth, pixelHeight;
    SDL_GetRendererOutputSize(renderer, &pixelWidth, &pixelHeight);
    int availCols = pixelWidth / charWidth;
    if (availCols <= 0)
        return false;

    int mapCols = (availCols < Mcolmx + 1) ? availCols : Mcolmx + 1;

    // The row ruler takes over the left ROW_RULER_WIDTH columns from
    // the terrain, same as drawMap()'s showRuler does with its bottom
    // row.
    rowRulerWidth = (mapCols > ROW_RULER_WIDTH) ? ROW_RULER_WIDTH : 0;
    terrainCols = mapCols - rowRulerWidth;
    return true;
}

private void drawMap(int lineSkip, SDL_Color textColour)
{
    Player *human = getHuman();
    if (human is null || human.display is null)
        return;			// nothing to show yet

    int charWidth, rowRulerWidth, terrainCols;
    if (!mapHGeometry(charWidth, rowRulerWidth, terrainCols))
        return;

    int pixelWidth, pixelHeight;
    SDL_GetRendererOutputSize(renderer, &pixelWidth, &pixelHeight);

    // The vbuffer text area occupies the top VBUFROWS rows; whatever's
    // left below it is available for the map viewport.
    int availRows = pixelHeight / lineSkip - VBUFROWS;
    if (availRows <= 0)
        return;			// window too small to bother

    int mapRows = (availRows < Mrowmx + 1) ? availRows : Mrowmx + 1;

    // The bottom row of the viewport is the column ruler, not
    // terrain, as long as there's room for at least one terrain row
    // above it -- same condition drawPlayerMapNcurses() uses.
    bool showRuler = mapRows >= 2;
    int terrainRows = showRuler ? mapRows - 1 : mapRows;

    // Centre the viewport on the player's cursor, clamped to the map.
    // Clamp against terrainRows/terrainCols, not mapRows/mapCols: the
    // latter include the screen space the rulers just took over, which
    // isn't actually available for showing terrain, so clamping against
    // them would leave the map's bottom row and rightmost column(s)
    // permanently out of view no matter how far the viewport scrolls.
    int r0 = ROW(human.curloc) - terrainRows / 2;
    if (r0 < 0) r0 = 0;
    if (r0 > Mrowmx + 1 - terrainRows) r0 = Mrowmx + 1 - terrainRows;

    // Normally centred on the cursor, but scrollMapAwayFromDialog() overrides
    // this just before the production dialog goes up, to scroll the city it's
    /// about to prompt about away from under the dialog box.
    int c0 = (columnOriginOverride >= 0)
    	? columnOriginOverride
	: COL(human.curloc) - terrainCols / 2;
    if (c0 < 0) c0 = 0;
    if (c0 > Mcolmx + 1 - terrainCols) c0 = Mcolmx + 1 - terrainCols;

    int mapTop = VBUFROWS * lineSkip;

    // The unit being moved, if we're in move mode -- see drawCell()'s
    // callers below and the blinkOn doc comment above.
    bool moving = (human.mode == mdMOVE && human.usv !is null);
    int movingLoc = moving ? human.usv.loc : -1;

    long msecsElapsed = MonoTime.currTime.ticks * 1000 / MonoTime.ticksPerSecond;
    bool blinkOn = (msecsElapsed / 500) % 2 == 0;

    if (rowRulerWidth)
    {
        foreach (r; 0 .. terrainRows)
            drawText(0, mapTop + r * lineSkip,
                toStringz(rowRulerLabel(r0 + r)), textColour);
    }

    foreach (r; 0 .. terrainRows)
    {
        int y = mapTop + r * lineSkip;

        foreach (c; 0 .. terrainCols)
        {
            int x = (rowRulerWidth + c) * charWidth;
            int loc = (r0 + r) * (Mcolmx + 1) + (c0 + c);

            // The moving unit's own cell blinks between its own
            // highlighted image and revealUnderneath()'s answer for
            // what's underneath it (a city, the ship it's aboard,
            // etc. -- see maps.d), rather than following the normal
            // rendering below.
            if (moving && loc == movingLoc)
            {
                if (blinkOn)
                    drawCell(x, y, charWidth, lineSkip,
                        typx[human.usv.typ].unichr,
                        playerColour[human.usv.own], true);
                else
                {
                    char rch; int rowner;
                    auto kind = revealUnderneath(human.usv, rch, rowner);
                    SDL_Color rcolour = (kind == RevealKind.terrain)
                        ? (rch == '~' ? COLOUR_SEA : COLOUR_LAND)
                        : (rowner ? playerColour[rowner] : textColour);
                    drawCell(x, y, charWidth, lineSkip, rch, rcolour, false);
                }
                continue;
            }

            int v = human.map[loc];
            char ch;
            SDL_Color colour;

            switch (v)
            {
                case MAPunknown:
                    ch = ' ';
                    colour = textColour;
                    break;
                case MAPcity:
                    ch = '*';		// unowned city
                    colour = textColour;
                    break;
                case MAPsea:
                    ch = '~';
                    colour = COLOUR_SEA;
                    break;
                case MAPland:
                    ch = '+';
                    colour = COLOUR_LAND;
                    break;
                default:
                    int t = typ[v];
                    ch = (t == X) ? 'O' : typx[t].unichr;
                    colour = playerColour[own[v]];
                    break;
            }

            bool atCursor = (loc == human.curloc);
            drawCell(x, y, charWidth, lineSkip, ch, colour, atCursor);
        }
    }

    if (showRuler)
        drawText(rowRulerWidth * charWidth, mapTop + terrainRows * lineSkip,
            toStringz(rulerLine(c0, terrainCols)), textColour);
}


/*
 * text.d calls these two hooks (declared extern(C) there, with no
 * body -- each frontend provides its own) to flush output and to
 * signal the terminal bell. See the module comment above for what
 * win_flush() does NOT do yet.
 */
extern (C) void win_flush()
{
    if (renderer is null)
        return;

    SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    SDL_RenderClear(renderer);

    if (font !is null)
    {
        SDL_Color white;
        white.r = 255;
        white.g = 255;
        white.b = 255;
        white.a = 255;

        int lineSkip = TTF_FontLineSkip(font);

        foreach (row; 0 .. VBUFROWS)
        {
            // vbuffer[row] is a fixed-size, nul-terminated char[]
            // (text.d's clear() nul-terminates it), so .ptr is a
            // valid C string as-is -- same assumption winmain.d's
            // WM_PAINT handler makes about it (see the comment there).
	    drawText(0, row * lineSkip, vbuffer[row].ptr, white);
        }

	drawMap(lineSkip, white);
    }

    SDL_RenderPresent(renderer);
}

extern (C) void sound_click()
{
    // TODO: play click.wav -- needs an SDL audio device set up first.
}

/********************************
 * Fallback dialog box to get a city's production phase, used only
 * when no font is loaded (see dialogCitySelect() below) -- dumb but
 * functional, since it's a native OS dialog rather than something
 * this module draws itself.
 *
 * SDL_MessageBoxButtonData has no letter-accelerator concept, only
 * SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT/_ESCAPEKEY_DEFAULT, so this
 * can't offer the A/F/D/... shortcuts dialogModalCitySelect() does --
 * mouse (or Tab/Enter) only.
 */

private int dialogCitySelectMessageBox(int oldphase)
{
    SDL_MessageBoxButtonData[TYPMAX] buttons;
    foreach (i, ref b; buttons)
    {
        b.buttonid = cast(int) i;
        b.text = typx[i].name;
        if (cast(int) i == oldphase)
            b.flags = SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT;
    }

    SDL_MessageBoxData data;
    data.flags = SDL_MESSAGEBOX_INFORMATION;
    data.window = mainWindow;
    data.title = "City production";
    data.message = "Select what this city should produce.";
    data.numbuttons = TYPMAX;
    data.buttons = buttons.ptr;

    int buttonid = oldphase;
    if (SDL_ShowMessageBox(&data, &buttonid) != 0)
    {
        stderr.writefln("SDL_ShowMessageBox failed: %s", SDL_GetError().fromStringz);
        return oldphase;	// best effort: keep the previous phase
    }
    return buttonid;
}

/*
 * One row of the production dialog: its on-screen rectangle (used for
 * both drawing and mouse hit-testing) and the var.d typx[] index it
 * selects.
 */
private struct ProdButton
{
    SDL_Rect rect;
    int index;
}

// Shared padding constants for the production dialog box, used both
// by computeCityDialogLayout() (to size the box) and
// dialogModalCitySelect() (to position the title/message/buttons
// inside it).
private enum int DIALOG_PADX = 12;
private enum int DIALOG_PADY = 10;
private enum int DIALOG_GAP = 4;

/*
 * Everything about the production dialog's size and screen position
 * that scrollMapAwayFromDialog() needs to know before the dialog is
 * actually drawn, plus the bits dialogModalCitySelect() itself needs
 * so the two don't compute (and risk disagreeing about) the box
 * geometry twice. valid is false if there's no font loaded, matching
 * dialogModalCitySelect()'s own precondition.
 */
private struct CityDialogLayout
{
    bool valid;
    string[TYPMAX] labels;
    int lineSkip;
    int titleH, msgH;
    int boxX, boxY, boxW, boxH;
    int winW, winH;
}

private CityDialogLayout computeCityDialogLayout()
{
    CityDialogLayout L;
    if (font is null || renderer is null)
        return L;		// L.valid stays false

    immutable string title = "City production";
    immutable string message = "What should this city produce?";

    L.lineSkip = TTF_FontLineSkip(font);
    int boxW = 0;
    foreach (i; 0 .. TYPMAX)
    {
        L.labels[i] = format("%c - %s", typx[i].unichr, to!string(typx[i].name));
        int w, h;
        TTF_SizeUTF8(font, toStringz(L.labels[i]), &w, &h);
        if (w > boxW)
            boxW = w;
    }

    int titleW, msgW;
    TTF_SizeUTF8(font, toStringz(title), &titleW, &L.titleH);
    TTF_SizeUTF8(font, toStringz(message), &msgW, &L.msgH);
    if (titleW > boxW) boxW = titleW;
    if (msgW > boxW) boxW = msgW;

    boxW += DIALOG_PADX * 2;
    int rowH = L.lineSkip + DIALOG_GAP;
    L.boxW = boxW;
    L.boxH = DIALOG_PADY * 2 + L.titleH + DIALOG_GAP + L.msgH + DIALOG_GAP +
        TYPMAX * rowH;

    SDL_GetRendererOutputSize(renderer, &L.winW, &L.winH);
    L.boxX = (L.winW - L.boxW) / 2;
    L.boxY = (L.winH - L.boxH) / 2;
    if (L.boxX < 0) L.boxX = 0;
    if (L.boxY < 0) L.boxY = 0;

    L.valid = true;
    return L;
}

/********************************
 * Scroll the map viewport so the city about to have its production
 * phase asked about doesn't end up hidden behind the dialog box
 * layout describes -- otherwise, a city that's currently centred in
 * view (the common case: phasin() in eplayer.d
 * only re-centres the view when the city *isn't* already visible, so
 * a city already on screen is generally centred on the cursor, right
 * where the box goes) would vanish behind the dialog with no visual
 * link between the two.
 *
 * Only changes which part of the map is scrolled into view (via
 * columnOriginOverride, read by drawMap()); the player's cursor
 * location itself is untouched. Repaints immediately via win_flush()
 * so the frame dialogModalCitySelect()'s redraw() dims and draws its
 * box over already reflects the new scroll position.
 *
 * If the window is too narrow for the city to actually clear the box
 * in either direction (box plus city needing more width than the map
 * viewport has to scroll through), this is a best-effort no-op and
 * the dialog will simply cover the city, same as before this
 * function existed.
 */
private void scrollMapAwayFromDialog(in CityDialogLayout layout)
{
    Player *human = getHuman();
    if (!layout.valid || human is null || human.display is null)
        return;

    int charWidth, charHeight;
    if (TTF_SizeUTF8(font, "0", &charWidth, &charHeight) != 0 || charWidth <= 0)
        return;

    int availRows = layout.winH / layout.lineSkip - VBUFROWS;
    int availCols = layout.winW / charWidth;
    if (availRows <= 0 || availCols <= 0)
        return;

    int mapCols = (availCols < Mcolmx + 1) ? availCols : Mcolmx + 1;
    int rowRulerWidth = (mapCols > ROW_RULER_WIDTH) ? ROW_RULER_WIDTH : 0;
    int terrainCols = mapCols - rowRulerWidth;
    if (terrainCols <= 0)
        return;

    int maxC0 = Mcolmx + 1 - terrainCols;
    int col = COL(human.curloc);

    int defaultC0 = col - terrainCols / 2;
    if (defaultC0 < 0) defaultC0 = 0;
    if (defaultC0 > maxC0) defaultC0 = maxC0;

    // Where the city's cell would land on screen under the normal
    // (centred-on-cursor) scroll position, and whether that overlaps
    // the dialog box horizontally -- if it doesn't (e.g. the city was
    // close enough to a map edge that defaultC0 got clamped away from
    // dead centre), there's nothing to do.
    int cellX = (rowRulerWidth + col - defaultC0) * charWidth;
    if (cellX + charWidth <= layout.boxX ||
        cellX >= layout.boxX + layout.boxW)
        return;

    // Candidate scroll positions that would put the city just to the
    // left, or just to the right, of the box (one column of margin
    // either side); each is only valid if it's reachable without
    // scrolling past the map's own edge.
    int leftC0  = col - (layout.boxX / charWidth - rowRulerWidth) + 1;
    int rightC0 = col - ((layout.boxX + layout.boxW) / charWidth -
        rowRulerWidth) - 1;

    bool leftOk  = leftC0  >= 0 && leftC0  <= maxC0;
    bool rightOk = rightC0 >= 0 && rightC0 <= maxC0;

    int newC0;
    if (leftOk && (!rightOk || abs(leftC0 - defaultC0) <= abs(rightC0 - defaultC0)))
        newC0 = leftC0;
    else if (rightOk)
        newC0 = rightC0;
    else
        return;		// can't clear the box either way -- give up

    columnOriginOverride = newC0;
    win_flush();
}

/********************************
 * Dialog box to get a city's production phase, drawn and driven by
 * hand instead of via SDL_ShowMessageBox() -- needed to get the same
 * A/F/D/T/S/R/C/B keyboard shortcuts textmain.d's dialogCitySelect()
 * offers (see var.d's typx[].unichr and findTypeByChar()), which
 * SDL_MessageBoxButtonData has no way to express: its only
 * accelerator-like flags are SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT
 * and _ESCAPEKEY_DEFAULT, not arbitrary per-button letters.
 *
 * Like SDL_ShowMessageBox() (see the old version of this function's
 * comment, kept above on dialogCitySelectMessageBox()), this pumps
 * its own SDL_WaitEvent() loop for as long as it's on screen, so it
 * doesn't depend on sdlmain.d's main loop at all -- including during
 * game setup, before that loop has even started. An SDL_QUIT seen
 * here is re-queued with SDL_PushEvent() rather than acted on
 * directly, so the main loop still does the actual quitting once this
 * function returns.
 *
 * Needs the font loaded by main() to draw any text at all; if that
 * failed (see openMonoFont()), dialogCitySelect() falls back to
 * dialogCitySelectMessageBox() instead of calling this.
 *
 * Input:
 *	oldphase = city's previous production phase (0..TYPMAX-1),
 *	           already clamped into range by dialogCitySelect().
 * Returns:
 *	Index into var.d's typx[] for the chosen production type.
 */

private int dialogModalCitySelect(int oldphase, in CityDialogLayout layout)
{
    immutable string title = "City production";
    immutable string message =
        "What should this city produce?";

    string[TYPMAX] labels = layout.labels;
    int lineSkip = layout.lineSkip;
    int titleH = layout.titleH, msgH = layout.msgH;
    int boxX = layout.boxX, boxY = layout.boxY;
    int boxW = layout.boxW, boxH = layout.boxH;
    int winW = layout.winW, winH = layout.winH;

    enum int PADX = DIALOG_PADX;
    enum int PADY = DIALOG_PADY;
    enum int GAP = DIALOG_GAP;

    int rowH = lineSkip + GAP;

    // This box sits horizontally centred, right on top of where
    // drawMap() would otherwise centre the viewport on the city being
    // asked about -- exactly where a new city (seabound? landlocked?
    // coastal?) most needs to be seen. Push the viewport off centre,
    // in whichever direction the map actually has room for, so the
    // city and its immediate neighbours end up visible beside the box
    // instead of hidden under it; see mapColBias's doc comment and
    // redraw() below, which is what actually applies this.
    mapColBias = 0;
    {
        Player *human = getHuman();
        int hCharWidth, hRowRulerWidth, terrainCols;
        if (human !is null && mapHGeometry(hCharWidth, hRowRulerWidth, terrainCols))
        {
            int maxC0 = Mcolmx + 1 - terrainCols;
            int baseC0 = COL(human.curloc) - terrainCols / 2;
            if (baseC0 < 0) baseC0 = 0;
            if (baseC0 > maxC0) baseC0 = maxC0;

            // A quarter of the viewport's width is enough to clear a
            // centred box that's much narrower than the window, and
            // at least 2 columns guarantees the city's immediate
            // (west/east) neighbours specifically, even in a tiny
            // window.
            int shiftCols = terrainCols / 4;
            if (shiftCols < 2)
                shiftCols = 2;

            int eastC0 = baseC0 + shiftCols;	// city moves screen-left
            if (eastC0 > maxC0) eastC0 = maxC0;
            int westC0 = baseC0 - shiftCols;	// city moves screen-right
            if (westC0 < 0) westC0 = 0;

            // Near a map edge, one of these directions clamps straight
            // back down to little or no actual shift -- use whichever
            // direction achieved the bigger real move.
            int devEast = eastC0 - baseC0;
            int devWest = baseC0 - westC0;
            mapColBias = (devEast >= devWest) ? shiftCols : -shiftCols;
        }
    }
    scope(exit) mapColBias = 0;

    ProdButton[TYPMAX] buttons;
    int y = boxY + PADY + titleH + GAP + msgH + GAP;
    foreach (i; 0 .. TYPMAX)
    {
        buttons[i].index = cast(int) i;
        buttons[i].rect = SDL_Rect(boxX + PADX, y, boxW - PADX * 2, lineSkip);
        y += rowH;
    }

    void redraw()
    {
        // Repaint the map/text view first, rather than dimming and
        // boxing over whatever the last frame happened to leave in
        // the backbuffer: that's the only way the mapColBias set
        // above actually reaches the screen.
        win_flush();

        // Dim the game view so the dialog reads as being on top of it,
        // the way a real modal window would.
        SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND);
        SDL_SetRenderDrawColor(renderer, 0, 0, 0, 160);
        SDL_Rect full = SDL_Rect(0, 0, winW, winH);
        SDL_RenderFillRect(renderer, &full);
        SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_NONE);

        SDL_Rect box = SDL_Rect(boxX, boxY, boxW, boxH);
        SDL_SetRenderDrawColor(renderer, 20, 20, 20, 255);
        SDL_RenderFillRect(renderer, &box);
        SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
        SDL_RenderDrawRect(renderer, &box);

        drawText(boxX + PADX, boxY + PADY, toStringz(title), COLOUR_WHITE);
        drawText(boxX + PADX, boxY + PADY + titleH + GAP, toStringz(message),
            COLOUR_WHITE);

        foreach (i; 0 .. TYPMAX)
        {
            // Highlight the previous phase, same as the
            // RETURNKEY_DEFAULT button used to -- Enter picks it.
            if (cast(int) i == oldphase)
            {
                SDL_SetRenderDrawColor(renderer, 70, 70, 70, 255);
                SDL_RenderFillRect(renderer, &buttons[i].rect);
                SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
                SDL_RenderDrawRect(renderer, &buttons[i].rect);
            }
            drawText(buttons[i].rect.x + 4, buttons[i].rect.y,
                toStringz(labels[i]), COLOUR_WHITE);
        }

        SDL_RenderPresent(renderer);
    }

    redraw();

    for (;;)
    {
        SDL_Event event;
        if (SDL_WaitEvent(&event) == 0)
        {
            stderr.writefln("SDL_WaitEvent failed: %s", SDL_GetError());
            return oldphase;	// best effort: keep the previous phase
        }

        switch (event.type)
        {
            case SDL_QUIT:
                // Don't quit here -- let the main loop see this event
                // and shut down normally once this function returns.
                SDL_PushEvent(&event);
                return oldphase;

            case SDL_KEYDOWN:
            {
                SDL_Keycode sym = event.key.keysym.sym;
                if (sym == SDLK_ESCAPE)
                    return oldphase;
                if (sym == SDLK_RETURN || sym == SDLK_KP_ENTER)
                    return oldphase;	// Enter picks the highlighted default

                // SDL's keycodes for the basic Latin range equal their
                // ASCII codepoints (same assumption main()'s keydown
                // handling makes) -- uppercase and look it up the same
                // way eplayer.d's text-frontend dialogCitySelect()
                // does via findTypeByChar(toUpper(ch)).
                if (sym >= 'a' && sym <= 'z')
                    sym -= 'a' - 'A';
                int i = findTypeByChar(cast(int) sym);
                if (i >= 0)
                    return i;
                break;	// not a production-type letter: ignore it
            }

            case SDL_MOUSEBUTTONDOWN:
                if (event.button.button == SDL_BUTTON_LEFT)
                {
                    int mx = event.button.x, my = event.button.y;
                    foreach (i; 0 .. TYPMAX)
                    {
                        SDL_Rect r = buttons[i].rect;
                        if (mx >= r.x && mx < r.x + r.w &&
                            my >= r.y && my < r.y + r.h)
                            return cast(int) i;
                    }
                }
                break;

            case SDL_WINDOWEVENT:
                // Keep the dialog visible/correctly placed across a
                // resize or after being uncovered, the same idea as
                // main()'s SDL_WINDOWEVENT_SIZE_CHANGED handling for
                // the normal map view.
                if (event.window.event == SDL_WINDOWEVENT_EXPOSED ||
                    event.window.event == SDL_WINDOWEVENT_SIZE_CHANGED)
                    redraw();
                break;

            default:
                break;
        }
    }
}

/********************************
 * Dialog box to get a city's production phase.
 *
 * This is the SDL2 counterpart to winmain.d's dialogCitySelect(): same
 * name, same signature, alternative implementation -- eplayer.d picks
 * whichever one matches the active frontend with a version(Windows)/
 * version(SDL2) check, the same way it already does for the import.
 * eplayer.d's phasin() polls TTin() for a keypress when there's no
 * dialog to delegate to, but TTin() only ever sees input that's been
 * fed in via TTunget(), and that only happens from this module's
 * main-loop keydown handling -- which can't run while phasin() itself
 * is blocking the same (single) thread. dialogModalCitySelect() (and,
 * as a fallback, dialogCitySelectMessageBox()) sidestep that the same
 * way Windows' modal DialogBoxParamA() does: each pumps its own event
 * loop for as long as it's on screen, so neither depends on
 * sdlmain.d's main loop at all -- including during game setup, before
 * that loop has even started.
 *
 * Input:
 *	oldphase = city's previous production phase (0..TYPMAX-1), or
 *	           an out-of-range value for a new city.
 * Returns:
 *	Index into var.d's typx[] for the chosen production type.
 */

int dialogCitySelect(int oldphase)
{
    if (oldphase < 0 || oldphase >= TYPMAX)
        oldphase = 0;		// default to Army, same as winmain.d

    // dialogModalCitySelect() needs the font to draw anything at all
    // (see openMonoFont()); if it's not there, fall back to the
    // native message box instead of putting up a dialog with no text
    // and no visible way to tell one button from another. Computed
    // once here so scrollMapAwayFromDialog() and
    // dialogModalCitySelect() agree on exactly where the box will go.
    CityDialogLayout layout = computeCityDialogLayout();

    int result;
    if (!layout.valid)
        result = dialogCitySelectMessageBox(oldphase);
    else
    {
        // Scroll the city into the clear before the box (and its
        // dimmed backdrop) are drawn over it -- see that function's
        // doc comment for why this doesn't already happen on its own.
        scrollMapAwayFromDialog(layout);
        result = dialogModalCitySelect(oldphase, layout);
    }

    // Undo scrollMapAwayFromDialog()'s scroll, if any, now that the
    // dialog it was compensating for is gone -- otherwise the map
    // would stay scrolled off-cursor until the player moved the
    // cursor again.
    columnOriginOverride = -1;

    // Either path leaves the screen showing the dialog (or, for the
    // message box, whatever the OS drew over the window); repaint the
    // normal map/text view now rather than leaving that up on screen
    // until something else happens to trigger a win_flush().
    win_flush();

    return result;
}


/***********************
 * Return the human player, if any.
 *
 * Mirrors textmain.d's getHuman(); duplicated rather than shared
 * because it's three lines and not worth a new module dependency.
 */
Player *getHuman()
{
    return Player.get(1);
}

int main()
{
    immutable SDLSupport loaded = loadSDL();
    if (loaded != sdlSupport)
    {
        stderr.writeln("Failed to load SDL2. Is libSDL2 installed?");
        return 1;
    }

    if (SDL_Init(SDL_INIT_VIDEO) != 0)
    {
        stderr.writefln("SDL_Init failed: %s", SDL_GetError().fromStringz);
        return 1;
    }
    scope (exit)
        SDL_Quit();

    SDL_Window* window = SDL_CreateWindow("Empire (SDL2)",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        640, 480, SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE);
    if (window is null)
    {
        stderr.writefln("SDL_CreateWindow failed: %s", SDL_GetError().fromStringz);
        return 1;
    }
    scope (exit)
        SDL_DestroyWindow(window);

    mainWindow = window;

    renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
    if (renderer is null)
    {
        stderr.writefln("SDL_CreateRenderer failed: %s", SDL_GetError().fromStringz);
        return 1;
    }
    scope (exit)
        SDL_DestroyRenderer(renderer);
    scope (exit)
    	clearGlyphCache();

    // Text rendering is best-effort: if SDL_ttf won't load or no
    // candidate font opens, font just stays null and win_flush() skips
    // drawing the vbuffer text instead of failing the whole program --
    // see the module comment and openMonoFont()'s doc comment.
    bool ttfReady = false;
    if (loadSDLTTF() != sdlTTFSupport)
    {
	stderr.writeln("SDL2_ttf unavailable; can't draw text area.");
    }
    else if (TTF_Init() != 0)
    {
	stderr.writeln("TTF_Init() failed; can't draw text area.");
    }
    else if ((font = openMonoFont(16)) is null)
    {
	stderr.writeln("No monospace font found; vbuffer text won't be drawn.");
    }
    else
    {
	ttfReady = true;
    }
    scope (exit)
    {
        if (font !is null)
            TTF_CloseFont(font);
        if (ttfReady)
            TTF_Quit();
    }

    setran(cast(uint) time(null));

    // humanWatch/humanMaptab are DAtty/MTterm rather than a dedicated
    // DA*/MT* pair for SDL, since nothing in display.d/text.d branches
    // on those values for anything but "is this player being watched
    // at all" -- see init.d's gameSetup() doc comment for the meaning
    // of the rest of the parameters. rows/cols come from
    // computeDispSize(), not VBUFROWS/VBUFCOLS -- see that function's
    // doc comment for why.
    int rows, cols;
    computeDispSize(rows, cols);
    gameSetup(NUMPLY, false, DAtty, MTterm, rows, cols);

    Player *human = getHuman();
    if (human.display)
        human.display.text.flush();

    bool quit = false;
    while (!quit)
    {
	SDL_Event event;

        // Drain all pending events before ticking the engine, the way
        // winmain.d's PeekMessage loop drains messages before calling
        // slice() on idle -- SDL_PollEvent is non-blocking, same as
        // PeekMessage(..., PM_REMOVE).
        while (SDL_PollEvent(&event) != 0)
        {
	    if (event.type == SDL_QUIT)
	    {
	        quit = true;
		break;
	    }

            if (event.type == SDL_KEYDOWN)
            {
		SDL_Keysym keysym = event.key.keysym;
		SDL_Keycode sym = keysym.sym;
                if (sym == SDLK_q &&
                    (keysym.mod & KMOD_CTRL) != 0)
                {
                    quit = true;
                    break;
                }

                // Forward ordinary ASCII-range keys straight to the
                // engine, the way winmain.d's WM_CHAR handler does.
                // TTinr() uppercases on the way out, so case doesn't
                // matter here. SDL's keycodes for the basic Latin
                // range equal their ASCII codepoints, which is what
                // this range check relies on.
                if (sym >= 0 && sym < 128 && human.display)
                    human.display.text.TTunget(cast(int) sym);
            }

            // While the user is dragging an edge, SDL delivers a
            // steady stream of these instead of running the main loop,
            // so repaint right here -- otherwise the window shows
            // stale (or garbage) content until the drag ends. The
            // renderer's target already tracks the window's pixel
            // size on its own; win_flush() just needs to be called.
            //
            // Also re-run computeDispSize() and feed it to
            // setdispsize(), the same way textmain.d's termResized()
            // dance keeps Text.Tmax/Display.Smax matching the real
            // terminal size -- otherwise a resize (typically growing
            // the window) leaves the engine's cursor-placement bounds
            // stuck at whatever they were at startup.
            if (event.type == SDL_WINDOWEVENT &&
                event.window.event == SDL_WINDOWEVENT_SIZE_CHANGED)
            {
                if (human.display)
                {
                    int newRows, newCols;
                    computeDispSize(newRows, newCols);
                    human.display.setdispsize(newRows, newCols);
                }
                win_flush();
            }
        }

        if (quit)
            break;

        // slice() (via hmove()) already blocks briefly (up to 500ms)
        // when it's the human's turn and no key is queued yet -- see
        // text.d's TTin() -- so this doesn't need its own delay/cap to
        // avoid pegging the CPU, same as textmain.d's loop.
        if (slice() != 0)
            break;
    }

    return 0;
}
