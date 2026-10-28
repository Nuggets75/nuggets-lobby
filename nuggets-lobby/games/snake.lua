-- Nuggets custom lobby: Snake (singleplayer). Imported as /nuggetslobby/snake.lua.
--
-- Arrow keys or WASD steer, Space or Escape pauses. Eat the red food to grow; hitting a
-- wall or yourself ends the run. The lobby normally keeps the keyboard on its chat box;
-- while a run is going the board borrows it (NuggetsLobby_BorrowKeyboard in the lobby
-- hook) and gives it back when the run ends, pauses or the window closes.
-- With "Steer with the mouse" on, the snake turns toward the cursor instead.
-- Moves on wall-clock time from the board's frame updates (CurrentTime).

local UIUtil        = import('/lua/ui/uiutil.lua')
local LayoutHelpers = import('/lua/maui/layouthelpers.lua')
local Bitmap        = import('/lua/maui/bitmap.lua').Bitmap
local Prefs         = import('/lua/user/prefs.lua')
local Frame         = import('/nuggetslobby/window.lua')

local C = {
    GRID        = 20,
    STEP_START  = 0.15,   -- seconds per move at the start
    STEP_MIN    = 0.06,   -- fastest
    STEP_FASTER = 0.004,  -- each food eaten makes moves this much quicker
    PAD         = 8,
    HEADER      = 30,
    FOOTER      = 26,
    PREF_BEST   = 'NuggetsLobby_SnakeBest',
    PREF_MOUSE  = 'NuggetsLobby_SnakeMouse',
    COL_BOARD   = 'ff0a1a2e',
    COL_EMPTY   = 'ff16283a',
    COL_BODY    = 'ff3fae4a',
    COL_HEAD    = 'ff9be36b',
    COL_FOOD    = 'ffd84040',
    COL_DEAD    = 'ffaa3333',
}

local UP, DOWN, LEFT, RIGHT = 1, 2, 3, 4
local DR = { -1, 1, 0, 0 }
local DC = { 0, 0, -1, 1 }
local OPPOSITE = { DOWN, UP, RIGHT, LEFT }

-- KeyCode -> direction (arrow keys and WASD)
local KEYS = { [38] = UP, [87] = UP, [40] = DOWN, [83] = DOWN, [37] = LEFT, [65] = LEFT, [39] = RIGHT, [68] = RIGHT }
local KEY_SPACE  = 32
local KEY_ESCAPE = 27

----------------------------------------------------------------------------
-- Rules (no UI)
----------------------------------------------------------------------------

Logic = {}

-- rand(n) returns a whole number from 1 to n
function Logic.New(size, rand)
    local g = {
        size = size, snake = {}, occupied = {}, dir = RIGHT, queue = {},
        alive = true, score = 0, rand = rand or math.random,
    }
    for r = 1, size do g.occupied[r] = {} end
    local mid = math.floor(size / 2) + 1
    for i = 0, 2 do
        local seg = { r = mid, c = mid - i }
        table.insert(g.snake, seg)
        g.occupied[seg.r][seg.c] = true
    end
    Logic.PlaceFood(g)
    return g
end

function Logic.PlaceFood(g)
    local free = {}
    for r = 1, g.size do
        for c = 1, g.size do
            if not g.occupied[r][c] then table.insert(free, { r = r, c = c }) end
        end
    end
    local n = table.getn(free)
    if n == 0 then
        g.food = nil
    else
        g.food = free[g.rand(n)]
    end
end

-- Queues a turn. Up to two turns wait, so a quick double press is not lost; turning
-- back into yourself and repeating the current direction are ignored.
function Logic.Turn(g, dir)
    local n = table.getn(g.queue)
    local last = g.queue[n] or g.dir
    if dir == last or dir == OPPOSITE[last] or n >= 2 then return false end
    table.insert(g.queue, dir)
    return true
end

