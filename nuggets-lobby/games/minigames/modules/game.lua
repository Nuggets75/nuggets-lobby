-- Lag Clicker: the mini-game window and the toggle button on the connection window.
--
-- Minigames addition: a song library. "Off" is the original endless mode, unchanged.
-- Song mode plays a song and spawns circles from a pre-made map (songs/<id>.lua).
-- A volume slider sets the songs' volume.
--
-- Blue circles: click when the shrinking ring reaches the circle.
-- Red circles: do not click, they disappear on their own.
-- Runs on wall-clock time (CurrentTime), so it works while the sim is stalled.
--
-- The window is resizable. Game logic works in "field units" (0..C.FIELD);
-- P() converts them to pixels using the field's current size, so circles,
-- hit tests and popups all scale with the window.

local UIUtil        = import('/lua/ui/uiutil.lua')
local LayoutHelpers = import('/lua/maui/layouthelpers.lua')
local Bitmap        = import('/lua/maui/bitmap.lua').Bitmap
local Dragger       = import('/lua/maui/dragger.lua').Dragger
local Window        = import('/lua/maui/window.lua').Window
local Prefs         = import('/lua/user/prefs.lua')
local Net           = import('/nuggetslobby/minigames/modules/net.lua')

local TEX = '/nuggetslobby/minigames/textures/'
local SONG_DIR = '/nuggetslobby/minigames/songs/'       -- song library and maps

local C = {
    FIELD     = 360,    -- logical field size (field units)
    FIELD_MIN = 240,    -- smallest field when resizing (design pixels)
    PANEL     = 210,    -- score panel width
    PAD       = 10,
    HUD       = 56,     -- space above the field for score and health
    TITLE     = 30,     -- Window title bar height
    EXTRA_W   = 12,     -- window border allowance
    EXTRA_H   = 14,
    PRESETS   = { { label = 'S', field = 260 }, { label = 'M', field = 360 }, { label = 'L', field = 520 } },

    -- speed scales ring closing time and time between circles; score scales points per hit
    DIFFS     = {
        { label = 'Easy',   speed = 0.75, score = 0.5 },
        { label = 'Normal', speed = 1,    score = 1   },
        { label = 'Hard',   speed = 2,    score = 2   },
    },
    DIFF_DEFAULT = 2,
    PREF_DIFF    = 'LagClicker_Difficulty',
    PANEL_TOP    = 98,  -- panel content starts below difficulty, song selector, volume and No Fail
    NOFAIL_TOP   = 74,  -- No Fail toggle row
    PREF_NOFAIL  = 'LagClicker_NoFail',
    SONG_TOP     = 28,  -- song selector row
    VOLUME_TOP   = 52,  -- volume slider row
    PREF_VOLUME  = 'LagClicker_Volume',
    VOLUME_DEFAULT = 1.0,
    VOLUME_STEP  = 0.05,
    -- The songs' cues are in the XACT category "Default". No sound of the game itself uses
    -- it (checked across all 90 sound banks), so this volume only affects the songs, and the
    -- game's master volume still applies on top.
    SOUND_CATEGORY = 'Default',
    PREF_SONG    = 'LagClicker_Song',
    PREF_SONGBEST = 'LagClicker_SongBest_v1',
    SONG_TAIL    = 1.0, -- seconds after the last note before a song counts as cleared
    AUDIO_OFFSET = 0,   -- extra audio delay in seconds for every song (each song also has its own)
    COLOR_FRAMES = 32,  -- textures circle_00..circle_31: blue, dark blue, purple, dark red, back to blue
    COLOR_CYCLE  = 10,  -- seconds for one full colour cycle
    LAUNCHER_SIZE = 28, -- the small always-available open button
    PREF_LAUNCHER = 'LagClicker_Launcher',
    POOL      = 8,      -- most circles on screen at once
    POPUPS    = 10,
    ROWS      = 8,      -- most rows per score list (fewer when the window is short)
    ROW_H     = 16,
    NAME_LEN  = 18,

    LEVEL_SECONDS = 15, -- the game speeds up every 15 seconds

    WIN_PERFECT = 0.07, -- seconds from the ring closing: 300 points
    WIN_GREAT   = 0.14, -- 100 points
    WIN_OK      = 0.22, -- 50 points; later than this is a miss

    HP_MAX   = 100,
    HP_MISS  = 12,
    HP_DECOY = 20,
    HEAL_300 = 4,
    HEAL_100 = 2,
    HEAL_50  = 1,
    EARLY_POINTS = 20,  -- clicked before the 50 window: fewer points, but not a miss
    NOFAIL_MULT  = 0.5, -- No Fail halves the score (as in osu!)

    COMBO_CAP     = 60, -- combo multiplier: 1 + min(combo, 60) / 15, so at most x5
    COMBO_DIV     = 15,
    POPUP_TIME    = 0.6,

    -- combo indicator next to the cursor
    COMBO_MIN       = 2,     -- show from this combo up (and breaks of at least this size)
    COMBO_TIME      = 0.35,  -- seconds on screen
    COMBO_TIME_BIG  = 0.5,   -- milestones (every COMBO_MILESTONE)
    COMBO_MILESTONE = 10,
    COMBO_FULL      = 50,    -- combo at which the green is at full brightness
    FLICKER_FROM    = 25,    -- from here the colour alternates green / gold
    COMBO_LO        = { 200, 247, 197 },   -- very light green
    COMBO_HI        = { 57, 255, 20 },     -- very bright green
    COL_GOLD        = 'ffffd700',
    COL_BREAK       = 'ffff3b30',
    RESTART_GUARD = 0.8, -- ignore clicks this long after a game over
    SPAWN_GAP     = 8,

    COL_300   = 'ff7fe7ff',
    COL_100   = 'ff8fe37a',
    COL_50    = 'fff2d16b',
    COL_MISS  = 'ffff5a4a',
    COL_TEXT  = 'ffdfe6ee',
    COL_DIM   = 'ff8a96a3',
    COL_ME    = 'ffffd25a',
    COL_FIELD = 'ff0c1016',
    COL_HPBG  = 'ff2a3038',
    COL_HP    = 'ff4fc3f7',
    COL_HPLOW = 'ffff5a4a',
    COL_BTN   = 'ff2c3440',
    COL_BTNHI = 'ff4a5a6e',
    COL_SEL   = 'ff2f6fa8',
}

local G = {
    win = false, field = false, client = false,
    targets = {}, popups = {}, hud = {}, overlay = {}, panel = {},
    comboPop = false,       -- the single combo indicator next to the cursor
    colorFrame = -1,        -- colour frame currently shown on the circles
    launcher = false,       -- the small open button
    openedBy = false,       -- 'dialog' | 'launcher' | 'console'
    mode = 'idle',          -- 'idle' | 'play' | 'over'
    start = 0, nextSpawn = 0, overAt = 0,
    hp = 0, score = 0, combo = 0, maxCombo = 0, level = 1,
    n300 = 0, n100 = 0, n50 = 0, nMiss = 0,
    result = false,         -- last finished run
    rowsShown = C.ROWS,
    diff = C.DIFF_DEFAULT,  -- index into C.DIFFS
    diffStart = C.DIFF_DEFAULT,
    diffMixed = false,      -- difficulty changed during the current run
    diffBtns = {},
    dialogBtn = false,
    listening = false,
    broken = false,
    songs = false,          -- song library, loaded on first use
    songIdx = 1,            -- index into the library; 1 = Off (endless mode)
    song = false,           -- the run's song: { entry, m = difficulty map, next, length }
    songHandle = false,     -- sound handle of the playing song
    songEndAt = 0,          -- CurrentTime() when the song audio is over
    songSel = false,        -- selector widgets
    volume = C.VOLUME_DEFAULT,  -- song volume 0..1
    volSel = false,         -- volume slider widgets
    noFail = false,         -- No Fail chosen (songs only)
    runNoFail = false,      -- the current run is a No Fail run
    nfBtn = false,          -- No Fail toggle
    nEarly = 0,
}

local D = {}                -- current difficulty, reused every frame

local Show, Hide, UpdateSongSelector, UpdateNoFailButton   -- forward declarations, filled by assignment below

-- design pixels -> screen pixels (UI scale)
local function S(n) return LayoutHelpers.ScaleNumber(n) end

-- field units -> screen pixels (current field size)
local function P(v) return math.floor(v * G.field.Width() / C.FIELD) end

local function Play(cue)
    local ok, err = pcall(function() PlaySound(Sound({ Bank = 'Interface', Cue = cue })) end)
    if not ok then WARN('LagClicker: sound ' .. tostring(cue) .. ' failed: ' .. tostring(err)) end
end

local function Elapsed() return CurrentTime() - G.start end

