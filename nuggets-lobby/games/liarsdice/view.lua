-- Nuggets custom lobby: the Liar's Dice table window. Imported as /nuggetslobby/liarsdice/view.lua.
--
-- Draws the table you are at from what its host sent (table.lua): seats round the table,
-- the current bid in the middle, this round's bids and the table's events on the right,
-- and your dice and moves at the bottom. Everything is redrawn from that state on every
-- change, and four times a second for the timers.
--
-- Closing the window leaves the table (asks first during a game, and closes the table
-- when it is yours). "Hide" keeps your seat; the window comes back when it is your turn.

local UI    = import('/nuggetslobby/ui.lua')
local Rules = import('/nuggetslobby/liarsdice/rules.lua')
local Table = import('/nuggetslobby/liarsdice/table.lua')

local ART  = '/nuggetslobby/liarsdice/art/'
local PREF = 'NuggetsLobby_LiarsDiceWindow_v1'
local C    = UI.COLORS
local W, H = 940, 650

-- the table area (690 x 432) and the seat plates round it, clockwise from the bottom centre
local AREA_W, AREA_H = 690, 432
local CX = AREA_W / 2
local SEAT_W, SEAT_H = 160, 74
local SEAT_POS = {
    { 265, 352 }, { 36, 316 }, { 6, 179 }, { 36, 42 },
    { 265, 6 }, { 494, 42 }, { 524, 179 }, { 494, 316 },
}

local HISTORY_ROWS = 9
local EVENT_LINES  = 12
local SETTING_ROWS = 5


local win = nil

-- wrapped lines per (width, text): measuring every word on every update adds up
local wrapCache = {}
local wrapCount = 0
local function WrapCached(label, text, width)
    local key = width .. '|' .. text
    local lines = wrapCache[key]
    if lines == nil then
        if wrapCount > 400 then
            wrapCache = {}
            wrapCount = 0
        end
        lines = UI.Wrap(label, text, width)
        wrapCache[key] = lines
        wrapCount = wrapCount + 1
    end
    return lines
end

----------------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------------

local function Svc()
    return Table.Get()
end

local function Wild(set) return set and set.ruleset == 'traditional' end

-- the smallest legal quantity for `face` in this state, nil when none
local function MinQ(snap, face)
    local q = 1
    if snap.bid then
        if face > snap.bid.f then q = snap.bid.q else q = snap.bid.q + 1 end
    end
    if q > snap.total then return nil end
    return q
end

local function Contains(list, value)
    if type(list) ~= 'table' then return false end
    for i = 1, table.getn(list) do
        if list[i] == value then return true end
    end
    return false
end

local function SeatName(snap, i)
    local s = snap.seats[i]
    if s then return s.n end
    return '?'
end

-- which picture of a die to show: 'n' normal, 'h' counts, 'w' wild one that counts, 'x' does not count
local function DieKind(face, res, wild)
    if res == nil then return 'n' end
    if face == res.f then return 'h' end
    if wild and face == 1 and res.f ~= 1 then return 'w' end
    return 'x'
end

-- With wild ones (Traditional) the one is a star: d1s / d1sh / d1sw / d1sx, s1s / s1sh / s1sw.
local function DieTex(face, kind, small, wild)
    local prefix = 'd'
    if small then prefix = 's' end
    if wild and face == 1 then
        local suffix = ''
        if kind == 'h' or kind == 'w' or (kind == 'x' and not small) then suffix = kind end
        return ART .. prefix .. '1s' .. suffix .. '.png'
    end
    if kind == 'h' then return ART .. prefix .. face .. 'h.png' end
    if kind == 'w' then return ART .. prefix .. '1w.png' end
    if kind == 'x' then return ART .. prefix .. face .. 'x.png' end
    return ART .. prefix .. face .. '.png'
end

local function SettingsLine(set)
    local parts = {}
    if set.ruleset == 'traditional' then
        table.insert(parts, 'Traditional (stars wild, Spot on)')
    else
        table.insert(parts, 'Basic')
    end
    if set.lose == 'dice' then
        table.insert(parts, set.dice .. ' dice, lose a die per loss')
    else
        local lives = set.lives .. ' lives'
        if set.lives == 1 then lives = '1 life' end
        table.insert(parts, lives .. ', ' .. set.dice .. ' dice')
    end
    table.insert(parts, set.timer .. ' s turns')
    return table.concat(parts, '  |  ')
end

local function RulesText(set)
    local text = 'Everyone rolls in secret. In turn, bid how many dice on the WHOLE table show a face: ' ..
        'raise the number, or keep it and name a higher face. Think the last bid is too high? Call LIAR! ' ..
        'Everyone shows their dice: if the bid was wrong the bidder loses, otherwise the caller does.'
    if Wild(set) then
        text = text .. ' The star is wild: it counts as every face, except in a bid on stars. ' ..
            'SPOT ON! says the bid is exactly right: if it is, everyone else loses, otherwise you do.'
    end
    if set.lose == 'dice' then
        text = text .. ' Each loss costs a die; no dice left and you are out.'
    else
        text = text .. ' Each loss costs a life; no lives left and you are out.'
    end
    return text .. ' Last player in wins.'
end

----------------------------------------------------------------------------
-- building the window
----------------------------------------------------------------------------

local Render   -- forward declaration

local function OnSeatRemove(slot)
    local svc = Svc()
    if not svc or not win then return end
    local seat = win.seats[slot].seatIndex
    local snap = svc.at and svc.at.snap
    if not seat or not snap or not snap.seats[seat] then return end
    local p = snap.seats[seat]
    if p.b then
        svc:RemoveSeat(seat)
        return
    end
    local name = p.n
    UI.Confirm(win.frame, 'Take ' .. name .. ' off the table? They can join again.', 'Remove', 'Cancel', function()
        local s = Svc()
        local current = s and s.at and s.at.snap
        -- the seats may have moved while the question was up
        if current then
            for i = 1, table.getn(current.seats) do
                if current.seats[i].n == name and not current.seats[i].b then s:RemoveSeat(i) end
            end
        end
    end)
end

