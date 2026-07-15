/*
 * feedback.d
 *
 * Audio/visual feedback hooks called by the platform-neutral display
 * logic (display.d, eplayer.d) when game events happen: explosions,
 * gunfire, sector redraws, and so on.
 *
 * These were originally defined directly inside winmain.d. Their
 * bodies were already correctly version(Windows)-gated internally --
 * a real Win32 call under Windows, a no-op everywhere else -- but
 * living inside winmain.d, which is excluded entirely from
 * non-Windows builds, meant importing them broke the link on any
 * other platform. This file just gives them a home that's part of
 * every configuration. No behavior change on Windows.
 *
 * sound_click() is deliberately NOT here: unlike everything below,
 * it has a genuinely different implementation per frontend (a real
 * .wav under the GUI, a terminal bell under the text frontend), so
 * it stays declared directly where each frontend needs it, matching
 * the extern(C) pattern text.d already uses for win_flush().
 */

module feedback;

import empire : loc_t, ROW, COL, MAPSIZE;

version (Windows)
{
    import core.sys.windows.windows;
    import winmain : global, LocToX, LocToY;
}

/******************************************
 * Invalidate entire sector.
 */

void invalidateSector()
{
    version (Windows)
    {
	InvalidateRect(global.hwnd, &global.sector, false);
    }
}

/*************************************
 * Invalidate display of loc on the screen, so
 * it will get updated.
 */

void invalidateLoc(loc_t loc)
{
    version (Windows)
    {
	RECT rect;
	int r, c;
	int dx;
	int dy;
	DWORD mode;

//PRINTF("invalidateLoc(loc = %d)\n", loc);
	assert(loc < MAPSIZE);

	r = ROW(loc) - ROW(global.ulcorner);
	c = COL(loc) - COL(global.ulcorner);
	dx = cast(int)(10 * global.scalex);
	dy = cast(int)(10 * global.scaley);

	rect.left = c * dx - global.offsetx;
	rect.top = 40 + r * dy - global.offsety;
	rect.right = rect.left + dx;
	rect.bottom = rect.top + dy;

	InvalidateRect(global.hwnd, &rect, false);
    }
}


/******************************
 * Play a sound.
 *
 * If sync is true, play it just once.  If false, loop forever.
 */
void play_sample(const(char) *path, bool sync)
{
    version (Windows)
    {
	UpdateWindow(global.hwnd);
	if (global.speaker)
	{
	    int repetition = (sync ? SND_SYNC : (SND_ASYNC | SND_NOSTOP));
	    PlaySoundA(path, null, SND_FILENAME, repetition);
	}
    }
}


/******************************
 * Various sounds.
 */

void sound_gun()
{
    play_sample("gun_1.wav", true);
}

void sound_bang()
{
    play_sample("explosi1.wav", true);
    play_sample("bubbles.wav", true);
}

void sound_error()
{
    play_sample("error.wav", true);
}

void sound_splash()
{
    play_sample("splash.wav", true);
}

void sound_aground()
{
    play_sample("bubbles.wav", true);
}

void sound_subjugate()
{
    play_sample("machine1.wav", true);
}

void sound_crushed()
{
    play_sample("gun_3.wav", true);
}

void sound_flyby()
{
    play_sample("flyby.wav", true);
}

void sound_fcrash()
{
    play_sample("explode.wav", true);
}

void sound_fuel()
{
    play_sample("fuel.wav", true);
}

void sound_taps()
{
    play_sample("taps.wav", true);
}

void sound_ackack()
{
    play_sample("ackack1.wav", true);
}


/*********************************************
 * Start/Stop blast graphic.
 */

void ShowBlast(int state, loc_t loc)
{
    version (Windows)
    {
        RECT blastbox;
        int x, y;

        x = LocToX(loc);
        y = LocToY(loc);
        blastbox.bottom = y + 5;
        blastbox.top = blastbox.bottom - 20;
        blastbox.left = x - 10;
        blastbox.right = x + 10;
        InvalidateRect(global.hwnd, &blastbox, false);
        global.blastState = state;
        global.blastx = blastbox.left;
        global.blasty = blastbox.top;
        if (state)
	    UpdateWindow(global.hwnd);
    }
}
