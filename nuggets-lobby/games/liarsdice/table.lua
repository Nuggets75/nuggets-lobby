-- Nuggets custom lobby: Liar's Dice tables. Imported as /nuggetslobby/liarsdice/table.lua.
--
-- One player hosts a table; the others play or watch through the host. The host's copy
-- runs the game (rules.lua) and sends every member what they may see: the table, and
-- their own dice. Other players' dice never leave the host before they are revealed.
--
-- Messages (lobby message type NuggetsLiarsDice, field t; every message carries v and,
-- except list, the table id tid):
--   host -> every player here with this lobby
--     table   announcement: phase, seated names, settings. Every 5 s, and soon after a change.
--     gone    the table closed
--   host -> a member
--     state   what that member sees (their own dice in `you.hand`), after every change
--     closed  you were taken off the table
--     refused a join or move the host did not accept, with the reason
--     info    a line for that member
--   member -> host
--     join    { as = 'play' | 'watch' }
--     leave
--     act     { round, step, kind = 'bid' | 'liar' | 'spot', q, f }: round and step say
--             which turn the move was made on, so a late click cannot hit a later turn
--     sync    ask for the state again
--   anyone -> every player here with this lobby
--     list    hosts answer with their announcement
--
-- The host notices a member who left the lobby within a few seconds and takes them off the
-- table: during the bidding everyone gets new dice and the round starts again. Members
-- notice a host who left the same way, and close the table on their side.
--
-- No UI here: the window (view.lua) and the Minigames window read a service object and
-- call its functions. The service gets the lobby through `env`, so the tests run several
-- services against a simulated lobby.

local Rules = import('/nuggetslobby/liarsdice/rules.lua')
local Bot   = import('/nuggetslobby/liarsdice/bot.lua')

VERSION        = 1
ANNOUNCE_EVERY = 5      -- seconds between announcements of a table
ANNOUNCE_MIN   = 0.5    -- at most this often after changes
TABLE_TIMEOUT  = 16     -- a table not heard from for this long is gone
GRACE          = 3      -- someone missing from the lobby this long has left
JOIN_TIMEOUT   = 8      -- a join without an answer for this long failed
REVEAL_TIME    = 7      -- seconds the dice stay on show after a call
REVEAL_EXTRA   = 2      -- ... longer when someone was knocked out
BOT_DELAY_MIN  = 1.3    -- a bot thinks this long, at least
BOT_DELAY_MAX  = 2.8
EVENTS_KEPT    = 8      -- lines in the table's event list
ACT_GUARD      = 4      -- seconds a sent move blocks the next one while the host answers
NOTICE_TIME    = 5      -- seconds a notice is shown

-- Bot names have a space, which player names never have, so they cannot clash.
BOT_NAMES = { 'Dicey Dan', 'Lucky Lou', 'Snake Eyes', 'Old Salt', 'Madame Six', 'Rolling Ron', "Cap'n Pip", 'Grumpy Gus' }

local function CopyList(list)
    local copy = {}
    if type(list) ~= 'table' then return copy end
    for i = 1, table.getn(list) do copy[i] = list[i] end
    return copy
end

local function CopyTable(t)
    local copy = {}
    for k, v in t do copy[k] = v end
    return copy
end

----------------------------------------------------------------------------
-- Dice: a seeded generator (Park-Miller), stirred with the time of every move
----------------------------------------------------------------------------

local RNG_M = 2147483647

local Rng = {}
Rng.__index = Rng

function Rng.Next(self)
    local x = self.s * 16807
    self.s = x - math.floor(x / RNG_M) * RNG_M
    return self.s
end

--- Stirs a number (a time in seconds, a hash) into the generator.
function Rng.Mix(self, x)
    x = math.floor(math.abs(tonumber(x) or 0) * 1000)
    x = x - math.floor(x / RNG_M) * RNG_M
    local s = self.s + x
    s = s - math.floor(s / RNG_M) * RNG_M
    if s == 0 then s = 1 end
    self.s = s
    self:Next()
    self:Next()
end

function Rng.Float(self)
    return (self:Next() - 1) / (RNG_M - 1)
end

--- A function like math.random: () -> 0 to below 1, (n) -> 1 to n.
function Rng.Fn(self)
    local rng = self
    return function(n)
        local f = rng:Float()
        if n == nil then return f end
        local v = math.floor(f * n) + 1
        if v > n then v = n end
        return v
    end
end

function NewRng(seed)
    local rng = setmetatable({ s = 1 }, Rng)
    rng:Mix(seed or 0)
    return rng
end

local function Hash(text)
    local h = 0
    text = tostring(text)
    for i = 1, string.len(text) do
        h = h * 31 + string.byte(text, i)
        h = h - math.floor(h / RNG_M) * RNG_M
    end
    return h
end

----------------------------------------------------------------------------
-- Words for the event lines
----------------------------------------------------------------------------

local FACE_WORDS = { 'ones', 'twos', 'threes', 'fours', 'fives', 'sixes' }
local FACE_WORD  = { 'one', 'two', 'three', 'four', 'five', 'six' }

--- "3 fives", "1 six". With wild ones (Traditional) the one is drawn as a star and
--- called one: "2 stars".
function BidText(q, f, wild)
    local one, many = FACE_WORD[f], FACE_WORDS[f]
    if wild and f == 1 then one, many = 'star', 'stars' end
    if q == 1 then return '1 ' .. tostring(one) end
    return tostring(q) .. ' ' .. tostring(many)
end

local function NameList(names)
    local n = table.getn(names)
    if n == 0 then return '' end
    if n == 1 then return names[1] end
    local text = names[1]
    for i = 2, n - 1 do text = text .. ', ' .. names[i] end
    return text .. ' and ' .. names[n]
