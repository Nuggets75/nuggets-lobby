-- Lag Clicker song library (Minigames addition).
--
-- The first entry, Off, is the original endless mode. The selector cycles through this
-- list in order.
--
-- To add a song:
--   1. put its map in   /nuggetslobby/minigames/songs/<id>.lua   (Easy / Normal / Hard, generated)
--   2. put its audio in /nuggetslobby/minigames/sounds/          (XACT .xwb + .xsb, unique bank name)
--   3. add an entry here
--
--   bank, cue : the XACT sound bank and cue that play the song (sounds/<bank>.xsb/.xwb).
--               LagClickerOne's cue names end in _normal_clicks from the conversion, but the
--               audio in it is the plain song (no clicks).
--   artist    : optional
--   offset    : seconds the audio starts late after it is triggered. Raise it if the
--               circles feel early compared to the music, lower it if they feel late.

Songs = {
    { id = 'off', title = 'Off' },
    {
        id = 'circle_the_halls', title = 'circle the halls', artist = 'nekodex',
        bank = 'LagClickerOne', cue = 'circle_the_halls_normal_clicks', offset = 0,
    },
    {
        id = 'circles', title = 'circles!', artist = 'nekodex',
        bank = 'LagClickerOne', cue = 'circles_normal_clicks', offset = 0,
    },
    {
        id = 'triangles', title = 'triangles', artist = 'cYsmix',
        bank = 'LagClickerOne', cue = 'triangles_normal_clicks', offset = 0,
    },
    {
        id = 'future_battlefield', title = 'The Future Battlefield',
        bank = 'LagClickerTwo', cue = 'Hardstyle_The_Future_Battlefield', offset = 0,
    },
    {
        id = 'one_planet', title = 'One Planet at a Time',
        bank = 'LagClickerTwo', cue = 'Electrified_One_Planet_at_a_time', offset = 0,
    },
}
