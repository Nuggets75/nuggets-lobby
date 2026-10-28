-- Nuggets custom lobby: the Minigames window. Imported as /nuggetslobby/hub.lua.
--
-- Three tabs: Liar's Dice (the tables in this lobby: host, join, watch), Challenges (Chess
-- and Battleship against a player picked from the list) and Solo games. The games
-- themselves live in minigames.lua (the bundled Minigames copy), snake.lua, sudoku.lua and
-- liarsdice\.

local UI       = import('/nuggetslobby/ui.lua')
local Games    = import('/nuggetslobby/minigames.lua')
local LDTable  = import('/nuggetslobby/liarsdice/table.lua')
local LDView   = import('/nuggetslobby/liarsdice/view.lua')

local C    = UI.COLORS
local ICON = UI.ART
local PREF = 'NuggetsLobby_MinigamesWindow_v2'
local W, H = 720, 480

local TABLE_ROWS  = 4
local PLAYER_ROWS = 8

local hub = nil
local lastTab = 1
local picked = nil       -- the player picked on the Challenges tab, kept while the lobby lasts

local SOLO = {
    { key = 'snake',         name = 'Snake',          icon = 'ic_snake.png',     bundle = false,
      text = { 'Eat, grow, and do not', 'bite yourself.' } },
    { key = 'sudoku',        name = 'Sudoku',         icon = 'ic_sudoku.png',    bundle = false,
      text = { 'Three levels; every puzzle', 'has exactly one solution.' } },
    { key = 'minesweeper',   name = 'Minesweeper',    icon = 'ic_mines.png',     bundle = true,
      text = { 'Clear the field without', 'touching a mine.' } },
    { key = 'dragonsweeper', name = 'Dragonsweeper',  icon = 'ic_dragon.png',    bundle = true,
      text = { 'Minesweeper with monsters', 'and a dragon to slay.' } },
    { key = 'lagclicker',    name = 'Lag Clicker',    icon = 'ic_lag.png',       bundle = true,
      text = { 'Click fast. Scores are', 'shared with players here.' } },
    { key = 'battleshipbot', name = 'Battleship Bot', icon = 'ic_bsbot.png',     bundle = true,
      text = { "Sink the bot's fleet", 'before it sinks yours.' } },
}

local CHALLENGE_GAMES = {
    { game = 'Chess',      icon = 'ic_chess.png',      text = { 'A full game of chess against', 'the player you picked.' } },
    { game = 'Battleship', icon = 'ic_battleship.png', text = { 'Hide your fleet, then take', 'turns firing at theirs.' } },
}

local function Svc() return LDTable.Get() end

local function Close()
    if hub and not IsDestroyed(hub.frame) then hub.frame:Destroy() end
    hub = nil
end

----------------------------------------------------------------------------
-- building
----------------------------------------------------------------------------

local Render   -- forward declaration

local function Header(page, icon, title, sub1, sub2)
    UI.Image(page, ICON .. icon, 0, 0, 52, 52, 3)
    UI.Label(page, title, 20, C.text, UI.FONT_BIG, 66, 0, 6)
    UI.Label(page, sub1, 12, C.dim, UI.FONT, 66, 31, 6)
    if sub2 then UI.Label(page, sub2, 12, C.dim, UI.FONT, 66, 47, 6) end
end

local function OpenTableWindow()
    local layer = Games.Layer()
    if layer then LDView.Open(layer) end
    Close()
end