end

----------------------------------------------------------------------------
-- The host's table
----------------------------------------------------------------------------
-- H = {
--   tid, settings, phase = 'lobby' | 'playing', seats = { { name, bot } } (lobby phase),
--   game = rules state (playing), watchers = { names }, seq (state number),
--   dirty (members need the state), annDirty, annAt, deadline (turn timer), botAt,
--   nextAt (next round), turnKey, auto = { [seat] = true: their last move was made for them },
--   events = { lines }, missing = { [name] = since }
-- }

local function Event(H, text)
    table.insert(H.events, text)
    while table.getn(H.events) > EVENTS_KEPT do
        table.remove(H.events, 1)
    end
end

local function Changed(H)
    H.dirty = true
    H.annDirty = true
end

-- The list of seated players of the current phase.
local function SeatList(H)
    if H.phase == 'lobby' then return H.seats end
    return H.game.players
end

local function SeatOf(H, name)
    local list = SeatList(H)
    for i = 1, table.getn(list) do
        local p = list[i]
        if p.name == name and not p.bot and not p.left then return i end
    end
    return nil
end

local function WatcherIndex(H, name)
    for i = 1, table.getn(H.watchers) do
        if H.watchers[i] == name then return i end
    end
    return nil
end

-- Human names that get the table's state (the host too).
local function Members(H)
    local list, seen = {}, {}
    local seats = SeatList(H)
    for i = 1, table.getn(seats) do
        local p = seats[i]
        if not p.bot and not p.left and not seen[p.name] then
            seen[p.name] = true
            table.insert(list, p.name)
        end
    end
    for i = 1, table.getn(H.watchers) do
        local name = H.watchers[i]
        if not seen[name] then
            seen[name] = true
            table.insert(list, name)
        end
    end
    return list
end

local function SeatedNames(H)
    local names = {}
    local seats = SeatList(H)
    for i = 1, table.getn(seats) do
        if not seats[i].left then table.insert(names, seats[i].name) end
    end
    return names
end

local function Phase(H)
    if H.phase == 'lobby' then return 'lobby' end
    return H.game.phase
end

local function Announcement(H)
    local names = SeatedNames(H)
    local round = 0
    if H.game then round = H.game.round end
    return {
        t = 'table', v = VERSION, tid = H.tid, phase = Phase(H), n = table.getn(names),
        max = Rules.MAX_PLAYERS, set = CopyTable(H.settings), names = names,
        w = table.getn(H.watchers), watch = CopyList(H.watchers), round = round, seq = H.seq,
    }
end

local function ResultFor(r)
    local hands = {}
    for seat, hand in r.hands do
        table.insert(hands, { s = seat, d = CopyList(hand) })
    end
    table.sort(hands, function(a, b) return a.s < b.s end)
    return {
        kind = r.kind, caller = r.caller, bidder = r.bidder, q = r.q, f = r.f,
        count = r.count, natural = r.natural, wilds = r.wilds, held = r.held, exact = r.exact,
        losers = CopyList(r.losers), out = CopyList(r.eliminated), hands = hands, round = r.round,
    }
end

----------------------------------------------------------------------------
-- The service
----------------------------------------------------------------------------

local Service = {}
Service.__index = Service

--- env = {
---   me()            -> my lobby name
---   peers()         -> names of the players here who run this lobby with Liar's Dice
---   send(payload, names) -> to those players (names = list, nil = all of them)
---   now()           -> seconds (wall clock)
---   seed            -> a number to start the dice with
---   chat(text)      -> optional, a lobby chat line
---   loadSettings()  -> optional, the table settings used last time
---   saveSettings(t) -> optional
--- }
function NewService(env)
    local svc = setmetatable({
        env = env,
        rng = NewRng(env.seed),
        tables = {},        -- host name -> announcement + heard (time)
        seen = {},          -- host .. '#' .. tid -> true: tables already told about in chat
        at = nil,           -- the table I am at, see below
        host = nil,         -- the table I host (H)
        listeners = {},
        nextListener = 0,
        notice = nil,       -- { text, at, id }
        noticeId = 0,
        lastPresence = -100,
        tidBase = 0,
    }, Service)
    svc.rng:Mix(Hash(env.me()))
    svc.rand = svc.rng:Fn()
    svc.tidBase = svc.rand(900000) * 1000
    -- at = { host, tid, role = 'pending' | 'play' | 'watch', want, since, heard, snap (state),
    --        recv (time the state came), acting (time a move was sent), missing }
    return svc
end

function Service.Now(self) return self.env.now() end
function Service.Me(self) return self.env.me() end

function Service.Send(self, payload, names)
    local ok, err = pcall(self.env.send, payload, names)
    if not ok then
        WARN('NuggetsLobby: Liar\'s Dice message failed: ' .. tostring(err))
    end
end

function Service.PeerSet(self)
    local set = {}
    local ok, list = pcall(self.env.peers)
    if ok and type(list) == 'table' then
        for i = 1, table.getn(list) do set[list[i]] = true end
    end
    return set
end

--- fn(svc, what) is called after changes; what = 'tables' | 'table' | 'notice'.
--- Returns a key for Unlisten.
function Service.Listen(self, fn)
    self.nextListener = self.nextListener + 1
    self.listeners[self.nextListener] = fn
    return self.nextListener
end

function Service.Unlisten(self, key)
    self.listeners[key] = nil
end

function Service.Notify(self, what)
    local list = {}
    for key, fn in self.listeners do table.insert(list, fn) end
    for i = 1, table.getn(list) do
        local ok, err = pcall(list[i], self, what)
        if not ok then WARN('NuggetsLobby: Liar\'s Dice window update failed: ' .. tostring(err)) end
    end