-- One move. Returns 'move', 'eat', 'win' or 'dead', plus the cells to repaint.
function Logic.Step(g)
    if not g.alive then return 'dead', {} end
    if table.getn(g.queue) > 0 then
        g.dir = table.remove(g.queue, 1)
    end
    local head = g.snake[1]
    local nr = head.r + DR[g.dir]
    local nc = head.c + DC[g.dir]
    if nr < 1 or nr > g.size or nc < 1 or nc > g.size then
        g.alive = false
        return 'dead', {}
    end
    local eating = g.food ~= nil and nr == g.food.r and nc == g.food.c
    local changed = {}
    -- the tail moves away first, so following your own tail is allowed
    local tail = nil
    if not eating then
        tail = table.remove(g.snake)
        g.occupied[tail.r][tail.c] = nil
    end
    if g.occupied[nr][nc] then
        g.alive = false
        if tail then
            table.insert(g.snake, tail)
            g.occupied[tail.r][tail.c] = true
        end
        return 'dead', {}
    end
    if tail then table.insert(changed, tail) end
    table.insert(g.snake, 1, { r = nr, c = nc })
    g.occupied[nr][nc] = true
    table.insert(changed, head)
    table.insert(changed, g.snake[1])
    if eating then
        g.score = g.score + 1
        Logic.PlaceFood(g)
        if g.food == nil then
            g.alive = false
            return 'win', changed
        end
        table.insert(changed, g.food)
        return 'eat', changed
    end
    return 'move', changed
end

function Logic.StepTime(score)
    return math.max(C.STEP_MIN, C.STEP_START - score * C.STEP_FASTER)
end

-- The direction from the head toward a point given in cells (row, column; the centre
-- of cell r is r). Never straight back; nil when the point is on the head.
function Logic.Toward(g, pr, pc)
    local head = g.snake[1]
    local dr = pr - head.r
    local dc = pc - head.c
    if math.abs(dr) < 0.5 and math.abs(dc) < 0.5 then return nil end
    local primary, secondary
    if math.abs(dc) >= math.abs(dr) then
        if dc > 0 then primary = RIGHT else primary = LEFT end
        if dr > 0 then secondary = DOWN else secondary = UP end
    else
        if dr > 0 then primary = DOWN else primary = UP end
        if dc > 0 then secondary = RIGHT else secondary = LEFT end
    end
    if primary == OPPOSITE[g.dir] then return secondary end
    return primary
end

----------------------------------------------------------------------------
-- Keyboard: borrowed from the lobby's chat box during a run
----------------------------------------------------------------------------

local function LobbyFn(name)
    local modules = rawget(_G, '__modules')
    local lobby = modules and modules['/lua/ui/lobby/lobby.lua']
    if lobby then return rawget(lobby, name) end
    return nil
end

local function TakeKeyboard(control)
    local fn = LobbyFn('NuggetsLobby_BorrowKeyboard')
    if fn then
        local ok, err = pcall(fn, control)
        if not ok then WARN('NuggetsLobby: Snake could not take the keyboard: ' .. tostring(err)) end
    end
end

local function GiveKeyboard(control)
    local fn = LobbyFn('NuggetsLobby_ReturnKeyboard')
    if fn then
        local ok, err = pcall(fn, control)
        if not ok then WARN('NuggetsLobby: Snake could not return the keyboard: ' .. tostring(err)) end
    end
end

----------------------------------------------------------------------------
-- Window
----------------------------------------------------------------------------

local win = nil

local function S(n) return LayoutHelpers.ScaleNumber(n) end

local function LoadBest()
    local v = tonumber(Prefs.GetFromCurrentProfile(C.PREF_BEST))
    if v and v > 0 then return math.floor(v) end
    return 0
end

