-- Nuggets custom lobby: the look of the lobby's game windows (the Minigames window and
-- Liar's Dice). Imported as /nuggetslobby/ui.lua.
--
-- Everything is placed at fixed, unscaled positions inside its parent (scaled with the
-- UI scale), so a window looks the same at every resolution. Buttons and panels are flat
-- colours with a soft gloss texture; text is the game's Arial.
--
-- Showing a control in this engine shows all of its children again, so the windows set
-- the visibility of everything on each update, parents first (see Show).

local UIUtil        = import('/lua/ui/uiutil.lua')
local LayoutHelpers = import('/lua/maui/layouthelpers.lua')
local Bitmap        = import('/lua/maui/bitmap.lua').Bitmap
local Group         = import('/lua/maui/group.lua').Group
local Dragger       = import('/lua/maui/dragger.lua').Dragger
local Prefs         = import('/lua/user/prefs.lua')

ART = '/nuggetslobby/art/'

COLORS = {
    shadow   = '66000000',
    bg       = 'ff161b21',
    bg2      = 'ff1b2128',
    nav      = 'ff12161b',
    title    = 'ff0e1216',
    panel    = 'ff1f262e',
    panelHi  = 'ff27303a',
    row      = 'ff222a33',
    rowHi    = 'ff2b3540',
    line     = 'ff333e49',
    lineHi   = 'ff4a5867',
    text     = 'ffe8ebee',
    dim      = 'ffa3adb8',
    faint    = 'ff6e7984',
    accent   = 'fff2b632',
    accentBg = 'ff3a2e14',
    good     = 'ff5cc46e',
    bad      = 'ffe55a4e',
    info     = 'ff58b6ff',
    overlay  = 'b0000000',
}

BUTTONS = {
    primary  = { up = 'ff2c8a4b', over = 'ff35a058', down = 'ff23703c', text = 'ffffffff', edge = 'ff1b5a2f' },
    danger   = { up = 'ffb3383a', over = 'ffcb4442', down = 'ff932c2e', text = 'ffffffff', edge = 'ff6f1f21' },
    gold     = { up = 'ffd09322', over = 'ffe6a62c', down = 'ffae7a19', text = 'ff221804', edge = 'ff7d5710' },
    normal   = { up = 'ff36424f', over = 'ff435263', down = 'ff2c3641', text = 'ffe8ebee', edge = 'ff232b33' },
    ghost    = { up = '00000000', over = 'ff2c3640', down = 'ff222a32', text = 'ffc9d1d9', edge = '00000000' },
    tab      = { up = '00000000', over = 'ff1e252d', down = 'ff1a2027', text = 'ffc9d1d9', edge = '00000000' },
    tabOn    = { up = 'ff222a33', over = 'ff222a33', down = 'ff222a33', text = 'ffffffff', edge = '00000000' },
}
DISABLED = { up = 'ff262d35', text = 'ff69737d', edge = 'ff1e242a' }

FONT      = 'Arial'
FONT_BOLD = 'Arial Bold'
FONT_BIG  = 'Arial Black'

function S(n) return LayoutHelpers.ScaleNumber(n) end

----------------------------------------------------------------------------
-- placing
----------------------------------------------------------------------------

--- Puts `control` at (x, y) inside `parent` (unscaled pixels); w, h set the size when given.
function Place(control, parent, x, y, w, h)
    control.Left:Set(function() return parent.Left() + S(x) end)
    control.Top:Set(function() return parent.Top() + S(y) end)
    if w then control.Width:Set(S(w)) end
    if h then control.Height:Set(S(h)) end
end

--- Depth `n` above `parent`.
function Over(control, parent, n)
    LayoutHelpers.DepthOverParent(control, parent, n or 1)
end

--- Shows or hides a control. Showing also shows its children, so set children after.
function Show(control, on)
    if control == nil then return end
    if on then
        if control:IsHidden() then control:Show() end
    else
        if not control:IsHidden() then control:Hide() end
    end
end

function NewGroup(parent, x, y, w, h, depth)
    local g = Group(parent)
    Place(g, parent, x, y, w, h)
    Over(g, parent, depth or 1)
    g:DisableHitTest()
    return g
end

