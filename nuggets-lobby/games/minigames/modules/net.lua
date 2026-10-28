-- Lag Clicker: personal best storage and score exchange over chat.
--
-- Messages are chat messages (SessionSendChatMessage). They reach only
-- players who run this mod, are capped at 1024 bytes and are not recorded
-- in replays. Every client keeps its own list of scores it has seen.

local Prefs = import('/lua/user/prefs.lua')

local CFG = {
    PREF_KEY  = 'LagClicker_Scores_v1',
    CHAT_ID   = 'LagClicker',
    PROTO     = 1,
    MAX_SCORE = 10000000,
    BOARD_MAX = 50,
    HELLO_DELAY = 8,
}

local S = {
    inited      = false,
    myName      = 'You',
    best        = 0,            -- all-time personal best (saved)
    gameBest    = 0,            -- best run in this game
    board       = {},           -- all-time list { { n = name, s = score }, ... } (saved)
    session     = {},           -- this game: name -> { best = n, game = n }
    replied     = {},           -- name -> true once we answered their hello
    listeners   = {},
    resendDue   = false,        -- a score changed while the connection window was up
}

local function ToScore(v)
    local n = tonumber(v)
    if not n or n < 0 or n > CFG.MAX_SCORE then return nil end
    return math.floor(n)
end

local function SortBoard()
    table.sort(S.board, function(a, b) return a.s > b.s end)
    while table.getn(S.board) > CFG.BOARD_MAX do
        table.remove(S.board)
    end
end

-- returns true when the all-time list changed
local function UpdateBoard(name, score)
    if not name or not score or score <= 0 then return false end
    for i = 1, table.getn(S.board) do
        local e = S.board[i]
        if e.n == name then
            if score > e.s then
                e.s = score
                SortBoard()
                return true
            end
            return false
        end
    end
    table.insert(S.board, { n = name, s = score })
    SortBoard()
    return true
end

local function Load()
    local data = Prefs.GetFromCurrentProfile(CFG.PREF_KEY)
    if type(data) ~= 'table' then return end
    S.best = ToScore(data.best) or 0
    if type(data.board) == 'table' then
        for i = 1, table.getn(data.board) do
            local e = data.board[i]
            if type(e) == 'table' and type(e.n) == 'string' then
                local s = ToScore(e.s)
                if s and s > 0 then table.insert(S.board, { n = e.n, s = s }) end
            end
        end
    end
    SortBoard()
end

local function Save(toDisk)
    local copy = {}
    for i = 1, table.getn(S.board) do
        copy[i] = { n = S.board[i].n, s = S.board[i].s }
    end
    Prefs.SetToCurrentProfile(CFG.PREF_KEY, { best = S.best, board = copy })
    if toDisk then SavePreferences() end
end

local function FindMyName()
    local clients = GetSessionClients()
    if not clients then return end
    for i = 1, table.getn(clients) do
        local c = clients[i]
        if c and c['local'] and c.name then
            S.myName = c.name
            return
        end
    end
end

local function Notify()
    for i = 1, table.getn(S.listeners) do
        local ok, err = pcall(S.listeners[i])
        if not ok then WARN('LagClicker: listener failed: ' .. tostring(err)) end
    end
end

local function SessionEntry(name)
    local e = S.session[name]
    if not e then
        e = { best = 0, game = 0 }
        S.session[name] = e
    end
    return e
end

-- kind: 'hi' asks everyone to answer with their scores, 'up' does not
local function Send(kind)
    local ok, err = pcall(function()
        SessionSendChatMessage({
            Identifier = CFG.CHAT_ID,
            v = CFG.PROTO,
            k = kind,
            s = S.best,
            g = S.gameBest,
        })
    end)
    if not ok then WARN('LagClicker: send failed: ' .. tostring(err)) end
end

local function OnChat(sender, data)
    local ok, err = pcall(function()
        if type(data) ~= 'table' or type(sender) ~= 'string' then return end
        local best = ToScore(data.s)
        local game = ToScore(data.g)
        if not best then return end
        local e = SessionEntry(sender)
        if best > e.best then e.best = best end
        if game and game > e.game then e.game = game end
        if sender ~= S.myName and UpdateBoard(sender, best) then
            Save(false)                                -- written to disk when the game exits
        end
        if data.k == 'hi' and sender ~= S.myName and not S.replied[sender] then
            S.replied[sender] = true
            Send('up')
        end
        Notify()
    end)
    if not ok then WARN('LagClicker: bad message from ' .. tostring(sender) .. ': ' .. tostring(err)) end
end

function Init()
    if S.inited then return end
    S.inited = true
    Load()
    FindMyName()
    local me = SessionEntry(S.myName)
    me.best = S.best
    import('/lua/ui/game/gamemain.lua').RegisterChatFunc(OnChat, CFG.CHAT_ID)
    ForkThread(function()
        WaitSeconds(CFG.HELLO_DELAY)
        Send('hi')
    end)
end

-- Called by the game when a run ends. Returns true on a new personal best.
function SubmitRun(score)
    score = ToScore(score) or 0
    local me = SessionEntry(S.myName)
    local newBest = false
    if score > S.gameBest then
        S.gameBest = score
        me.game = score
        S.resendDue = true
    end
    if score > S.best then
        S.best = score
        me.best = score
        UpdateBoard(S.myName, score)
        Save(true)
        newBest = true
    end
    if S.resendDue then Send('up') end
    Notify()
    return newBest
end

-- The connection window closed: send again in case messages sent while a
-- player was not responding did not get through.
function OnDialogClosed()
    if S.resendDue then
        S.resendDue = false
        Send('up')
    end
end

function AddListener(fn)
    table.insert(S.listeners, fn)
end

function GetBest() return S.best end
function GetGameBest() return S.gameBest end
function GetMyName() return S.myName end

-- all-time list, highest first
function GetBoard() return S.board end

-- this game, highest all-time best first: { { n = name, best = n, game = n }, ... }
function GetSession()
    local list = {}
    for name, e in S.session do
        table.insert(list, { n = name, best = e.best, game = e.game })
    end
    table.sort(list, function(a, b) return a.best > b.best end)
    return list
end
