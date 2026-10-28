-- Nuggets custom lobby: the games of the Minigames window (the window is hub.lua).
-- Imported as /nuggetslobby/minigames.lua (init_nuggets.lua mounts nuggets-lobby\games
-- at /nuggetslobby). Standalone: the Minigames mod does not need to be installed.
--
-- Snake and Sudoku are this lobby's own games (snake.lua, sudoku.lua next to this file),
-- and so is Liar's Dice (liarsdice\, with its own lobby messages).
--
-- Chess, Battleship, Minesweeper, Dragonsweeper and Lag Clicker are a copy of the
-- Minigames mod's game files, bundled in games\minigames with their paths pointed at
-- /nuggetslobby/minigames/: Main.lua, modules/game.lua (Lag Clicker), modules/net.lua
-- (Lag Clicker scores), songs, art and sound banks. The mod's mod_info, ReUI options and
-- in-game hooks are not part of it. Changes to the mod do not reach this copy by themselves.
--
-- That code is written for a running game. It is loaded into its own environment in which
-- the few game-only functions it uses are replaced:
--   SessionSendChatMessage, RegisterChatFunc -> lobby messages to the players here who run
--                                               this lobby (see the lobby.lua hook)
--   GetArmiesTable, GetFocusArmy,
--   GetSessionClients                         -> your lobby name
--   ReUI hotkeys and options                  -> the buttons and settings of the Minigames window (hub.lua)
--   print                                     -> lobby chat
--   GetFrame(0)                               -> a layer over the lobby, removed with the lobby
-- Stakes (paying mass to the winner) are always off: there is no game to pay in yet.
--
-- One set of loaded games per lobby. Leaving the lobby or launching the game closes them.

local LayoutHelpers = import('/lua/maui/layouthelpers.lua')
local Group         = import('/lua/maui/group.lua').Group
local Prefs         = import('/lua/user/prefs.lua')

local MOD_ROOT     = '/nuggetslobby/minigames/'
local MOD_MODULES  = MOD_ROOT .. 'modules/'
local MAIN_FILE    = MOD_ROOT .. 'main.lua'
local NET_FILE     = MOD_MODULES .. 'net.lua'
local GAME_FILE    = MOD_MODULES .. 'game.lua'
local PREF_KEY     = 'NuggetsLobby_Minigames_v1'

-- The names the mod registers its hotkeys under.
local ACTION_CHESS     = 'Minigames - Chess'
local ACTION_BS        = 'Minigames - Battleship'
local ACTION_MINES     = 'Minigames - Minesweeper'
local ACTION_DRAGON    = 'Minigames - Dragonsweeper'

-- this lobby's own games
local SNAKE_FILE  = '/nuggetslobby/snake.lua'
local SUDOKU_FILE = '/nuggetslobby/sudoku.lua'

----------------------------------------------------------------------------
-- The lobby (functions exported by the lobby.lua hook)
----------------------------------------------------------------------------

local function LobbyFn(name)
    local modules = rawget(_G, '__modules')
    local lobby = modules and modules['/lua/ui/lobby/lobby.lua']
    if lobby then
        return rawget(lobby, name)
    end
    return nil
end

local function MyName()
    local fn = LobbyFn('NuggetsLobby_MyName')
    local name = fn and fn()
    if type(name) == 'string' and name ~= '' then return name end
    return 'You'
end

local function LobbyGUI()
    local fn = LobbyFn('NuggetsLobby_GUI')
    return fn and fn() or nil
end

local function Chat(text)
    local fn = LobbyFn('NuggetsLobby_Chat')
    if fn then
        local ok = pcall(fn, tostring(text))
        if ok then return end
    end
    LOG('NuggetsLobby: ' .. tostring(text))
end

-- { { id = peerId, name = playerName }, ... } of the players here who run this lobby
local function Peers()
    local fn = LobbyFn('NuggetsLobby_MinigamePeers')
    local peers = fn and fn()
    if type(peers) == 'table' then return peers end
    return {}
end

-- names: list of player names, or nil for every player who has the minigames
local function SendToPeers(payload, names)
    local fn = LobbyFn('NuggetsLobby_SendMinigames')
    if fn then fn(payload, names) end