local function BuildLiarsDice(page)
    local p = {}
    Header(page, 'ic_liarsdice.png', "Liar's Dice",
        "Bluff about the dice under everyone's cups. 2 to 8 players,",
        'bots welcome. The rules are shown at the table.')
    p.host = UI.Button(page, 'HOST A TABLE', 'primary', 0, 70, 170, 36, function()
        local svc = Svc()
        if not svc then return end
        local ok, why = svc:OpenTable()
        if ok then
            OpenTableWindow()
        elseif why then
            UI.Txt(p.hostNote, why)
        end
    end, 13, 8)
    p.hostNote = UI.Label(page, '', 12, C.dim, UI.FONT, 184, 81, 6)

    -- "you are at ..." banner (instead of the host button)
    p.banner = UI.Panel(page, 0, 66, 512, 46, C.accentBg, C.accent, 2)
    p.bannerTitle = UI.Label(page, '', 13, C.text, UI.FONT_BOLD, 12, 71, 6)
    p.bannerLine = UI.Label(page, '', 11, C.dim, UI.FONT, 12, 90, 6)
    p.open = UI.Button(page, 'OPEN', 'primary', 372, 73, 64, 32, OpenTableWindow, 12, 8)
    p.leave = UI.Button(page, 'LEAVE', 'normal', 440, 73, 64, 32, function()
        local svc = Svc()
        if not svc or not svc.at or not hub then return end
        local at = svc.at
        local snap = at.snap
        local playing = snap ~= nil and snap.phase ~= 'lobby' and snap.phase ~= 'over'
        local stillIn = snap ~= nil and snap.you.seat > 0 and snap.seats[snap.you.seat] ~= nil and not snap.seats[snap.you.seat].o
        local function Go()
            local s = Svc()
            if not s or not s.at then return end
            if s.at.host == s:Me() then s:CloseTable() else s:Leave() end
            LDView.CloseWindow()
            Render()
        end
        -- same questions as the table window's X
        if at.host == svc:Me() and playing then
            UI.Confirm(hub.frame, 'Close your table and end the game for everyone?', 'Close table', 'Cancel', Go)
        elseif playing and stillIn then
            UI.Confirm(hub.frame, 'Leave the game? You are out of it, and everyone else rolls again.', 'Leave', 'Stay', Go)
        else
            Go()
        end
    end, 12, 8)

    UI.Label(page, 'TABLES IN THIS LOBBY', 10, C.dim, UI.FONT_BOLD, 0, 126, 6)
    p.rows = {}
    for r = 1, TABLE_ROWS do
        local y = 144 + (r - 1) * 52
        local row = {}
        row.panel = UI.Panel(page, 0, y, 512, 46, C.row, C.line, 2)
        row.name = UI.Label(page, '', 14, C.text, UI.FONT_BOLD, 12, y + 6, 6)
        row.info = UI.Label(page, '', 11, C.dim, UI.FONT, 12, y + 26, 6)
        row.state = UI.Label(page, '', 11, C.good, UI.FONT_BOLD, 0, y + 16, 6)
        UI.RightAt(row.state, page, 360)
        local rowIndex = r
        row.join = UI.Button(page, 'JOIN', 'primary', 370, y + 9, 66, 28, function()
            local svc = Svc()
            local entry = hub and hub.tableRows[rowIndex]
            if svc and entry then
                if entry.mine or (svc.at and svc.at.host == entry.host) then
                    -- my table, or the one I am at: the button says OPEN
                    OpenTableWindow()
                elseif svc:Join(entry.host, false) then
                    OpenTableWindow()
                end
            end
        end, 12, 8)
        row.watch = UI.Button(page, 'WATCH', 'normal', 440, y + 9, 66, 28, function()
            local svc = Svc()
            local entry = hub and hub.tableRows[rowIndex]
            if svc and entry and svc:Join(entry.host, true) then OpenTableWindow() end
        end, 12, 8)
        p.rows[r] = row
    end
    p.empty1 = UI.Label(page, 'No tables yet.', 14, C.text, UI.FONT_BOLD, 0, 210, 6)
    p.empty2 = UI.Label(page, 'Host one, and everyone here with this lobby gets a chat message.', 12, C.dim, UI.FONT, 0, 232, 6)
    UI.CenterX(p.empty1, page, 0, 512)
    UI.CenterX(p.empty2, page, 0, 512)
    p.more = UI.Label(page, '', 10, C.faint, UI.FONT_BOLD, 0, 126, 6)
    UI.RightAt(p.more, page, 512)

    -- the rules in short
    UI.Panel(page, 0, 358, 512, 60, C.panel, C.line, 1)
    UI.Label(page, 'HOW TO PLAY', 10, C.dim, UI.FONT_BOLD, 12, 366, 6)
    UI.Label(page, 'Bid how many dice on the whole table show a face. Raise the bid, or call LIAR!', 11, C.text, UI.FONT, 12, 382, 6)
    UI.Label(page, 'when you think it is too high. Whoever was wrong loses a life (or a die).', 11, C.text, UI.FONT, 12, 397, 6)
    return p
