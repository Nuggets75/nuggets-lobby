-- Nuggets custom lobby: additions to the game's init.
--
-- Goes in the FAF bin folder (C:\ProgramData\FAForever\bin\).
-- Its presence there is what switches the custom lobby on.
--
-- Not started directly: wrapper.exe writes init_nuggets_launch.lua next to it before
-- every launch, which runs the client's own init file (init_faf.lua, init.lua, ...) and
-- then this file.
--
-- Mounts, from ..\nuggets-lobby:
--   hook                   at /nuggetshook   (a hook folder: hook\lua\ui\lobby\lobby.lua
--                                            is appended to /lua/ui/lobby/lobby.lua)
--   games                  at /nuggetslobby  (the lobby's games; no mod needed)
--   games\minigames\sounds at /sounds        (Lag Clicker's sound banks; skipped when an
--                                            installed mod already has banks of these
--                                            names, because FAF never mounts a bank twice)

local NuggetsRoot = InitFileDir .. '/../nuggets-lobby'

local function NuggetsEntries(pattern)
    local found = {}
    local list = io.dir(pattern) or {}
    for _, entry in list do
        if entry ~= '.' and entry ~= '..' then
            table.insert(found, entry)
        end
    end
    return found
end

-- lower-case names of the .xwb sound banks in a folder
local function NuggetsBanks(dir)
    local banks = {}
    local entries = NuggetsEntries(dir .. '/*')
    for i = 1, table.getn(entries) do
        local name = string.lower(entries[i])
        if string.sub(name, -4) == '.xwb' then
            banks[name] = true
        end
    end
    return banks
end

-- true when a mod in the vault (the same places FAF's init loads mods from) already
-- has one of these banks
local function NuggetsBanksInVault(banks)
    local vaults = {}
    local customVault = rawget(_G, 'custom_vault_path')
    if customVault then
        table.insert(vaults, customVault)
    else
        table.insert(vaults, InitFileDir .. '/../user/My Games/Gas Powered Games/Supreme Commander Forged Alliance')
        table.insert(vaults, SHGetFolderPath('PERSONAL') .. 'My Games/Gas Powered Games/Supreme Commander Forged Alliance')
    end
    for v = 1, table.getn(vaults) do
        local modsDir = vaults[v] .. '/mods'
        local mods = NuggetsEntries(modsDir .. '/*')
        for m = 1, table.getn(mods) do
            local theirs = NuggetsBanks(modsDir .. '/' .. mods[m] .. '/sounds')
            for name, _ in theirs do
                if banks[name] then
                    return true, mods[m]
                end
            end
        end
    end
    return false, nil
end

if type(rawget(_G, 'path')) ~= 'table' or type(rawget(_G, 'hook')) ~= 'table' then
    LOG('NuggetsLobby: init_nuggets.lua ran before the client init file, nothing added')
else
    local hookDir = NuggetsRoot .. '/hook'
    if table.getn(NuggetsEntries(hookDir .. '/*')) > 0 then
        table.insert(hook, '/nuggetshook')
        table.insert(path, { dir = hookDir, mountpoint = '/nuggetshook' })
        LOG('NuggetsLobby: mounted ' .. hookDir .. ' at /nuggetshook')
    else
        LOG('NuggetsLobby: hook folder not found or empty: ' .. hookDir .. ' (lobby runs unmodified)')
    end

    local gamesDir = NuggetsRoot .. '/games'
    if table.getn(NuggetsEntries(gamesDir .. '/*')) > 0 then
        table.insert(path, { dir = gamesDir, mountpoint = '/nuggetslobby' })
        LOG('NuggetsLobby: mounted ' .. gamesDir .. ' at /nuggetslobby')
    else
        LOG('NuggetsLobby: games folder not found or empty: ' .. gamesDir)
    end

    local soundsDir = gamesDir .. '/minigames/sounds'
    local banks = NuggetsBanks(soundsDir)
    if next(banks) ~= nil then
        local taken, byMod = NuggetsBanksInVault(banks)
        if taken then
            LOG('NuggetsLobby: Lag Clicker sound banks already provided by mod ' .. tostring(byMod) .. ', using those')
        else
            table.insert(path, { dir = soundsDir, mountpoint = '/sounds' })
            LOG('NuggetsLobby: mounted ' .. soundsDir .. ' at /sounds')
        end
    end
end