end

-- false only when games\minigames is missing from the install
local function BundleInstalled()
    local ok, found = pcall(exists, MAIN_FILE)
    return ok and found and true or false
end

----------------------------------------------------------------------------
-- Settings (what the mod reads from its ReUI options in a game)
----------------------------------------------------------------------------

local DEFAULTS = {
    acceptChess      = true,
    acceptBattleship = true,
    gridSize         = 9,
    hardMode         = false,
}

local settings = nil

local function Settings()
    if settings then return settings end
    settings = {}
    local saved = Prefs.GetFromCurrentProfile(PREF_KEY)
    for key, default in DEFAULTS do
        local value = default
        if type(saved) == 'table' and type(saved[key]) == type(default) then
            value = saved[key]
        end
        settings[key] = value
    end
    settings.gridSize = math.floor(settings.gridSize)
    if settings.gridSize < 5 or settings.gridSize > 20 then
        settings.gridSize = DEFAULTS.gridSize
    end
    return settings
end

local function SaveSettings()
    local copy = {}
    local current = Settings()
    for key, value in current do
        copy[key] = value
    end
    Prefs.SetToCurrentProfile(PREF_KEY, copy)
    SavePreferences()
end

-- ReUI option objects: opt() reads the value, opt:Bind(fn) calls fn(opt) now and on change.
local function MakeOption(read)
    local opt = { listeners = {} }
    opt.Bind = function(self, fn)
        table.insert(self.listeners, fn)
        fn(self)
    end
    setmetatable(opt, { __call = function(self) return read() end })
    return opt
end

local function MakeOptions()
    return {
        stakesStorage        = MakeOption(function() return false end),
        stakesMex            = MakeOption(function() return false end),
        disableChessRequests = MakeOption(function() return not Settings().acceptChess end),
        disableBsRequests    = MakeOption(function() return not Settings().acceptBattleship end),
        gridSize             = MakeOption(function() return Settings().gridSize end),
        hardMode             = MakeOption(function() return Settings().hardMode end),
    }
end

----------------------------------------------------------------------------
-- Session: the mod's code loaded for one lobby
----------------------------------------------------------------------------

local Current = nil

local function SessionValid(s)
    if s == nil or not s.gui then return false end
    if IsDestroyed(s.gui) then return false end
    return s.gui == LobbyGUI()
end

-- Every game window in the lobby (the Minigames window, the mod's games through
-- GetFrame(0), Snake, Sudoku) goes on this layer: above the lobby, and destroyed
-- together with it. One layer per lobby window.
local layerState = { gui = nil, layer = nil }

local function LobbyLayer()
    local gui = LobbyGUI()
    if not gui or IsDestroyed(gui) then return nil end
    if layerState.gui ~= gui or layerState.layer == nil or IsDestroyed(layerState.layer) then
        local layer = Group(gui, 'NuggetsMinigamesLayer')
        LayoutHelpers.FillParent(layer, gui)
        layer:DisableHitTest()
        layer.GetTopmostDepth = function(self) return GetFrame(0):GetTopmostDepth() end
        layer.Depth:Set(GetFrame(0):GetTopmostDepth() + 1)
        layerState = { gui = gui, layer = layer }
    end
    return layerState.layer
end

-- Lift the layer above anything the lobby opened since (its own dialogs).
local function RaiseLobbyLayer()
    local layer = LobbyLayer()
    if layer then
        layer.Depth:Set(GetFrame(0):GetTopmostDepth() + 1)
    end
    return layer
end

local function CallHandler(fn, sender, data)
    local ok, err = pcall(fn, sender, data)
    if not ok then
        WARN('NuggetsLobby: minigame message handler failed: ' .. tostring(err))
    end
end

-- Same routing as the game's ReceiveChat (/lua/ui/game/gamemain.lua).
local function Dispatch(s, sender, data)
    if type(data) ~= 'table' then return end
    if data.Identifier then
        local fn = s.chatFuncs[data.Identifier]
        if fn then CallHandler(fn, sender, data) end
    else
        for identifier, fn in s.chatFuncs do
            if data[identifier] then CallHandler(fn, sender, data) end
        end
    end