local function BuildSeat(area, slot)
    local x, y = SEAT_POS[slot][1], SEAT_POS[slot][2]
    local s = { slot = slot }
    s.group = UI.NewGroup(area, x, y, SEAT_W, SEAT_H, 10)
    s.bg = UI.Rect(s.group, 'ee12161c', 0, 0, SEAT_W, SEAT_H, 1)
    s.gloss = UI.Image(s.group, UI.ART .. 'gloss.png', 0, 0, SEAT_W, 34, 2)
    s.border = UI.Border(s.group, C.line, 0, 0, SEAT_W, SEAT_H, 3)
    s.glow = UI.Border(s.group, C.accent, -2, -2, SEAT_W + 4, SEAT_H + 4, 4, 2)
    s.name = UI.Label(s.group, '', 13, C.text, UI.FONT_BOLD, 8, 5, 6)
    s.tag = UI.Label(s.group, '', 9, C.faint, UI.FONT_BOLD, 0, 8, 6)
    UI.RightAt(s.tag, s.group, SEAT_W - 8)
    s.dice = {}
    for k = 1, 6 do
        s.dice[k] = UI.Image(s.group, ART .. 'sq.png', 8 + (k - 1) * 24, 26, 21, 21, 5)
    end
    s.hearts = {}
    for k = 1, 5 do
        s.hearts[k] = UI.Image(s.group, ART .. 'heart.png', 8 + (k - 1) * 15, 52, 14, 14, 5)
    end
    s.count = UI.Label(s.group, '', 11, C.dim, UI.FONT_BOLD, 8, 52, 6)
    s.status = UI.Label(s.group, '', 12, C.text, UI.FONT_BOLD, 0, 51, 7)
    s.statusDie = UI.Image(s.group, ART .. 's1.png', SEAT_W - 8 - 18, 50, 18, 18, 7)
    s.bar = UI.Bar(s.group, 1, SEAT_H - 4, SEAT_W - 2, 3, C.good, 7)
    s.crown = UI.Image(s.group, ART .. 'crown.png', SEAT_W - 30, -20, 34, 34, 9)
    local slotIndex = slot
    s.remove = UI.Button(s.group, 'x', 'ghost', SEAT_W - 26, SEAT_H - 25, 20, 20, function() OnSeatRemove(slotIndex) end, 12, 9)
    return s
end

local function OnClose()
    local svc = Svc()
    local at = svc and svc.at
    if not at then
        if win then win.frame:Destroy() end
        return
    end
    local snap = at.snap
    local me = svc:Me()
    local playing = snap and snap.phase ~= 'lobby' and snap.phase ~= 'over'
    local stillIn = snap and snap.you.seat > 0 and snap.seats[snap.you.seat] and not snap.seats[snap.you.seat].o
    if at.host == me then
        local text = 'Close your table? Everyone at it goes back to the lobby.'
        if playing then text = 'Close your table and end the game for everyone?' end
        UI.Confirm(win.frame, text, 'Close table', 'Cancel', function()
            svc:CloseTable()
            if win then win.frame:Destroy() end
        end)
    elseif playing and stillIn then
        UI.Confirm(win.frame, 'Leave the game? You are out of it, and everyone else rolls again.', 'Leave', 'Stay', function()
            svc:Leave()
            if win then win.frame:Destroy() end
        end)
    else
        svc:Leave()
        if win then win.frame:Destroy() end
    end
end

local function Hide()
    if win then
        win.hidden = true
        win.frame:Hide()
    end
end

-- bid composer
local function Sel() return win.sel end

local function ClampSel(snap)
    local sel = Sel()
    if sel.f == nil or MinQ(snap, sel.f) == nil then
        sel.f = nil
        for f = 6, 1, -1 do
            if sel.f == nil and MinQ(snap, f) then sel.f = f end
        end
    end
    if sel.f == nil then return end
    local minQ = MinQ(snap, sel.f)
    if sel.q == nil or sel.q < minQ then sel.q = minQ end
    if sel.q > snap.total then sel.q = snap.total end
end

-- a starting suggestion for a new turn: the face I hold most of
local function SuggestSel(snap)
    local sel = Sel()
    local hand = snap.you.hand or {}
    local wild = Wild(snap.set)
    local counts = { 0, 0, 0, 0, 0, 0 }
    for i = 1, table.getn(hand) do
        local d = hand[i]
        counts[d] = counts[d] + 1
    end
    local best, bestCount = nil, -1
    for f = 1, 6 do
        local mine = counts[f]
        if wild and f ~= 1 then mine = mine + counts[1] end
        if MinQ(snap, f) and mine > bestCount and not (wild and f == 1) then
            best, bestCount = f, mine
        end
    end
    if best == nil and snap.bid then best = snap.bid.f end
    sel.f = best
    sel.q = nil
    if best and snap.bid == nil then
        sel.q = math.max(1, bestCount)
    end
    ClampSel(snap)
end

local function Act(kind)
    local svc = Svc()
    if not svc or not win then return end
    local snap = svc.at and svc.at.snap
    if not snap then return end
    if kind == 'bid' then
        ClampSel(snap)
        local sel = Sel()
        if sel.f and sel.q then svc:Act('bid', sel.q, sel.f) end
    else
        svc:Act(kind)
    end
    Render()
end

local function Step(dir)
    local svc = Svc()
    local snap = svc and svc.at and svc.at.snap
    if not snap then return end
    local sel = Sel()
    if sel.q then sel.q = sel.q + dir end
    ClampSel(snap)
    Render()
end

local function PickFace(f)
    local svc = Svc()
    local snap = svc and svc.at and svc.at.snap
    if not snap or MinQ(snap, f) == nil then return end
    local sel = Sel()
    sel.f = f
    ClampSel(snap)
    Render()
end

local function SettingRow(panel, row)
    local y = 36 + (row - 1) * 34
    local r = {}
    r.label = UI.Label(panel, '', 12, C.dim, UI.FONT, 12, y + 6, 6)
    local rowIndex = row
    r.stepper = UI.Stepper(panel, 84, y, 124, function(dir)
        local svc = Svc()
        if svc and win and win.settingKeys[rowIndex] then
            svc:StepSetting(win.settingKeys[rowIndex], dir)
        end
    end, 8)
    r.value = UI.Label(panel, '', 12, C.text, UI.FONT_BOLD, 0, y + 6, 6)
    UI.RightAt(r.value, panel, 208)
    return r
end

