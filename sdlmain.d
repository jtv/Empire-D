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
    char[2] buf;
    buf[0] = ch;
    buf[1] = '\0';

    if (highlighted)
    {
        SDL_Rect rect;
        rect.x = x;
        rect.y = y;
        rect.w = cellWidth;
        rect.h = cellHeight;
        SDL_SetRenderDrawColor(renderer, colour.r, colour.g, colour.b, 255);
        SDL_RenderFillRect(renderer, &rect);
        drawText(x, y, buf.ptr, COLOUR_BLACK);
    }
    else
        drawText(x, y, buf.ptr, colour);
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
private void drawMap(int lineSkip, SDL_Color textColour)
{
    Player *human = getHuman();
    if (human is null || human.display is null)
        return;			// nothing to show yet

    int charWidth, charHeight;
    if (TTF_SizeUTF8(font, "0", &charWidth, &charHeight) != 0 || charWidth <= 0)
        return;

    int pixelWidth, pixelHeight;
    SDL_GetRendererOutputSize(renderer, &pixelWidth, &pixelHeight);

    // The vbuffer text area occupies the top VBUFROWS rows; whatever's
    // left below it is available for the map viewport.
    int availRows = pixelHeight / lineSkip - VBUFROWS;
    int availCols = pixelWidth / charWidth;
    if (availRows <= 0 || availCols <= 0)
        return;			// window too small to bother

    int mapRows = (availRows < Mrowmx + 1) ? availRows : Mrowmx + 1;
    int mapCols = (availCols < Mcolmx + 1) ? availCols : Mcolmx + 1;

    // The bottom row of the viewport is the column ruler, not
    // terrain, as long as there's room for at least one terrain row
    // above it -- same condition drawPlayerMapNcurses() uses.
    bool showRuler = mapRows >= 2;
    int terrainRows = showRuler ? mapRows - 1 : mapRows;

    // The row ruler takes over the left ROW_RULER_WIDTH columns from
    // the terrain, same as showRuler does with the bottom row.
    int rowRulerWidth = (mapCols > ROW_RULER_WIDTH) ? ROW_RULER_WIDTH : 0;
    int terrainCols = mapCols - rowRulerWidth;

    // Centre the viewport on the player's cursor, clamped to the map.
    // Clamp against terrainRows/terrainCols, not mapRows/mapCols: the
    // latter include the screen space the rulers just took over, which
    // isn't actually available for showing terrain, so clamping against
    // them would leave the map's bottom row and rightmost column(s)
    // permanently out of view no matter how far the viewport scrolls.
    int r0 = ROW(human.curloc) - terrainRows / 2;
    if (r0 < 0) r0 = 0;
    if (r0 > Mrowmx + 1 - terrainRows) r0 = Mrowmx + 1 - terrainRows;

    int c0 = COL(human.curloc) - terrainCols / 2;
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

private int dialogModalCitySelect(int oldphase)
{
    immutable string title = "City production";
    immutable string message =
        "What should this city produce?";

    string[TYPMAX] labels;
    int lineSkip = TTF_FontLineSkip(font);
    int boxW = 0;
    foreach (i; 0 .. TYPMAX)
    {
        labels[i] = format("%c - %s", typx[i].unichr, to!string(typx[i].name));
        int w, h;
        TTF_SizeUTF8(font, toStringz(labels[i]), &w, &h);
        if (w > boxW)
            boxW = w;
    }

    int titleW, titleH, msgW, msgH;
    TTF_SizeUTF8(font, toStringz(title), &titleW, &titleH);
    TTF_SizeUTF8(font, toStringz(message), &msgW, &msgH);
    if (titleW > boxW) boxW = titleW;
    if (msgW > boxW) boxW = msgW;

    enum int PADX = 12;
    enum int PADY = 10;
    enum int GAP = 4;

    boxW += PADX * 2;
    int rowH = lineSkip + GAP;
    int boxH = PADY * 2 + titleH + GAP + msgH + GAP + TYPMAX * rowH;

    int winW, winH;
    SDL_GetRendererOutputSize(renderer, &winW, &winH);
    int boxX = (winW - boxW) / 2;
    int boxY = (winH - boxH) / 2;
    if (boxX < 0) boxX = 0;
    if (boxY < 0) boxY = 0;

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
    // and no visible way to tell one button from another.
    int result = (font is null)
        ? dialogCitySelectMessageBox(oldphase)
        : dialogModalCitySelect(oldphase);

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