end

function Service.Notice(self, text)
    self.noticeId = self.noticeId + 1
    self.notice = { text = text, at = self:Now(), id = self.noticeId }
    self:Notify('notice')
end

--- The current notice, nil when there is none or it is old.
function Service.CurrentNotice(self)
    local n = self.notice
    if n and self:Now() - n.at <= NOTICE_TIME then return n end
    return nil
end

function Service.Chat(self, text)
    if self.env.chat then pcall(self.env.chat, text) end
end

--- Known tables, sorted: mine first, then by host name.
function Service.Tables(self)
    local list = {}
    local me = self:Me()
    for host, t in self.tables do
        local entry = CopyTable(t)
        entry.host = host
        entry.mine = (host == me)
        table.insert(list, entry)
    end
    table.sort(list, function(a, b)
        if a.mine ~= b.mine then return a.mine end
        return string.lower(a.host) < string.lower(b.host)
    end)
    return list
end

function Service.IsHosting(self) return self.host ~= nil end

----------------------------------------------------------------------------
-- Host side
----------------------------------------------------------------------------

function Service.Snapshot(self, H, name)
    local now = self:Now()
    local snap = {
        t = 'state', v = VERSION, tid = H.tid, seq = H.seq, host = self:Me(),
        set = CopyTable(H.settings), ev = CopyList(H.events), watch = CopyList(H.watchers),
        seats = {}, round = 0, turn = 0, step = 0, total = 0, win = 0,
    }
    if H.phase == 'lobby' then
        snap.phase = 'lobby'
        for i = 1, table.getn(H.seats) do
            local s = H.seats[i]
            table.insert(snap.seats, { n = s.name, b = s.bot, l = H.settings.lives, d = H.settings.dice, o = false, x = false, a = false })
        end
    else
        local g = H.game
        snap.phase = g.phase
        for i = 1, table.getn(g.players) do
            local p = g.players[i]
            local dice = Rules.DiceOf(g, p)
            if p.out then dice = 0 end
            table.insert(snap.seats, { n = p.name, b = p.bot, l = p.lives, d = dice, o = p.out, x = p.left, a = H.auto[i] and true or false })
        end
        snap.round = g.round
        snap.turn = g.turn or 0
        snap.starter = g.starter
        if g.bid then snap.bid = { q = g.bid.q, f = g.bid.f, by = g.bid.by } end
        snap.hist = {}
        for i = 1, table.getn(g.history) do
            local h = g.history[i]
            table.insert(snap.hist, { by = h.by, q = h.q, f = h.f, call = h.call, a = h.a and true or false })
        end
        snap.step = table.getn(g.history)
        snap.total = Rules.TotalDice(g)
        if g.result then snap.res = ResultFor(g.result) end
        snap.win = g.winner or 0
        if g.phase == 'bidding' and H.deadline then
            snap.left = math.max(0, H.deadline - now)
            snap.limit = H.settings.timer
        end
        if g.phase == 'reveal' and H.nextAt then
            snap.next = math.max(0, H.nextAt - now)
        end
    end
    local seat = SeatOf(H, name)
    local role = nil
    if seat then role = 'play' elseif WatcherIndex(H, name) then role = 'watch' end
    snap.you = { role = role, seat = seat or 0 }
    if seat and H.phase ~= 'lobby' then
        local hand = H.game.hands[seat]
        if hand and not H.game.players[seat].out then snap.you.hand = CopyList(hand) end
    end
    return snap
end

-- Sends the table's state to its members, when it changed.
function Service.Flush(self)
    local H = self.host
    if H == nil or not H.dirty then return end
    H.dirty = false
    H.seq = H.seq + 1
    local me = self:Me()
    local members = Members(H)
    for i = 1, table.getn(members) do
        local name = members[i]
        local snap = self:Snapshot(H, name)
        if name == me then
            self:ApplyState(me, snap)
        else
            self:Send(snap, { name })
        end
    end
end

-- Timers for the turn that is up now, or the next round.
function Service.Schedule(self, H)
    local now = self:Now()
    if H.phase ~= 'playing' then
        H.deadline, H.botAt, H.nextAt, H.turnKey = nil, nil, nil, nil
        return
    end
    local g = H.game
    if g.phase == 'bidding' then
        H.nextAt = nil
        local key = tostring(g.round) .. ':' .. tostring(table.getn(g.history))
        if H.turnKey ~= key then
            H.turnKey = key
            local p = g.players[g.turn]
            if p.bot then
                H.botAt = now + BOT_DELAY_MIN + self.rand() * (BOT_DELAY_MAX - BOT_DELAY_MIN)
                H.deadline = nil
            else
                H.deadline = now + H.settings.timer
                H.botAt = nil
            end
        end
    elseif g.phase == 'reveal' then
        H.deadline, H.botAt, H.turnKey = nil, nil, nil
        if H.nextAt == nil then
            local wait = REVEAL_TIME
            if g.result and table.getn(g.result.eliminated) > 0 then wait = wait + REVEAL_EXTRA end
            H.nextAt = now + wait
        end
    else
        H.deadline, H.botAt, H.nextAt, H.turnKey = nil, nil, nil, nil
    end
end

local function SeatName(g, i)
    local p = g.players[i]
    if p then return p.name end
    return '?'
end