local function Build(parent)
    win = {
        seats = {}, history = {}, events = {}, settings = {}, faces = {}, myDice = {},
        sel = { f = nil, q = nil, key = nil }, settingKeys = {}, last = nil, hidden = false,
    }
    local frame = UI.Frame(parent, "Liar's Dice", PREF, W, H, OnClose)
    win.frame = frame
    local body = frame.body

    win.subtitle = UI.Label(frame, '', 12, C.dim, UI.FONT, 140, 12, 7)
    win.hide = UI.Button(frame, 'Hide', 'ghost', W - 96, 4, 54, 28, Hide, 12, 8)

    -- the table
    local area = UI.NewGroup(body, 10, 8, AREA_W, AREA_H, 1)
    win.area = area
    UI.Image(area, ART .. 'table.png', 0, 0, AREA_W, AREA_H, 1)
    for slot = 1, 8 do
        win.seats[slot] = BuildSeat(area, slot)
    end
    local c = {}
    c.small = UI.Label(area, '', 11, C.dim, UI.FONT_BOLD, 0, 150, 12)
    c.title = UI.Label(area, '', 26, C.text, UI.FONT_BIG, 0, 140, 12)
    c.qty = UI.Label(area, '', 32, C.text, UI.FONT_BIG, 0, 170, 12)
    c.die = UI.Image(area, ART .. 'd6.png', 0, 168, 50, 50, 12)
    c.line1 = UI.Label(area, '', 13, C.text, UI.FONT_BOLD, 0, 226, 12)
    c.line2 = UI.Label(area, '', 12, C.dim, UI.FONT, 0, 248, 12)
    c.line3 = UI.Label(area, '', 13, C.text, UI.FONT_BOLD, 0, 268, 12)
    c.line4 = UI.Label(area, '', 11, C.faint, UI.FONT, 0, 290, 12)
    local centred = { 'small', 'title', 'line1', 'line2', 'line3', 'line4' }
    for i = 1, table.getn(centred) do
        UI.CenterX(c[centred[i]], area, 0, AREA_W)
        c[centred[i]]:SetDropShadow(true)
    end
    c.qty:SetDropShadow(true)
    -- "4 x" and the die, centred together
    c.qty.Left:Set(function() return area.Left() + UI.S(CX) - math.floor((c.qty.Width() + UI.S(56)) / 2) end)
    c.die.Left:Set(function() return c.qty.Right() + UI.S(6) end)
    c.crown = UI.Image(area, ART .. 'crown.png', CX - 32, 104, 64, 64, 12)
    win.center = c

    -- right side: this round's bids (or the settings), and the table's events
    local side = UI.NewGroup(body, 710, 8, 220, 432, 1)
    win.side = side
    UI.Panel(side, 0, 0, 220, 216, C.panel, C.line, 1)
    win.sideHeader = UI.Label(side, '', 10, C.dim, UI.FONT_BOLD, 12, 12, 6)
    for row = 1, HISTORY_ROWS do
        local y = 34 + (row - 1) * 20
        local h = {}
        h.name = UI.Label(side, '', 12, C.text, UI.FONT, 12, y + 2, 6)
        h.right = UI.Label(side, '', 12, C.text, UI.FONT_BOLD, 0, y + 2, 6)
        h.die = UI.Image(side, ART .. 's1.png', 220 - 12 - 17, y, 17, 17, 6)
        win.history[row] = h
    end
    for row = 1, SETTING_ROWS do
        win.settings[row] = SettingRow(side, row)
    end
    UI.Panel(side, 0, 224, 220, 208, C.panel, C.line, 1)
    UI.Label(side, 'TABLE', 10, C.dim, UI.FONT_BOLD, 12, 236, 6)
    for i = 1, EVENT_LINES do
        win.events[i] = UI.Label(side, '', 11, C.text, UI.FONT, 12, 256 + (i - 1) * 14, 6)
    end

    -- bottom: your dice, your bid, your moves
    local tray = UI.NewGroup(body, 10, 448, 920, 156, 1)
    win.tray = tray
    UI.Panel(tray, 0, 0, 920, 156, C.panel, C.line, 1)
    win.myBar = UI.Bar(tray, 1, 1, 918, 4, C.good, 4)
    win.status = UI.Label(tray, '', 16, C.text, UI.FONT_BOLD, 16, 13, 6)
    win.statusRight = UI.Label(tray, '', 16, C.accent, UI.FONT_BOLD, 0, 13, 6)
    win.statusRight.Left:Set(function() return win.status.Right() + UI.S(10) end)
    win.diceLabel = UI.Label(tray, 'YOUR DICE', 10, C.dim, UI.FONT_BOLD, 16, 44, 6)
    for k = 1, 6 do
        win.myDice[k] = UI.Image(tray, ART .. 'd1.png', 16 + (k - 1) * 46, 62, 40, 40, 6)
    end
    win.bidLabel = UI.Label(tray, 'YOUR BID', 10, C.dim, UI.FONT_BOLD, 306, 44, 6)
    win.minus = UI.Button(tray, '-', 'normal', 306, 62, 30, 42, function() Step(-1) end, 18, 8)
    win.qtyBg = UI.Rect(tray, C.bg2, 338, 62, 52, 42, 5)
    win.qty = UI.Label(tray, '', 22, C.text, UI.FONT_BIG, 0, 69, 7)
    UI.CenterX(win.qty, tray, 338, 52)
    win.plus = UI.Button(tray, '+', 'normal', 392, 62, 30, 42, function() Step(1) end, 18, 8)
    win.times = UI.Label(tray, '\195\151', 14, C.dim, UI.FONT_BOLD, 427, 74, 6)
    for f = 1, 6 do
        local face = f
        win.faces[f] = UI.ImageButton(tray, { up = ART .. 'd' .. f .. '.png', over = ART .. 'd' .. f .. '.png', off = ART .. 'd' .. f .. 'x.png' },
            444 + (f - 1) * 42, 63, 38, 38, function() PickFace(face) end, 9)
    end
    win.hint = UI.Label(tray, '', 12, C.dim, UI.FONT, 16, 124, 6)
    win.rules = {}
    for i = 1, 5 do
        win.rules[i] = UI.Label(tray, '', 12, C.dim, UI.FONT, 16, 42 + (i - 1) * 17, 6)
    end

    win.bid = UI.Button(tray, 'BID', 'primary', 712, 38, 192, 42, function() Act('bid') end, 14, 8)
    win.liar = UI.Button(tray, 'LIAR!', 'danger', 712, 86, 94, 38, function() Act('liar') end, 14, 8)
    -- without Spot on (Basic rules) Liar! takes the whole row
    win.liarWide = UI.Button(tray, 'LIAR!', 'danger', 712, 86, 192, 38, function() Act('liar') end, 14, 8)
    win.spot = UI.Button(tray, 'SPOT ON!', 'gold', 810, 86, 94, 38, function() Act('spot') end, 13, 8)
    win.start = UI.Button(tray, 'START GAME', 'primary', 712, 38, 192, 42, function()
        local svc = Svc()
        if svc then svc:Start() end
    end, 14, 8)
    win.addBot = UI.Button(tray, 'ADD A BOT', 'normal', 712, 86, 192, 34, function()
        local svc = Svc()
        if svc then svc:AddBot() end
    end, 13, 8)
    win.sit = UI.Button(tray, 'TAKE A SEAT', 'primary', 712, 38, 192, 42, function()
        local svc = Svc()
        if svc then svc:Sit() end
    end, 14, 8)
    win.newGame = UI.Button(tray, 'NEW GAME', 'primary', 712, 38, 192, 42, function()
        local svc = Svc()
        if svc then svc:NewGame() end
    end, 14, 8)
    win.leave = UI.Button(tray, 'LEAVE TABLE', 'normal', 712, 86, 192, 34, OnClose, 13, 8)
    win.closeBtn = UI.Button(tray, 'CLOSE', 'normal', 712, 38, 192, 42, function()
        if win then win.frame:Destroy() end
    end, 14, 8)

    local svc = Svc()
    if svc then
        win.listener = svc:Listen(function(s, what) Render() end)
    end
    local frameRef = frame
    frame.OnDestroy = function(self)
        local s = Svc()
        if s and win and win.frame == frameRef and win.listener then s:Unlisten(win.listener) end
        if win and win.frame == frameRef then win = nil end
    end
    ForkThread(function()
        while not IsDestroyed(frameRef) do
            local ok, err = pcall(Render)
            if not ok then WARN("NuggetsLobby: Liar's Dice window failed: " .. tostring(err)) end
            WaitSeconds(0.25)
        end
    end)