local function Difficulty(now)
    local lv = 1 + math.floor(now / C.LEVEL_SECONDS)
    local k  = lv - 1
    D.level     = lv
    D.approach  = math.max(0.45, 1.25 - 0.06 * k)   -- ring closing time, seconds
    D.interval  = math.max(0.28, 0.95 - 0.05 * k)   -- seconds between circles
    D.radius    = math.max(17, 30 - 1.2 * k)        -- circle radius, field units
    D.maxActive = math.min(C.POOL, 3 + math.floor(lv / 3))
    if lv >= 3 then
        D.decoy = math.min(0.3, 0.08 * (lv - 2))    -- chance a circle is red
    else
        D.decoy = 0
    end
    local speed = C.DIFFS[G.diff].speed
    D.approach = D.approach / speed
    D.interval = D.interval / speed
    return D
end

local function DiffLabel()
    if G.diffMixed then return 'Mixed' end
    return C.DIFFS[G.diff].label
end

local function Accuracy()
    local total = G.n300 + G.n100 + G.n50 + G.nEarly + G.nMiss
    if total == 0 then return 100 end
    return (300 * G.n300 + 100 * G.n100 + 50 * G.n50 + C.EARLY_POINTS * G.nEarly) / (3 * total)
end

local function ShortName(name)
    name = tostring(name or '?')
    if string.len(name) > C.NAME_LEN then
        return string.sub(name, 1, C.NAME_LEN - 1) .. '.'
    end
    return name
end

-- position helpers: offsets in design pixels, evaluated lazily so they follow the window
local function SetTopOff(ctrl, off)
    local client = G.client
    ctrl.Top:Set(function() return client.Top() + S(off) end)
end

local function SetPanelLeft(ctrl)
    local field = G.field
    ctrl.Left:Set(function() return field.Right() + S(C.PAD) end)
end

----------------------------------------------------------------------------
-- Song library. Entry 1 is "Off": the endless mode.
----------------------------------------------------------------------------

local function Library()
    if not G.songs then
        local ok, mod = pcall(import, SONG_DIR .. 'library.lua')
        if ok and mod and type(mod.Songs) == 'table' and table.getn(mod.Songs) > 0 then
            G.songs = mod.Songs
        else
            WARN('LagClicker: song library failed: ' .. tostring(mod))
            G.songs = { { id = 'off', title = 'Off' } }
        end
    end
    return G.songs
end

-- the selected library entry, or nil when Off
local function SelectedSong()
    local e = Library()[G.songIdx]
    if not e or e.id == 'off' then return nil end
    return e
end

-- the song's map module (Length, Easy, Normal, Hard), loaded once
local function LoadSongMap(entry)
    if entry.map == nil then
        local ok, mod = pcall(import, SONG_DIR .. entry.id .. '.lua')
        if ok and mod then
            entry.map = mod
        else
            WARN('LagClicker: map for ' .. tostring(entry.id) .. ' failed: ' .. tostring(mod))
            entry.map = false
        end
    end
    return entry.map
end

local function SongBest(id, diffLabel)
    local all = Prefs.GetFromCurrentProfile(C.PREF_SONGBEST)
    if type(all) ~= 'table' or type(all[id]) ~= 'table' then return 0 end
    return tonumber(all[id][diffLabel]) or 0
end

-- Saved per song and difficulty on this PC. The shared score list stays endless-only.
local function SubmitSongRun(id, diffLabel, score)
    if score <= SongBest(id, diffLabel) then return false end
    local all = Prefs.GetFromCurrentProfile(C.PREF_SONGBEST)
    if type(all) ~= 'table' then all = {} end
    if type(all[id]) ~= 'table' then all[id] = {} end
    all[id][diffLabel] = score
    Prefs.SetToCurrentProfile(C.PREF_SONGBEST, all)
    SavePreferences()
    return true
end

local function ApplyVolume()
    local ok, err = pcall(SetVolume, C.SOUND_CATEGORY, G.volume)
    if not ok then WARN('LagClicker: setting the volume failed: ' .. tostring(err)) end
end

local function LoadVolume()
    local v = tonumber(Prefs.GetFromCurrentProfile(C.PREF_VOLUME))
    if v and v >= 0 and v <= 1 then G.volume = v end
end

local function StopSong(immediate)
    G.songEndAt = 0
    if not G.songHandle then return end
    local h = G.songHandle
    G.songHandle = false
    local ok, err = pcall(StopSound, h, immediate and true or false)
    if not ok then WARN('LagClicker: stopping the song failed: ' .. tostring(err)) end
end

local function StartSong(entry, length)
    StopSong(true)
    ApplyVolume()
    local ok, res = pcall(function() return PlaySound(Sound({ Bank = entry.bank, Cue = entry.cue })) end)
    if not ok then
        WARN('LagClicker: song ' .. tostring(entry.bank) .. '/' .. tostring(entry.cue) .. ' failed: ' .. tostring(res))
    elseif res then
        G.songHandle = res
        G.songEndAt = CurrentTime() + (length or 0) + 0.5
    end
end

-- difficulty multiplier, halved in a No Fail run (outside a run: what the next run would use)
local function ScoreMult()
    local m = C.DIFFS[G.diff].score
    local nf = G.runNoFail
    if G.mode ~= 'play' then nf = G.noFail and SelectedSong() ~= nil end
    if nf then m = m * C.NOFAIL_MULT end
    return m
end

----------------------------------------------------------------------------
-- HUD, overlay and score panel
----------------------------------------------------------------------------

local function UpdateHud()
    local h = G.hud
    h.score:SetText(string.format('Score  %d', G.score))
    h.combo:SetText(string.format('Combo  %d', G.combo))
    h.acc:SetText(string.format('Accuracy  %.1f%%', Accuracy()))
    if SelectedSong() then
        h.level:SetText(string.format('x%g   %d%%', ScoreMult(), G.level))
    else
        h.level:SetText(string.format('x%g   Level %d', ScoreMult(), G.level))
    end
    local hp = math.max(0, math.min(C.HP_MAX, G.hp))
    if hp <= 0 then
        h.hpFill:Hide()
    else
        local frac = hp / C.HP_MAX
        local field = G.field
        h.hpFill:Show()
        h.hpFill.Width:Set(function() return math.max(1, math.floor(field.Width() * frac)) end)
    end
    if hp < 30 then h.hpFill:SetSolidColor(C.COL_HPLOW) else h.hpFill:SetSolidColor(C.COL_HP) end
end

local function SetOverlay(title, titleColor, lines)
    local o = G.overlay
    o.title:SetText(title)
    o.title:SetColor(titleColor)
    for i = 1, table.getn(o.lines) do
        o.lines[i]:SetText(lines[i] or '')
    end
end

local function ShowOverlay()
    local o = G.overlay
    local song = SelectedSong()
    if G.mode == 'over' and G.result and G.result.song then
        local r = G.result
        local title, col = 'FAILED', C.COL_MISS
        if r.cleared then title, col = 'SONG CLEAR', C.COL_300 end
        if r.newBest then title, col = 'NEW BEST!', C.COL_ME end
        local last = string.format('Progress  %d%%', r.level)
        if r.cleared then last = string.format('Song best  %d', SongBest(r.song.id, r.diffKey)) end
        SetOverlay(title, col, {
            tostring(r.song.title) .. (r.song.artist and ('  -  ' .. tostring(r.song.artist)) or ''),
            string.format('Score  %d', r.score),
            string.format('Max combo  %d', r.maxCombo),
            string.format('Accuracy  %.1f%%', r.acc),
            last,
            'Difficulty  ' .. r.diff .. (r.noFail and '  (No Fail)' or ''),
            'Click to play again',
        })
    elseif G.mode == 'over' and G.result then
        local r = G.result
        local title, col = 'GAME OVER', C.COL_MISS
        if r.newBest then title, col = 'NEW BEST!', C.COL_ME end
        SetOverlay(title, col, {
            string.format('Score  %d', r.score),
            string.format('Max combo  %d', r.maxCombo),
            string.format('Accuracy  %.1f%%', r.acc),
            string.format('Level reached  %d', r.level),
            'Difficulty  ' .. r.diff,
            '',
            'Click to play again',
        })
    elseif song then
        SetOverlay('LAG CLICKER', C.COL_300, {
            tostring(song.title),
            song.artist and ('by ' .. tostring(song.artist)) or '',
            '',
            'Click the circles on the beat,',
            'as the ring closes.',
            'Misses cost health.',
            'Click to start',
        })
    else
        SetOverlay('LAG CLICKER', C.COL_300, {
            'Click blue circles',
            'as the ring closes.',
            'Never click the X circles.',
            'Misses cost health.',
            '',
            'Click to start',
        })
    end
    o.title:Show()
    for i = 1, table.getn(o.lines) do o.lines[i]:Show() end