-- Event lines and timers after a move was made.
function Service.AfterAct(self, H, seat, action)
    local g = H.game
    if action.kind ~= 'bid' then
        local r = g.result
        local caller, bidder = SeatName(g, r.caller), SeatName(g, r.bidder)
        local wild = Rules.Wild(g.settings)
        local line
        if r.kind == 'liar' then
            line = caller .. ' called Liar on ' .. bidder .. "'s " .. BidText(r.q, r.f, wild) .. '.'
        else
            line = caller .. ' called Spot on for ' .. BidText(r.q, r.f, wild) .. '.'
        end
        local found = 'There were ' .. tostring(r.count)
        if r.wilds > 0 then
            found = found .. ' (' .. tostring(r.natural) .. ' + ' .. tostring(r.wilds) .. ' wild)'
        end
        line = line .. ' ' .. found .. '.'
        local losers = {}
        for i = 1, table.getn(r.losers) do table.insert(losers, SeatName(g, r.losers[i])) end
        local what = 'a life'
        if g.settings.lose == 'dice' then what = 'a die' end
        if table.getn(losers) == 1 then
            line = line .. ' ' .. losers[1] .. ' loses ' .. what .. '.'
        else
            line = line .. ' Everyone else loses ' .. what .. '.'
        end
        Event(H, line)
        if table.getn(r.eliminated) > 0 then
            local out = {}
            for i = 1, table.getn(r.eliminated) do table.insert(out, SeatName(g, r.eliminated[i])) end
            if table.getn(out) == 1 then
                Event(H, out[1] .. ' is out.')
            else
                Event(H, NameList(out) .. ' are out.')
            end
        end
        if g.phase == 'over' and g.winner then
            Event(H, SeatName(g, g.winner) .. ' wins the game!')
        end
    end
    self:Schedule(H)
    Changed(H)
end

-- A move for player `seat` (a bot, or someone whose time ran out).
function Service.AutoMove(self, H, seat, timedOut)
    local g = H.game
    local hand = g.hands[seat] or {}
    local view = { settings = g.settings, dice = hand, total = Rules.TotalDice(g), bid = g.bid }
    local ok, move = pcall(Bot.Decide, view, self.rand)
    if not ok or type(move) ~= 'table' then
        WARN('NuggetsLobby: Liar\'s Dice bot failed: ' .. tostring(move))
        move = nil
    end
    local done = false
    if move then done = Rules.Act(g, seat, move) end
    if not done then
        -- never expected: the smallest raise there is, or a call
        move = nil
        for f = 1, Rules.FACES do
            local q = Rules.MinQuantity(g, f)
            if q and move == nil then move = { kind = 'bid', q = q, f = f } end
        end
        if move == nil or g.bid ~= nil and self.rand() < 0.5 then move = { kind = 'liar' } end
        done = Rules.Act(g, seat, move)
    end
    if not done then
        WARN('NuggetsLobby: Liar\'s Dice found no move for seat ' .. tostring(seat))
        return
    end
    local last = g.history[table.getn(g.history)]
    if timedOut then
        if last then last.a = true end
        H.auto[seat] = true
        Event(H, SeatName(g, seat) .. ' ran out of time.')
    end
    self:AfterAct(H, seat, move)
end

function Service.NextRound(self, H)
    self.rng:Mix(self:Now())
    Rules.StartRound(H.game, self.rand)
    H.nextAt = nil
    self:Schedule(H)
    Changed(H)
end

-- Takes `name` off my table. `why` (optional) is sent to them.
function Service.HostRemove(self, H, name, why)
    local changed = false
    local w = WatcherIndex(H, name)
    if w then
        table.remove(H.watchers, w)
        changed = true
    end
    if H.phase == 'lobby' then
        for i = table.getn(H.seats), 1, -1 do
            if H.seats[i].name == name and not H.seats[i].bot then
                table.remove(H.seats, i)
                changed = true
            end
        end
        if changed then Event(H, name .. ' left the table.') end
    else
        local g = H.game
        local seat = SeatOf(H, name)
        if seat then
            changed = true
            local wasIn = not g.players[seat].out
            local what = Rules.Leave(g, seat)
            H.auto[seat] = nil
            if what == 'reroll' then
                Event(H, name .. ' left. Everyone rolls again.')
                self.rng:Mix(self:Now())
                Rules.StartRound(g, self.rand)
                H.turnKey = nil
            elseif what == 'over' then
                Event(H, name .. ' left.')
                if g.winner then Event(H, SeatName(g, g.winner) .. ' wins the game!') end
            elseif wasIn then
                Event(H, name .. ' left.')
            end
            self:Schedule(H)
        elseif w then
            -- a watcher: no event line
        end
    end
    H.missing[name] = nil
    if why and name ~= self:Me() then
        self:Send({ t = 'closed', v = VERSION, tid = H.tid, why = why }, { name })
    end
    if changed then Changed(H) end
end

function Service.HostJoin(self, H, name, want)
    local full = table.getn(H.seats) >= Rules.MAX_PLAYERS
    if SeatOf(H, name) then
        H.dirty = true   -- already seated: the state is the answer
        return
    end
    local w = WatcherIndex(H, name)
    if w then
        if want == 'play' and H.phase == 'lobby' and not full then
            table.remove(H.watchers, w)
            table.insert(H.seats, { name = name, bot = false })
            Event(H, name .. ' took a seat.')
            Changed(H)
        else
            H.dirty = true
        end
        return
    end
    if want == 'play' and H.phase == 'lobby' and not full then
        table.insert(H.seats, { name = name, bot = false })
        Event(H, name .. ' took a seat.')
    else
        table.insert(H.watchers, name)
        if want == 'play' then
            local why = 'The game has already started'
            if H.phase == 'lobby' then why = 'The table is full' end
            self:Send({ t = 'info', v = VERSION, tid = H.tid, text = why .. ': you are watching. You can take a seat when the host starts a new game.' }, { name })
        end
    end
    Changed(H)
