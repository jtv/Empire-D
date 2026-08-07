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
 *   - win_flush() does not draw the map or message area. There is no
 *     SDL_Renderer-based equivalent yet of textmain.d's vbuffer/
 *     drawPlayerMap() printing, or winmain.d's GDI blitting. It only
 *     clears and presents the (currently blank) window, to prove the
 *     hook is really wired to a live SDL_Renderer.
 *   - sound_click() is a no-op, same status as textmain.d's version.
 *     winmain.d's plays click.wav; doing that here needs an SDL audio
 *     device (SDL_mixer, or SDL_LoadWAV + SDL_QueueAudio) that hasn't
 *     been set up.
 *   - Keyboard input only forwards ASCII-range SDLK_* keydowns
 *     (letters, digits, space, enter, ...) straight to TTunget(), the
 *     way winmain.d's WM_CHAR handler does. Arrow/function keys and
 *     text-input-with-modifiers (SDL_TEXTINPUT) aren't mapped to
 *     anything.
 *   - No mouse handling, no window-resize handling (c.f. textmain.d's
 *     termResized()/setdispsize() dance).
 *
 * The *.bmp tiles and *.wav sounds this configuration already copies
 * next to the executable are still unused until the above is written.
 */

module sdlmain;

import bindbc.sdl;
import std.stdio : stderr, writeln, writefln;

import core.stdc.time : time;

import empire : DAtty, MTterm, setran, TYPMAX;
import init : gameSetup;
import move : slice;
import eplayer : Player;
import display : Display;
import text : VBUFROWS, VBUFCOLS;
import var : typx;

// Hard-wired for now: 1 human player + 1 computer player. Same as
// textmain.d -- see that file's module comment for why this should
// eventually become a real player-count prompt or command-line option
// instead.
enum int NUMPLY = 2;

// Set once in main() before the game engine can call win_flush() or
// dialogCitySelectSDL(); read only from the main thread, same one
// that set them.
private __gshared SDL_Renderer* renderer;
private __gshared SDL_Window* mainWindow;

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
    SDL_RenderPresent(renderer);
}

extern (C) void sound_click()
{
    // TODO: play click.wav -- needs an SDL audio device set up first.
}

/********************************
 * Dialog box to get a city's production phase.
 *
 * Mirrors winmain.d's dialogCitySelect(): eplayer.d's phasin() polls
 * TTin() for a keypress when there's no dialog to delegate to, but
 * TTin() only ever sees input that's been fed in via TTunget(), and
 * that only happens from this module's main-loop keydown handling --
 * which can't run while phasin() itself is blocking the same (single)
 * thread. SDL_ShowMessageBox() sidesteps that the same way Windows'
 * modal DialogBoxParamA() does: it pumps its own event loop for as
 * long as it's on screen, so it doesn't depend on sdlmain.d's main
 * loop at all -- including during game setup, before that loop has
 * even started.
 *
 * Input:
 *	oldphase = city's previous production phase (0..TYPMAX-1), or
 *	           an out-of-range value for a new city.
 * Returns:
 *	Index into var.d's typx[] for the chosen production type.
 */

int dialogCitySelectSDL(int oldphase)
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
        640, 480, SDL_WINDOW_SHOWN);
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