end

local function BuildChallenges(page)
    local p = {}
    Header(page, 'ic_players.png', 'Challenges',
        'Challenge a player here who runs this lobby.',
        'Only that player gets the challenge.')
    UI.Label(page, 'PLAYERS', 10, C.dim, UI.FONT_BOLD, 0, 72, 6)
    UI.Panel(page, 0, 90, 200, 232, C.panel, C.line, 1)
    p.players = {}
    for r = 1, PLAYER_ROWS do
        local rowIndex = r
        local b = UI.Button(page, '', 'ghost', 4, 94 + (r - 1) * 28, 192, 26, function()
            if hub and hub.playerRows[rowIndex] then
                picked = hub.playerRows[rowIndex]
                Render()
            end
        end, 13, 8)
        p.players[r] = b
    end
    p.nobody1 = UI.Label(page, 'Nobody here runs', 12, C.dim, UI.FONT, 0, 180, 6)
    p.nobody2 = UI.Label(page, 'this lobby yet.', 12, C.dim, UI.FONT, 0, 196, 6)
    UI.CenterX(p.nobody1, page, 0, 200)
    UI.CenterX(p.nobody2, page, 0, 200)

    p.cards = {}
    for i = 1, table.getn(CHALLENGE_GAMES) do
        local def = CHALLENGE_GAMES[i]
        local y = 90 + (i - 1) * 118
        local card = {}
        UI.Panel(page, 212, y, 300, 110, C.row, C.line, 1)
        UI.Image(page, ICON .. def.icon, 224, y + 12, 44, 44, 3)
        UI.Label(page, def.game, 15, C.text, UI.FONT_BOLD, 280, y + 12, 6)
        UI.Label(page, def.text[1], 11, C.dim, UI.FONT, 280, y + 33, 6)
        UI.Label(page, def.text[2], 11, C.dim, UI.FONT, 280, y + 48, 6)
        local game = def.game
        card.button = UI.Button(page, 'CHALLENGE', 'primary', 382, y + 72, 120, 30, function()
            if picked then
                Games.Challenge(game, picked)
                Close()
            end
        end, 12, 8)
        card.who = UI.Label(page, '', 11, C.faint, UI.FONT, 224, y + 80, 6)
        p.cards[i] = card
    end
    p.acceptChess = UI.Toggle(page, 'Accept Chess challenges', 0, 336, Games.GetSetting('acceptChess'), function(on)
        Games.SetSetting('acceptChess', on)
    end, 8)
    p.acceptBs = UI.Toggle(page, 'Accept Battleship challenges', 0, 362, Games.GetSetting('acceptBattleship'), function(on)
        Games.SetSetting('acceptBattleship', on)
    end, 8)
    p.missing = UI.Label(page, 'Chess and Battleship did not load: nuggets-lobby\\games\\minigames is missing.', 11, C.bad, UI.FONT, 0, 396, 6)
    return p
end