end

-- The mod's challenge messages, and the game each belongs to.
local CHALLENGES = { chess_challenge = 'Chess', bs_challenge = 'Battleship' }

-- Who a message goes to:
--   a challenge                       -> only the player picked in the Minigames window
--                                        (nobody for a game against the bot)
--   addressed to a player (accept,
--   decline, start: the 'target' field) -> only that player
--   anything else (moves, shots,
--   Lag Clicker scores)                -> every player here who has the minigames, exactly
--                                        as in a game; each copy of the mod ignores what is
--                                        not from its own opponent
local function Recipients(s, msg)
    local game = CHALLENGES[msg.type]
    if game then
        local to = s.challengeTo or ''
        s.challenged[game] = to
        s.challengeSent = true
        if to == '' then return {} end
        return { to }
    end
    if type(msg.target) == 'string' and msg.target ~= 'all' then
        return { msg.target }
    end
    return nil
end

local function Send(s, msg)
    if type(msg) ~= 'table' then return end
    SendToPeers(msg, Recipients(s, msg))
    -- In a game every chat message also comes back to its sender, and the mod's
    -- handlers are written for that. Do the same here.
    ForkThread(function()
        WaitSeconds(0.1)
        if SessionValid(s) then
            Dispatch(s, MyName(), msg)
        end
    end)
end

-- The mod's own lines assume a challenge goes to everyone ("Others have 3 seconds to
-- accept", "No one accepted"). Say who it went to instead. Lines that do not match are
-- shown as they are. Returns nil to show nothing.
local function RewritePrint(s, text)
    if type(text) ~= 'string' then return text end
    for game, who in s.challenged do
        local prefix = game .. ': '
        if string.sub(text, 1, string.len(prefix)) == prefix then
            if string.find(text, 'Challenge sent', 1, true) then
                if who == '' then return nil end
                return prefix .. 'challenge sent to ' .. who .. ', waiting for an answer.'
            elseif string.find(text, 'No one accepted', 1, true) then
                if who == '' then return nil end
                if string.find(text, 'Bot', 1, true) then
                    return prefix .. who .. ' did not accept. Starting a game against the bot instead.'
                end
                return prefix .. who .. ' did not accept.'
            end
        end
    end
    return text
end

local LoadModule  -- forward declaration: the import stand-in needs it

local function NewSession(gui)
    local s = {
        gui       = gui,
        chatFuncs = {},
        actions   = {},
        postCreate = {},
        modules   = {},
        options   = MakeOptions(),
        failed    = false,
        challengeTo   = nil,    -- set while a challenge is being made: name, '' = the bot
        challenged    = {},     -- game -> who its last challenge went to
        challengeSent = false,
        printed       = false,
    }
    s.gamemain = {
        RegisterChatFunc = function(fn, identifier)
            s.chatFuncs[identifier] = fn
        end,
    }

    local shims = setmetatable({}, { __index = _G })
    s.shims = shims

    shims.print = function(text)
        s.printed = true
        local line = RewritePrint(s, text)
        if line ~= nil then Chat(line) end
    end
    shims.GetFrame = function(index) return LobbyLayer() or GetFrame(index) end
    shims.GetFocusArmy = function() return 1 end
    shims.GetArmiesTable = function()
        return {
            focusArmy = 1,
            numArmies = 1,
            armiesTable = { { nickname = MyName(), human = true, civilian = false, outOfGame = false } },
        }
    end
    shims.GetSessionClients = function()
        return { { name = MyName(), ['local'] = true, connected = true } }
    end
    shims.SessionIsReplay = function() return false end
    shims.SessionGetScenarioInfo = function() return { Options = {} } end
    shims.SessionSendChatMessage = function(a, b)
        -- (msg) or (clients, msg)
        local msg = a
        if b ~= nil then msg = b end
        Send(s, msg)
    end
    -- only reached by stakes, which are off
    shims.SimCallback = function(callback) end
    shims.GetSelectedUnits = function() return nil end
    shims.SelectUnits = function(units) end
    shims.IsAlly = function(a, b) return false end

    shims.ReUI = {
        Require = function(list) end,
        Options = { Mods = { Minigames = s.options } },
        Actions = {
            SelectionAction = function(name, fn)
                s.actions[name] = fn
            end,
        },
        Core = {
            OnPostCreateUI = function(fn)
                table.insert(s.postCreate, fn)
            end,
        },
    }

    shims.import = function(name, isLazy)
        local key = string.lower(name)
        if key == '/lua/ui/game/gamemain.lua' then
            return s.gamemain
        end
        if key == '/lua/keymap/keymapper.lua' then
            -- the mod extends in-game hotkeys here; there are none in the lobby
            return {}
        end
        if string.sub(key, 1, string.len(MOD_MODULES)) == MOD_MODULES then
            return LoadModule(s, key)
        end
        return import(name, isLazy)
    end

    return s