--- A solid rectangle (no mouse).
function Rect(parent, color, x, y, w, h, depth)
    local b = Bitmap(parent)
    b:SetSolidColor(color)
    b:DisableHitTest()
    Place(b, parent, x, y, w, h)
    Over(b, parent, depth or 1)
    return b
end

--- A texture stretched to (w, h) (no mouse).
function Image(parent, texture, x, y, w, h, depth)
    local b = Bitmap(parent, texture)
    b:DisableHitTest()
    Place(b, parent, x, y, w, h)
    Over(b, parent, depth or 2)
    return b
end

--- A 1 px frame round (x, y, w, h). Returns its four lines (call SetColor on them).
function Border(parent, color, x, y, w, h, depth, thickness)
    local t = thickness or 1
    local lines = {
        Rect(parent, color, x, y, w, t, depth),
        Rect(parent, color, x, y + h - t, w, t, depth),
        Rect(parent, color, x, y, t, h, depth),
        Rect(parent, color, x + w - t, y, t, h, depth),
    }
    lines.SetColor = function(self, c)
        for i = 1, 4 do self[i]:SetSolidColor(c) end
    end
    lines.SetShown = function(self, on)
        for i = 1, 4 do Show(self[i], on) end
    end
    return lines
end

--- A panel: background, a soft gloss and a border.
function Panel(parent, x, y, w, h, color, borderColor, depth)
    local d = depth or 1
    local p = {}
    p.bg = Rect(parent, color or COLORS.panel, x, y, w, h, d)
    p.gloss = Image(parent, ART .. 'gloss.png', x, y, w, math.min(h, 40), d + 1)
    p.gloss:SetAlpha(0.35)
    p.border = Border(parent, borderColor or COLORS.line, x, y, w, h, d + 1)
    p.SetColors = function(self, bgColor, lineColor)
        if bgColor then self.bg:SetSolidColor(bgColor) end
        if lineColor then self.border:SetColor(lineColor) end
    end
    p.SetShown = function(self, on)
        Show(self.bg, on)
        Show(self.gloss, on)
        self.border:SetShown(on)
    end
    return p
end

----------------------------------------------------------------------------
-- text
----------------------------------------------------------------------------

function Label(parent, text, size, color, font, x, y, depth)
    local t = UIUtil.CreateText(parent, text or '', size or 13, font or FONT, false)
    t:SetColor(color or COLORS.text)
    t:DisableHitTest()
    Place(t, parent, x or 0, y or 0)
    Over(t, parent, depth or 6)
    return t
end

--- Centres a label horizontally on parent.Left + x + w / 2 (keeps its Top).
function CenterX(label, parent, x, w)
    label.Left:Set(function() return parent.Left() + S(x) + math.floor((S(w) - label.Width()) / 2) end)
end

--- Right-aligns a label so it ends at parent.Left + x.
function RightAt(label, parent, x)
    label.Left:Set(function() return parent.Left() + S(x) - label.Width() end)
end

--- SetText / SetColor / SetTexture that do nothing when the value is unchanged (the
--- windows update often). The remembered values live in fields starting with _nl:
--- MAUI's own classes use _color, _font, _filename, ... for their internals.
function Txt(label, text)
    text = tostring(text or '')
    if label._nlText ~= text then
        label._nlText = text
        label._nlFitted = nil
        label:SetText(text)
    end
end

function Col(control, color)
    if control._nlColor ~= color then
        control._nlColor = color
        if control.SetColor then control:SetColor(color) else control:SetSolidColor(color) end
    end
end

function Tex(bitmap, texture)
    if bitmap._nlTex ~= texture then
        bitmap._nlTex = texture
        bitmap:SetTexture(texture)
    end
end

--- Moves a control to y (unscaled) inside parent, keeping its Left.
function SetY(control, parent, y)
    if control._nlY ~= y then
        control._nlY = y
        control.Top:Set(function() return parent.Top() + S(y) end)
    end
end

--- Width of `text` in `label`'s font, in unscaled pixels.
local function Advance(label, text)
    local ok, w = pcall(label.GetStringAdvance, label, text)
    if ok and type(w) == 'number' then return w / LayoutHelpers.ScaleNumber(100) * 100 end
    return string.len(text) * 7
end

-- UTF-8 aware length and start of a string (player names can have any letters)
local function Len(text)
    local ok, n = pcall(STR_Utf8Len, text)
    if ok and type(n) == 'number' then return n end
    return string.len(text)