end

local function HideOverlay()
    local o = G.overlay
    o.title:Hide()
    for i = 1, table.getn(o.lines) do o.lines[i]:Hide() end
end

local function FillRows(rows, entries, valueKey, me)
    for i = 1, C.ROWS do
        local row = rows[i]
        local e = entries[i]
        if e then
            row.name:SetText(string.format('%d. %s', i, ShortName(e.n)))
            row.value:SetText(string.format('%d', e[valueKey] or 0))
            if e.n == me then
                row.name:SetColor(C.COL_ME)
                row.value:SetColor(C.COL_ME)
            else
                row.name:SetColor(C.COL_TEXT)
                row.value:SetColor(C.COL_TEXT)
            end
        else
            row.name:SetText(i == 1 and '-' or '')
            row.value:SetText('')
        end
    end
end

local function RefreshPanel()
    if not G.win then return end
    local p  = G.panel
    local me = Net.GetMyName()
    local song = SelectedSong()
    if song then
        local label = C.DIFFS[G.diff].label
        p.bestLabel:SetText('SONG BEST')
        p.best:SetText(string.format('%d', SongBest(song.id, label)))
        p.gameBest:SetText(label .. ' - ' .. tostring(song.title))
        p.sessionLabel:SetText('ENDLESS MODE: THIS GAME')
        p.boardLabel:SetText('ENDLESS MODE: ALL-TIME')
    else
        p.bestLabel:SetText('YOUR BEST')
        p.best:SetText(string.format('%d', Net.GetBest()))
        p.gameBest:SetText(string.format('This game: %d', Net.GetGameBest()))
        p.sessionLabel:SetText('PLAYERS IN THIS GAME')
        p.boardLabel:SetText('ALL-TIME (SEEN BY YOU)')
    end
    FillRows(p.sessionRows, Net.GetSession(), 'best', me)
    FillRows(p.boardRows, Net.GetBoard(), 's', me)
end

-- Fit the two score lists to the window height. Called on show and on every resize.
local function Relayout()
    if not G.win or G.win:IsHidden() then return end
    local p = G.panel
    local height = LayoutHelpers.InvScaleNumber(G.client.Height())
    -- fixed panel parts: difficulty row, best block 72, two list labels 18 + 28, notes 34
    local n = math.floor((height - 152 - C.PANEL_TOP) / (2 * C.ROW_H))
    n = math.max(1, math.min(C.ROWS, n))
    G.rowsShown = n

    local y = C.PANEL_TOP + 90
    for i = 1, C.ROWS do
        local row = p.sessionRows[i]
        SetTopOff(row.name, y + (i - 1) * C.ROW_H)
        SetTopOff(row.value, y + (i - 1) * C.ROW_H)
        if i <= n then row.name:Show() row.value:Show() else row.name:Hide() row.value:Hide() end
    end
    y = y + n * C.ROW_H + 10
    SetTopOff(p.boardLabel, y)
    y = y + 18
    for i = 1, C.ROWS do
        local row = p.boardRows[i]
        SetTopOff(row.name, y + (i - 1) * C.ROW_H)
        SetTopOff(row.value, y + (i - 1) * C.ROW_H)
        if i <= n then row.name:Show() row.value:Show() else row.name:Hide() row.value:Hide() end
    end
end

----------------------------------------------------------------------------
-- Circles and judgement popups
----------------------------------------------------------------------------

local function Deactivate(t)
    t.active = false
    t.bmp:Hide()
    t.dec:Hide()
    t.ring:Hide()
end

-- the bitmap that is visible for this circle
local function Face(t)
    if t.decoy then return t.dec end
    return t.bmp
end

local function ColorTextures()
    local list = {}
    for i = 0, C.COLOR_FRAMES - 1 do
        table.insert(list, string.format('%scircle_%02d.dds', TEX, i))
    end
    return list
end

-- All clickable circles share one colour that drifts slowly through the cycle.
local function UpdateColors()
    local phase = math.mod(CurrentTime() / C.COLOR_CYCLE, 1)
    local frame = math.min(C.COLOR_FRAMES - 1, math.floor(phase * C.COLOR_FRAMES))
    if frame == G.colorFrame then return end
    G.colorFrame = frame
    for i = 1, C.POOL do
        G.targets[i].bmp:SetFrame(frame)
    end
end

local function Popup(t, label, color)
    local p = nil
    for i = 1, C.POPUPS do
        if not G.popups[i].active then p = G.popups[i] break end
    end
    if not p then return end
    local field = G.field
    local px = t.x
    local text = p.text
    p.active = true
    p.t0 = CurrentTime()
    p.y = t.y
    text:SetText(label)
    text:SetColor(color)
    text:SetAlpha(1)
    text.Left:Set(function() return field.Left() + P(px) - math.floor(text.Width() / 2) end)
    text.Top:Set(field.Top() + P(p.y) - S(8))
    text:Show()
end

local function UpdatePopups()
    local now = CurrentTime()
    local field = G.field
    for i = 1, C.POPUPS do
        local p = G.popups[i]
        if p.active then
            local age = now - p.t0
            if age >= C.POPUP_TIME then
                p.active = false
                p.text:Hide()
            else
                p.text:SetAlpha(1 - age / C.POPUP_TIME)
                p.text.Top:Set(field.Top() + P(p.y) - S(8 + math.floor(age * 30)))
            end
        end
    end
end

-- light green -> bright green with the combo; from FLICKER_FROM it alternates with gold,
-- faster from COMBO_FULL. Breaks are always red.
local function ComboColor(n, broken, age)
    if broken then return C.COL_BREAK end
    if n >= C.FLICKER_FROM then
        local period = 0.1
        if n >= C.COMBO_FULL then period = 0.06 end
        if math.mod(math.floor(age / period), 2) == 1 then return C.COL_GOLD end
    end
    local k = math.min(1, n / C.COMBO_FULL)
    local lo, hi = C.COMBO_LO, C.COMBO_HI
    return string.format('ff%02x%02x%02x',
        math.floor(lo[1] + (hi[1] - lo[1]) * k),
        math.floor(lo[2] + (hi[2] - lo[2]) * k),
        math.floor(lo[3] + (hi[3] - lo[3]) * k))
end

local function PlaceComboPop(age)
    local p, field = G.comboPop, G.field
    local text = p.text
    local x = math.max(0, math.min(p.ox, field.Width() - text.Width()))
    local y = math.max(0, math.min(p.oy - S(math.floor(age * 40)), field.Height() - text.Height()))
    text.Left:Set(field.Left() + x)
    text.Top:Set(field.Top() + y)
end

-- Show the combo (or the combo just lost) briefly next to the cursor.
local function ComboPop(n, broken, mx, my)
    local p = G.comboPop
    local field = G.field
    if not mx then
        local pos = GetMouseScreenPos()
        if not pos then return end
        mx, my = pos[1], pos[2]
    end
    p.active = true
    p.t0 = CurrentTime()
    p.n = n
    p.broken = broken
    local big = (not broken) and math.mod(n, C.COMBO_MILESTONE) == 0
    if big then p.dur = C.COMBO_TIME_BIG else p.dur = C.COMBO_TIME end
    p.ox = mx - field.Left() + S(16)            -- below-right of the cursor, off the circle
    p.oy = my - field.Top() + S(10)
    local text = p.text
    if broken then
        text:SetText(string.format('%dx lost', n))
    else
        text:SetText(string.format('%dx', n))
    end
    if big then text:SetFont(UIUtil.bodyFont, 18) else text:SetFont(UIUtil.bodyFont, 13) end
    text:SetColor(ComboColor(n, broken, 0))
    text:SetAlpha(1)
    PlaceComboPop(0)
    text:Show()
end

local function UpdateComboPop()
    local p = G.comboPop
    if not p.active then return end
    local age = CurrentTime() - p.t0
    if age >= p.dur then
        p.active = false
        p.text:Hide()
        return
    end
    local text = p.text
    local hold = 0.4 * p.dur                    -- full strength first, then fade out
    if age > hold then text:SetAlpha(1 - (age - hold) / (p.dur - hold)) end
    text:SetColor(ComboColor(p.n, p.broken, age))
    PlaceComboPop(age)
end

-- mx, my: cursor position, or nil when the circle expired without a click
local function Miss(t, label, hpLoss, mx, my)
    local lost = G.combo
    G.nMiss = G.nMiss + 1
    G.combo = 0
    G.hp = math.max(0, G.hp - hpLoss)
    Popup(t, label, C.COL_MISS)
    if lost >= C.COMBO_MIN then ComboPop(lost, true, mx, my) end
    Play('UI_Menu_Error_01')
    UpdateHud()
end