end

----------------------------------------------------------------------------
-- drawing
----------------------------------------------------------------------------

-- where each seat sits: the viewer at the bottom, the others spread round the table
local function SlotsFor(snap)
    local n = table.getn(snap.seats)
    local viewer = snap.you.seat
    if viewer == nil or viewer < 1 then viewer = 1 end
    local slots = {}
    for i = 1, n do
        local k = i - viewer
        if k < 0 then k = k + n end
        local slot = math.floor(k * 8 / n + 0.5)
        if slot >= 8 then slot = slot - 8 end
        slots[i] = slot + 1
    end
    return slots
end

-- this round's last bid by each seat, and calls
local function RoundActions(snap)
    local lastBid, call = {}, {}
    if snap.hist then
        for i = 1, table.getn(snap.hist) do
            local h = snap.hist[i]
            if h.call then call[h.by] = h.call else lastBid[h.by] = h end
        end
    end
    return lastBid, call
end

local function DrawSeat(s, snap, i, svc)
    local p = snap.seats[i]
    local me = (i == snap.you.seat)
    local wild = Wild(snap.set)
    local phase = snap.phase
    local res = snap.res
    if res and res.round ~= snap.round then res = nil end
    local showRes = (phase == 'reveal' or phase == 'over') and res ~= nil
    s.seatIndex = i
    UI.Show(s.group, true)

    -- name and tags
    UI.SetFitted(s.name, p.n, 104)
    local nameColor = C.text
    if me then nameColor = C.accent end
    if p.o then nameColor = C.faint end
    UI.Col(s.name, nameColor)
    local tag = ''
    if p.b then tag = 'BOT' elseif p.n == svc.at.host then tag = 'HOST' end
    if p.x then tag = 'LEFT' end
    UI.Txt(s.tag, tag)

    -- the border: whose turn it is, the winner
    local turn = (phase == 'bidding' and snap.turn == i)
    local winner = (phase == 'over' and snap.win == i)
    s.glow:SetShown(turn or winner)
    if turn or winner then s.glow:SetColor(C.accent) end
    local bg = 'ee12161c'
    if turn then bg = 'ee2a2410' elseif p.o then bg = 'cc0d1013' end
    UI.Col(s.bg, bg)
    s.border:SetColor(me and C.lineHi or C.line)

    -- dice
    local hand = nil
    if showRes then
        for k = 1, table.getn(res.hands) do
            if res.hands[k].s == i then hand = res.hands[k].d end
        end
    elseif me and snap.you.hand and phase ~= 'lobby' then
        hand = snap.you.hand
    end
    local count = p.d or 0
    if phase == 'lobby' then count = snap.set.dice end
    if hand then count = table.getn(hand) end
    if p.o and not hand then count = 0 end
    for k = 1, 6 do
        local die = s.dice[k]
        if k <= count then
            UI.Show(die, true)
            if hand then
                local kind = 'n'
                if showRes then kind = DieKind(hand[k], res, wild) end
                UI.Tex(die, DieTex(hand[k], kind, true, wild))
            else
                UI.Tex(die, ART .. 'sq.png')
            end
        else
            UI.Show(die, false)
        end
    end

    -- lives (or dice left)
    local lose = snap.set.lose
    for k = 1, 5 do
        local heart = s.hearts[k]
        if lose == 'lives' and k <= snap.set.lives and not p.x then
            UI.Show(heart, true)
            if k <= p.l then UI.Tex(heart, ART .. 'heart.png') else UI.Tex(heart, ART .. 'heart0.png') end
        else
            UI.Show(heart, false)
        end
    end
    if lose == 'dice' and not p.x then
        UI.Show(s.count, true)
        local d = p.d
        if phase == 'lobby' then d = snap.set.dice end
        if d == 1 then UI.Txt(s.count, '1 die left') else UI.Txt(s.count, d .. ' dice left') end
    else
        UI.Show(s.count, false)
    end

    -- status: last bid, call, result
    local lastBid, call = RoundActions(snap)
    local text, color, dieFace = '', C.text, nil
    if phase == 'lobby' then
        text = ''
    elseif p.x then
        text = ''
    elseif phase == 'over' and winner then
        text, color = 'WINNER', C.accent
    elseif p.o and not (showRes and Contains(res.out, i)) then
        text, color = 'OUT', C.faint
    elseif showRes then
        local lost = Contains(res.losers, i)
        if Contains(res.out, i) then
            text, color = 'OUT', C.bad
        elseif lost then
            if lose == 'dice' then text = '-1 die' else text = '-1 life' end
            color = C.bad
        elseif res.caller == i then
            if res.kind == 'spot' then text, color = 'SPOT ON!', C.accent else text, color = 'LIAR!', C.bad end
        elseif lastBid[i] then
            text, dieFace = lastBid[i].q .. ' \195\151', lastBid[i].f
        end
    elseif turn then
        if me then text, color = 'your turn', C.accent else text, color = 'thinking...', C.dim end
    elseif call[i] then
        if call[i] == 'spot' then text, color = 'SPOT ON!', C.accent else text, color = 'LIAR!', C.bad end
    elseif lastBid[i] then
        text, dieFace = lastBid[i].q .. ' \195\151', lastBid[i].f
        if snap.bid and snap.bid.by == i then color = C.accent else color = C.dim end
    end
    UI.Txt(s.status, text)
    UI.Col(s.status, color)
    if dieFace then
        UI.Show(s.statusDie, true)
        UI.Tex(s.statusDie, DieTex(dieFace, 'n', true, wild))
        if s._statusRight ~= 1 then
            s._statusRight = 1
            UI.RightAt(s.status, s.group, SEAT_W - 8 - 18 - 4)
        end
    else
        UI.Show(s.statusDie, false)
        if s._statusRight ~= 2 then
            s._statusRight = 2
            UI.RightAt(s.status, s.group, SEAT_W - 8)
        end
    end

    -- turn timer
    local left = svc:TurnLeft()
    if turn and left and snap.limit and not p.b then
        s.bar:SetShown(true)
        local v = left / snap.limit
        s.bar:SetValue(v)
        if v > 0.5 then s.bar:SetColor(C.good) elseif v > 0.25 then s.bar:SetColor(C.accent) else s.bar:SetColor(C.bad) end
    else
        s.bar:SetShown(false)
    end
    UI.Show(s.crown, winner)
    -- the host can take others off the table before a game
    local canRemove = phase == 'lobby' and svc.at.host == svc:Me() and not me and p.n ~= svc:Me()
    s.remove:SetShown(canRemove)
