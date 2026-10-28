-- Nuggets custom lobby: Sudoku (singleplayer). Imported as /nuggetslobby/sudoku.lua.
--
-- Click a cell, then a number below the board; right-click a cell (or pick X) to clear
-- it. Numbers that clash with another in the same row, column or 3x3 box turn red.
-- Every puzzle has exactly one solution: a full grid is filled at random, then numbers
-- are taken out one by one as long as the solution stays unique. That runs in a thread
-- that pauses now and then, so the lobby does not freeze while a puzzle is made.

local UIUtil        = import('/lua/ui/uiutil.lua')
local LayoutHelpers = import('/lua/maui/layouthelpers.lua')
local Bitmap        = import('/lua/maui/bitmap.lua').Bitmap
local Prefs         = import('/lua/user/prefs.lua')
local Frame         = import('/nuggetslobby/window.lua')

local C = {
    -- numbers left on the board per difficulty; the digging stops earlier if taking out
    -- one more would allow a second solution
    LEVELS     = {
        { name = 'Easy',   clues = 38 },
        { name = 'Medium', clues = 31 },
        { name = 'Hard',   clues = 26 },
    },
    PAD        = 8,
    HEADER     = 30,
    BOX_GAP    = 3,       -- extra space between the 3x3 boxes
    PREF_BEST  = 'NuggetsLobby_SudokuBest',   -- { Easy = seconds, ... }
    COL_BOARD  = 'ff0a1a2e',
    COL_CELL   = 'ff1c3048',
    COL_PEER   = 'ff24405c',   -- same row, column or box as the selected cell
    COL_SAME   = 'ff2f5a7a',   -- same number as the selected cell
    COL_SEL    = 'ff4a7fb0',
    COL_PAD    = 'ff2a4a6a',
    COL_PAD_HOVER = 'ff3a6a9a',
    TXT_GIVEN  = 'ffffffff',
    TXT_ENTRY  = 'ff8fd0ff',
    TXT_BAD    = 'ffff5555',
}

----------------------------------------------------------------------------
-- Rules (no UI). A grid is a list of 81 numbers, 0 = empty, row by row.
----------------------------------------------------------------------------

Logic = {}

local function Index(r, c) return (r - 1) * 9 + c end
local function RowOf(i) return math.floor((i - 1) / 9) + 1 end
local function ColOf(i) return i - (RowOf(i) - 1) * 9 end
local function BoxStart(n) return math.floor((n - 1) / 3) * 3 + 1 end

-- can `v` go in cell i (ignoring what is in cell i itself)?
function Logic.Allowed(grid, i, v)
    local r, c = RowOf(i), ColOf(i)
    for k = 1, 9 do
        local ri = Index(r, k)
        if ri ~= i and grid[ri] == v then return false end
        local ci = Index(k, c)
        if ci ~= i and grid[ci] == v then return false end
    end
    local br, bc = BoxStart(r), BoxStart(c)
    for rr = br, br + 2 do
        for cc = bc, bc + 2 do
            local bi = Index(rr, cc)
            if bi ~= i and grid[bi] == v then return false end
        end
    end
    return true
end

local function Candidates(grid, i)
    local list = {}
    for v = 1, 9 do
        if Logic.Allowed(grid, i, v) then table.insert(list, v) end
    end
    return list
end

-- the empty cell with the fewest candidates; nil when the grid is full,
-- false when some empty cell has none
local function MostConstrained(grid)
    local best, bestList = nil, nil
    for i = 1, 81 do
        if grid[i] == 0 then
            local list = Candidates(grid, i)
            local n = table.getn(list)
            if n == 0 then return false, nil end
            if best == nil or n < table.getn(bestList) then
                best, bestList = i, list
                if n == 1 then break end
            end
        end
    end
    return best, bestList
end

local function Shuffle(list, rand)
    for i = table.getn(list), 2, -1 do
        local j = rand(i)
        list[i], list[j] = list[j], list[i]
    end
    return list
end