local function BuildSolo(page)
    local p = {}
    Header(page, 'ic_solo.png', 'Solo games', 'Something to do while the lobby fills up.')
    p.cards = {}
    for i = 1, table.getn(SOLO) do
        local def = SOLO[i]
        local col = (i - 1) - math.floor((i - 1) / 3) * 3
        local row = math.floor((i - 1) / 3)
        local x, y = col * 174, 70 + row * 140
        local card = {}
        UI.Panel(page, x, y, 164, 130, C.row, C.line, 1)
        UI.Image(page, ICON .. def.icon, x + 12, y + 12, 40, 40, 3)
        UI.Label(page, def.name, 13, C.text, UI.FONT_BOLD, x + 58, y + 25, 6)
        UI.Label(page, def.text[1], 11, C.dim, UI.FONT, x + 12, y + 60, 6)
        UI.Label(page, def.text[2], 11, C.dim, UI.FONT, x + 12, y + 75, 6)
        local key = def.key
        card.button = UI.Button(page, 'PLAY', 'normal', x + 12, y + 96, 140, 26, function()
            if Games.PlaySolo(key) then Close() end
        end, 12, 8)
        card.def = def
        p.cards[i] = card
    end
    UI.Label(page, 'Minesweeper', 12, C.text, UI.FONT_BOLD, 0, 360, 6)
    p.size = UI.Stepper(page, 96, 355, 110, function(dir)
        local n = Games.GetSetting('gridSize') + dir
        if n < 5 then n = 20 end
        if n > 20 then n = 5 end
        Games.SetSetting('gridSize', n)
        Render()
    end, 8)
    p.hard = UI.Toggle(page, 'Hard mode (more mines)', 222, 359, Games.GetSetting('hardMode'), function(on)
        Games.SetSetting('hardMode', on)
    end, 8)
    p.missing = UI.Label(page, 'Minesweeper, Dragonsweeper, Lag Clicker and Battleship did not load: games\\minigames is missing.', 11, C.bad, UI.FONT, 0, 396, 6)
    return p
end

local TABS = {
    { name = "Liar's Dice", icon = 'ic_liarsdice.png', build = BuildLiarsDice },
    { name = 'Challenges',  icon = 'ic_players.png',   build = BuildChallenges },
    { name = 'Solo games',  icon = 'ic_solo.png',      build = BuildSolo },
}

local function SelectTab(i)
    lastTab = i
    if hub then
        for k = 1, table.getn(TABS) do
            UI.Show(hub.pages[k], k == i)
        end
        local ok, err = pcall(Render)
        if not ok then WARN('NuggetsLobby: Minigames window failed: ' .. tostring(err)) end
    end
end

local function Build(parent)
    hub = { pages = {}, tabs = {}, views = {}, tableRows = {}, playerRows = {} }
    local frame = UI.Frame(parent, 'Minigames', PREF, W, H, Close)
    hub.frame = frame
    local body = frame.body
    UI.Rect(body, C.nav, 1, 0, 176, H - 38, 1)
    UI.Rect(body, C.line, 177, 0, 1, H - 38, 1)
    for i = 1, table.getn(TABS) do
        local def = TABS[i]
        local y = 12 + (i - 1) * 50
        local tab = {}
        local index = i
        tab.button = UI.Button(body, '', 'tab', 8, y, 162, 44, function() SelectTab(index) end, 13, 8)
        tab.mark = UI.Rect(body, C.accent, 8, y, 3, 44, 9)
        tab.icon = UI.Image(body, ICON .. def.icon, 20, y + 8, 28, 28, 10)
        tab.label = UI.Label(body, def.name, 13, C.text, UI.FONT_BOLD, 58, y + 14, 10)
        hub.tabs[i] = tab
        local page = UI.NewGroup(body, 192, 12, 512, H - 38 - 24, 2)
        hub.pages[i] = page
        hub.views[i] = def.build(page)
    end
    UI.Label(body, 'Nuggets lobby', 10, C.faint, UI.FONT, 16, H - 38 - 24, 6)

    local svc = Svc()
    if svc then
        hub.listener = svc:Listen(function(s, what) Render() end)
        svc:RequestTables()
    end
    local frameRef = frame
    frame.OnDestroy = function(self)
        local s = Svc()
        if s and hub and hub.frame == frameRef and hub.listener then s:Unlisten(hub.listener) end
        if hub and hub.frame == frameRef then hub = nil end
    end
    -- the player list and table states change without telling us
    ForkThread(function()
        while not IsDestroyed(frameRef) do
            local ok, err = pcall(Render)
            if not ok then WARN('NuggetsLobby: Minigames window failed: ' .. tostring(err)) end
            WaitSeconds(1)
        end
    end)
    SelectTab(lastTab)