-- early: clicked before the 50 window; still a hit, with fewer points and no healing
local function Hit(t, value, mx, my, early)
    local heal, col = C.HEAL_50, C.COL_50
    if early then
        G.nEarly = G.nEarly + 1
        heal = 0
    elseif value == 300 then
        G.n300 = G.n300 + 1
        heal, col = C.HEAL_300, C.COL_300
    elseif value == 100 then
        G.n100 = G.n100 + 1
        heal, col = C.HEAL_100, C.COL_100
    else
        G.n50 = G.n50 + 1
    end
    G.combo = G.combo + 1
    if G.combo > G.maxCombo then G.maxCombo = G.combo end
    local mult = 1 + math.min(G.combo, C.COMBO_CAP) / C.COMBO_DIV
    G.score = G.score + math.floor(value * mult * ScoreMult())
    G.hp = math.min(C.HP_MAX, G.hp + heal)
    Popup(t, early and 'EARLY' or tostring(value), col)
    if G.combo >= C.COMBO_MIN then ComboPop(G.combo, false, mx, my) end
    Play('UI_Tab_Click_01')
    UpdateHud()
end

local function FreeSpot(r)
    for attempt = 1, 12 do
        local x = math.random(r + 4, C.FIELD - r - 4)
        local y = math.random(r + 4, C.FIELD - r - 4)
        local clear = true
        for i = 1, C.POOL do
            local o = G.targets[i]
            if o.active then
                local dx, dy = x - o.x, y - o.y
                local min = r + o.r + C.SPAWN_GAP
                if dx * dx + dy * dy < min * min then clear = false break end
            end
        end
        if clear then return x, y end
    end
    return nil
end

-- Lay out and show a circle from t.x, t.y, t.r (endless and song mode).
local function ShowTarget(t)
    local x, y, r = t.x, t.y, t.r
    -- lazy: follows the field when the window is moved or resized mid-run.
    -- t.dec and t.ring are laid out from t.bmp, so only t.bmp is placed.
    local field = G.field
    t.bmp.Width:Set(function() return P(2 * r) end)
    t.bmp.Height:Set(function() return P(2 * r) end)
    t.bmp.Left:Set(function() return field.Left() + P(x - r) end)
    t.bmp.Top:Set(function() return field.Top() + P(y - r) end)
    t.ring.Width:Set(P(6 * r))
    t.ring.Height:Set(P(6 * r))
    local face = Face(t)
    face:SetAlpha(0)
    t.ring:SetAlpha(0)
    if t.decoy then t.bmp:Hide() else t.dec:Hide() end
    face:Show()
    t.ring:Show()
    t.active = true
end

local function Spawn(now)
    local t = nil
    local active = 0
    for i = 1, C.POOL do
        local o = G.targets[i]
        if o.active then active = active + 1 elseif not t then t = o end
    end
    if not t or active >= D.maxActive then return false end
    local r = math.floor(D.radius)
    local x, y = FreeSpot(r)
    if not x then return false end

    t.x, t.y, t.r = x, y, r
    t.spawn    = now
    t.hit      = now + D.approach
    t.approach = D.approach
    t.decoy    = math.random() < D.decoy
    ShowTarget(t)
    return true
end

-- Song mode: one map note { time, x, y } becomes one circle.
local function SpawnNote(note, m)
    local t = nil
    for i = 1, C.POOL do
        if not G.targets[i].active then t = G.targets[i] break end
    end
    if not t then return false end
    t.x, t.y, t.r = note[2], note[3], m.radius
    t.hit      = note[1]
    t.approach = m.approach
    t.spawn    = note[1] - m.approach
    t.decoy    = false
    ShowTarget(t)
    return true
end

local function UpdateTarget(t, now)
    local remaining = t.hit - now
    if remaining < -C.WIN_OK then
        Deactivate(t)
        if not t.decoy then Miss(t, 'MISS', C.HP_MISS) end
        return
    end
    local frac = math.max(0, math.min(1, remaining / t.approach))
    local size = P(2 * t.r * (1 + 2 * frac))
    t.ring.Width:Set(size)
    t.ring.Height:Set(size)
    t.ring:SetAlpha(0.35 + 0.65 * (1 - frac))
    Face(t):SetAlpha(math.min(1, (now - t.spawn) / (0.25 * t.approach)))
end

----------------------------------------------------------------------------
-- Game flow
----------------------------------------------------------------------------

local function ClearBoard()
    for i = 1, C.POOL do Deactivate(G.targets[i]) end
    for i = 1, C.POPUPS do
        G.popups[i].active = false
        G.popups[i].text:Hide()
    end
    G.comboPop.active = false
    G.comboPop.text:Hide()
end

local function StartRun()
    ClearBoard()
    StopSong(true)
    G.song = false
    local entry = SelectedSong()
    if entry then
        local map = LoadSongMap(entry)
        local m = map and map[C.DIFFS[G.diff].label]
        if type(m) ~= 'table' or type(m.notes) ~= 'table' or table.getn(m.notes) == 0 then
            WARN('LagClicker: no ' .. C.DIFFS[G.diff].label .. ' map for ' .. tostring(entry.id))
            return
        end
        G.song = { entry = entry, m = m, next = 1, length = tonumber(map.Length) or 0 }
    end
    G.mode = 'play'
    G.start = CurrentTime()
    G.nextSpawn = 0.6
    G.hp = C.HP_MAX
    G.score, G.combo, G.maxCombo, G.level = 0, 0, 0, 1
    G.n300, G.n100, G.n50, G.nMiss, G.nEarly = 0, 0, 0, 0, 0
    G.runNoFail = (G.song and G.noFail) and true or false
    G.diffStart = G.diff
    G.diffMixed = false
    HideOverlay()
    if G.song then
        G.level = 0
        StartSong(G.song.entry, G.song.length)
        -- song time 0 is when the audio actually starts; offset covers the start-up delay
        G.start = CurrentTime() + (tonumber(G.song.entry.offset) or 0) + C.AUDIO_OFFSET
    else
        Play('UI_Score_Window_Open')
    end
    UpdateHud()
    UpdateSongSelector()
    UpdateNoFailButton()
end

-- cleared: song mode only, the song was played to the end
local function EndRun(cleared)
    if G.mode ~= 'play' then return end
    G.mode = 'over'
    G.overAt = CurrentTime()
    ClearBoard()
    local newBest = false
    local diffKey = C.DIFFS[G.diff].label
    if G.song then
        if cleared then
            -- the song plays out; a run with a difficulty change does not set a best
            if not G.diffMixed then newBest = SubmitSongRun(G.song.entry.id, diffKey, G.score) end
        else
            StopSong(false)                     -- failed or closed: the music stops
        end
    else
        newBest = Net.SubmitRun(G.score)
    end
    G.result = {
        score = G.score, maxCombo = G.maxCombo, acc = Accuracy(),
        level = G.level, newBest = newBest, diff = DiffLabel(),
        song = G.song and G.song.entry or false, cleared = cleared and true or false, diffKey = diffKey,
        noFail = G.runNoFail,
    }
    ShowOverlay()
    RefreshPanel()
    UpdateSongSelector()
    UpdateNoFailButton()
    if newBest or (G.song and cleared) then Play('UI_END_Game_Victory') else Play('UI_END_Game_Fail') end
end

local function Step()
    local now = Elapsed()
    Difficulty(now)
    if D.level ~= G.level then
        G.level = D.level
        UpdateHud()
    end
    local guard = 0
    while now >= G.nextSpawn and guard < 3 do
        guard = guard + 1
        if Spawn(now) then
            G.nextSpawn = G.nextSpawn + D.interval
        else
            G.nextSpawn = now + 0.05
        end
    end
    if G.nextSpawn < now - 1 then G.nextSpawn = now end   -- no burst after a long frame
    for i = 1, C.POOL do
        local t = G.targets[i]
        if t.active then UpdateTarget(t, now) end
    end
    if G.hp <= 0 then EndRun() end
end

-- Song mode: spawn circles from the map on the song's clock.
local function SongStep()
    local s = G.song
    local m = s.m
    local notes = m.notes
    local n = table.getn(notes)
    local now = Elapsed()
    while s.next <= n and notes[s.next][1] - m.approach <= now do
        SpawnNote(notes[s.next], m)
        s.next = s.next + 1
    end
    local busy = false
    for i = 1, C.POOL do
        local t = G.targets[i]
        if t.active then
            UpdateTarget(t, now)
            if t.active then busy = true end
        end
    end
    local pct = math.floor(100 * (s.next - 1) / n)
    if pct ~= G.level then
        G.level = pct
        UpdateHud()
    end
    if G.hp <= 0 and not G.runNoFail then
        EndRun()
        return
    end
    if s.next > n and not busy and now > notes[n][1] + C.SONG_TAIL then EndRun(true) end
end