-- fills every empty cell with a random valid number; true on success
function Logic.Fill(grid, rand)
    local i, list = MostConstrained(grid)
    if i == nil then return true end
    if i == false then return false end
    Shuffle(list, rand)
    for k = 1, table.getn(list) do
        grid[i] = list[k]
        if Logic.Fill(grid, rand) then return true end
    end
    grid[i] = 0
    return false
end

-- number of solutions, counting no further than `limit`. Leaves the grid as it was.
function Logic.CountSolutions(grid, limit)
    local i, list = MostConstrained(grid)
    if i == nil then return 1 end
    if i == false then return 0 end
    local count = 0
    for k = 1, table.getn(list) do
        grid[i] = list[k]
        count = count + Logic.CountSolutions(grid, limit - count)
        if count >= limit then break end
    end
    grid[i] = 0
    return count
end

-- Returns puzzle, solution and the number of clues left. `pause(k)` is called after
-- each of the 81 attempts to take a number out (the window passes one that waits).
function Logic.Generate(clues, rand, pause)
    local solution = {}
    for i = 1, 81 do solution[i] = 0 end
    Logic.Fill(solution, rand)
    local puzzle = {}
    for i = 1, 81 do puzzle[i] = solution[i] end
    local order = {}
    for i = 1, 81 do order[i] = i end
    Shuffle(order, rand)
    local left = 81
    for k = 1, 81 do
        if left <= clues then break end
        local i = order[k]
        local keep = puzzle[i]
        puzzle[i] = 0
        if Logic.CountSolutions(puzzle, 2) == 1 then
            left = left - 1
        else
            puzzle[i] = keep
        end
        if pause then pause(k) end
    end
    return puzzle, solution, left
end

-- set of cell indices whose number clashes with another in its row, column or box
function Logic.Conflicts(grid)
    local bad = {}
    for i = 1, 81 do
        local v = grid[i]
        if v ~= 0 and not Logic.Allowed(grid, i, v) then bad[i] = true end
    end
    return bad
end

function Logic.Solved(grid, solution)
    for i = 1, 81 do
        if grid[i] ~= solution[i] then return false end
    end
    return true
end

local function TimeText(seconds)
    seconds = math.floor(seconds)
    local m = math.floor(seconds / 60)
    local s = seconds - m * 60
    if s < 10 then return m .. ':0' .. s end
    return m .. ':' .. s
end
Logic.TimeText = TimeText

----------------------------------------------------------------------------
-- Window
----------------------------------------------------------------------------

local win = nil

local function S(n) return LayoutHelpers.ScaleNumber(n) end

local function LoadBest()
    local saved = Prefs.GetFromCurrentProfile(C.PREF_BEST)
    local best = {}
    if type(saved) == 'table' then
        for i = 1, table.getn(C.LEVELS) do
            local name = C.LEVELS[i].name
            local v = tonumber(saved[name])
            if v and v > 0 then best[name] = v end
        end
    end
    return best
end