end

local CENTER_LABELS = { 'small', 'title', 'line1', 'line2', 'line3', 'line4' }

local function DrawCenter(snap, svc)
    local c = win.center
    local set = snap.set
    local wild = Wild(set)
    local seated = 0
    for i = 1, table.getn(snap.seats) do
        if not snap.seats[i].x then seated = seated + 1 end
    end
    -- what each label shows: { text, y, colour }; labels not listed are hidden
    local spec = {}
    local bidShown, bidQ, bidF, bidKind, bidY = false, nil, nil, 'n', 166
    local crown = false
    local dicePart = snap.total .. ' dice on the table'
    if wild then dicePart = dicePart .. '  |  stars are wild' end

    if snap.phase == 'lobby' then
        spec.title = { 'Waiting for players', 150, C.text }
        spec.line1 = { seated .. ' of ' .. Rules.MAX_PLAYERS .. ' seats taken', 192, C.text }
        if svc.at.host == svc:Me() then
            spec.line2 = { 'Add bots or wait for players, then start the game.', 214, C.dim }
        else
            spec.line2 = { svc.at.host .. ' starts the game.', 214, C.dim }
        end
    elseif snap.phase == 'bidding' then
        if snap.bid then
            spec.small = { 'ROUND ' .. snap.round .. '  |  CURRENT BID', 142, C.dim }
            bidShown, bidQ, bidF, bidY = true, snap.bid.q, snap.bid.f, 163
            spec.line1 = { 'bid by ' .. SeatName(snap, snap.bid.by), 220, C.text }
            spec.line2 = { dicePart, 242, C.dim }
        else
            spec.small = { 'ROUND ' .. snap.round, 146, C.dim }
            spec.title = { 'New dice', 164, C.text }
            if snap.turn == snap.you.seat then
                spec.line1 = { 'You open the bidding', 206, C.accent }
            else
                spec.line1 = { SeatName(snap, snap.turn) .. ' opens the bidding', 206, C.text }
            end
            spec.line2 = { dicePart, 228, C.dim }
        end
    else
        -- reveal, or over: the last call stays up
        local res = snap.res
        local shown = res ~= nil and res.round == snap.round
        if shown then
            local caller, bidder = SeatName(snap, res.caller), SeatName(snap, res.bidder)
            if res.kind == 'spot' then
                spec.title = { 'SPOT ON!', 106, C.accent }
                spec.small = { caller .. ' says ' .. bidder .. "'s bid is exactly right", 145, C.dim }
            else
                spec.title = { 'LIAR!', 106, C.bad }
                spec.small = { caller .. ' doubts ' .. bidder .. "'s bid", 145, C.dim }
            end
            bidShown, bidQ, bidF, bidKind, bidY = true, res.q, res.f, 'h', 165
            local found = 'There were ' .. res.count
            if res.wilds > 0 then found = found .. '  (' .. res.natural .. ' + ' .. res.wilds .. ' wild)' end
            spec.line1 = { found, 222, C.text }
            local what = 'a life'
            if set.lose == 'dice' then what = 'a die' end
            local loser = SeatName(snap, res.losers[1] or 0)
            local verdict
            if res.kind == 'spot' then
                if res.exact then verdict = 'Exactly right! Everyone else loses ' .. what .. '.' else verdict = 'Not exact: ' .. loser .. ' loses ' .. what .. '.' end
            elseif res.held then
                verdict = 'The bid holds: ' .. loser .. ' loses ' .. what .. '.'
            else
                verdict = 'Too high: ' .. loser .. ' loses ' .. what .. '.'
            end
            local color = C.bad
            if res.kind == 'spot' and res.exact then color = C.accent end
            spec.line3 = { verdict, 244, color }
            if snap.phase == 'reveal' then
                local nextIn = svc:NextLeft()
                if nextIn then spec.line4 = { 'Next round in ' .. math.max(0, math.ceil(nextIn - 0.05)), 268, C.faint } end
            end
        end
        if snap.phase == 'over' then
            -- the winner on top, the last call below
            local name = SeatName(snap, snap.win) .. ' wins!'
            if snap.win == snap.you.seat then name = 'You win!' end
            local rounds = 'GAME OVER AFTER ' .. snap.round .. ' ROUNDS'
            if snap.round == 1 then rounds = 'GAME OVER AFTER 1 ROUND' end
            if shown then
                spec.title = { name, 106, C.accent }
                spec.small = { rounds, 145, C.dim }
            else
                crown = true
                spec.title = { name, 176, C.accent }
                spec.line1 = { rounds, 216, C.dim }
            end
        end
    end

    for i = 1, table.getn(CENTER_LABELS) do
        local key = CENTER_LABELS[i]
        local label = c[key]
        local def = spec[key]
        if def then
            UI.Show(label, true)
            UI.Txt(label, def[1])
            UI.SetY(label, win.area, def[2])
            UI.Col(label, def[3])
        else
            UI.Show(label, false)
        end
    end
    UI.Show(c.qty, bidShown)
    UI.Show(c.die, bidShown)
    if bidShown then
        UI.Txt(c.qty, bidQ .. ' \195\151')
        UI.SetY(c.qty, win.area, bidY + 3)
        UI.SetY(c.die, win.area, bidY)
        UI.Tex(c.die, DieTex(bidF, bidKind, false, wild))
    end
    UI.Show(c.crown, crown)