end

----------------------------------------------------------------------------
-- drawing
----------------------------------------------------------------------------

local function TableState(t)
    if t.phase == 'lobby' then
        if t.n >= t.max then return 'Full', C.dim end
        return 'Waiting', C.good
    elseif t.phase == 'over' then
        return 'Game over', C.dim
    end
    return 'Round ' .. t.round, C.accent
end

local function TableInfo(t)
    local set = t.set
    local rules = 'Basic'
    if set.ruleset == 'traditional' then rules = 'Traditional' end
    local loss = set.lives .. ' lives'
    if set.lives == 1 then loss = '1 life' end
    if set.lose == 'dice' then loss = 'lose dice' end
    local text = t.n .. '/' .. t.max .. ' seated  |  ' .. rules .. ', ' .. loss .. ', ' .. set.timer .. ' s'
    if t.w > 0 then text = text .. '  |  ' .. t.w .. ' watching' end
    return text
end

local function DrawLiarsDice(p)
    local svc = Svc()
    local at = svc and svc.at
    local me = svc and svc:Me()
    -- my table, or the host button
    local atTable = at ~= nil
    p.host:SetShown(not atTable)
    p.host:SetEnabled(svc ~= nil)
    UI.Show(p.hostNote, not atTable)
    p.banner:SetShown(atTable)
    UI.Show(p.bannerTitle, atTable)
    UI.Show(p.bannerLine, atTable)
    p.open:SetShown(atTable)
    p.leave:SetShown(atTable)
    if not atTable then
        local count = 0
        if svc then count = table.getn(svc.env.peers()) end
        local notice = svc and svc:CurrentNotice()
        if notice then
            -- what just happened to my table (closed, no answer, ...)
            UI.SetFitted(p.hostNote, notice.text, 320)
            UI.Col(p.hostNote, C.accent)
        else
            UI.Col(p.hostNote, C.dim)
            if count == 1 then
                UI.Txt(p.hostNote, '1 other player here has this lobby.')
            else
                UI.Txt(p.hostNote, count .. ' other players here have this lobby.')
            end
        end
    else
        local title, line
        if at.host == me then title = 'You are hosting a table' else title = 'You are at ' .. at.host .. "'s table" end
        local snap = at.snap
        if at.role == 'pending' or not snap then
            line = 'Joining...'
        elseif snap.phase == 'lobby' then
            line = 'Waiting for players, ' .. table.getn(snap.seats) .. ' of 8 seats taken'
        elseif snap.phase == 'over' then
            line = 'Game over'
        else
            line = 'Round ' .. snap.round .. ' in progress'
        end
        if at.role == 'watch' then line = line .. '  (watching)' end
        UI.Txt(p.bannerTitle, title)
        UI.Txt(p.bannerLine, line)
        if at.host == me then p.leave:SetLabel('CLOSE') else p.leave:SetLabel('LEAVE') end
    end

    local list = svc and svc:Tables() or {}
    hub.tableRows = {}
    for r = 1, TABLE_ROWS do
        local row = p.rows[r]
        local t = list[r]
        hub.tableRows[r] = t
        local on = t ~= nil
        row.panel:SetShown(on)
        UI.Show(row.name, on)
        UI.Show(row.info, on)
        UI.Show(row.state, on)
        row.join:SetShown(on)
        row.watch:SetShown(on and not (t and t.mine))
        if on then
            local name = t.host .. "'s table"
            if t.mine then name = 'Your table' end
            UI.SetFitted(row.name, name, 230)
            UI.Txt(row.info, TableInfo(t))
            local state, color = TableState(t)
            UI.Txt(row.state, state)
            UI.Col(row.state, color)
            local mineNow = at and at.host == t.host
            if t.mine or mineNow then
                row.join:SetLabel('OPEN')
                row.join:SetStyle('primary')
                row.join:SetEnabled(true)
                row.watch:SetShown(false)
            else
                row.join:SetLabel('JOIN')
                row.join:SetEnabled(at == nil and t.phase == 'lobby' and t.n < t.max)
                row.watch:SetEnabled(at == nil)
            end
            if t.mine or mineNow then row.panel:SetColors(C.rowHi, C.accent) else row.panel:SetColors(C.row, C.line) end
        end
    end
    local none = table.getn(list) == 0
    UI.Show(p.empty1, none)
    UI.Show(p.empty2, none)
    local extra = table.getn(list) - TABLE_ROWS
    UI.Show(p.more, extra > 0)
    if extra > 0 then UI.Txt(p.more, extra .. ' MORE NOT SHOWN') end