-- Difficulty changed mid-song: continue with that difficulty's map from now on.
local function SongUseDifficulty()
    local s = G.song
    local map = s and s.entry.map
    local m = map and map[C.DIFFS[G.diff].label]
    if type(m) ~= 'table' or type(m.notes) ~= 'table' or table.getn(m.notes) == 0 then return end
    local now = Elapsed()
    local i, n = 1, table.getn(m.notes)
    while i <= n and m.notes[i][1] - m.approach <= now do i = i + 1 end
    s.m = m
    s.next = i
end

local function OnClick(mx, my)
    if G.mode ~= 'play' then
        if G.mode == 'over' and CurrentTime() - G.overAt < C.RESTART_GUARD then return end
        StartRun()
        return
    end
    local now = Elapsed()
    local field = G.field
    local best = nil
    for i = 1, C.POOL do
        local t = G.targets[i]
        if t.active then
            local dx = mx - (field.Left() + P(t.x))
            local dy = my - (field.Top() + P(t.y))
            local rr = P(t.r)
            if dx * dx + dy * dy <= rr * rr and (best == nil or t.hit < best.hit) then
                best = t
            end
        end
    end
    if not best then
        -- clicked next to every circle: a miss, so spam-clicking costs health and combo
        local fx = (mx - field.Left()) * C.FIELD / field.Width()
        local fy = (my - field.Top()) * C.FIELD / field.Width()
        Miss({ x = fx, y = fy }, 'MISS', C.HP_MISS, mx, my)
        if G.hp <= 0 and not G.runNoFail then EndRun() end
        return
    end
    Deactivate(best)
    if best.decoy then
        Miss(best, 'WRONG', C.HP_DECOY, mx, my)
        return
    end
    local off = now - best.hit
    local a = math.abs(off)
    if off < -C.WIN_OK then
        Hit(best, C.EARLY_POINTS, mx, my, true)         -- too early: fewer points, not a miss
    elseif a <= C.WIN_PERFECT then
        Hit(best, 300, mx, my)
    elseif a <= C.WIN_GREAT then
        Hit(best, 100, mx, my)
    else
        Hit(best, 50, mx, my)
    end
    if G.hp <= 0 and not G.runNoFail then EndRun() end
end

local function Frame()
    UpdateColors()
    if G.mode == 'play' then
        if G.song then SongStep() else Step() end
    elseif G.songHandle and G.songEndAt > 0 and CurrentTime() > G.songEndAt then
        StopSong(false)                         -- song over (also stops a cue that loops)
    end
    UpdatePopups()
    UpdateComboPop()
end

local function Broken(where, err)
    WARN('LagClicker: ' .. where .. ' failed: ' .. tostring(err))
    G.broken = true
    G.mode = 'idle'
    pcall(function() G.field:SetNeedsFrameUpdate(false) end)
end

----------------------------------------------------------------------------
-- Window size
----------------------------------------------------------------------------

local function WindowSizeFor(fieldSize)
    local w = C.PAD * 3 + fieldSize + C.PANEL + C.EXTRA_W
    local h = C.TITLE + C.HUD + fieldSize + C.PAD + C.EXTRA_H
    return w, h
end

-- Resize to a preset, keeping the window's top-left corner where possible.
local function ApplyPreset(fieldSize)
    local win = G.win
    local frame = GetFrame(0)
    local dw, dh = WindowSizeFor(fieldSize)
    local w = math.min(S(dw), frame.Width())
    local h = math.min(S(dh), frame.Height())
    local left = math.max(frame.Left(), math.min(win.Left(), frame.Right() - w))
    local top  = math.max(frame.Top(), math.min(win.Top(), frame.Bottom() - h))
    win.Left:Set(left)
    win.Top:Set(top)
    win.Right:Set(left + w)
    win.Bottom:Set(top + h)
    win:SaveWindowLocation()
    Relayout()
end

----------------------------------------------------------------------------
-- Window construction (once; afterwards only shown and hidden)
----------------------------------------------------------------------------

local function MakeText(parent, text, size, color, depthParent)
    local t = UIUtil.CreateText(parent, text, size, UIUtil.bodyFont, true)
    t:SetColor(color)
    t:DisableHitTest()
    if depthParent then LayoutHelpers.DepthOverParent(t, depthParent, 8) end
    return t
end

local function BuildPresetButtons(win)
    local anchor = win._closeBtn
    for i = table.getn(C.PRESETS), 1, -1 do
        local preset = C.PRESETS[i]
        local fieldSize = preset.field
        local btn = Bitmap(win.TitleGroup)
        btn:SetSolidColor(C.COL_BTN)
        LayoutHelpers.SetDimensions(btn, 22, 18)
        LayoutHelpers.AnchorToLeft(btn, anchor, 6)
        LayoutHelpers.AtTopIn(btn, win.TitleGroup, 6)
        LayoutHelpers.DepthOverParent(btn, win.TitleGroup, 5)
        local label = MakeText(btn, preset.label, 12, C.COL_TEXT, btn)
        LayoutHelpers.AtCenterIn(label, btn)
        btn.HandleEvent = function(self, event)
            if event.Type == 'MouseEnter' then
                self:SetSolidColor(C.COL_BTNHI)
                return true
            elseif event.Type == 'MouseExit' then
                self:SetSolidColor(C.COL_BTN)
                return true
            elseif event.Type == 'ButtonPress' or event.Type == 'ButtonDClick' then
                local ok, err = pcall(ApplyPreset, fieldSize)
                if not ok then WARN('LagClicker: resize failed: ' .. tostring(err)) end
                Play('UI_Tab_Click_01')
                return true                     -- keep the title bar from starting a drag
            end
            return false
        end
        anchor = btn
    end
end

local function BuildTargets(field)
    local colors = ColorTextures()
    for i = 1, C.POOL do
        local t = { active = false, x = 0, y = 0, r = 10, hit = 0, spawn = 0, approach = 1, decoy = false }
        t.bmp  = Bitmap(field)                          -- clickable circle, one texture frame per colour
        t.bmp:SetNewTexture(colors)
        t.bmp:SetFrame(0)
        t.dec  = Bitmap(field, TEX .. 'decoy.dds')      -- "don't click" circle
        t.ring = Bitmap(field, TEX .. 'ring.dds')
        t.bmp:DisableHitTest()
        t.dec:DisableHitTest()
        t.ring:DisableHitTest()
        LayoutHelpers.DepthOverParent(t.bmp, field, 2)
        LayoutHelpers.DepthOverParent(t.dec, field, 2)
        LayoutHelpers.DepthOverParent(t.ring, field, 3)
        t.bmp.Width:Set(S(20))
        t.bmp.Height:Set(S(20))
        t.bmp.Left:Set(field.Left)
        t.bmp.Top:Set(field.Top)
        t.dec.Left:Set(t.bmp.Left)
        t.dec.Top:Set(t.bmp.Top)
        t.dec.Width:Set(t.bmp.Width)
        t.dec.Height:Set(t.bmp.Height)
        t.ring.Width:Set(S(20))
        t.ring.Height:Set(S(20))
        LayoutHelpers.AtCenterIn(t.ring, t.bmp)
        t.bmp:Hide()
        t.dec:Hide()
        t.ring:Hide()
        G.targets[i] = t
    end
    for i = 1, C.POPUPS do
        local p = { active = false, t0 = 0, y = 0 }
        p.text = MakeText(field, '', 16, C.COL_TEXT, field)
        p.text.Left:Set(field.Left)
        p.text.Top:Set(field.Top)
        p.text:Hide()
        G.popups[i] = p
    end
    -- combo indicator: above the judgement popups, never takes clicks
    local cp = { active = false, t0 = 0, dur = C.COMBO_TIME, n = 0, broken = false, ox = 0, oy = 0 }
    cp.text = MakeText(field, '', 13, C.COL_TEXT, field)
    LayoutHelpers.DepthOverParent(cp.text, field, 10)
    cp.text.Left:Set(field.Left)
    cp.text.Top:Set(field.Top)
    cp.text:Hide()
    G.comboPop = cp
end