end

local function DrawSide(snap, svc)
    local isHost = svc.at.host == svc:Me()
    if snap.phase == 'lobby' then
        UI.Txt(win.sideHeader, 'TABLE SETTINGS')
        for row = 1, HISTORY_ROWS do
            local h = win.history[row]
            UI.Show(h.name, false)
            UI.Show(h.right, false)
            UI.Show(h.die, false)
        end
        local set = snap.set
        local rows = {
            { 'ruleset', 'Rules', (set.ruleset == 'traditional') and 'Traditional' or 'Basic' },
            { 'lose', 'A loss costs', (set.lose == 'dice') and 'a die' or 'a life' },
        }
        if set.lose == 'lives' then
            table.insert(rows, { 'lives', 'Lives', tostring(set.lives) })
            table.insert(rows, { 'dice', 'Dice each', tostring(set.dice) })
        else
            table.insert(rows, { 'dice', 'Dice to start', tostring(set.dice) })
        end
        table.insert(rows, { 'timer', 'Turn time', set.timer .. ' s' })
        win.settingKeys = {}
        for row = 1, SETTING_ROWS do
            local r = win.settings[row]
            local def = rows[row]
            if def then
                win.settingKeys[row] = def[1]
                UI.Show(r.label, true)
                UI.Txt(r.label, def[2])
                r.stepper:SetShown(isHost)
                r.stepper:SetValue(def[3])
                UI.Show(r.value, not isHost)
                UI.Txt(r.value, def[3])
            else
                UI.Show(r.label, false)
                r.stepper:SetShown(false)
                UI.Show(r.value, false)
            end
        end
    else
        UI.Txt(win.sideHeader, 'BIDS THIS ROUND')
        for row = 1, SETTING_ROWS do
            local r = win.settings[row]
            UI.Show(r.label, false)
            r.stepper:SetShown(false)
            UI.Show(r.value, false)
        end
        local hist = snap.hist or {}
        local n = table.getn(hist)
        local first = math.max(1, n - HISTORY_ROWS + 1)
        for row = 1, HISTORY_ROWS do
            local h = win.history[row]
            local e = hist[first + row - 1]
            if e then
                UI.Show(h.name, true)
                UI.Show(h.right, true)
                local name = SeatName(snap, e.by)
                if e.a then name = name .. ' (timed out)' end
                UI.SetFitted(h.name, name, 120)
                UI.Col(h.name, (e.by == snap.you.seat) and C.accent or C.text)
                if e.call then
                    UI.Show(h.die, false)
                    if e.call == 'spot' then
                        UI.Txt(h.right, 'SPOT ON!')
                        UI.Col(h.right, C.accent)
                    else
                        UI.Txt(h.right, 'LIAR!')
                        UI.Col(h.right, C.bad)
                    end
                    if h._r ~= 1 then h._r = 1; UI.RightAt(h.right, win.side, 208) end
                else
                    UI.Show(h.die, true)
                    UI.Tex(h.die, DieTex(e.f, 'n', true, Wild(snap.set)))
                    UI.Txt(h.right, e.q .. ' \195\151')
                    UI.Col(h.right, C.text)
                    if h._r ~= 2 then h._r = 2; UI.RightAt(h.right, win.side, 208 - 17 - 4) end
                end
            else
                UI.Show(h.name, false)
                UI.Show(h.right, false)
                UI.Show(h.die, false)
            end
        end
    end

    -- events, newest at the bottom, as many whole ones as fit
    local ev = snap.ev or {}
    local blocks = {}
    local used = 0
    for i = table.getn(ev), 1, -1 do
        local wrapped = WrapCached(win.events[1], ev[i], 196)
        if used + table.getn(wrapped) > EVENT_LINES then break end
        used = used + table.getn(wrapped)
        table.insert(blocks, 1, wrapped)
    end
    local lines = {}
    for i = 1, table.getn(blocks) do
        for k = 1, table.getn(blocks[i]) do table.insert(lines, blocks[i][k]) end
    end
    for i = 1, EVENT_LINES do
        local text = lines[i]
        UI.Txt(win.events[i], text or '')
        UI.Show(win.events[i], text ~= nil)
    end
end

local function ShowControls(list, on)
    for i = 1, table.getn(list) do
        local c = list[i]
        if c.SetShown then c:SetShown(on) else UI.Show(c, on) end
    end
end

-- new dice: my dice tumble for a moment before they settle
local ROLL_TIME = 0.7

local function Rolling()
    return win ~= nil and win.rollUntil ~= nil and CurrentTime() < win.rollUntil
end

local function StartRoll(wild)
    if not win then return end
    win.rollUntil = CurrentTime() + ROLL_TIME
    local frameRef = win.frame
    ForkThread(function()
        while win and win.frame == frameRef and not IsDestroyed(frameRef) and Rolling() do
            for k = 1, 6 do
                local die = win.myDice[k]
                if not die:IsHidden() then UI.Tex(die, DieTex(math.random(1, 6), 'n', false, wild)) end
            end
            WaitSeconds(0.06)
        end
        if win and win.frame == frameRef and not IsDestroyed(frameRef) then
            win.rollUntil = nil
            Render()
        end
    end)
end

