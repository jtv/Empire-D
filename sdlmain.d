/*
 * sdlmain.d
 *
 * Entry point for the SDL2 frontend.
 *
 * No SDL2 frontend exists yet -- this is a placeholder in the same
 * spirit as textmain.d was for the text frontends: it proves that the
 * "gui-sdl2" dub configuration actually links and runs against SDL2
 * (via bindbc-sdl, loaded dynamically at runtime), by loading the
 * library, opening a window, and waiting for the user to close it.
 *
 * None of the game engine (init.d, move.d, display.d, eplayer.d, ...)
 * is wired up here yet. A real frontend still needs to be written:
 * translating Display's drawing calls into SDL_Render* calls, mapping
 * the *.bmp tiles and *.wav sounds this configuration already copies
 * next to the executable, and feeding keyboard/mouse SDL_Event's into
 * the engine the way winmain.d does for Win32 messages and textmain.d
 * does for terminal keystrokes.
 */

module sdlmain;

import bindbc.sdl;
import std.stdio : stderr, writeln, writefln;

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

    SDL_Window* window = SDL_CreateWindow("Empire (SDL2 stub)",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        640, 480, SDL_WINDOW_SHOWN);
    if (window is null)
    {
        stderr.writefln("SDL_CreateWindow failed: %s", SDL_GetError());
        return 1;
    }
    scope (exit)
        SDL_DestroyWindow(window);

    bool quit = false;
    SDL_Event event;
    while (!quit)
    {
        while (SDL_WaitEvent(&event) != 0)
        {
	    quit = quit || (
	        (event.type == SDL_QUIT) ||
		(event.type == SDL_KEYDOWN &&
	             event.key.keysym.sym == SDLK_q &&
		     (event.key.keysym.mod & KMOD_CTRL) != 0)
	    );
	    if (quit)
		break;
        }
    }

    return 0;
}
