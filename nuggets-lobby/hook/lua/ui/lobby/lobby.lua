-- Nuggets custom lobby: appended by the engine to the end of /lua/ui/lobby/lobby.lua,
-- so it can use the file's own top-level locals (lobbyOptions, gameInfo, Mods,
-- ModOptionMapping, IsDefaultOption, IsOptionUsedByGivenMods, lobbyComm, GUI,
-- localPlayerName, MessageHandlers, UIUtil, LayoutHelpers).
--
-- Everything sits in a do-block so no new top-level locals outlive this file.
--
-- FEATURE: hide lobby options of mods that are not active.
--   FAF loads the lobby options of EVERY installed mod into one list (AIOpts)
--   and shows all of them. While the lobby draws its option summary, and while
--   the Options dialog builds its list (see the mapselect.lua hook), that list
--   is swapped for a filtered copy and put back straight after.
--   Display only: game options themselves are never changed, and FAF already
--   drops options of disabled mods at launch.

do
    LOG('NuggetsLobby: hook appended to lobby.lua')

    local function NuggetsLoadedModule(name)
        local modules = rawget(_G, '__modules')
        if modules then
            return modules[name]
        end
        return nil
    end

    -- The mods whose options are shown: the game's sim mods (chosen by the
    -- host, synced to every player) plus this player's own UI mods.
    local function NuggetsEnabledMods()
        local enabled = {}
        if gameInfo and gameInfo.GameMods then
            for k, v in gameInfo.GameMods do
                -- normally uid -> true; at launch FAF turns it into a list of mod infos
                if type(v) == 'table' and v.uid then
                    enabled[v.uid] = true
                else
                    enabled[k] = true
                end
            end
        end
        local ok, uiMods = pcall(Mods.GetUiMods)
        if ok and uiMods then
            for _, mod in uiMods do
                enabled[mod.uid] = true
            end
        end
        return enabled
    end

    --- Returns a new list without the options of inactive mods. Options of FAF
    --- itself, and options no installed mod claims, are always kept.
    function NuggetsLobby_VisibleOptions(options)
        local enabled = NuggetsEnabledMods()
        local visible = {}
        for i = 1, table.getn(options) do
            local option = options[i]
            local key = option.key
            if IsDefaultOption(key) or not ModOptionMapping[key] or IsOptionUsedByGivenMods(key, enabled) then
                table.insert(visible, option)
            end
        end
        return visible
    end

    --- Calls fn(arg1) while lobbyoptions.lua's AIOpts holds only the visible
    --- options, then restores the full list, also when fn raises an error.
    --- If filtering itself fails, fn runs on the full list as in stock FAF.
    function NuggetsLobby_WithVisibleAIOpts(fn, arg1)
        local all = lobbyOptions.AIOpts
        local ok, visible = pcall(NuggetsLobby_VisibleOptions, all)
        if not ok then
            WARN('NuggetsLobby: option filter failed, showing all options: ' .. tostring(visible))
            fn(arg1)
            return
        end
        lobbyOptions.AIOpts = visible
        local fnOk, fnErr = pcall(fn, arg1)
        lobbyOptions.AIOpts = all
        if not fnOk then
            error(fnErr, 0)
        end
    end

    -- The option summary on the lobby screen, on every player's lobby.
    local oldRefreshOptionDisplayData = RefreshOptionDisplayData
    if type(oldRefreshOptionDisplayData) == 'function' then
        RefreshOptionDisplayData = function(scenarioInfo)
            NuggetsLobby_WithVisibleAIOpts(oldRefreshOptionDisplayData, scenarioInfo)
        end
    else
        WARN('NuggetsLobby: RefreshOptionDisplayData not found, lobby option summary unfiltered')
    end

    -- Mods switched on or off from inside the host's Options dialog: rebuild
    -- that dialog's option list. The lobby summary refreshes by itself.
    local oldOnModsChanged = OnModsChanged
    if type(oldOnModsChanged) == 'function' then
        OnModsChanged = function(simMods, UIMods, ignoreRefresh)
            oldOnModsChanged(simMods, UIMods, ignoreRefresh)
            local mapselect = NuggetsLoadedModule('/lua/ui/dialogs/mapselect.lua')
            local refresh = mapselect and rawget(mapselect, 'NuggetsLobby_RefreshModOptions')
            if refresh then
                local ok, err = pcall(refresh)
                if not ok then
                    WARN('NuggetsLobby: could not refresh the Options dialog: ' .. tostring(err))
                end
            end
        end
    else
        WARN('NuggetsLobby: OnModsChanged not found, Options dialog will not refresh on mod changes')
    end