local function DrawTray(snap, svc)
    local me = svc:Me()
    local isHost = svc.at.host == me
    local seat = snap.you.seat
    local mine = seat > 0 and snap.seats[seat] or nil
    local inGame = mine ~= nil and not mine.o
    local myTurn = snap.phase == 'bidding' and snap.turn == seat and inGame
    local wild = Wild(snap.set)
    local acting = svc:Acting()

    -- which controls this phase has
    local composer = { win.bidLabel, win.minus, win.qtyBg, win.qty, win.plus, win.times }
    local actions = { win.bid, win.liar, win.liarWide, win.spot }
    local others = { win.start, win.addBot, win.sit, win.newGame, win.leave, win.closeBtn }
    local showDice = inGame and snap.phase ~= 'lobby' and snap.you.hand ~= nil
    local showComposer = inGame and snap.phase == 'bidding'
    UI.Show(win.diceLabel, showDice)
    ShowControls(composer, showComposer)
    for f = 1, 6 do win.faces[f]:SetShown(showComposer) end
    ShowControls(actions, showComposer)
    ShowControls(others, false)
    UI.Show(win.hint, showComposer or showDice)

    -- rules text where the dice go, before a game and for watchers
    local rulesLines = {}
    if not showDice then
        rulesLines = WrapCached(win.rules[1], RulesText(snap.set), 670)
    end
    for i = 1, 5 do
        UI.Txt(win.rules[i], rulesLines[i] or '')
        UI.Show(win.rules[i], rulesLines[i] ~= nil)
    end

    -- my dice
    local res = snap.res
    if res and res.round ~= snap.round then res = nil end
    local showRes = (snap.phase == 'reveal' or snap.phase == 'over') and res ~= nil
    local hand = snap.you.hand or {}
    local rolling = Rolling() and snap.phase == 'bidding'
    for k = 1, 6 do
        local die = win.myDice[k]
        if showDice and k <= table.getn(hand) then
            UI.Show(die, true)
            local face = hand[k]
            if rolling then face = nil end
            if face then
                local kind = 'n'
                if showRes then kind = DieKind(face, res, wild) end
                UI.Tex(die, DieTex(face, kind, false, wild))
            end
        else
            UI.Show(die, false)
        end
    end

    -- status line and my timer
    local status, right, statusColor = '', '', C.text
    local left = svc:TurnLeft()
    win.myBar:SetShown(myTurn and left ~= nil)
    if myTurn and left and snap.limit then
        local v = left / snap.limit
        win.myBar:SetValue(v)
        if v > 0.5 then win.myBar:SetColor(C.good) elseif v > 0.25 then win.myBar:SetColor(C.accent) else win.myBar:SetColor(C.bad) end
    end
    if snap.phase == 'lobby' then
        if isHost then
            status = 'Your table. Players here can join it from the Minigames window.'
            ShowControls({ win.start, win.addBot }, true)
            win.start:SetEnabled(svc:CanStart())
            win.addBot:SetEnabled(table.getn(snap.seats) < Rules.MAX_PLAYERS)
        elseif seat > 0 then
            status = 'You have a seat. Waiting for ' .. svc.at.host .. ' to start the game.'
            ShowControls({ win.leave }, true)
        else
            status = 'You are watching.'
            win.sit:SetShown(true)
            win.sit:SetEnabled(table.getn(snap.seats) < Rules.MAX_PLAYERS)
            ShowControls({ win.leave }, true)
        end
    elseif snap.phase == 'bidding' then
        if myTurn then
            status, statusColor = 'Your turn', C.accent
            if left then right = math.max(0, math.ceil(left - 0.05)) .. ' s' end
        elseif inGame then
            status = 'Waiting for ' .. SeatName(snap, snap.turn) .. '...'
            statusColor = C.dim
        elseif mine then
            status, statusColor = 'You are out. Watch the rest of the game.', C.dim
            ShowControls({ win.leave }, true)
        else
            status, statusColor = 'You are watching. ' .. SeatName(snap, snap.turn) .. ' is bidding.', C.dim
            ShowControls({ win.leave }, true)
        end
    elseif snap.phase == 'reveal' then
        status, statusColor = 'Everyone shows their dice.', C.text
        if not inGame then ShowControls({ win.leave }, true) end
    elseif snap.phase == 'over' then
        local w = SeatName(snap, snap.win)
        if snap.win == seat then status, statusColor = 'You win!', C.accent else status = w .. ' wins the game.' end
        if isHost then
            win.newGame:SetShown(true)
        else
            ShowControls({ win.leave }, true)
        end
    end
    UI.Txt(win.status, status)
    UI.Col(win.status, statusColor)
    UI.Txt(win.statusRight, right)

    -- the bid composer
    if showComposer then
        local sel = Sel()
        local key = snap.round .. ':' .. snap.step
        if sel.key ~= key then
            sel.key = key
            SuggestSel(snap)
        end
        ClampSel(snap)
        local canBid = myTurn and not acting and sel.f ~= nil
        UI.Txt(win.qty, sel.q or '-')
        local minQ = sel.f and MinQ(snap, sel.f)
        win.minus:SetEnabled(canBid and sel.q ~= nil and minQ ~= nil and sel.q > minQ)
        win.plus:SetEnabled(canBid and sel.q ~= nil and sel.q < snap.total)
        if win.facesWild ~= wild then
            win.facesWild = wild
            win.faces[1]:SetTextures({ up = DieTex(1, 'n', false, wild), over = DieTex(1, 'n', false, wild), off = DieTex(1, 'x', false, wild) })
        end
        for f = 1, 6 do
            local b = win.faces[f]
            b:SetEnabled(myTurn and not acting and MinQ(snap, f) ~= nil)
            b:SetSelected(myTurn and sel.f == f)
        end
        if sel.f and sel.q then
            win.bid:SetLabel('BID ' .. string.upper(Table.BidText(sel.q, sel.f, wild)))
        else
            win.bid:SetLabel('BID')
        end
        win.bid:SetEnabled(canBid and sel.q ~= nil)
        win.liar:SetShown(wild)
        win.liarWide:SetShown(not wild)
        win.liar:SetEnabled(myTurn and not acting and snap.bid ~= nil)
        win.liarWide:SetEnabled(myTurn and not acting and snap.bid ~= nil)
        win.spot:SetShown(wild)
        win.spot:SetEnabled(myTurn and not acting and snap.bid ~= nil)
        local hint
        if myTurn then
            if snap.bid then
                hint = 'Raise: more dice, or as many with a higher face. Or call it.'
            else
                hint = 'Open the bidding: how many dice on the whole table show one face?'
            end
            if wild then hint = hint .. ' Stars are wild.' end
        else
            hint = 'Your dice stay hidden until someone calls.'
            if wild then hint = hint .. ' Stars are wild: they count for every face, except in a bid on stars.' end
        end
        UI.Txt(win.hint, hint)
    elseif showDice then
        UI.Txt(win.hint, 'Your dice from this round.')
    end
end