end

LoadModule = function(s, path)
    local key = string.lower(path)
    local env = s.modules[key]
    if env then return env end
    env = setmetatable({}, { __index = s.shims })
    s.modules[key] = env
    doscript(key, env)
    return env
end

local function NotifyOption(s, name)
    local opt = s.options[name]
    if not opt then return end
    for i = 1, table.getn(opt.listeners) do
        local ok, err = pcall(opt.listeners[i], opt)
        if not ok then WARN('NuggetsLobby: option ' .. name .. ' update failed: ' .. tostring(err)) end
    end
end

-- The session for the current lobby, loading the mod's code on first use.
-- Returns nil when there is no lobby, the mod is not installed, or it failed to load.
local function Session()
    if SessionValid(Current) then
        if Current.failed then return nil end
        return Current
    end
    Current = nil
    local gui = LobbyGUI()
    if not gui or IsDestroyed(gui) then return nil end
    if not BundleInstalled() then return nil end

    local s = NewSession(gui)
    Current = s
    local ok, err = pcall(function()
        local main = LoadModule(s, MAIN_FILE)
        main.Main(false)
        for i = 1, table.getn(s.postCreate) do
            s.postCreate[i]()
        end
    end)
    if not ok then
        s.failed = true
        WARN('NuggetsLobby: Minigames failed to load: ' .. tostring(err))
        Chat('Minigames could not start in the lobby: ' .. tostring(err))
        return nil
    end

    -- Lag Clicker scores: exchanged with the other players here who run this lobby
    local netOk, netErr = pcall(function() LoadModule(s, NET_FILE).Init() end)
    if not netOk then
        WARN('NuggetsLobby: Lag Clicker scores unavailable: ' .. tostring(netErr))
    end

    LOG('NuggetsLobby: Minigames loaded for this lobby')
    return s
end

-- Called by the lobby.lua hook for every minigame message from another player.
function Receive(sender, payload)
    if type(sender) ~= 'string' or type(payload) ~= 'table' then return end
    local s = Session()
    if s then
        Dispatch(s, sender, payload)
    end
end

----------------------------------------------------------------------------
-- Starting games
----------------------------------------------------------------------------

-- Runs one of the mod's game actions. For Chess and Battleship, `opponent` is who the
-- challenge goes to ('' = nobody, so Battleship starts against the bot).
-- Returns true when a challenge was sent.
local function RunAction(name, opponent, game)
    local s = Session()
    if not s then return false end
    local fn = s.actions[name]
    if not fn then
        Chat('Minigames: "' .. name .. '" is missing from the bundled games')
        return false
    end
    RaiseLobbyLayer()
    s.challengeTo = opponent
    s.challengeSent = false
    s.printed = false
    local ok, err = pcall(fn, nil)
    s.challengeTo = nil
    if not ok then
        WARN('NuggetsLobby: ' .. name .. ' failed: ' .. tostring(err))
        Chat('Minigames: ' .. name .. ' failed: ' .. tostring(err))
    elseif game ~= nil and not s.challengeSent and not s.printed then
        -- the mod does nothing while its window for that game is open
        Chat(game .. ': finish or close your current game first.')
    end
    return ok and s.challengeSent
end