end

local function DrawChallenges(p)
    local names = Games.Opponents()
    local stillHere = false
    for i = 1, table.getn(names) do
        if names[i] == picked then stillHere = true end
    end
    if not stillHere then picked = names[1] end
    hub.playerRows = {}
    for r = 1, PLAYER_ROWS do
        local b = p.players[r]
        local name = names[r]
        hub.playerRows[r] = name
        b:SetShown(name ~= nil)
        if name then
            b:SetLabel(name)
            if name == picked then b:SetStyle('tabOn') else b:SetStyle('ghost') end
        end
    end
    local nobody = table.getn(names) == 0
    UI.Show(p.nobody1, nobody)
    UI.Show(p.nobody2, nobody)
    local bundle = Games.HasBundle()
    for i = 1, table.getn(p.cards) do
        local card = p.cards[i]
        card.button:SetEnabled(bundle and picked ~= nil)
        if picked then UI.Txt(card.who, 'vs ' .. picked) else UI.Txt(card.who, 'pick a player') end
    end
    p.acceptChess:SetChecked(Games.GetSetting('acceptChess'))
    p.acceptBs:SetChecked(Games.GetSetting('acceptBattleship'))
    UI.Show(p.missing, not bundle)
end

local function DrawSolo(p)
    local bundle = Games.HasBundle()
    for i = 1, table.getn(p.cards) do
        local card = p.cards[i]
        card.button:SetEnabled(bundle or not card.def.bundle)
    end
    local n = Games.GetSetting('gridSize')
    p.size:SetValue(n .. ' \195\151 ' .. n)
    p.size:SetEnabled(bundle)
    -- showing the page shows every tick mark again
    p.hard:SetChecked(Games.GetSetting('hardMode'))
    UI.Show(p.missing, not bundle)
end

Render = function()
    if not hub or IsDestroyed(hub.frame) then return end
    hub.frame.close:SetShown(true)
    for i = 1, table.getn(TABS) do
        local tab = hub.tabs[i]
        local on = (i == lastTab)
        tab.button:SetStyle(on and 'tabOn' or 'tab')
        UI.Show(tab.mark, on)
        UI.Col(tab.label, on and C.text or C.dim)
    end
    if lastTab == 1 then
        DrawLiarsDice(hub.views[1])
    elseif lastTab == 2 then
        DrawChallenges(hub.views[2])
    else
        DrawSolo(hub.views[3])
    end
end

--- The lobby's Minigames button: opens the window, or closes it when it is open.
function Toggle()
    if hub and not IsDestroyed(hub.frame) then
        Close()
        return
    end
    local layer = Games.Layer()
    if not layer then return end
    Build(layer)
end

function IsOpen()
    return hub ~= nil and not IsDestroyed(hub.frame)
end
