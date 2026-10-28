-- Nuggets custom lobby: appended by the engine to the end of /lua/ui/dialogs/mapselect.lua
-- (the host's map and Options dialog), so it can use the file's own locals
-- (OptionContainer, Options).
--
-- FEATURE: hide lobby options of mods that are not active.
--   The filter itself lives in the lobby hook (NuggetsLobby_WithVisibleAIOpts).
--   RefreshOptions(true) is where the dialog reads the option lists; it runs
--   with only the visible mod options. If the lobby hook is not loaded, the
--   dialog behaves exactly as stock FAF.

do
    local function NuggetsLobbyFunction(name)
        local modules = rawget(_G, '__modules')
        local lobby = modules and modules['/lua/ui/lobby/lobby.lua']
        if lobby then
            return rawget(lobby, name)
        end
        return nil
    end

    local oldRefreshOptions = RefreshOptions
    if type(oldRefreshOptions) == 'function' then
        RefreshOptions = function(skipRefresh)
            local withVisible = skipRefresh and NuggetsLobbyFunction('NuggetsLobby_WithVisibleAIOpts')
            if withVisible then
                withVisible(oldRefreshOptions, skipRefresh)
            else
                oldRefreshOptions(skipRefresh)
            end
        end
    else
        WARN('NuggetsLobby: mapselect RefreshOptions not found, Options dialog unfiltered')
    end

    --- Called by the lobby hook after mods change. Rebuilds the option list of
    --- the open dialog; does nothing when the dialog is closed. Choices already
    --- made in the dialog are kept.
    function NuggetsLobby_RefreshModOptions()
        if OptionContainer and not IsDestroyed(OptionContainer) then
            RefreshOptions(true)
            OptionContainer.top = 0
            OptionContainer:CalcVisible()
        end
    end
end