end

local function Head(text, n)
    local ok, sub = pcall(STR_Utf8SubString, text, 1, n)
    if ok and type(sub) == 'string' then return sub end
    return string.sub(text, 1, n)
end

--- Sets the text, shortened with '..' to fit `maxWidth` unscaled pixels.
function SetFitted(label, text, maxWidth)
    text = tostring(text or '')
    local key = text .. '\n' .. maxWidth
    if label._nlFitted == key then return end
    label._nlFitted = key
    label._nlText = nil
    if Advance(label, text) <= maxWidth then
        label:SetText(text)
        return
    end
    local n = Len(text)
    while n > 1 and Advance(label, Head(text, n) .. '..') > maxWidth do
        n = n - 1
    end
    label:SetText(Head(text, n) .. '..')
end

--- Splits `text` into lines that fit `maxWidth` (unscaled), measured with `label`'s font.
function Wrap(label, text, maxWidth)
    local lines = {}
    local line = ''
    for word in string.gfind(tostring(text or ''), '[^ ]+') do
        local candidate = word
        if line ~= '' then candidate = line .. ' ' .. word end
        if line ~= '' and Advance(label, candidate) > maxWidth then
            table.insert(lines, line)
            line = word
        else
            line = candidate
        end
    end
    if line ~= '' then table.insert(lines, line) end
    return lines
end

----------------------------------------------------------------------------
-- sounds
----------------------------------------------------------------------------

function PlayCue(cue)
    local ok, err = pcall(function() PlaySound(Sound({ Bank = 'Interface', Cue = cue })) end)
    if not ok then WARN('NuggetsLobby: sound ' .. tostring(cue) .. ' failed: ' .. tostring(err)) end
end

----------------------------------------------------------------------------
-- buttons
----------------------------------------------------------------------------