end

-- FEATURE: minigames in the lobby (the game side is /nuggetslobby/minigames.lua, from
--          nuggets-lobby\games; the lobby needs no mod for it).
--
--   Players running this lobby find each other with a NuggetsLobbyHello message. Each
--   connected player is greeted at most twice; a player on the stock lobby drops it and
--   logs one "Unknown message type" warning per greeting. Both sides greet, so a missed
--   greeting is made up by the other side's.
--   The greeting says whether this lobby's bundled games and Liar's Dice are present.
--   Minigame messages (NuggetsMinigames) go only to players who run this lobby with
--   them; a challenge goes only to the player picked in the Minigames window. Liar's
--   Dice has its own message type (NuggetsLiarsDice) for the players who have it.

do
    -- capable[id]   : that player runs this lobby
    -- minigames[id] : ... with the bundled games present (they said so in their greeting)
    -- liarsdice[id] : ... with Liar's Dice
    local NuggetsPeerState = { comm = nil, capable = {}, minigames = {}, liarsdice = {}, tries = {} }

    -- reset for every new lobby connection
    local function NuggetsPeers()
        if NuggetsPeerState.comm ~= lobbyComm then
            NuggetsPeerState = { comm = lobbyComm, capable = {}, minigames = {}, liarsdice = {}, tries = {} }
        end
        return NuggetsPeerState
    end

    local function NuggetsHasFile(path)
        local ok, found = pcall(exists, path)
        return ok and found and true or false
    end

    -- nuggets-lobby\games\minigames, mounted by init_nuggets.lua
    local function NuggetsHasMinigames()
        return NuggetsHasFile('/nuggetslobby/minigames/main.lua')
    end

    local function NuggetsHasLiarsDice()
        return NuggetsHasFile('/nuggetslobby/liarsdice/table.lua')
    end

    local function NuggetsSendHello(peerId, reply)
        local hasMinigames = NuggetsHasMinigames()
        local hasLiarsDice = NuggetsHasLiarsDice()
        local ok, err = pcall(function()
            lobbyComm:SendData(peerId, { Type = 'NuggetsLobbyHello', Version = 4, Reply = reply, Minigames = hasMinigames, LiarsDice = hasLiarsDice })
        end)
        if not ok then
            WARN('NuggetsLobby: hello to ' .. tostring(peerId) .. ' failed: ' .. tostring(err))
        end
    end

    local function NuggetsEstablishedPeers()
        if not lobbyComm then return {} end
        local ok, peers = pcall(function() return lobbyComm:GetPeers() end)
        if not ok or type(peers) ~= 'table' then return {} end
        local list = {}
        for _, peer in peers do
            if peer.status == 'Established' then
                table.insert(list, peer)
            end
        end
        return list
    end

    --- { { id = peerId, name = playerName }, ... } of connected players who run this
    --- lobby with its bundled games
    function NuggetsLobby_MinigamePeers()
        local state = NuggetsPeers()
        local list = {}
        local peers = NuggetsEstablishedPeers()
        for i = 1, table.getn(peers) do
            local peer = peers[i]
            if state.capable[peer.id] and state.minigames[peer.id] then
                table.insert(list, { id = peer.id, name = peer.name })
            end
        end
        return list
    end

    --- { { id = peerId, name = playerName }, ... } of connected players who run this
    --- lobby with Liar's Dice
    function NuggetsLobby_LiarsDicePeers()
        local state = NuggetsPeers()
        local list = {}
        local peers = NuggetsEstablishedPeers()
        for i = 1, table.getn(peers) do
            local peer = peers[i]
            if state.capable[peer.id] and state.liarsdice[peer.id] then
                table.insert(list, { id = peer.id, name = peer.name })
            end
        end
        return list
    end

    --- Sends a Liar's Dice message to the players named in `names` (a list), or to every
    --- player from NuggetsLobby_LiarsDicePeers when `names` is nil.
    function NuggetsLobby_SendLiarsDice(payload, names)
        local wanted = nil
        if names ~= nil then
            wanted = {}
            for i = 1, table.getn(names) do
                wanted[names[i]] = true
            end
        end
        local peers = NuggetsLobby_LiarsDicePeers()
        for i = 1, table.getn(peers) do
            local peerId = peers[i].id
            if wanted == nil or wanted[peers[i].name] then
                local ok, err = pcall(function()
                    lobbyComm:SendData(peerId, { Type = 'NuggetsLiarsDice', Payload = payload })
                end)
                if not ok then
                    WARN("NuggetsLobby: Liar's Dice message to " .. tostring(peerId) .. ' failed: ' .. tostring(err))
                end
            end
        end
    end

    --- Sends a minigame message to the players named in `names` (a list), or to every
    --- player from NuggetsLobby_MinigamePeers when `names` is nil.
    function NuggetsLobby_SendMinigames(payload, names)
        local wanted = nil
        if names ~= nil then
            wanted = {}
            for i = 1, table.getn(names) do
                wanted[names[i]] = true
            end
        end
        local peers = NuggetsLobby_MinigamePeers()
        for i = 1, table.getn(peers) do
            local peerId = peers[i].id
            if wanted == nil or wanted[peers[i].name] then
                local ok, err = pcall(function()
                    lobbyComm:SendData(peerId, { Type = 'NuggetsMinigames', Payload = payload })
                end)
                if not ok then
                    WARN('NuggetsLobby: minigame message to ' .. tostring(peerId) .. ' failed: ' .. tostring(err))
                end
            end
        end
    end

    function NuggetsLobby_MyName() return localPlayerName end
    function NuggetsLobby_GUI() return GUI end
    function NuggetsLobby_Chat(text) AddChatText(text) end

    -- The lobby keeps the keyboard on its chat box: when the box loses it, it takes it
    -- straight back, so in-game hotkeys cannot fire in the lobby. Snake lends it for a
    -- run: the box's take-back is switched off, `control` takes the keyboard with
    -- key presses blocked from everything else, and returning restores both.
    local NuggetsKeyboard = { chat = nil, control = nil, handler = nil }

    local function NuggetsKeyboardState()
        local chat = GUI and GUI.chatEdit or nil
        if NuggetsKeyboard.chat ~= chat then
            NuggetsKeyboard = { chat = chat, control = nil, handler = nil }
        end
        return NuggetsKeyboard
    end

    function NuggetsLobby_BorrowKeyboard(control)
        local state = NuggetsKeyboardState()
        if state.chat == nil or IsDestroyed(state.chat) or control == nil or IsDestroyed(control) then
            return false
        end
        if state.control == nil then
            state.handler = state.chat.OnLoseKeyboardFocus
            state.chat.OnLoseKeyboardFocus = function(self) end
        end
        state.control = control
        state.chat:AbandonFocus()
        control:AcquireKeyboardFocus(true)
        return true
    end

    function NuggetsLobby_ReturnKeyboard(control)
        local state = NuggetsKeyboardState()
        if state.control == nil or state.control ~= control then return end
        state.control = nil
        if not IsDestroyed(control) then
            control:AbandonKeyboardFocus()
        end
        if state.chat ~= nil and not IsDestroyed(state.chat) then
            state.chat.OnLoseKeyboardFocus = state.handler
            state.chat:AcquireFocus()
        end
        state.handler = nil
    end

    local function NuggetsSenderName(data)
        if type(data.SenderName) == 'string' and data.SenderName ~= '' then
            return data.SenderName
        end
        return FindNameForID(data.SenderID)
    end

    MessageHandlers.NuggetsLobbyHello = {
        Handle = function(data)
            local state = NuggetsPeers()
            state.capable[data.SenderID] = true
            state.minigames[data.SenderID] = (data.Minigames == true)
            state.liarsdice[data.SenderID] = (data.LiarsDice == true)
            if not data.Reply then
                NuggetsSendHello(data.SenderID, true)
            end
        end,
    }

    MessageHandlers.NuggetsMinigames = {
        Handle = function(data)
            local state = NuggetsPeers()
            state.capable[data.SenderID] = true
            state.minigames[data.SenderID] = true
            local sender = NuggetsSenderName(data)
            local payload = data.Payload
            local ok, err = pcall(function()
                import('/nuggetslobby/minigames.lua').Receive(sender, payload)
            end)
            if not ok then
                WARN('NuggetsLobby: minigame message failed: ' .. tostring(err))
            end
        end,
    }

    MessageHandlers.NuggetsLiarsDice = {
        Handle = function(data)
            local state = NuggetsPeers()
            state.capable[data.SenderID] = true
            state.liarsdice[data.SenderID] = true
            local sender = NuggetsSenderName(data)
            local payload = data.Payload
            local ok, err = pcall(function()
                import('/nuggetslobby/liarsdice/table.lua').Receive(sender, payload)
            end)
            if not ok then
                WARN("NuggetsLobby: Liar's Dice message failed: " .. tostring(err))
            end
        end,
    }

    -- Greets every connected player that has not answered yet, at most twice each,
    -- for as long as this lobby window exists.
    local function NuggetsDiscover(gui)
        while lobbyComm and GUI == gui do
            local state = NuggetsPeers()
            local peers = NuggetsEstablishedPeers()
            for i = 1, table.getn(peers) do
                local peerId = peers[i].id
                if not state.capable[peerId] then
                    local tries = state.tries[peerId] or 0
                    if tries < 2 then
                        state.tries[peerId] = tries + 1
                        NuggetsSendHello(peerId, false)
                    end
                end
            end
            WaitSeconds(3)
        end
    end

    local function NuggetsAddMinigamesButton()
        if not GUI or not GUI.panel or not GUI.LobbyOptions then return end
        local btn = UIUtil.CreateButtonWithDropshadow(GUI.panel, '/BUTTON/medium/', 'Minigames')
        LayoutHelpers.LeftOf(btn, GUI.LobbyOptions, -10)
        btn.OnClick = function(self, modifiers)
            local anchor = self
            local ok, err = pcall(function()
                import('/nuggetslobby/minigames.lua').ToggleMenu(anchor)
            end)
            if not ok then
                WARN('NuggetsLobby: Minigames window failed: ' .. tostring(err))
                AddChatText('Minigames window failed: ' .. tostring(err))
            end
        end
        GUI.NuggetsMinigamesButton = btn
    end

    local oldCreateUI = CreateUI
    if type(oldCreateUI) == 'function' then
        CreateUI = function(maxPlayers)
            oldCreateUI(maxPlayers)
            local ok, err = pcall(NuggetsAddMinigamesButton)
            if not ok then
                WARN('NuggetsLobby: could not add the Minigames button: ' .. tostring(err))
            end
            ForkThread(NuggetsDiscover, GUI)
        end
    else
        WARN('NuggetsLobby: CreateUI not found, no minigames in this lobby')
    end
end
