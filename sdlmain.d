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
 *     it, the horizontal/vertical map rulers (see drawMapRulers()) --
 *     but not the map terrain itself.  There is no SDL_Renderer-based
 *     equivalent yet of textmain.d's drawPlayerMap() or winmain.d's
 *     map/sprite GDI blitting.
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
 *     is handled well enough to keep it repainted while dragging, but
 *     there's no equivalent yet of textmain.d's termResized()/
 *     setdispsize() dance -- win_flush() has no map/message content to
 *     re-lay-out at the new size anyway (see above).
 *
 * The *.bmp tiles and *.wav sounds this configuration already copies
 * next to the executable are still unused until the above is written.
 */

module sdlmain;

import bindbc.sdl;
import std.stdio : stderr, writeln, writefln;
import std.string : toStringz;

import core.stdc.time : time;

import empire : DAtty, MTterm, setran, TYPMAX, Mrowmx, Mcolmx, ROW, COL;
import init : gameSetup;
import move : slice;
import eplayer : Player;
import display : Display;
import ruler : rulerLine, rowRulerLabel, ROW_RULER_WIDTH;
import text : VBUFROWS, VBUFCOLS, vbuffer;
import var : typx;

// Hard-wired for now: 1 human player + 1 computer player. Same as
// textmain.d -- see that file's module comment for why this should
// eventually become a real player-count prompt or command-line option
// instead.
enum int NUMPLY = 2;

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
 * Horizontal and vertical map rulers, drawn below the vbuffer text
 * area -- the SDL2 counterpart to textmain.d's drawPlayerMapNcurses()
 * use of rulerLine()/rowRulerLabel(), except there's no map terrain
 * to go with them yet (see the module comment above). The layout
 * mirrors that function exactly -- same viewport sizing, centred on
 * the cursor, same ROW_RULER_WIDTH-column/bottom-row placement -- so
 * the rulers will already line up correctly once terrain drawing
 * catches up to them.
 *
 * Unlike a character-cell terminal, the SDL window's size is in
 * pixels, so it's converted to a map-column/row viewport size using
 * the monospace font's fixed glyph width and TTF_FontLineSkip().
 */
private void drawMapRulers(int lineSkip, SDL_Color color)
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

    // Centre the viewport on the player's cursor, clamped to the map.
    int r0 = ROW(human.curloc) - mapRows / 2;
    if (r0 < 0) r0 = 0;
    if (r0 > Mrowmx + 1 - mapRows) r0 = Mrowmx + 1 - mapRows;

    int c0 = COL(human.curloc) - mapCols / 2;
    if (c0 < 0) c0 = 0;
    if (c0 > Mcolmx + 1 - mapCols) c0 = Mcolmx + 1 - mapCols;

    // The bottom row of the viewport is the column ruler, not
    // terrain, as long as there's room for at least one terrain row
    // above it -- same condition drawPlayerMapNcurses() uses.
    bool showRuler = mapRows >= 2;
    int terrainRows = showRuler ? mapRows - 1 : mapRows;

    // The row ruler takes over the left ROW_RULER_WIDTH columns from
    // the terrain, same as showRuler does with the bottom row.
    int rowRulerWidth = (mapCols > ROW_RULER_WIDTH) ? ROW_RULER_WIDTH : 0;
    int terrainCols = mapCols - rowRulerWidth;

    int mapTop = VBUFROWS * lineSkip;

    if (rowRulerWidth)
    {
        foreach (r; 0 .. terrainRows)
            drawText(0, mapTop + r * lineSkip,
                toStringz(rowRulerLabel(r0 + r)), color);
    }

    if (showRuler)
        drawText(rowRulerWidth * charWidth, mapTop + terrainRows * lineSkip,
            toStringz(rulerLine(c0, terrainCols)), color);
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

	drawMapRulers(lineSkip, white);
    }

    SDL_RenderPresent(renderer);
}

extern (C) void sound_click()
{
    // TODO: play click.wav -- needs an SDL audio device set up first.
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
 * is blocking the same (single) thread. SDL_ShowMessageBox() sidesteps
 * that the same way Windows' modal DialogBoxParamA() does: it pumps
 * its own event loop for as long as it's on screen, so it doesn't
 * depend on sdlmain.d's main loop at all -- including during game
 * setup, before that loop has even started.
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
        stderr.writefln("SDL_ShowMessageBox failed: %s", SDL_GetError());
        return oldphase;	// best effort: keep the previous phase
    }
    return buttonid;
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
        stderr.writefln("SDL_Init failed: %s", SDL_GetError());
        return 1;
    }
    scope (exit)
        SDL_Quit();

    SDL_Window* window = SDL_CreateWindow("Empire (SDL2)",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        640, 480, SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE);
    if (window is null)
    {
        stderr.writefln("SDL_CreateWindow failed: %s", SDL_GetError());
        return 1;
    }
    scope (exit)
        SDL_DestroyWindow(window);

    mainWindow = window;

    renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
    if (renderer is null)
    {
        stderr.writefln("SDL_CreateRenderer failed: %s", SDL_GetError());
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
    // of the rest of the parameters. rows/cols is VBUFROWS/VBUFCOLS,
    // same as winmain.d passes, not a real screen size -- see that
    // same doc comment for why.
    gameSetup(NUMPLY, false, DAtty, MTterm, VBUFROWS, VBUFCOLS);

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
            if (event.type == SDL_WINDOWEVENT &&
                event.window.event == SDL_WINDOWEVENT_SIZE_CHANGED)
            {
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