-- A click is a press and a release over the button (same as the game's buttons).
local function ClickEvents(control, onClick)
    control.HandleEvent = function(self, event)
        if event.Type == 'MouseEnter' then
            self.mouseOver = true
            self:Refresh()
            return true
        elseif event.Type == 'MouseExit' then
            self.mouseOver = false
            self.pressed = false
            self:Refresh()
            return true
        elseif event.Type == 'ButtonPress' or event.Type == 'ButtonDClick' then
            if not self.enabled then return true end
            self.pressed = true
            self:Refresh()
            local dragger = Dragger()
            dragger.OnRelease = function(d, x, y)
                d:Destroy()
                -- released over the button? (the engine's own answer; the enter/exit
                -- flag is the fallback)
                local inside = self.mouseOver
                if not IsDestroyed(self) then
                    local ok, hit = pcall(self.HitTest, self, x, y)
                    if ok and hit ~= nil then inside = hit and true or false end
                end
                self.pressed = false
                if not IsDestroyed(self) then self:Refresh() end
                if inside and self.enabled and not IsDestroyed(self) then
                    if self.clickCue then PlayCue(self.clickCue) end
                    local ok, err = pcall(onClick, self, event.Modifiers)
                    if not ok then WARN('NuggetsLobby: button failed: ' .. tostring(err)) end
                end
            end
            dragger.OnCancel = function(d)
                d:Destroy()
                self.pressed = false
                if not IsDestroyed(self) then self:Refresh() end
            end
            PostDragger(self:GetRootFrame(), event.KeyCode, dragger)
            return true
        end
        return false
    end
end

--- A flat button with a centred label. style: a key of BUTTONS.
--- onClick(button, modifiers). Returns the button (SetLabel, SetStyle, SetEnabled, SetShown).
function Button(parent, label, style, x, y, w, h, onClick, size, depth)
    local d = depth or 8
    local btn = Bitmap(parent)
    Place(btn, parent, x, y, w, h)
    Over(btn, parent, d)
    btn.style = BUTTONS[style] and style or 'normal'
    btn.enabled = true
    btn.mouseOver = false
    btn.pressed = false
    btn.clickCue = 'UI_Opt_Mini_Button_Click'

    btn.edge = Rect(btn, 'ff000000', 0, h - 2, w, 2, 1)
    btn.gloss = Image(btn, ART .. 'gloss.png', 0, 0, w, h, 1)
    btn.label = Label(btn, label, size or 13, 'ffffffff', FONT_BOLD, 0, 0, 2)
    btn.label.Top:Set(function() return btn.Top() + math.floor((btn.Height() - btn.label.Height()) / 2) - S(1) end)
    CenterX(btn.label, btn, 0, w)

    btn.Refresh = function(self)
        local st = BUTTONS[self.style]
        local color = st.up
        local text = st.text
        local edge = st.edge
        if not self.enabled then
            color, text, edge = DISABLED.up, DISABLED.text, DISABLED.edge
            if self.style == 'ghost' or self.style == 'tab' then color, edge = '00000000', '00000000' end
        elseif self.pressed then
            color = st.down
        elseif self.mouseOver then
            color = st.over
        end
        self:SetSolidColor(color)
        self.edge:SetSolidColor(edge)
        self.label:SetColor(text)
    end
    btn.SetLabel = function(self, text) self.label:SetText(text or '') end
    btn.SetStyle = function(self, s)
        if BUTTONS[s] and self.style ~= s then
            self.style = s
            self:Refresh()
            if not self:IsHidden() then Show(self.gloss, s ~= 'ghost' and s ~= 'tab') end
        end
    end
    btn.SetEnabled = function(self, on)
        on = on and true or false
        if self.enabled ~= on then
            self.enabled = on
            self.pressed = false
            self:Refresh()
        end
    end
    btn.SetShown = function(self, on)
        if not on and (self.mouseOver or self.pressed) then
            self.mouseOver = false
            self.pressed = false
            self:Refresh()
        end
        Show(self, on)
        if on then
            -- children follow the button; the gloss is hidden on flat styles
            Show(self.gloss, self.style ~= 'ghost' and self.style ~= 'tab')
        end
    end
    ClickEvents(btn, onClick)
    btn:Refresh()
    Show(btn.gloss, btn.style ~= 'ghost' and btn.style ~= 'tab')
    return btn
end

--- A button that is a picture (dice faces). Textures: { up, over, off }.
--- SetSelected draws a ring round it.
function ImageButton(parent, textures, x, y, w, h, onClick, depth)
    local btn = Bitmap(parent, textures.up)
    Place(btn, parent, x, y, w, h)
    Over(btn, parent, depth or 8)
    btn.textures = textures
    btn.enabled = true
    btn.mouseOver = false
    btn.pressed = false
    btn.selected = false
    btn.clickCue = 'UI_Opt_Mini_Button_Click'
    btn.ring = Border(parent, COLORS.accent, x - 3, y - 3, w + 6, h + 6, (depth or 8) - 1, 2)
    btn.hover = Border(parent, COLORS.lineHi, x - 2, y - 2, w + 4, h + 4, (depth or 8) - 1, 1)
    btn.Refresh = function(self)
        local tex = self.textures.up
        if not self.enabled then
            tex = self.textures.off
        elseif self.mouseOver and self.textures.over then
            tex = self.textures.over
        end
        self:SetTexture(tex)
        self.ring:SetShown(self.selected and self.shown ~= false)
        self.hover:SetShown(self.mouseOver and self.enabled and not self.selected and self.shown ~= false)
    end
    btn.SetTextures = function(self, t)
        self.textures = t
        self:Refresh()
    end
    btn.SetEnabled = function(self, on)
        on = on and true or false
        if self.enabled ~= on then
            self.enabled = on
            self:Refresh()
        end
    end
    btn.SetSelected = function(self, on)
        on = on and true or false
        if self.selected ~= on then
            self.selected = on
            self:Refresh()
        end
    end
    btn.SetShown = function(self, on)
        self.shown = on and true or false
        if not on then self.mouseOver = false end
        Show(self, on)
        self:Refresh()
    end
    ClickEvents(btn, onClick)
    btn:Refresh()
    return btn
end

--- A tick box with a label. onChange(checked).
function Toggle(parent, label, x, y, checked, onChange, depth)
    local box = Bitmap(parent)
    Place(box, parent, x, y, 18, 18)
    Over(box, parent, depth or 8)
    box.checked = checked and true or false
    box.enabled = true
    box.mouseOver = false
    box.clickCue = 'UI_Opt_Mini_Button_Click'
    box.border = Border(box, COLORS.lineHi, 0, 0, 18, 18, 1)
    box.mark = Rect(box, COLORS.accent, 4, 4, 10, 10, 2)
    box.label = Label(parent, label, 13, COLORS.text, FONT, x + 26, y + 1, (depth or 8) + 1)
    box.Refresh = function(self)
        if self.mouseOver then self:SetSolidColor(COLORS.rowHi) else self:SetSolidColor(COLORS.bg2) end
        Show(self.mark, self.checked)
    end
    box.SetChecked = function(self, on)
        self.checked = on and true or false
        self:Refresh()
    end
    ClickEvents(box, function(self)
        self.checked = not self.checked
        self:Refresh()
        if onChange then onChange(self.checked) end
    end)
    box:Refresh()
    return box
end

--- [<] value [>] : value is a label, the arrows call onStep(-1) / onStep(1).
function Stepper(parent, x, y, w, onStep, depth)
    local st = {}
    st.minus = Button(parent, '<', 'normal', x, y, 22, 26, function() onStep(-1) end, 13, depth)
    st.plus = Button(parent, '>', 'normal', x + w - 22, y, 22, 26, function() onStep(1) end, 13, depth)
    st.bg = Rect(parent, COLORS.bg2, x + 24, y, w - 48, 26, (depth or 8) - 2)
    st.value = Label(parent, '', 13, COLORS.text, FONT_BOLD, x + 24, y + 5, (depth or 8) + 1)
    CenterX(st.value, parent, x + 24, w - 48)
    st.SetValue = function(self, text) self.value:SetText(text) end
    st.SetEnabled = function(self, on)
        self.minus:SetEnabled(on)
        self.plus:SetEnabled(on)
    end
    st.SetShown = function(self, on)
        self.minus:SetShown(on)
        self.plus:SetShown(on)
        Show(self.bg, on)
        Show(self.value, on)
    end
    return st
end

--- A thin bar; SetValue(0..1), SetColor.
function Bar(parent, x, y, w, h, color, depth)
    local bar = {}
    bar.bg = Rect(parent, 'ff0b0e11', x, y, w, h, depth or 3)
    bar.fill = Rect(parent, color or COLORS.good, x, y, w, h, (depth or 3) + 1)
    bar.w = w
    bar.SetValue = function(self, v)
        if v < 0 then v = 0 end
        if v > 1 then v = 1 end
        self.fill.Width:Set(math.max(0, math.floor(S(self.w) * v)))
        Show(self.fill, v > 0 and not self.bg:IsHidden())
    end
    bar.SetColor = function(self, c) self.fill:SetSolidColor(c) end
    bar.SetShown = function(self, on)
        Show(self.bg, on)
        Show(self.fill, on)
    end
    return bar
end

----------------------------------------------------------------------------
-- windows
----------------------------------------------------------------------------

--- Puts a window above everything on the screen (the newest window is the top one).
function Raise(frame)
    local ok, top = pcall(function() return GetFrame(0):GetTopmostDepth() end)
    if ok and type(top) == 'number' then
        frame.Depth:Set(top + 1)
    else
        frame.Depth:Set(function() return frame:GetParent().Depth() + 1 end)
    end
end

--- A movable window of w x h (unscaled) on `parent`, centred the first time and then where
--- it was left (saved under prefKey). Title bar with `title`, and a close button that
--- calls onClose. Returns the frame; put content into frame.body (below the title bar).
function Frame(parent, title, prefKey, w, h, onClose)
    local frame = Group(parent)
    frame:DisableHitTest()
    frame.uw, frame.uh = w, h
    local width, height = S(w), S(h)
    local left = math.floor(parent.Left() + (parent.Width() - width) / 2)
    local top = math.floor(parent.Top() + (parent.Height() - height) / 2)
    local saved = prefKey and Prefs.GetFromCurrentProfile(prefKey)
    if type(saved) == 'table' and type(saved.x) == 'number' and type(saved.y) == 'number' then
        left = parent.Left() + saved.x
        top = parent.Top() + saved.y
    end
    -- keep it on the screen
    left = math.max(parent.Left(), math.min(left, parent.Right() - width))
    top = math.max(parent.Top(), math.min(top, parent.Bottom() - height))
    frame.Left:Set(left)
    frame.Top:Set(top)
    frame.Width:Set(width)
    frame.Height:Set(height)
    Raise(frame)

    frame.shadow = Rect(frame, COLORS.shadow, -6, -4, w + 12, h + 12, 0)
    frame.bg = Rect(frame, COLORS.bg, 0, 0, w, h, 1)
    -- clicks, wheel and hover on the window's empty parts stay in the window instead
    -- of reaching the lobby below it
    frame.bg:EnableHitTest()
    frame.bg.HandleEvent = function(self, event) return true end
    frame.border = Border(frame, COLORS.lineHi, 0, 0, w, h, 2)
    frame.titleBar = Bitmap(frame)
    frame.titleBar:SetSolidColor(COLORS.title)
    Place(frame.titleBar, frame, 1, 1, w - 2, 35)
    Over(frame.titleBar, frame, 3)
    frame.titleLine = Rect(frame, COLORS.accent, 1, 36, w - 2, 1, 4)
    frame.title = Label(frame, title, 15, COLORS.text, FONT_BIG, 14, 9, 7)
    frame.close = Button(frame, 'X', 'ghost', w - 38, 4, 30, 28, function() if onClose then onClose() end end, 14, 8)

    frame.body = Group(frame)
    Place(frame.body, frame, 0, 37, w, h - 37)
    Over(frame.body, frame, 4)
    frame.body:DisableHitTest()

    -- drag by the title bar
    frame.titleBar.HandleEvent = function(self, event)
        if event.Type == 'ButtonPress' then
            local offX = event.MouseX - frame.Left()
            local offY = event.MouseY - frame.Top()
            local drag = Dragger()
            drag.OnMove = function(d, x, y)
                if IsDestroyed(frame) or IsDestroyed(parent) then return end
                local nx = math.max(parent.Left(), math.min(x - offX, parent.Right() - frame.Width()))
                local ny = math.max(parent.Top(), math.min(y - offY, parent.Bottom() - frame.Height()))
                frame.Left:Set(nx)
                frame.Top:Set(ny)
            end
            drag.OnRelease = function(d)
                d:Destroy()
                if prefKey and not IsDestroyed(frame) and not IsDestroyed(parent) then
                    Prefs.SetToCurrentProfile(prefKey, { x = frame.Left() - parent.Left(), y = frame.Top() - parent.Top() })
                end
            end
            drag.OnCancel = function(d) d:Destroy() end
            PostDragger(self:GetRootFrame(), event.KeyCode, drag)
            return true
        end
        return false
    end
    return frame
end

--- A question over a window: text and two buttons. onYes runs on the first button;
--- the second just closes it. Returns the dialog (Destroy closes it).
function Confirm(frame, text, yesLabel, noLabel, onYes, yesStyle)
    local w, h = 400, 150
    local fw, fh = frame.uw, frame.uh
    local dialog = Group(frame)
    Place(dialog, frame, 0, 0, fw, fh)
    Over(dialog, frame, 50)
    -- swallows clicks on the window below
    local shade = Bitmap(dialog)
    shade:SetSolidColor(COLORS.overlay)
    Place(shade, dialog, 0, 0, fw, fh)
    Over(shade, dialog, 1)
    shade.HandleEvent = function(self, event) return true end
    local x, y = math.floor((fw - w) / 2), math.floor((fh - h) / 2)
    Panel(dialog, x, y, w, h, COLORS.panelHi, COLORS.accent, 2)
    local lines = {}
    local probe = Label(dialog, '', 14, COLORS.text, FONT, x + 20, y + 18, 6)
    local wrapped = Wrap(probe, text, w - 40)
    probe:SetText(wrapped[1] or '')
    for i = 2, math.min(table.getn(wrapped), 4) do
        Label(dialog, wrapped[i], 14, COLORS.text, FONT, x + 20, y + 18 + (i - 1) * 20, 6)
    end
    Button(dialog, yesLabel, yesStyle or 'danger', x + w - 20 - 130 - 10 - 110, y + h - 48, 130, 32, function()
        dialog:Destroy()
        onYes()
    end, 13, 10)
    Button(dialog, noLabel, 'normal', x + w - 20 - 110, y + h - 48, 110, 32, function()
        dialog:Destroy()
    end, 13, 10)
    return dialog
end
