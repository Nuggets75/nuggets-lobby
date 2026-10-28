-- Nuggets custom lobby: the window frame of the lobby's own games (Snake, Sudoku).
-- Imported as /nuggetslobby/window.lua. Same panel textures, title font and drag
-- handles as the Minigames mod's windows, so all games in the lobby look alike.

local UIUtil        = import('/lua/ui/uiutil.lua')
local LayoutHelpers = import('/lua/maui/layouthelpers.lua')
local Bitmap        = import('/lua/maui/bitmap.lua').Bitmap
local Window        = import('/lua/maui/window.lua').Window

--- A movable, resizable window centred in `parent` the first time; afterwards it opens
--- where it was left (saved under `prefID`). Closing destroys it.
--- Sizes are in unscaled UI pixels.
function Create(parent, title, prefID, width, height, minWidth, minHeight)
    local textures = {
        tl = UIUtil.SkinnableFile('/game/panel/panel_brd_ul.dds'),
        tr = UIUtil.SkinnableFile('/game/panel/panel_brd_ur.dds'),
        tm = UIUtil.SkinnableFile('/game/panel/panel_brd_horz_um.dds'),
        ml = UIUtil.SkinnableFile('/game/panel/panel_brd_vert_l.dds'),
        m  = UIUtil.SkinnableFile('/game/panel/panel_brd_m.dds'),
        mr = UIUtil.SkinnableFile('/game/panel/panel_brd_vert_r.dds'),
        bl = UIUtil.SkinnableFile('/game/panel/panel_brd_ll.dds'),
        bm = UIUtil.SkinnableFile('/game/panel/panel_brd_lm.dds'),
        br = UIUtil.SkinnableFile('/game/panel/panel_brd_lr.dds'),
        borderColor = '00415055',
    }
    local w = LayoutHelpers.ScaleNumber(width)
    local h = LayoutHelpers.ScaleNumber(height)
    local left = math.floor(parent.Left() + (parent.Width() - w) / 2)
    local top  = math.floor(parent.Top() + (parent.Height() - h) / 2)

    local win = Window(parent, title, nil, false, false, false, false, prefID, {
        Left   = function() return left end,
        Top    = function() return top end,
        Right  = function() return left + w end,
        Bottom = function() return top + h end,
    }, textures)
    win:SetMinimumResize(minWidth, minHeight)
    -- on top of the windows that are already open
    local ok, top = pcall(function() return GetFrame(0):GetTopmostDepth() end)
    if ok and type(top) == 'number' then win.Depth:Set(top + 1) end

    win._title:SetFont('Arial Black', 14)
    win._title:DisableHitTest()
    LayoutHelpers.AtCenterIn(win._title, win.TitleGroup)

    local handles = {
        { '/game/drag-handle/drag-handle-ul_btn_up.dds', 'AtLeftTopIn',     -24, -8 },
        { '/game/drag-handle/drag-handle-ur_btn_up.dds', 'AtRightTopIn',    -22, -8 },
        { '/game/drag-handle/drag-handle-ll_btn_up.dds', 'AtLeftBottomIn',  -24, -8 },
        { '/game/drag-handle/drag-handle-lr_btn_up.dds', 'AtRightBottomIn', -22, -8 },
    }
    for i = 1, table.getn(handles) do
        local def = handles[i]
        local handle = Bitmap(win, UIUtil.SkinnableFile(def[1]))
        LayoutHelpers[def[2]](handle, win, def[3], def[4])
        LayoutHelpers.DepthOverParent(handle, win, 10)
        handle:DisableHitTest()
    end

    win.OnClose = function(self)
        self:Destroy()
    end
    return win
end