local function BuildHud(client, field)
    local h = G.hud
    h.score = MakeText(client, 'Score  0', 16, C.COL_TEXT)
    LayoutHelpers.AtLeftTopIn(h.score, client, C.PAD, 4)
    h.level = MakeText(client, 'Level 1', 14, C.COL_DIM)
    LayoutHelpers.AtTopIn(h.level, client, 6)
    LayoutHelpers.AtRightIn(h.level, field)
    h.combo = MakeText(client, 'Combo  0', 14, C.COL_TEXT)
    LayoutHelpers.AtLeftTopIn(h.combo, client, C.PAD, 25)
    h.acc = MakeText(client, 'Accuracy  100.0%', 14, C.COL_DIM)
    LayoutHelpers.AtTopIn(h.acc, client, 25)
    LayoutHelpers.AtRightIn(h.acc, field)

    h.hpBg = Bitmap(client)
    h.hpBg:SetSolidColor(C.COL_HPBG)
    h.hpBg:DisableHitTest()
    LayoutHelpers.AtLeftTopIn(h.hpBg, client, C.PAD, 44)
    LayoutHelpers.SetHeight(h.hpBg, 7)
    h.hpBg.Width:Set(function() return field.Width() end)

    h.hpFill = Bitmap(client)
    h.hpFill:SetSolidColor(C.COL_HP)
    h.hpFill:DisableHitTest()
    LayoutHelpers.AtLeftTopIn(h.hpFill, client, C.PAD, 44)
    LayoutHelpers.SetHeight(h.hpFill, 7)
    h.hpFill.Width:Set(function() return field.Width() end)
    LayoutHelpers.DepthOverParent(h.hpFill, h.hpBg, 1)
end

local function BuildOverlay(field)
    local o = G.overlay
    o.title = MakeText(field, 'LAG CLICKER', 26, C.COL_300, field)
    LayoutHelpers.AtHorizontalCenterIn(o.title, field)
    o.title.Top:Set(function() return field.Top() + math.floor(field.Height() * 0.2) end)
    o.lines = {}
    for i = 1, 7 do
        local line = MakeText(field, '', 14, C.COL_TEXT, field)
        local off = 40 + (i - 1) * 20
        LayoutHelpers.AtHorizontalCenterIn(line, field)
        line.Top:Set(function() return field.Top() + math.floor(field.Height() * 0.2) + S(off) end)
        o.lines[i] = line
    end
end

local function BuildRows(client)
    local field = G.field
    local rows = {}
    for i = 1, C.ROWS do
        local row = {}
        row.name = MakeText(client, '', 12, C.COL_TEXT)
        SetPanelLeft(row.name)
        row.value = MakeText(client, '', 12, C.COL_TEXT)
        row.value.Right:Set(function() return field.Right() + S(C.PAD + C.PANEL - 4) end)
        rows[i] = row                            -- Top is set by Relayout
    end
    return rows
end

local function UpdateDiffButtons()
    for i = 1, table.getn(G.diffBtns) do
        local b = G.diffBtns[i]
        if i == G.diff then
            b:SetSolidColor(C.COL_SEL)
            b.label:SetColor(C.COL_TEXT)
        else
            b:SetSolidColor(C.COL_BTN)
            b.label:SetColor(C.COL_DIM)
        end
    end
end

-- Live change: affects circles spawned and hits scored from now on.
local function SetDifficulty(i)
    if i == G.diff then return end
    G.diff = i
    if G.mode == 'play' and i ~= G.diffStart then G.diffMixed = true end
    if G.mode == 'play' and G.song then SongUseDifficulty() end
    Prefs.SetToCurrentProfile(C.PREF_DIFF, i)
    UpdateDiffButtons()
    UpdateHud()
    RefreshPanel()
end

local function LoadDifficulty()
    local i = tonumber(Prefs.GetFromCurrentProfile(C.PREF_DIFF))
    if i and C.DIFFS[i] then G.diff = i end
end

local function BuildDiffButtons(client)
    local field = G.field
    for i = 1, table.getn(C.DIFFS) do
        local index = i
        local x = (i - 1) * 70
        local btn = Bitmap(client)
        LayoutHelpers.SetDimensions(btn, 66, 20)
        btn.Left:Set(function() return field.Right() + S(C.PAD + x) end)
        SetTopOff(btn, 4)
        btn.label = MakeText(btn, C.DIFFS[i].label, 12, C.COL_DIM, btn)
        LayoutHelpers.AtCenterIn(btn.label, btn)
        btn.HandleEvent = function(self, event)
            if event.Type == 'MouseEnter' then
                if index ~= G.diff then self:SetSolidColor(C.COL_BTNHI) end
                return true
            elseif event.Type == 'MouseExit' then
                UpdateDiffButtons()
                return true
            elseif event.Type == 'ButtonPress' or event.Type == 'ButtonDClick' then
                local ok, err = pcall(SetDifficulty, index)
                if not ok then WARN('LagClicker: difficulty change failed: ' .. tostring(err)) end
                Play('UI_Tab_Click_01')
                return true
            end
            return false
        end
        G.diffBtns[i] = btn
    end
    UpdateDiffButtons()
end

----------------------------------------------------------------------------
-- Song selector:  [<] [ Song: Off ] [>]  below the difficulty buttons
----------------------------------------------------------------------------

local function SongLabel()
    local song = SelectedSong()
    if not song then return 'Song: Off' end
    return tostring(song.title)                     -- titles are too long for a 'Song:' prefix
end

UpdateSongSelector = function()
    local s = G.songSel
    if not s then return end
    local col = C.COL_TEXT
    if G.mode == 'play' then col = C.COL_DIM end     -- no switching mid-run
    s.title.label:SetText(SongLabel())
    s.title.label:SetColor(col)
    s.prev.label:SetColor(col)
    s.next.label:SetColor(col)
end

local function SetSong(i)
    if G.mode == 'play' then return end
    local lib = Library()
    local n = table.getn(lib)
    if i < 1 then i = n elseif i > n then i = 1 end
    if i == G.songIdx then return end
    StopSong(true)
    G.songIdx = i
    G.song = false
    G.result = false
    G.mode = 'idle'
    if SelectedSong() then G.level = 0 else G.level = 1 end
    Prefs.SetToCurrentProfile(C.PREF_SONG, lib[i].id)
    UpdateSongSelector()
    UpdateNoFailButton()
    ShowOverlay()
    UpdateHud()
    RefreshPanel()
end

local function LoadSongChoice()
    local id = Prefs.GetFromCurrentProfile(C.PREF_SONG)
    local lib = Library()
    G.songIdx = 1
    for i = 1, table.getn(lib) do
        if lib[i].id == id then G.songIdx = i end
    end
    if SelectedSong() then G.level = 0 end
end

local function MakeSongButton(client, width, text, onClick)
    local btn = Bitmap(client)
    btn:SetSolidColor(C.COL_BTN)
    LayoutHelpers.SetDimensions(btn, width, 20)
    btn.label = MakeText(btn, text, 12, C.COL_TEXT, btn)
    LayoutHelpers.AtCenterIn(btn.label, btn)
    btn.HandleEvent = function(self, event)
        if event.Type == 'MouseEnter' then
            if G.mode ~= 'play' then self:SetSolidColor(C.COL_BTNHI) end
            return true
        elseif event.Type == 'MouseExit' then
            self:SetSolidColor(C.COL_BTN)
            return true
        elseif event.Type == 'ButtonPress' or event.Type == 'ButtonDClick' then
            if G.mode == 'play' then return true end
            local ok, err = pcall(onClick, event)
            if not ok then WARN('LagClicker: song change failed: ' .. tostring(err)) end
            Play('UI_Tab_Click_01')
            return true
        end
        return false
    end
    return btn
end

local function BuildSongSelector(client)
    local field = G.field
    local s = {}
    s.prev = MakeSongButton(client, 22, '<', function() SetSong(G.songIdx - 1) end)
    s.prev.Left:Set(function() return field.Right() + S(C.PAD) end)
    SetTopOff(s.prev, C.SONG_TOP)
    -- left click: next song, right click: previous
    s.title = MakeSongButton(client, 158, '', function(event)
        if event.Modifiers.Right then SetSong(G.songIdx - 1) else SetSong(G.songIdx + 1) end
    end)
    s.title.Left:Set(function() return field.Right() + S(C.PAD + 24) end)
    SetTopOff(s.title, C.SONG_TOP)
    s.next = MakeSongButton(client, 22, '>', function() SetSong(G.songIdx + 1) end)
    s.next.Left:Set(function() return field.Right() + S(C.PAD + 184) end)
    SetTopOff(s.next, C.SONG_TOP)
    G.songSel = s
    UpdateSongSelector()
end

----------------------------------------------------------------------------
-- Volume slider:  Volume [=======|---]  80%   (click, drag or mouse wheel)
----------------------------------------------------------------------------

local function UpdateVolumeSlider()
    local v = G.volSel
    if not v then return end
    local frac = G.volume
    local bar, knob = v.bar, v.knob
    v.fill.Width:Set(function() return math.max(1, math.floor(bar.Width() * frac)) end)
    if frac <= 0 then v.fill:Hide() else v.fill:Show() end
    knob.Left:Set(function() return bar.Left() + math.floor((bar.Width() - knob.Width()) * frac) end)
    v.value:SetText(string.format('%d%%', math.floor(frac * 100 + 0.5)))
end