--- Opens the Snake window on `parent` (the lobby's minigame layer), or returns the open one.
function Open(parent)
    if win ~= nil and not IsDestroyed(win) then return win end
    win = Frame.Create(parent, 'Snake', 'NuggetsLobby_SnakeWindow', 420, 520, 300, 390)
    local client = win:GetClientGroup()

    local state = 'ready'      -- ready | running | paused | over
    local g = Logic.New(C.GRID)
    local nextAt = 0
    local best = LoadBest()
    local mouseSteer = Prefs.GetFromCurrentProfile(C.PREF_MOUSE) == true
    local mouseX, mouseY = nil, nil

    local scoreLabel = UIUtil.CreateText(client, '', 14, 'Arial Bold', true)
    LayoutHelpers.AtLeftTopIn(scoreLabel, client, C.PAD + 4, C.PAD + 4)
    scoreLabel:DisableHitTest()

    local btnNew = UIUtil.CreateButtonWithDropshadow(client, '/BUTTON/medium/', 'New Game')
    LayoutHelpers.AtRightTopIn(btnNew, client, C.PAD, C.PAD - 4)
    LayoutHelpers.DepthOverParent(btnNew, client, 5)

    local status = UIUtil.CreateText(client, '', 12, 'Arial', true)
    LayoutHelpers.AtLeftIn(status, client, C.PAD + 4)
    status.Top:Set(function() return client.Top() + S(C.PAD + C.HEADER) end)
    status:DisableHitTest()

    -- square board, as large as the window allows
    local cell = function()
        local w = client.Width() - S(C.PAD * 2)
        local h = client.Height() - S(C.PAD * 3 + C.HEADER + 18 + C.FOOTER)
        local size = math.min(w, h)
        return math.max(4, math.floor(size / C.GRID))
    end
    local board = Bitmap(client)
    board:SetSolidColor(C.COL_BOARD)
    board.Width:Set(function() return cell() * C.GRID end)
    board.Height:Set(function() return cell() * C.GRID end)
    board.Left:Set(function() return client.Left() + math.floor((client.Width() - board.Width()) / 2) end)
    board.Top:Set(function() return client.Top() + S(C.PAD * 2 + C.HEADER + 18) end)
    LayoutHelpers.DepthOverParent(board, client, 2)

    local tiles = {}
    for r = 1, C.GRID do
        tiles[r] = {}
        for c = 1, C.GRID do
            local fr, fc = r, c
            local tile = Bitmap(board)
            tile.Left:Set(function() return board.Left() + (fc - 1) * cell() + 1 end)
            tile.Top:Set(function() return board.Top() + (fr - 1) * cell() + 1 end)
            tile.Width:Set(function() return cell() - 2 end)
            tile.Height:Set(function() return cell() - 2 end)
            LayoutHelpers.DepthOverParent(tile, board, 1)
            tile:SetSolidColor(C.COL_EMPTY)
            tile:DisableHitTest()
            tiles[r][c] = tile
        end
    end

    local mouseBox = UIUtil.CreateCheckbox(client, '/CHECKBOX/', 'Steer with the mouse', true, 12)
    LayoutHelpers.AtLeftIn(mouseBox, client, C.PAD + 2)
    mouseBox.Top:Set(function() return board.Bottom() + S(6) end)
    LayoutHelpers.DepthOverParent(mouseBox, client, 5)
    mouseBox:SetCheck(mouseSteer, true)
    mouseBox.OnCheck = function(self, checked)
        mouseSteer = checked and true or false
        Prefs.SetToCurrentProfile(C.PREF_MOUSE, mouseSteer)
        SavePreferences()
    end

    local function Paint(r, c)
        local color = C.COL_EMPTY
        if g.occupied[r][c] then
            local head = g.snake[1]
            if head.r == r and head.c == c then
                if g.alive then color = C.COL_HEAD else color = C.COL_DEAD end
            else
                color = C.COL_BODY
            end
        elseif g.food and g.food.r == r and g.food.c == c then
            color = C.COL_FOOD
        end
        tiles[r][c]:SetSolidColor(color)
    end

    local function PaintAll()
        for r = 1, C.GRID do
            for c = 1, C.GRID do Paint(r, c) end
        end
    end

    local function ShowScore()
        scoreLabel:SetText('Length ' .. table.getn(g.snake) .. '    Food ' .. g.score .. '    Best ' .. best)
    end

    local function SetStatus(text)
        status:SetText(text)
    end

    local function Pause()
        if state ~= 'running' then return end
        state = 'paused'
        GiveKeyboard(board)
        SetStatus('Paused. Click the board to continue.')
    end

    local function Start()
        if state == 'over' then
            g = Logic.New(C.GRID)
            PaintAll()
            ShowScore()
        end
        state = 'running'
        nextAt = CurrentTime() + Logic.StepTime(g.score)
        if mouseSteer then
            SetStatus('Steering with the mouse. Space or a click pauses.')
        else
            SetStatus('Arrow keys or WASD steer. Space pauses.')
        end
        TakeKeyboard(board)
    end

    local function End(won)
        state = 'over'
        GiveKeyboard(board)
        local newBest = g.score > best
        if newBest then
            best = g.score
            Prefs.SetToCurrentProfile(C.PREF_BEST, best)
            SavePreferences()
        end
        PaintAll()
        ShowScore()
        local line
        if won then
            line = 'You filled the whole board with ' .. g.score .. ' food!'
        else
            line = 'Game over after ' .. g.score .. ' food.'
        end
        if newBest then line = line .. ' New best!' end
        SetStatus(line .. ' Click the board to play again.')
    end

    local function SteerToMouse()
        if not mouseSteer or mouseX == nil then return end
        local size = cell()
        local pr = (mouseY - board.Top()) / size + 0.5
        local pc = (mouseX - board.Left()) / size + 0.5
        local dir = Logic.Toward(g, pr, pc)
        g.queue = {}
        if dir ~= nil and dir ~= g.dir then
            table.insert(g.queue, dir)
        end
    end

    local function Step()
        SteerToMouse()
        local result, changed = Logic.Step(g)
        for i = 1, table.getn(changed) do
            Paint(changed[i].r, changed[i].c)
        end
        if result == 'dead' then
            End(false)
        elseif result == 'win' then
            End(true)
        else
            ShowScore()
        end
    end

    board.OnFrame = function(self, delta)
        if state ~= 'running' then return end
        local now = CurrentTime()
        if now < nextAt then return end
        local ok, err = pcall(Step)
        if not ok then
            WARN('NuggetsLobby: Snake failed: ' .. tostring(err))
            state = 'over'
            GiveKeyboard(board)
            SetStatus('Snake stopped after an error, see the game log.')
            return
        end
        nextAt = now + Logic.StepTime(g.score)
    end
    board:SetNeedsFrameUpdate(true)

    board.HandleEvent = function(self, event)
        local t = event.Type
        if t == 'ButtonPress' then
            if state == 'running' then Pause() else Start() end
            return true
        elseif t == 'MouseMotion' or t == 'MouseEnter' then
            mouseX, mouseY = event.MouseX, event.MouseY
        elseif t == 'MouseExit' then
            mouseX, mouseY = nil, nil
        elseif t == 'KeyDown' then
            local code = event.KeyCode
            if KEYS[code] then
                if state == 'running' and not mouseSteer then Logic.Turn(g, KEYS[code]) end
                return true
            elseif code == KEY_SPACE then
                if state == 'running' then Pause() else Start() end
                return true
            elseif code == KEY_ESCAPE then
                Pause()
                return true
            end
        end
        return false
    end

    local oldOnDestroy = board.OnDestroy
    board.OnDestroy = function(self)
        GiveKeyboard(self)
        if oldOnDestroy then oldOnDestroy(self) end
    end

    btnNew.OnClick = function(self, modifiers)
        GiveKeyboard(board)
        g = Logic.New(C.GRID)
        state = 'ready'
        PaintAll()
        ShowScore()
        SetStatus('Click the board to start.')
    end

    PaintAll()
    ShowScore()
    SetStatus('Click the board to start.')
    return win
end