end

function Service.HostAct(self, H, name, p)
    if H.phase ~= 'playing' then return end
    local g = H.game
    local seat = SeatOf(H, name)
    if seat == nil then return end
    if p.round ~= g.round or p.step ~= table.getn(g.history) then
        H.dirty = true   -- made on an older turn: send the current state
        return
    end
    local action
    if p.kind == 'bid' then
        action = { kind = 'bid', q = p.q, f = p.f }
    elseif p.kind == 'liar' or p.kind == 'spot' then
        action = { kind = p.kind }
    else
        return
    end
    self.rng:Mix(self:Now())
    local ok, why = Rules.Act(g, seat, action)
    if not ok then
        H.dirty = true
        if name ~= self:Me() then
            self:Send({ t = 'refused', v = VERSION, tid = H.tid, why = why }, { name })
        else
            self:Notice(why)
        end
        return
    end
    H.auto[seat] = nil
    self:AfterAct(H, seat, action)
end

function Service.HostTick(self, H, now)
    if H.phase == 'playing' then
        local g = H.game
        if g.phase == 'bidding' then
            local p = g.players[g.turn]
            if p and p.bot then
                if H.botAt and now >= H.botAt then self:AutoMove(H, g.turn, false) end
            elseif H.deadline and now >= H.deadline then
                self:AutoMove(H, g.turn, true)
            end
        elseif g.phase == 'reveal' then
            if H.nextAt and now >= H.nextAt then self:NextRound(H) end
        end
    end
    if (H.annDirty and now - H.annAt >= ANNOUNCE_MIN) or now - H.annAt >= ANNOUNCE_EVERY then
        self:Announce(H)
    end
end

function Service.Announce(self, H)
    H.annDirty = false
    H.annAt = self:Now()
    local ann = Announcement(H)
    self:Send(ann, nil)
    self:OnTable(self:Me(), ann)
end