local function SetVolumeLevel(frac, save)
    frac = math.max(0, math.min(1, frac))
    frac = math.floor(frac / C.VOLUME_STEP + 0.5) * C.VOLUME_STEP
    if frac ~= G.volume then
        G.volume = frac
        ApplyVolume()
        UpdateVolumeSlider()
    end
    if save then Prefs.SetToCurrentProfile(C.PREF_VOLUME, G.volume) end
end

local function VolumeAt(x)
    local bar = G.volSel.bar
    local w = bar.Width()
    if w <= 0 then return G.volume end
    return (x - bar.Left()) / w
end

local function StartVolumeDrag(ctrl, event)
    SetVolumeLevel(VolumeAt(event.MouseX), false)
    local drag = Dragger()
    drag.OnMove = function(dragself, x, y)
        local ok, err = pcall(SetVolumeLevel, VolumeAt(x), false)
        if not ok then WARN('LagClicker: volume drag failed: ' .. tostring(err)) end
    end
    drag.OnRelease = function(dragself, x, y)
        drag:Destroy()
        local ok, err = pcall(SetVolumeLevel, VolumeAt(x), true)
        if not ok then WARN('LagClicker: volume drag failed: ' .. tostring(err)) end
    end
    drag.OnCancel = function(dragself)
        drag:Destroy()
        Prefs.SetToCurrentProfile(C.PREF_VOLUME, G.volume)
    end
    PostDragger(ctrl:GetRootFrame(), event.KeyCode, drag)
end

local function BuildVolumeSlider(client)
    local field = G.field
    local v = {}
    v.label = MakeText(client, 'Volume', 12, C.COL_DIM)
    SetPanelLeft(v.label)
    SetTopOff(v.label, C.VOLUME_TOP)

    -- invisible hit area, taller than the bar so it is easy to grab
    v.hit = Bitmap(client)
    v.hit:SetSolidColor('00000000')
    LayoutHelpers.SetDimensions(v.hit, 120, 18)
    v.hit.Left:Set(function() return field.Right() + S(C.PAD + 50) end)
    SetTopOff(v.hit, C.VOLUME_TOP - 1)

    v.bar = Bitmap(client)
    v.bar:SetSolidColor(C.COL_HPBG)
    v.bar:DisableHitTest()
    LayoutHelpers.SetDimensions(v.bar, 116, 6)
    v.bar.Left:Set(function() return v.hit.Left() + S(2) end)
    v.bar.Top:Set(function() return v.hit.Top() + S(6) end)
    LayoutHelpers.DepthOverParent(v.bar, v.hit, 1)

    v.fill = Bitmap(client)
    v.fill:SetSolidColor(C.COL_HP)
    v.fill:DisableHitTest()
    v.fill.Left:Set(v.bar.Left)
    v.fill.Top:Set(v.bar.Top)
    v.fill.Height:Set(v.bar.Height)
    LayoutHelpers.DepthOverParent(v.fill, v.bar, 1)

    v.knob = Bitmap(client)
    v.knob:SetSolidColor(C.COL_TEXT)
    v.knob:DisableHitTest()
    LayoutHelpers.SetDimensions(v.knob, 6, 14)
    v.knob.Top:Set(function() return v.bar.Top() - S(4) end)
    LayoutHelpers.DepthOverParent(v.knob, v.bar, 2)

    v.value = MakeText(client, '100%', 12, C.COL_TEXT)
    v.value.Right:Set(function() return field.Right() + S(C.PAD + 206) end)
    SetTopOff(v.value, C.VOLUME_TOP)

    v.hit.HandleEvent = function(self, event)
        if event.Type == 'MouseEnter' then
            v.knob:SetSolidColor(C.COL_ME)
            return true
        elseif event.Type == 'MouseExit' then
            v.knob:SetSolidColor(C.COL_TEXT)
            return true
        elseif event.Type == 'ButtonPress' and event.Modifiers.Left then
            local ok, err = pcall(StartVolumeDrag, self, event)
            if not ok then WARN('LagClicker: volume failed: ' .. tostring(err)) end
            return true
        elseif event.Type == 'WheelRotation' then
            local step = C.VOLUME_STEP
            if event.WheelRotation < 0 then step = -step end
            local ok, err = pcall(SetVolumeLevel, G.volume + step, true)
            if not ok then WARN('LagClicker: volume failed: ' .. tostring(err)) end
            return true
        end
        return false
    end
    G.volSel = v
    UpdateVolumeSlider()
end

----------------------------------------------------------------------------
-- No Fail toggle (songs only): health cannot run out, the score is halved
----------------------------------------------------------------------------

local function LoadNoFail()
    G.noFail = tonumber(Prefs.GetFromCurrentProfile(C.PREF_NOFAIL)) == 1
end

UpdateNoFailButton = function()
    local b = G.nfBtn
    if not b then return end
    if not SelectedSong() then
        b:SetSolidColor(C.COL_BTN)
        b.label:SetText('No Fail (songs only)')
        b.label:SetColor(C.COL_DIM)
        return
    end
    if G.noFail then
        b:SetSolidColor(C.COL_SEL)
        b.label:SetText('No Fail: On  (score x0.5)')
    else
        b:SetSolidColor(C.COL_BTN)
        b.label:SetText('No Fail: Off')
    end
    if G.mode == 'play' then b.label:SetColor(C.COL_DIM) else b.label:SetColor(C.COL_TEXT) end
end

local function ToggleNoFail()
    if G.mode == 'play' or not SelectedSong() then return false end      -- songs only, not mid-run
    G.noFail = not G.noFail
    Prefs.SetToCurrentProfile(C.PREF_NOFAIL, G.noFail and 1 or 0)
    UpdateNoFailButton()
    UpdateHud()
    return true
end

local function BuildNoFailButton(client)
    local field = G.field
    local b = Bitmap(client)
    b:SetSolidColor(C.COL_BTN)
    LayoutHelpers.SetDimensions(b, 206, 18)
    b.Left:Set(function() return field.Right() + S(C.PAD) end)
    SetTopOff(b, C.NOFAIL_TOP)
    b.label = MakeText(b, 'No Fail: Off', 12, C.COL_TEXT, b)
    LayoutHelpers.AtCenterIn(b.label, b)
    b.HandleEvent = function(self, event)
        if event.Type == 'MouseEnter' then
            if G.mode ~= 'play' and SelectedSong() and not G.noFail then self:SetSolidColor(C.COL_BTNHI) end
            return true
        elseif event.Type == 'MouseExit' then
            UpdateNoFailButton()
            return true
        elseif event.Type == 'ButtonPress' or event.Type == 'ButtonDClick' then
            local ok, res = pcall(ToggleNoFail)
            if not ok then WARN('LagClicker: No Fail toggle failed: ' .. tostring(res)) end
            if ok and res then Play('UI_Tab_Click_01') end
            return true
        end
        return false
    end
    G.nfBtn = b
    UpdateNoFailButton()
end

local function BuildPanel(client)
    local p = G.panel
    BuildDiffButtons(client)
    BuildSongSelector(client)
    BuildVolumeSlider(client)
    BuildNoFailButton(client)
    local top = C.PANEL_TOP
    p.bestLabel = MakeText(client, 'YOUR BEST', 12, C.COL_DIM)
    SetPanelLeft(p.bestLabel)
    SetTopOff(p.bestLabel, top + 4)
    p.best = MakeText(client, '0', 22, C.COL_ME)
    SetPanelLeft(p.best)
    SetTopOff(p.best, top + 18)
    p.gameBest = MakeText(client, 'This game: 0', 12, C.COL_DIM)
    SetPanelLeft(p.gameBest)
    SetTopOff(p.gameBest, top + 46)

    p.sessionLabel = MakeText(client, 'PLAYERS IN THIS GAME', 12, C.COL_DIM)
    SetPanelLeft(p.sessionLabel)
    SetTopOff(p.sessionLabel, top + 72)
    p.sessionRows = BuildRows(client)

    p.boardLabel = MakeText(client, 'ALL-TIME (SEEN BY YOU)', 12, C.COL_DIM)
    SetPanelLeft(p.boardLabel)
    p.boardRows = BuildRows(client)

    -- notes stick to the bottom of the window
    p.note2 = MakeText(client, 'who also run Lag Clicker.', 10, C.COL_DIM)
    SetPanelLeft(p.note2)
    p.note2.Bottom:Set(function() return client.Bottom() - S(6) end)
    p.note1 = MakeText(client, 'Scores are shared with players', 10, C.COL_DIM)
    SetPanelLeft(p.note1)
    p.note1.Bottom:Set(function() return p.note2.Top() - S(1) end)
end