local function ChallengePlayer(game, action, opponent)
    if type(opponent) ~= 'string' or opponent == '' then
        Chat(game .. ': pick an opponent first.')
        return
    end
    local stillHere = false
    local peers = Peers()
    for i = 1, table.getn(peers) do
        if peers[i].name == opponent then stillHere = true end
    end
    if not stillHere then
        Chat(game .. ': ' .. opponent .. ' is no longer here.')
        return
    end
    RunAction(action, opponent, game)
end

-- The mod starts its bot game when a challenge goes unanswered, so this is a
-- challenge sent to nobody.
local function BattleshipVsBot()
    if RunAction(ACTION_BS, '', 'Battleship') then
        Chat('Battleship: a game against the bot starts in a few seconds.')
    end
end

local function ToggleLagClicker()
    local s = Session()
    if not s then return end
    RaiseLobbyLayer()
    local ok, err = pcall(function() LoadModule(s, GAME_FILE).Toggle() end)
    if not ok then
        WARN('NuggetsLobby: Lag Clicker failed: ' .. tostring(err))
        Chat('Minigames: Lag Clicker failed: ' .. tostring(err))
    end
end

----------------------------------------------------------------------------
-- For the Minigames window (hub.lua)
----------------------------------------------------------------------------

-- Snake and Sudoku are this lobby's own games (they do not use the bundled copy).
local function OpenLobbyGame(path, label)
    local layer = RaiseLobbyLayer()
    if not layer then return false end
    local ok, err = pcall(function() import(path).Open(layer) end)
    if not ok then
        WARN('NuggetsLobby: ' .. label .. ' failed: ' .. tostring(err))
        Chat('Minigames: ' .. label .. ' failed: ' .. tostring(err))
        return false
    end
    return true
end

--- The layer the game windows go on (raised above the lobby's own windows).
function Layer()
    return RaiseLobbyLayer()
end

--- True when the bundled Chess, Battleship, Minesweeper, ... loaded for this lobby.
function HasBundle()
    return Session() ~= nil
end

--- Names of the players here who run this lobby with the bundled games, sorted.
function Opponents()
    local peers = Peers()
    local names = {}
    for i = 1, table.getn(peers) do
        table.insert(names, tostring(peers[i].name))
    end
    table.sort(names, function(a, b) return string.lower(a) < string.lower(b) end)
    return names
end

--- Challenges `opponent` to game 'Chess' or 'Battleship'.
function Challenge(game, opponent)
    if game == 'Chess' then
        ChallengePlayer('Chess', ACTION_CHESS, opponent)
    elseif game == 'Battleship' then
        ChallengePlayer('Battleship', ACTION_BS, opponent)
    end
end

--- Starts a game on your own. Returns true when it opened.
function PlaySolo(key)
    if key == 'snake' then return OpenLobbyGame(SNAKE_FILE, 'Snake') end
    if key == 'sudoku' then return OpenLobbyGame(SUDOKU_FILE, 'Sudoku') end
    if key == 'minesweeper' then RunAction(ACTION_MINES, nil, nil) return true end
    if key == 'dragonsweeper' then RunAction(ACTION_DRAGON, nil, nil) return true end
    if key == 'lagclicker' then ToggleLagClicker() return true end
    if key == 'battleshipbot' then BattleshipVsBot() return true end
    return false
end

-- which of the mod's options a setting feeds
local OPTION_OF = {
    acceptChess = 'disableChessRequests',
    acceptBattleship = 'disableBsRequests',
    gridSize = 'gridSize',
    hardMode = 'hardMode',
}

function GetSetting(key)
    return Settings()[key]
end

function SetSetting(key, value)
    if DEFAULTS[key] == nil or type(value) ~= type(DEFAULTS[key]) then return end
    Settings()[key] = value
    SaveSettings()
    local s = nil
    if SessionValid(Current) and not Current.failed then s = Current end
    if s and OPTION_OF[key] then NotifyOption(s, OPTION_OF[key]) end
end

--- The lobby's Minigames button.
function ToggleMenu(anchor)
    local ok, err = pcall(function() import('/nuggetslobby/hub.lua').Toggle() end)
    if not ok then
        WARN('NuggetsLobby: Minigames window failed: ' .. tostring(err))
        Chat('Minigames window failed: ' .. tostring(err))
    end
end