----------------------------------------------------------------------------
-- Host controls (only for the host's own table)
----------------------------------------------------------------------------

--- Opens my table. Returns true, or false and why not.
function Service.OpenTable(self)
    if self.host then return false, 'You already host a table.' end
    if self.at then return false, 'Leave your table first.' end
    local me = self:Me()
    local saved = nil
    if self.env.loadSettings then
        local ok, value = pcall(self.env.loadSettings)
        if ok then saved = value end
    end
    self.tidBase = self.tidBase + 1
    local H = {
        tid = self.tidBase, settings = Rules.NormalizeSettings(saved), phase = 'lobby',
        seats = { { name = me, bot = false } }, watchers = {}, game = nil, seq = 0,
        dirty = true, annDirty = true, annAt = -100, auto = {}, events = {}, missing = {},
    }
    Event(H, me .. ' opened the table.')
    self.host = H
    self.at = { host = me, tid = H.tid, role = 'play', want = 'play', since = self:Now(), heard = self:Now() }
    self:Announce(H)
    self:Flush()
    self:Notify('tables')
    return true
end

local function HostLobby(self)
    local H = self.host
    if H and H.phase == 'lobby' then return H end
    return nil
end

function Service.SetSetting(self, key, value)
    local H = HostLobby(self)
    if not H or Rules.CHOICES[key] == nil then return false end
    local s = CopyTable(H.settings)
    s[key] = value
    s = Rules.NormalizeSettings(s)
    if s[key] ~= value then return false end
    H.settings = s
    if self.env.saveSettings then pcall(self.env.saveSettings, CopyTable(s)) end
    Changed(H)
    self:Flush()
    return true
end

--- The next allowed value of a setting (dir = 1 or -1), wrapping round.
function Service.StepSetting(self, key, dir)
    local H = HostLobby(self)
    if not H then return false end
    local list = Rules.CHOICES[key]
    if list == nil then return false end
    local index = 1
    for i = 1, table.getn(list) do
        if list[i] == H.settings[key] then index = i end
    end
    index = index + dir
    if index < 1 then index = table.getn(list) end
    if index > table.getn(list) then index = 1 end
    return self:SetSetting(key, list[index])
end

function Service.AddBot(self)
    local H = HostLobby(self)
    if not H or table.getn(H.seats) >= Rules.MAX_PLAYERS then return false end
    local used = {}
    for i = 1, table.getn(H.seats) do used[H.seats[i].name] = true end
    local free = {}
    for i = 1, table.getn(BOT_NAMES) do
        if not used[BOT_NAMES[i]] then table.insert(free, BOT_NAMES[i]) end
    end
    if table.getn(free) == 0 then return false end
    local name = free[self.rand(table.getn(free))]
    table.insert(H.seats, { name = name, bot = true })
    Event(H, name .. ' (bot) took a seat.')
    Changed(H)
    self:Flush()
    return true
end

--- Takes seat i off the table (a bot, or a player, who gets told).
function Service.RemoveSeat(self, i)
    local H = HostLobby(self)
    if not H then return false end
    local s = H.seats[i]
    if s == nil or s.name == self:Me() then return false end
    if s.bot then
        table.remove(H.seats, i)
        Event(H, s.name .. ' (bot) left the table.')
        Changed(H)
    else
        self:HostRemove(H, s.name, 'The host took you off the table.')
    end
    self:Flush()
    return true
end

function Service.CanStart(self)
    local H = HostLobby(self)
    return H ~= nil and table.getn(H.seats) >= Rules.MIN_PLAYERS
end

function Service.Start(self)
    if not self:CanStart() then return false end
    local H = self.host
    self.rng:Mix(self:Now())
    local seats = {}
    for i = 1, table.getn(H.seats) do
        table.insert(seats, { name = H.seats[i].name, bot = H.seats[i].bot })
    end
    H.game = Rules.NewGame(H.settings, seats, self.rand)
    H.phase = 'playing'
    H.auto = {}
    H.turnKey = nil
    Rules.StartRound(H.game, self.rand)
    Event(H, 'The game starts. ' .. SeatName(H.game, H.game.turn) .. ' bids first.')
    self:Schedule(H)
    Changed(H)
    self:Flush()
    return true
end

--- After a game: back to the waiting table with the same players.
function Service.NewGame(self)
    local H = self.host
    if not H or H.phase ~= 'playing' or H.game.phase ~= 'over' then return false end
    local seats = {}
    for i = 1, table.getn(H.game.players) do
        local p = H.game.players[i]
        if not p.left then table.insert(seats, { name = p.name, bot = p.bot }) end
    end
    H.seats = seats
    H.game = nil
    H.phase = 'lobby'
    H.auto = {}
    self:Schedule(H)
    Event(H, 'New game: take your seats.')
    Changed(H)
    self:Flush()
    return true
end

function Service.CloseTable(self)
    local H = self.host
    if not H then return false end
    self:Send({ t = 'gone', v = VERSION, tid = H.tid }, nil)
    self.host = nil
    self.at = nil
    self.tables[self:Me()] = nil
    self:Notify('tables')
    self:Notify('table')
    return true
end

----------------------------------------------------------------------------
-- Member side
----------------------------------------------------------------------------

function Service.Join(self, host, watch)
    if self.at then return false, 'Leave your table first.' end
    local t = self.tables[host]
    if t == nil or host == self:Me() then return false, 'That table is gone.' end
    local want = 'play'
    if watch then want = 'watch' end
    self.at = { host = host, tid = t.tid, role = 'pending', want = want, since = self:Now(), heard = self:Now() }
    self:Send({ t = 'join', v = VERSION, tid = t.tid, as = want }, { host })
    self:Notify('table')
    return true
end

--- Watcher to player, while the table waits for a game.
function Service.Sit(self)
    local at = self.at
    if not at or at.role ~= 'watch' then return false end
    if at.host == self:Me() then
        if self.host then self:HostJoin(self.host, self:Me(), 'play') end
        self:Flush()
        return true
    end
    self:Send({ t = 'join', v = VERSION, tid = at.tid, as = 'play' }, { at.host })
    return true
end

--- Leaves my table (closes it when it is mine).
function Service.Leave(self)
    local at = self.at
    if not at then return false end
    if at.host == self:Me() then return self:CloseTable() end
    self:Send({ t = 'leave', v = VERSION, tid = at.tid }, { at.host })
    self.at = nil
    self:Notify('table')
    return true
end

--- My move: kind = 'bid' (with q, f), 'liar' or 'spot'. Returns true when sent.
function Service.Act(self, kind, q, f)
    local at = self.at
    if not at or at.role ~= 'play' or not at.snap then return false end
    local snap = at.snap
    if snap.phase ~= 'bidding' or snap.turn ~= snap.you.seat then return false end
    local now = self:Now()
    if at.acting and now - at.acting < ACT_GUARD then return false end
    local msg = { t = 'act', v = VERSION, tid = at.tid, round = snap.round, step = snap.step, kind = kind, q = q, f = f }
    at.acting = now
    if at.host == self:Me() then
        if self.host then self:HostAct(self.host, self:Me(), msg) end
        at.acting = nil
        self:Flush()
    else
        self:Send(msg, { at.host })
        self:Notify('table')
    end
    return true
end

--- True while a move of mine is on its way to the host.
function Service.Acting(self)
    local at = self.at
    return at ~= nil and at.acting ~= nil and self:Now() - at.acting < ACT_GUARD
end

-- Shape checks for a state from the network; a malformed one is dropped.
local function ValidState(p)
    if type(p.tid) ~= 'number' or type(p.seq) ~= 'number' or type(p.phase) ~= 'string' then return false end
    if type(p.seats) ~= 'table' or type(p.you) ~= 'table' or type(p.set) ~= 'table' then return false end
    if type(p.you.seat) ~= 'number' then return false end
    if type(p.round) ~= 'number' or type(p.turn) ~= 'number' or type(p.step) ~= 'number' then return false end
    for i = 1, table.getn(p.seats) do
        local s = p.seats[i]
        if type(s) ~= 'table' or type(s.n) ~= 'string' then return false end
    end
    if p.bid ~= nil and (type(p.bid) ~= 'table' or type(p.bid.q) ~= 'number' or type(p.bid.f) ~= 'number') then return false end
    if p.you.hand ~= nil and type(p.you.hand) ~= 'table' then return false end
    if p.res ~= nil and (type(p.res) ~= 'table' or type(p.res.hands) ~= 'table') then return false end
    if p.hist ~= nil and type(p.hist) ~= 'table' then return false end
    if p.ev ~= nil and type(p.ev) ~= 'table' then return false end
    if p.watch ~= nil and type(p.watch) ~= 'table' then return false end
    return true
end

function Service.ApplyState(self, sender, p)
    local at = self.at
    if not ValidState(p) then return end
    if not at or at.host ~= sender then
        -- not at that table (any more): make sure the host knows
        if sender ~= self:Me() then
            self:Send({ t = 'leave', v = VERSION, tid = p.tid }, { sender })
        end
        return
    end
    if at.role ~= 'pending' and p.tid ~= at.tid then return end
    if at.snap and p.tid == at.snap.tid and p.seq <= at.snap.seq then return end
    local role = p.you.role
    if role ~= 'play' and role ~= 'watch' then
        if at.role ~= 'pending' then
            self.at = nil
            self:Notice('You are no longer at ' .. sender .. "'s table.")
            self:Notify('table')
        end
        return
    end
    local old = at.snap
    if old == nil or old.round ~= p.round or old.step ~= p.step or old.phase ~= p.phase then
        at.acting = nil
    end
    at.tid = p.tid
    at.role = role
    at.snap = p
    at.recv = self:Now()
    at.heard = at.recv
    self:Notify('table')
end

function Service.OnTable(self, sender, p)
    if type(p.tid) ~= 'number' or type(p.phase) ~= 'string' or type(p.n) ~= 'number' or type(p.names) ~= 'table' or type(p.set) ~= 'table' then
        return
    end
    local now = self:Now()
    local entry = {
        tid = p.tid, phase = p.phase, n = p.n, max = tonumber(p.max) or Rules.MAX_PLAYERS,
        set = Rules.NormalizeSettings(p.set), names = CopyList(p.names), w = tonumber(p.w) or 0,
        round = tonumber(p.round) or 0, heard = now,
    }
    self.tables[sender] = entry
    local at = self.at
    local me = self:Me()
    local listed = false
    for i = 1, table.getn(p.names) do
        if p.names[i] == me then listed = true end
    end
    if type(p.watch) == 'table' then
        for i = 1, table.getn(p.watch) do
            if p.watch[i] == me then listed = true end
        end
    end
    if at and at.host == sender and sender ~= me then
        at.heard = now
        if at.role ~= 'pending' and at.tid ~= p.tid then
            -- the host closed my table and opened a new one
            self.at = nil
            self:Notice(sender .. ' closed the table.')
            self:Notify('table')
        elseif at.role ~= 'pending' and at.snap and type(p.seq) == 'number' then
            if p.seq >= at.snap.seq and not listed then
                -- the host no longer has me (a message got lost on the way)
                self.at = nil
                self:Notice('You are no longer at ' .. sender .. "'s table.")
                self:Notify('table')
            elseif p.seq > at.snap.seq and self:Now() - (at.synced or -100) >= 2 then
                -- a state did not reach me: ask again
                at.synced = self:Now()
                self:Send({ t = 'sync', v = VERSION, tid = at.tid }, { sender })
            end
        end
    end
    -- listed at a table I am not at (I left, or came back to the lobby): tell the host
    if listed and sender ~= me and not (self.at and self.at.host == sender) then
        self:Send({ t = 'leave', v = VERSION, tid = p.tid }, { sender })
    end
    local key = sender .. '#' .. tostring(p.tid)
    if not self.seen[key] and sender ~= me then
        self.seen[key] = true
        if p.phase == 'lobby' then
            self:Chat("Liar's Dice: " .. sender .. ' opened a table. Join it in Minigames.')
        end
    end
    self:Notify('tables')
end

function Service.DropTable(self, host, why)
    local at = self.at
    self.tables[host] = nil
    if at and at.host == host and host ~= self:Me() then
        self.at = nil
        if why then self:Notice(why) end
        self:Notify('table')
    end
    self:Notify('tables')
end

----------------------------------------------------------------------------
-- Messages and time
----------------------------------------------------------------------------

--- A message from another player here.
function Service.Receive(self, sender, p)
    if type(sender) ~= 'string' or type(p) ~= 'table' or type(p.t) ~= 'string' then return end
    if p.v ~= VERSION then return end
    local me = self:Me()
    if sender == me then return end
    local kind = p.t
    local H = self.host
    local at = self.at

    if kind == 'list' then
        if H then self:Send(Announcement(H), { sender }) end
    elseif kind == 'table' then
        self:OnTable(sender, p)
    elseif kind == 'gone' then
        local t = self.tables[sender]
        if (t and t.tid == p.tid) or (at and at.host == sender and at.tid == p.tid) then
            self:DropTable(sender, sender .. ' closed the table.')
        end
    elseif kind == 'state' then
        self:ApplyState(sender, p)
    elseif kind == 'closed' then
        if at and at.host == sender and (at.tid == p.tid or at.role == 'pending') then
            self.at = nil
            local why = sender .. "'s table: you were taken off the table."
            if type(p.why) == 'string' then why = sender .. "'s table: " .. p.why end
            self:Notice(why)
            self:Notify('table')
        end
    elseif kind == 'refused' then
        if at and at.host == sender then
            local why = 'The host refused.'
            if type(p.why) == 'string' then why = p.why end
            if at.role == 'pending' then
                self.at = nil
                self:Notice(sender .. "'s table: " .. why)
                self:Notify('table')
            else
                at.acting = nil
                self:Notice(why)
            end
        end
    elseif kind == 'info' then
        if at and at.host == sender and type(p.text) == 'string' then
            self:Notice(p.text)
        end
    elseif H and p.tid ~= H.tid then
        -- a message for a table of mine that is closed
        if kind == 'join' then
            self:Send({ t = 'refused', v = VERSION, tid = p.tid, why = 'That table is closed.' }, { sender })
        end
    elseif H then
        if kind == 'join' then
            local want = 'play'
            if p.as == 'watch' then want = 'watch' end
            self:HostJoin(H, sender, want)
        elseif kind == 'leave' then
            self:HostRemove(H, sender, nil)
        elseif kind == 'act' then
            self:HostAct(H, sender, p)
        elseif kind == 'sync' then
            if SeatOf(H, sender) or WatcherIndex(H, sender) then H.dirty = true end
        end
    elseif kind == 'join' then
        self:Send({ t = 'refused', v = VERSION, tid = p.tid, why = 'That table is closed.' }, { sender })
    end
    self:Flush()
end

--- Asks every host here for their table (when the Minigames window opens).
function Service.RequestTables(self)
    self:Send({ t = 'list', v = VERSION }, nil)
end

-- Players who left the lobby, tables that went quiet.
function Service.CheckPresence(self, now)
    local peers = self:PeerSet()
    local me = self:Me()

    local stale = {}
    for host, t in self.tables do
        if host ~= me then
            if peers[host] then
                t.missing = nil
            else
                t.missing = t.missing or now
            end
            if (t.missing and now - t.missing >= GRACE) or now - t.heard > TABLE_TIMEOUT then
                table.insert(stale, host)
            end
        end
    end
    for i = 1, table.getn(stale) do
        local host = stale[i]
        local why = 'Lost contact with ' .. host .. "'s table."
        if not peers[host] then why = host .. ' left the lobby, so the table closed.' end
        self:DropTable(host, why)
    end

    local at = self.at
    if at and at.host ~= me then
        if not peers[at.host] then
            at.missing = at.missing or now
            if now - at.missing >= GRACE then
                self:DropTable(at.host, at.host .. ' left the lobby, so the table closed.')
                return
            end
        else
            at.missing = nil
        end
        if at.role == 'pending' then
            if now - at.since > JOIN_TIMEOUT then
                self.at = nil
                self:Notice(at.host .. "'s table did not answer.")
                self:Notify('table')
            end
        elseif now - at.heard > TABLE_TIMEOUT then
            self:DropTable(at.host, 'Lost contact with ' .. at.host .. "'s table.")
        end
    end

    local H = self.host
    if H then
        local members = Members(H)
        for i = 1, table.getn(members) do
            local name = members[i]
            if name ~= me then
                if peers[name] then
                    H.missing[name] = nil
                else
                    H.missing[name] = H.missing[name] or now
                    if now - H.missing[name] >= GRACE then
                        self:HostRemove(H, name, nil)
                    end
                end
            end
        end
    end
end

--- Called about ten times a second.
function Service.Tick(self)
    local now = self:Now()
    if now - self.lastPresence >= 1 then
        self.lastPresence = now
        self:CheckPresence(now)
    end
    if self.host then self:HostTick(self.host, now) end
    self:Flush()
end

----------------------------------------------------------------------------
-- For the window
----------------------------------------------------------------------------

--- Seconds left on the turn timer of my table, or nil.
function Service.TurnLeft(self)
    local at = self.at
    if not at or not at.snap or at.snap.left == nil then return nil end
    return math.max(0, at.snap.left - (self:Now() - at.recv))
end

--- Seconds until the next round, or nil.
function Service.NextLeft(self)
    local at = self.at
    if not at or not at.snap or at.snap.next == nil then return nil end
    return math.max(0, at.snap.next - (self:Now() - at.recv))
end

----------------------------------------------------------------------------
-- The service of the current lobby
----------------------------------------------------------------------------

local function LobbyFn(name)
    local modules = rawget(_G, '__modules')
    local lobby = modules and modules['/lua/ui/lobby/lobby.lua']
    if lobby then return rawget(lobby, name) end
    return nil
end

local function LobbyCall(name, a, b)
    local fn = LobbyFn(name)
    if fn == nil then return nil end
    local ok, result = pcall(fn, a, b)
    if ok then return result end
    WARN('NuggetsLobby: ' .. name .. ' failed: ' .. tostring(result))
    return nil
end

local PREF_SETTINGS = 'NuggetsLobby_LiarsDice_v1'

local function LobbyEnv()
    local Prefs = import('/lua/user/prefs.lua')
    local seed = CurrentTime() * 1000 + math.random(1, 1000000)
    return {
        me = function()
            local name = LobbyCall('NuggetsLobby_MyName')
            if type(name) == 'string' and name ~= '' then return name end
            return 'You'
        end,
        peers = function()
            local list = LobbyCall('NuggetsLobby_LiarsDicePeers') or {}
            local names = {}
            for i = 1, table.getn(list) do table.insert(names, list[i].name) end
            return names
        end,
        send = function(payload, names) LobbyCall('NuggetsLobby_SendLiarsDice', payload, names) end,
        now = function() return CurrentTime() end,
        seed = seed,
        chat = function(text) LobbyCall('NuggetsLobby_Chat', text) end,
        loadSettings = function() return Prefs.GetFromCurrentProfile(PREF_SETTINGS) end,
        saveSettings = function(s)
            Prefs.SetToCurrentProfile(PREF_SETTINGS, s)
            SavePreferences()
        end,
    }
end

local current = { gui = nil, svc = nil }

--- The service of the lobby that is open now (nil when there is none). The first call
--- starts it; it stops when the lobby closes.
function Get()
    -- the lobby sets GUI to false once it is gone
    local gui = LobbyCall('NuggetsLobby_GUI')
    if not gui or IsDestroyed(gui) then return nil end
    if current.gui == gui and current.svc then return current.svc end
    local svc = NewService(LobbyEnv())
    current = { gui = gui, svc = svc }
    ForkThread(function()
        while current.svc == svc and not IsDestroyed(gui) do
            local ok, err = pcall(svc.Tick, svc)
            if not ok then WARN('NuggetsLobby: Liar\'s Dice tick failed: ' .. tostring(err)) end
            WaitSeconds(0.1)
        end
    end)
    svc:RequestTables()
    LOG("NuggetsLobby: Liar's Dice started for this lobby")
    return svc
end

--- Called by the lobby.lua hook for every Liar's Dice message.
function Receive(sender, payload)
    local svc = Get()
    if svc then svc:Receive(sender, payload) end
end