local function DrawClosed(text)
    for slot = 1, 8 do UI.Show(win.seats[slot].group, false) end
    local c = win.center
    UI.Show(c.qty, false)
    UI.Show(c.die, false)
    UI.Show(c.crown, false)
    for i = 1, table.getn(CENTER_LABELS) do UI.Show(c[CENTER_LABELS[i]], false) end
    UI.Show(c.title, true)
    UI.Txt(c.title, 'Table closed')
    UI.Col(c.title, C.text)
    UI.SetY(c.title, win.area, 170)
    UI.Show(c.line1, true)
    UI.Txt(c.line1, text or '')
    UI.Col(c.line1, C.dim)
    UI.SetY(c.line1, win.area, 210)
    UI.Txt(win.sideHeader, '')
    for row = 1, HISTORY_ROWS do
        UI.Show(win.history[row].name, false)
        UI.Show(win.history[row].right, false)
        UI.Show(win.history[row].die, false)
    end
    for row = 1, SETTING_ROWS do
        UI.Show(win.settings[row].label, false)
        win.settings[row].stepper:SetShown(false)
        UI.Show(win.settings[row].value, false)
    end
    for i = 1, EVENT_LINES do UI.Show(win.events[i], false) end
    ShowControls({ win.diceLabel, win.bidLabel, win.minus, win.qtyBg, win.qty, win.plus, win.times, win.hint,
        win.bid, win.liar, win.liarWide, win.spot, win.start, win.addBot, win.sit, win.newGame, win.leave }, false)
    for f = 1, 6 do win.faces[f]:SetShown(false) end
    for k = 1, 6 do UI.Show(win.myDice[k], false) end
    for i = 1, 5 do UI.Show(win.rules[i], false) end
    win.myBar:SetShown(false)
    UI.Txt(win.status, '')
    UI.Txt(win.statusRight, '')
    win.closeBtn:SetShown(true)
    UI.Txt(win.subtitle, '')
    win.hide:SetShown(false)
    win.frame.close:SetShown(true)
end

-- sounds and bringing a hidden window back, from what changed since the last update
local function Changes(snap, svc)
    local last = win.last
    local seat = snap.you.seat
    local now = { tid = snap.tid, round = snap.round, step = snap.step, phase = snap.phase, seats = table.getn(snap.seats) }
    local mine = seat > 0 and snap.seats[seat] or nil
    now.lives = mine and mine.l or nil
    now.dice = mine and mine.d or nil
    now.myTurn = snap.phase == 'bidding' and snap.turn == seat and mine ~= nil and not mine.o
    win.last = now
    if last == nil or last.tid ~= now.tid then return end
    local show = false
    if now.phase == 'bidding' and last.phase == 'lobby' then
        UI.PlayCue('UI_Announcement_Open')
        StartRoll(Wild(snap.set))
        show = true
    elseif now.phase == 'bidding' and (now.round ~= last.round) then
        UI.PlayCue('UI_MFD_checklist')
        StartRoll(Wild(snap.set))
    elseif now.phase == 'bidding' and now.step ~= last.step then
        UI.PlayCue('UI_Economy_Click')
    end
    if now.phase == 'reveal' and last.phase == 'bidding' then
        UI.PlayCue('UI_Score_Window_Open')
    end
    if now.myTurn and not last.myTurn then
        UI.PlayCue('UI_Announcement_Open')
        show = true
    end
    if mine and last.lives and ((now.lives or 0) < last.lives or (now.dice or 0) < (last.dice or 0)) and now.phase ~= 'lobby' then
        UI.PlayCue('UI_Menu_Error_01')
    end
    if now.phase == 'over' and last.phase ~= 'over' and mine then
        if snap.win == seat then UI.PlayCue('UI_END_Game_Victory') else UI.PlayCue('UI_END_Game_Fail') end
    end
    if now.phase == 'lobby' and last.phase == 'lobby' and now.seats > last.seats then
        UI.PlayCue('UI_Opt_Mini_Button_Click')
    end
    if show and win.hidden then
        win.hidden = false
        UI.Raise(win.frame)
        win.frame:Show()
        win.last = nil
        Render()
    end
end

Render = function()
    if not win or IsDestroyed(win.frame) then return end
    local svc = Svc()
    if not svc then return end
    if win.hidden then
        -- while hidden: come back for my turn, or when the table is gone
        local at = svc.at
        if at and at.snap then
            Changes(at.snap, svc)
            return
        elseif at then
            return
        end
        win.hidden = false
        UI.Raise(win.frame)
        win.frame:Show()
    end
    local at = svc.at
    if not at then
        if not win.closed then
            win.closed = true
            local n = svc.notice
            DrawClosed(n and n.text or 'You left the table.')
        end
        return
    end
    win.closed = false
    win.hide:SetShown(true)
    win.frame.close:SetShown(true)
    win.closeBtn:SetShown(false)

    -- title line: whose table and the settings, or a notice for a few seconds
    local notice = svc:CurrentNotice()
    if notice then
        UI.Txt(win.subtitle, notice.text)
        UI.Col(win.subtitle, C.accent)
    elseif at.snap then
        UI.Txt(win.subtitle, at.host .. "'s table  |  " .. SettingsLine(at.snap.set))
        UI.Col(win.subtitle, C.dim)
    else
        UI.Txt(win.subtitle, 'Joining ' .. at.host .. "'s table...")
        UI.Col(win.subtitle, C.dim)
    end

    local snap = at.snap
    if not snap then
        -- asked to join, no answer yet
        DrawClosed('Waiting for ' .. at.host .. ' to answer...')
        UI.Txt(win.center.title, 'Joining')
        UI.Txt(win.subtitle, 'Joining ' .. at.host .. "'s table...")
        UI.Col(win.subtitle, C.dim)
        win.closeBtn:SetShown(false)
        win.hide:SetShown(true)
        win.closed = false
        return
    end
    Changes(snap, svc)
    if win.hidden then return end

    local slots = SlotsFor(snap)
    local used = {}
    for i = 1, table.getn(snap.seats) do
        local slot = slots[i]
        used[slot] = true
        DrawSeat(win.seats[slot], snap, i, svc)
    end
    for slot = 1, 8 do
        if not used[slot] then
            UI.Show(win.seats[slot].group, false)
            win.seats[slot].seatIndex = nil
        end
    end
    DrawCenter(snap, svc)
    DrawSide(snap, svc)
    DrawTray(snap, svc)
end

----------------------------------------------------------------------------
-- opening
----------------------------------------------------------------------------

local function SafeRender()
    local ok, err = pcall(Render)
    if not ok then WARN("NuggetsLobby: Liar's Dice window failed: " .. tostring(err)) end
end

--- Opens the window of the table I am at on `layer` (or brings it back).
function Open(layer)
    if win and not IsDestroyed(win.frame) then
        win.hidden = false
        UI.Raise(win.frame)
        win.frame:Show()
        win.last = nil
        SafeRender()
        return true
    end
    local svc = Svc()
    if not svc or not svc.at or not layer then return false end
    Build(layer)
    SafeRender()
    return true
end

function IsOpen()
    return win ~= nil and not IsDestroyed(win.frame) and not win.hidden
end

function CloseWindow()
    if win and not IsDestroyed(win.frame) then win.frame:Destroy() end
    win = nil
end