--- Opens the Sudoku window on `parent` (the lobby's minigame layer), or returns the open one.
function Open(parent)
    if win ~= nil and not IsDestroyed(win) then return win end
    win = Frame.Create(parent, 'Sudoku', 'NuggetsLobby_SudokuWindow', 440, 560, 340, 450)
    local client = win:GetClientGroup()

    local level = 2
    local puzzle, solution, grid = nil, nil, nil
    local selected = nil
    local state = 'making'     -- making | playing | solved
    local startedAt = 0
    local shownSecond = -1
    local token = 0
    local best = LoadBest()

    -- difficulty buttons
    local levelButtons = {}
    local prevButton = nil
    for i = 1, table.getn(C.LEVELS) do
        local btn = UIUtil.CreateButtonWithDropshadow(client, '/BUTTON/medium/', C.LEVELS[i].name)
        if prevButton == nil then
            LayoutHelpers.AtLeftTopIn(btn, client, 0, C.PAD - 4)
        else
            LayoutHelpers.RightOf(btn, prevButton, -6)
        end
        LayoutHelpers.DepthOverParent(btn, client, 5)
        levelButtons[i] = btn
        prevButton = btn
    end

    local status = UIUtil.CreateText(client, '', 13, 'Arial Bold', true)
    LayoutHelpers.AtLeftIn(status, client, C.PAD + 4)
    status.Top:Set(function() return levelButtons[1].Bottom() + S(4) end)
    status:DisableHitTest()

    -- board: 9 cells plus two box gaps across, then a row of 10 number buttons below
    local cell = function()
        local w = client.Width() - S(C.PAD * 2)
        local h = client.Bottom() - status.Bottom() - S(C.PAD * 3)
        local byWidth = (w - S(C.BOX_GAP * 2)) / 10
        local byHeight = (h - S(C.BOX_GAP * 2)) / 10.4
        return math.max(10, math.floor(math.min(byWidth, byHeight)))
    end
    local gap = function() return S(C.BOX_GAP) end

    local board = Bitmap(client)
    board:SetSolidColor(C.COL_BOARD)
    board.Width:Set(function() return cell() * 9 + gap() * 2 end)
    board.Height:Set(function() return cell() * 9 + gap() * 2 end)
    board.Left:Set(function() return client.Left() + math.floor((client.Width() - board.Width()) / 2) end)
    board.Top:Set(function() return status.Bottom() + S(C.PAD) end)
    LayoutHelpers.DepthOverParent(board, client, 2)
    board:DisableHitTest()

    local cells = {}
    local Select, SetValue

    for i = 1, 81 do
        local fi = i
        local r, c = RowOf(i), ColOf(i)
        local bg = Bitmap(board)
        bg.Left:Set(function() return board.Left() + (c - 1) * cell() + math.floor((c - 1) / 3) * gap() + 1 end)
        bg.Top:Set(function() return board.Top() + (r - 1) * cell() + math.floor((r - 1) / 3) * gap() + 1 end)
        bg.Width:Set(function() return cell() - 2 end)
        bg.Height:Set(function() return cell() - 2 end)
        LayoutHelpers.DepthOverParent(bg, board, 1)
        bg:SetSolidColor(C.COL_CELL)

        local txt = UIUtil.CreateText(board, '', 18, 'Arial Bold', true)
        LayoutHelpers.AtCenterIn(txt, bg)
        LayoutHelpers.DepthOverParent(txt, board, 2)
        txt:DisableHitTest()

        bg.HandleEvent = function(self, event)
            if event.Type == 'ButtonPress' then
                if event.Modifiers.Right then
                    Select(fi)
                    SetValue(0)
                else
                    Select(fi)
                end
                return true
            end
            return false
        end
        cells[i] = { bg = bg, txt = txt }
    end

    -- number pad: 1-9 and X (clear)
    local pad = {}
    for k = 1, 10 do
        local fk = k
        local tile = Bitmap(client)
        tile.Width:Set(function() return cell() - 2 end)
        tile.Height:Set(function() return cell() - 2 end)
        tile.Left:Set(function()
            local rowWidth = cell() * 10
            return client.Left() + math.floor((client.Width() - rowWidth) / 2) + (fk - 1) * cell() + 1
        end)
        tile.Top:Set(function() return board.Bottom() + S(C.PAD) end)
        LayoutHelpers.DepthOverParent(tile, client, 2)
        tile:SetSolidColor(C.COL_PAD)

        local label = 'X'
        if k <= 9 then label = tostring(k) end
        local txt = UIUtil.CreateText(client, label, 18, 'Arial Bold', true)
        LayoutHelpers.AtCenterIn(txt, tile)
        LayoutHelpers.DepthOverParent(txt, client, 3)
        txt:DisableHitTest()

        tile.HandleEvent = function(self, event)
            if event.Type == 'MouseEnter' then
                self:SetSolidColor(C.COL_PAD_HOVER)
            elseif event.Type == 'MouseExit' then
                self:SetSolidColor(C.COL_PAD)
            elseif event.Type == 'ButtonPress' then
                if fk <= 9 then SetValue(fk) else SetValue(0) end
                return true
            end
            return false
        end
        pad[k] = tile
    end

    local function Repaint()
        if grid == nil then
            for i = 1, 81 do
                cells[i].bg:SetSolidColor(C.COL_CELL)
                cells[i].txt:SetText('')
            end
            return
        end
        local bad = Logic.Conflicts(grid)
        local selValue = 0
        local sr, sc, sbr, sbc = nil, nil, nil, nil
        if selected then
            selValue = grid[selected]
            sr, sc = RowOf(selected), ColOf(selected)
            sbr, sbc = BoxStart(sr), BoxStart(sc)
        end
        for i = 1, 81 do
            local r, c = RowOf(i), ColOf(i)
            local color = C.COL_CELL
            if selected then
                if i == selected then
                    color = C.COL_SEL
                elseif selValue ~= 0 and grid[i] == selValue then
                    color = C.COL_SAME
                elseif r == sr or c == sc or (BoxStart(r) == sbr and BoxStart(c) == sbc) then
                    color = C.COL_PEER
                end
            end
            cells[i].bg:SetSolidColor(color)
            local v = grid[i]
            if v == 0 then
                cells[i].txt:SetText('')
            else
                cells[i].txt:SetText(tostring(v))
                if bad[i] then
                    cells[i].txt:SetColor(C.TXT_BAD)
                elseif puzzle[i] ~= 0 then
                    cells[i].txt:SetColor(C.TXT_GIVEN)
                else
                    cells[i].txt:SetColor(C.TXT_ENTRY)
                end
            end
        end
    end

    local function LevelName() return C.LEVELS[level].name end

    local function BestText()
        local b = best[LevelName()]
        if b then return '   Best ' .. TimeText(b) end
        return ''
    end

    local function ShowTime()
        local seconds = math.floor(CurrentTime() - startedAt)
        if seconds == shownSecond then return end
        shownSecond = seconds
        status:SetText(LevelName() .. '   ' .. TimeText(seconds) .. BestText())
    end

    Select = function(i)
        if state ~= 'playing' then return end
        selected = i
        Repaint()
    end

    SetValue = function(v)
        if state ~= 'playing' or selected == nil then return end
        if puzzle[selected] ~= 0 then return end   -- the puzzle's own numbers stay
        grid[selected] = v
        Repaint()
        if Logic.Solved(grid, solution) then
            state = 'solved'
            local seconds = math.floor(CurrentTime() - startedAt)
            local name = LevelName()
            local line = 'Solved ' .. name .. ' in ' .. TimeText(seconds) .. '!'
            if best[name] == nil or seconds < best[name] then
                best[name] = seconds
                local copy = {}
                for key, value in best do copy[key] = value end
                Prefs.SetToCurrentProfile(C.PREF_BEST, copy)
                SavePreferences()
                line = line .. ' New best.'
            else
                line = line .. ' Best ' .. TimeText(best[name]) .. '.'
            end
            status:SetText(line)
        end
    end

    local function NewPuzzle(newLevel)
        level = newLevel
        token = token + 1
        local myToken = token
        state = 'making'
        selected = nil
        grid = nil
        Repaint()
        status:SetText('Making a ' .. LevelName() .. ' puzzle...')
        ForkThread(function()
            local made, answer = Logic.Generate(C.LEVELS[newLevel].clues, math.random, function(k)
                if k - math.floor(k / 3) * 3 == 0 then WaitSeconds(0.01) end
            end)
            if myToken ~= token or IsDestroyed(board) then return end
            puzzle = made
            solution = answer
            grid = {}
            for i = 1, 81 do grid[i] = made[i] end
            state = 'playing'
            startedAt = CurrentTime()
            shownSecond = -1
            Repaint()
            ShowTime()
        end)
    end

    for i = 1, table.getn(levelButtons) do
        local fi = i
        levelButtons[i].OnClick = function(self, modifiers) NewPuzzle(fi) end
    end

    board.OnFrame = function(self, delta)
        if state == 'playing' then ShowTime() end
    end
    board:SetNeedsFrameUpdate(true)

    pcall(function() math.randomseed(math.floor(GetSystemTimeSeconds() * 1000)) end)
    NewPuzzle(level)
    return win
end