local function BuildWindow()
    local dw, dh = WindowSizeFor(C.FIELD)
    local win = Window(GetFrame(0), 'Lag Clicker', nil, false, false, false, false,
        'LagClicker_Window_v1', { Left = 30, Top = 120, Right = 30 + dw, Bottom = 120 + dh })
    local minW, minH = WindowSizeFor(C.FIELD_MIN)
    win:SetMinimumResize(minW, minH)
    win.OnClose = function(self)
        local ok, err = pcall(Hide)
        if not ok then WARN('LagClicker: close failed: ' .. tostring(err)) end
    end
    win.OnResize = function(self, x, y, firstFrame)
        local ok, err = pcall(Relayout)
        if not ok then WARN('LagClicker: relayout failed: ' .. tostring(err)) end
    end
    win.OnResizeSet = function(self)
        local ok, err = pcall(Relayout)
        if not ok then WARN('LagClicker: relayout failed: ' .. tostring(err)) end
    end
    local client = win:GetClientGroup()

    -- square field: as big as the window allows, never smaller than FIELD_MIN
    local field = Bitmap(client)
    field:SetSolidColor(C.COL_FIELD)
    LayoutHelpers.AtLeftTopIn(field, client, C.PAD, C.HUD)
    field.Width:Set(function()
        local w = client.Width() - S(C.PAD * 3 + C.PANEL)
        local h = client.Height() - S(C.HUD + C.PAD)
        return math.max(S(C.FIELD_MIN), math.min(w, h))
    end)
    field.Height:Set(function() return field.Width() end)
    field.HandleEvent = function(self, event)
        if event.Type == 'ButtonPress' or event.Type == 'ButtonDClick' then
            if not G.broken then
                local ok, err = pcall(OnClick, event.MouseX, event.MouseY)
                if not ok then Broken('click', err) end
            end
            return true
        end
        return false
    end
    field.OnFrame = function(self, delta)
        if G.broken then return end
        local ok, err = pcall(Frame)
        if not ok then Broken('frame', err) end
    end

    G.win, G.client, G.field = win, client, field
    LoadDifficulty()
    LoadSongChoice()
    LoadVolume()
    ApplyVolume()
    LoadNoFail()
    BuildHud(client, field)
    BuildTargets(field)
    BuildOverlay(field)
    BuildPanel(client)
    BuildPresetButtons(win)
    win:Hide()
end

-- Window:Show shows every child again; hide what is not in use.
local function SyncVisibility()
    for i = 1, C.POOL do
        local t = G.targets[i]
        if not t.active then
            t.bmp:Hide() t.dec:Hide() t.ring:Hide()
        elseif t.decoy then
            t.bmp:Hide()
        else
            t.dec:Hide()
        end
    end
    for i = 1, C.POPUPS do
        if not G.popups[i].active then G.popups[i].text:Hide() end
    end
    if not G.comboPop.active then G.comboPop.text:Hide() end
    if G.mode == 'play' then HideOverlay() else ShowOverlay() end
    UpdateHud()
    Relayout()
end

local function IsVisible()
    return G.win and not G.win:IsHidden()
end

local function UpdateButtonLabel()
    local btn = G.dialogBtn
    if btn and not IsDestroyed(btn) and btn.label then
        if IsVisible() then btn.label:SetText('Hide mini-game') else btn.label:SetText('Play mini-game') end
    end
end

Show = function()
    if not G.win then BuildWindow() end
    if not G.listening then
        G.listening = true
        Net.AddListener(function() if IsVisible() then RefreshPanel() end end)
    end
    if G.mode ~= 'over' then G.mode = 'idle' end
    G.win.Depth:Set(GetFrame(0):GetTopmostDepth() + 1)
    G.win:Show()
    SyncVisibility()
    RefreshPanel()
    if not G.broken then G.field:SetNeedsFrameUpdate(true) end
    UpdateButtonLabel()
end

Hide = function()
    if not G.win then return end
    if G.mode == 'play' then EndRun() end           -- the run counts with the score it has
    StopSong(true)
    G.field:SetNeedsFrameUpdate(false)
    G.win:Hide()
    UpdateButtonLabel()
end

----------------------------------------------------------------------------
-- Entry points
----------------------------------------------------------------------------

-- source: 'dialog' | 'launcher' | 'console'. Remembered so that the window only
-- closes itself on connection recovery when it was opened from the connection window.
local function ToggleFrom(source)
    if IsVisible() then
        Hide()
    else
        G.openedBy = source
        Show()
    end
end

function Toggle()
    ToggleFrom('console')
end

----------------------------------------------------------------------------
-- Launcher: small button that opens the game at any time (live games only)
----------------------------------------------------------------------------

local function ClampLauncher(left, top)
    local frame = GetFrame(0)
    local size = S(C.LAUNCHER_SIZE)
    left = math.max(frame.Left(), math.min(left, frame.Right() - size))
    top  = math.max(frame.Top(), math.min(top, frame.Bottom() - size))
    return left, top
end

local function StartLauncherDrag(btn, event)
    local startX, startY = event.MouseX, event.MouseY
    local offX, offY = startX - btn.Left(), startY - btn.Top()
    local moved = false
    local drag = Dragger()
    drag.OnMove = function(dragself, x, y)
        if not moved and (math.abs(x - startX) > 4 or math.abs(y - startY) > 4) then
            moved = true
        end
        if moved then
            local l, t = ClampLauncher(x - offX, y - offY)
            btn.Left:Set(l)
            btn.Top:Set(t)
        end
    end
    drag.OnRelease = function(dragself, x, y)
        drag:Destroy()
        if moved then
            Prefs.SetToCurrentProfile(C.PREF_LAUNCHER, { left = btn.Left(), top = btn.Top() })
        else
            local ok, err = pcall(ToggleFrom, 'launcher')
            if not ok then WARN('LagClicker: toggle failed: ' .. tostring(err)) end
        end
    end
    drag.OnCancel = function(dragself)
        drag:Destroy()
    end
    PostDragger(btn:GetRootFrame(), event.KeyCode, drag)
end

-- Called from the gamemain.lua hook once the game UI exists.
function CreateLauncher()
    if G.launcher or SessionIsReplay() then return end
    local frame = GetFrame(0)
    local btn = Bitmap(frame, TEX .. 'circle_00.dds')
    G.launcher = btn
    LayoutHelpers.SetDimensions(btn, C.LAUNCHER_SIZE, C.LAUNCHER_SIZE)

    -- default: left screen edge, a little above the middle; then the saved position
    local left, top = frame.Left() + S(4), frame.Top() + math.floor(frame.Height() * 0.45)
    local saved = Prefs.GetFromCurrentProfile(C.PREF_LAUNCHER)
    if type(saved) == 'table' and tonumber(saved.left) and tonumber(saved.top) then
        left, top = tonumber(saved.left), tonumber(saved.top)
    end
    left, top = ClampLauncher(left, top)
    btn.Left:Set(left)
    btn.Top:Set(top)
    btn.Depth:Set(frame:GetTopmostDepth() + 1)
    btn:SetAlpha(0.6)

    btn.HandleEvent = function(self, event)
        if event.Type == 'MouseEnter' then
            self:SetAlpha(1)
            return true
        elseif event.Type == 'MouseExit' then
            self:SetAlpha(0.6)
            return true
        elseif event.Type == 'ButtonPress' and event.Modifiers.Left then
            local ok, err = pcall(StartLauncherDrag, self, event)
            if not ok then WARN('LagClicker: launcher failed: ' .. tostring(err)) end
            return true
        end
        return false
    end
end

-- Follows the game's "hide UI" toggle.
function SetLauncherHidden(hidden)
    if not G.launcher then return end
    if hidden then G.launcher:Hide() else G.launcher:Show() end
end

-- Called from the disconnect.lua hook when the connection window appears.
function AttachToDialog(dlg)
    if SessionIsReplay() then return end
    Net.Init()
    local btn = UIUtil.CreateButtonStd(dlg, '/widgets02/small', 'Play mini-game', 12, 0)
    btn.label:SetFont(UIUtil.bodyFont, 12)
    LayoutHelpers.AtHorizontalCenterIn(btn, dlg)
    LayoutHelpers.AnchorToBottom(btn, dlg, 12)
    LayoutHelpers.DepthOverParent(btn, dlg, 50)
    btn.OnClick = function(self, modifiers)
        local ok, err = pcall(ToggleFrom, 'dialog')
        if not ok then WARN('LagClicker: toggle failed: ' .. tostring(err)) end
    end
    dlg.LagClickerButton = btn
    G.dialogBtn = btn
    UpdateButtonLabel()
end

-- Called from the disconnect.lua hook when the connection window closes.
-- Only a window opened from the connection window closes with it.
function OnDialogClosed()
    G.dialogBtn = false
    if IsVisible() and G.openedBy == 'dialog' then Hide() end
    Net.OnDialogClosed()
end
