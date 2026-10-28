ReUI.Require
{
    "ReUI.Core >= 1.2.0",
    'ReUI.Actions >= 1.2.0',
    'ReUI.Options >= 1.0.0',
}

-- =============================================================================
-- Minigames  (merged Chess + Minesweeper + Battleship)
-- Each game keeps its own scoped block, chat tag, window class and chat handler,
-- so their multiplayer protocols stay independent and backward-compatible with
-- the standalone Chess / Battleship mods. Hotkeys are now ONE bindable entry per
-- game instead of five: a shared modifiers table makes ReUI auto-generate the
-- single-modifier variants, and a small keymapper wrapper adds the combined ones.
-- =============================================================================

function Main(isReplay)
    if isReplay then return end

    -- Shared modifiers table: when you bind ONE key to a game action, ReUI's own
    -- keymapper hook auto-creates the Shift / Ctrl / Alt single-modifier variants.
    local MG_MODIFIERS = { shift = true, ctrl = true, alt = true }

    -- Combined-modifier support (Shift+Ctrl, Shift+Alt, Ctrl+Alt, Shift+Ctrl+Alt).
    -- ReUI's built-in hook only generates SINGLE-modifier variants, so we wrap the
    -- same keymapper function and append the combined ones for every action that
    -- already received single-modifier variants (i.e. our MG_MODIFIERS actions).
    -- pcall-guarded + idempotent so it can never break mod loading.
    pcall(function()
        local KeyMapper = import('/lua/keymap/keymapper.lua')
        if type(KeyMapper.GenerateHotbuildModifiers) ~= 'function' then return end
        if KeyMapper._minigamesComboHook then return end
        KeyMapper._minigamesComboHook = true

        local prevGen = KeyMapper.GenerateHotbuildModifiers
        KeyMapper.GenerateHotbuildModifiers = function()
            local modifiers = prevGen() or {}
            local additions = {}
            for modKey, actionInfo in modifiers do
                local cat = ''
                if actionInfo and actionInfo.category then
                    cat = string.lower(actionInfo.category)
                end
                local isHotbuild = (cat == 'hotbuilding')
                    or (cat == 'hotbuildingalternative')
                    or (cat == 'hotbuildingextra')
                if not isHotbuild then
                    -- strip leading Ctrl-/Shift-/Alt- tokens to find the base key
                    local base = modKey
                    local hasMod = false
                    local stripping = true
                    while stripping do
                        stripping = false
                        if string.sub(base, 1, 5) == 'Ctrl-' then
                            base = string.sub(base, 6) ; hasMod = true ; stripping = true
                        elseif string.sub(base, 1, 6) == 'Shift-' then
                            base = string.sub(base, 7) ; hasMod = true ; stripping = true
                        elseif string.sub(base, 1, 4) == 'Alt-' then
                            base = string.sub(base, 5) ; hasMod = true ; stripping = true
                        end
                    end
                    if hasMod and base ~= '' then
                        -- canonical FA order is Ctrl-Shift-Alt-<key>
                        local combos = {
                            'Ctrl-Shift-' .. base,
                            'Ctrl-Alt-' .. base,
                            'Shift-Alt-' .. base,
                            'Ctrl-Shift-Alt-' .. base,
                        }
                        for ci = 1, table.getn(combos) do
                            local ck = combos[ci]
                            if not modifiers[ck] and not additions[ck] then
                                additions[ck] = actionInfo
                            end
                        end
                    end
                end
            end
            for k, v in additions do
                modifiers[k] = v
            end
            return modifiers
        end
    end)

    -- =====================================================================
    -- Stakes (shared by Chess and Battleship)
    --
    -- Configured PER PLAYER: each client reads its own option and pays its own
    -- forfeit, so both sides can have different settings and neither can see
    -- what the other picked.
    --
    --   Winner is an ally  -> all stored mass + one highest-tier mass extractor
    --   Winner is an enemy -> public chat line instead. The engine refuses both
    --                         GiveResourcesToPlayer and GiveUnitsToPlayer across
    --                         enemy lines (IsAlly gate in /lua/SimUtils.lua), so
    --                         there is no transfer to make.
    -- =====================================================================
    local MG_Stakes = {}

    -- Read live so toggling an option mid-game takes effect immediately.
    -- Each stake is its own switch and they are read independently.
    local function MG_OptOn(key)
        local on = true
        pcall(function()
            local o = ReUI.Options.Mods["Minigames"]
            if o and o[key] then
                local v = o[key]()
                if v == false or v == 0 then on = false end
            end
        end)
        return on
    end

    -- Resolve a nickname to a live army index. Returns nil for bots, observers
    -- and anyone who is not present as a real army.
    local function MG_ArmyByNick(nick)
        if nick == nil or nick == '' then return nil end
        local found = nil
        pcall(function()
            local t = GetArmiesTable()
            if t == nil or t.armiesTable == nil then return end
            for i, a in t.armiesTable do
                if a ~= nil and a.nickname == nick and not a.civilian then
                    found = i
                end
            end
        end)
        return found
    end

    -- Hand over a single mass extractor, highest tech first.
    -- GiveUnitsToPlayer operates on the current selection, so save it, swap in
    -- the mex, fire, and put the player's selection back. Same ConExecute +
    -- GetSelectedUnits pattern FAF itself uses in /lua/keymap/misckeyactions.lua.
    local function MG_GiveTopMex(toArmy)
        local prevSel = GetSelectedUnits() or {}
        local picked  = nil
        for tech = 3, 1, -1 do
            if picked == nil then
                ConExecute('UI_SelectByCategory MASSEXTRACTION TECH' .. tech)
                local sel = GetSelectedUnits()
                if sel ~= nil and table.getn(sel) > 0 then
                    picked = sel[1]
                end
            end
        end
        if picked ~= nil then
            SelectUnits({ picked })
            SimCallback({
                Func = "GiveUnitsToPlayer",
                Args = { From = GetFocusArmy(), To = toArmy },
            }, true)
        end
        SelectUnits(prevSel)
        return picked ~= nil
    end

    -- Called on the LOSER's client only.
    MG_Stakes.Pay = function(winnerNick, gameLabel)
        local wantStorage = MG_OptOn('stakesStorage')
        local wantMex     = MG_OptOn('stakesMex')
        if (not wantStorage) and (not wantMex) then return end

        local myArmy = GetFocusArmy()
        if myArmy == nil or myArmy < 1 then return end   -- observers pay nothing

        local toArmy = MG_ArmyByNick(winnerNick)
        if toArmy == nil or toArmy == myArmy then return end

        local winner = nil
        pcall(function() winner = GetArmiesTable().armiesTable[toArmy] end)
        if winner == nil then return end
        if winner.human == false then return end         -- never pay an AI
        if winner.outOfGame then return end

        local allied = false
        pcall(function() allied = IsAlly(myArmy, toArmy) and true or false end)

        if not allied then
            pcall(function()
                SessionSendChatMessage({
                    to   = 'all',
                    Chat = true,
                    text = winnerNick .. " is the superior player",
                })
            end)
            return
        end

        -- Mass/Energy are 0..1 fractions of current storage, not absolute
        -- amounts, so 1.0 empties the store. Anything over the winner's own
        -- storage cap is discarded by the engine.
        local sentStorage = false
        if wantStorage then
            pcall(function()
                SimCallback({
                    Func = "GiveResourcesToPlayer",
                    Args = { From = myArmy, To = toArmy, Mass = 1.0, Energy = 1.0 },
                })
                sentStorage = true
            end)
        end

        -- The host can switch unit sharing off entirely; storage still goes.
        local share = nil
        if wantMex then
            pcall(function()
                local si = SessionGetScenarioInfo()
                share = si and si.Options and si.Options.ManualUnitShare
            end)
        end

        local gaveMex = false
        if wantMex and share ~= 'none' then
            pcall(function() gaveMex = MG_GiveTopMex(toArmy) end)
        end

        local sent = ""
        if sentStorage then
            sent = "all stored mass + energy"
        end
        if gaveMex then
            if sent ~= "" then sent = sent .. " + " end
            sent = sent .. "1 mass extractor"
        end

        if sent ~= "" then
            print(gameLabel .. ": stakes paid to " .. winnerNick .. " - " .. sent)
        elseif wantMex and share == 'none' then
            print(gameLabel .. ": stakes not sent to " .. winnerNick .. " (host has unit sharing off)")
        else
            print(gameLabel .. ": stakes not sent to " .. winnerNick .. " (nothing to send)")
        end
    end

    -- ===================================================================
    -- CHESS
    -- ===================================================================
    do

    local UIUtil        = import('/lua/ui/uiutil.lua')
    local Group         = import("/lua/maui/group.lua").Group
    local LayoutHelpers = import("/lua/maui/layouthelpers.lua")
    local Bitmap        = import("/lua/maui/bitmap.lua").Bitmap
    local Popup         = import("/lua/ui/controls/popups/popup.lua").Popup
    local Window        = import("/lua/maui/window.lua").Window
    local LazyVar       = import('/lua/lazyvar.lua').Create

    -- =========================================================
    -- Constants
    -- =========================================================

    local CELL      = 52          -- pixels per cell (board = 8*CELL)
    local BOARD_PX  = 8 * CELL    -- 416px

    -- Colors
    local C_LIGHT      = "fff0d9b5"   -- light square
    local C_DARK       = "ffb58863"   -- dark square
    local C_SELECTED   = "ff7fc97f"   -- selected piece highlight
    local C_MOVE       = "ff7fbfff"   -- valid move highlight
    local C_CHECK      = "ffff4444"   -- king in check
    local C_LASTMOVE   = "ffcdd16e"   -- last move highlight
    local C_WHITE_PIE  = "fff5f5f5"   -- white piece fill
    local C_BLACK_PIE  = "ff222222"   -- black piece fill
    local C_W_BORDER   = "ff888888"   -- white piece border
    local C_B_BORDER   = "ffaaaaaa"   -- black piece border

    -- Piece type constants
    local EMPTY  = 0
    local PAWN   = 1
    local KNIGHT = 2
    local BISHOP = 3
    local ROOK   = 4
    local QUEEN  = 5
    local KING   = 6

    local WHITE = 1
    local BLACK = 2

    -- Piece texture paths: /mods/Chess/pieces/<color><type>.png
    -- color: w/b   type: p/n/b/r/q/k  (indices match PAWN=1..KING=6)
    local PIECE_FILE_W = { "wp.png", "wn.png", "wb.png", "wr.png", "wq.png", "wk.png" }
    local PIECE_FILE_B = { "bp.png", "bn.png", "bb.png", "br.png", "bq.png", "bk.png" }
    local PIECE_DIR    = "/nuggetslobby/minigames/pieces/"

    -- =========================================================
    -- Chess logic
    -- =========================================================

    -- Board: board[r][c] = { type=PAWN, color=WHITE } or nil
    local function NewBoard()
        local b = {}
        for r = 1, 8 do b[r] = {} end

        local function Place(r, c, t, col)
            b[r][c] = { t = t, col = col }
        end

        -- Black back rank (row 1 from White's perspective = row 8 visually)
        Place(1,1,ROOK,BLACK) Place(1,2,KNIGHT,BLACK) Place(1,3,BISHOP,BLACK)
        Place(1,4,QUEEN,BLACK) Place(1,5,KING,BLACK)
        Place(1,6,BISHOP,BLACK) Place(1,7,KNIGHT,BLACK) Place(1,8,ROOK,BLACK)
        for c = 1, 8 do Place(2, c, PAWN, BLACK) end
        -- White back rank
        Place(8,1,ROOK,WHITE) Place(8,2,KNIGHT,WHITE) Place(8,3,BISHOP,WHITE)
        Place(8,4,QUEEN,WHITE) Place(8,5,KING,WHITE)
        Place(8,6,BISHOP,WHITE) Place(8,7,KNIGHT,WHITE) Place(8,8,ROOK,WHITE)
        for c = 1, 8 do Place(7, c, PAWN, WHITE) end

        return b
    end

    local function CopyBoard(b)
        local nb = {}
        for r = 1, 8 do
            nb[r] = {}
            for c = 1, 8 do
                if b[r][c] then
                    nb[r][c] = { t = b[r][c].t, col = b[r][c].col }
                end
            end
        end
        return nb
    end

    local function OtherColor(col)
        if col == WHITE then return BLACK else return WHITE end
    end

    -- Find king position for a color
    local function FindKing(b, col)
        for r = 1, 8 do
            for c = 1, 8 do
                if b[r][c] and b[r][c].t == KING and b[r][c].col == col then
                    return r, c
                end
            end
        end
        return nil, nil
    end

    -- Is square (r,c) attacked by 'attacker' color?
    local function IsAttacked(b, r, c, attacker)
        -- Pawn attacks: white pawns move up (row-1), attack from row+1
        -- If attacker is WHITE, a white pawn at (r+1) attacks (r,c)
        local pDir = attacker == WHITE and 1 or -1
        for _, dc in ipairs({-1, 1}) do
            local ar, ac = r + pDir, c + dc
            if ar >= 1 and ar <= 8 and ac >= 1 and ac <= 8 then
                local p = b[ar][ac]
                if p and p.t == PAWN and p.col == attacker then return true end
            end
        end
        -- Knight attacks
        local knightMoves = {{-2,-1},{-2,1},{-1,-2},{-1,2},{1,-2},{1,2},{2,-1},{2,1}}
        for _, d in ipairs(knightMoves) do
            local ar, ac = r + d[1], c + d[2]
            if ar >= 1 and ar <= 8 and ac >= 1 and ac <= 8 then
                local p = b[ar][ac]
                if p and p.t == KNIGHT and p.col == attacker then return true end
            end
        end
        -- Sliding pieces (bishop/queen diagonals, rook/queen straights)
        local dirs = {{0,1},{0,-1},{1,0},{-1,0},{1,1},{1,-1},{-1,1},{-1,-1}}
        for _, d in ipairs(dirs) do
            local isDiag = (d[1] ~= 0 and d[2] ~= 0)
            local ar, ac = r + d[1], c + d[2]
            while ar >= 1 and ar <= 8 and ac >= 1 and ac <= 8 do
                local p = b[ar][ac]
                if p then
                    if p.col == attacker then
                        if isDiag and (p.t == BISHOP or p.t == QUEEN) then return true end
                        if not isDiag and (p.t == ROOK or p.t == QUEEN) then return true end
                    end
                    break
                end
                ar, ac = ar + d[1], ac + d[2]
            end
        end
        -- King attacks (for adjacency)
        for _, d in ipairs(dirs) do
            local ar, ac = r + d[1], c + d[2]
            if ar >= 1 and ar <= 8 and ac >= 1 and ac <= 8 then
                local p = b[ar][ac]
                if p and p.t == KING and p.col == attacker then return true end
            end
        end
        return false
    end

    local function IsInCheck(b, col)
        local kr, kc = FindKing(b, col)
        if not kr then return false end
        return IsAttacked(b, kr, kc, OtherColor(col))
    end

    -- Apply a move to a board copy and return new board (does not mutate)
    -- move = { fr, fc, tr, tc, promo (optional) }
    local function ApplyMove(b, move)
        local nb = CopyBoard(b)
        local piece = nb[move.fr][move.fc]
        nb[move.tr][move.tc] = piece
        nb[move.fr][move.fc] = nil

        -- Promotion
        if piece.t == PAWN and (move.tr == 1 or move.tr == 8) then
            nb[move.tr][move.tc].t = move.promo or QUEEN
        end

        -- En passant capture
        if piece.t == PAWN and move.fc ~= move.tc and not b[move.tr][move.tc] then
            nb[move.fr][move.tc] = nil
        end

        -- Castling: move rook
        if piece.t == KING and math.abs(move.tc - move.fc) == 2 then
            if move.tc > move.fc then  -- kingside
                nb[move.fr][move.tc - 1] = nb[move.fr][8]
                nb[move.fr][8] = nil
            else  -- queenside
                nb[move.fr][move.tc + 1] = nb[move.fr][1]
                nb[move.fr][1] = nil
            end
        end

        return nb
    end

    -- Get all pseudo-legal moves for a piece (may leave king in check)
    -- state = { board, enPassantCol, castling = {wK, wQ, bK, bQ} }
    local function PseudoMoves(state, r, c)
        local b     = state.board
        local piece = b[r][c]
        if not piece then return {} end

        local moves = {}
        local col   = piece.col
        local opp   = OtherColor(col)

        local function AddIfValid(tr, tc, promo)
            if tr < 1 or tr > 8 or tc < 1 or tc > 8 then return end
            local target = b[tr][tc]
            if target and target.col == col then return end
            moves[table.getn(moves) + 1] = { fr=r, fc=c, tr=tr, tc=tc, promo=promo }
        end

        local function Slide(dr, dc)
            local tr, tc = r + dr, c + dc
            while tr >= 1 and tr <= 8 and tc >= 1 and tc <= 8 do
                local target = b[tr][tc]
                if target then
                    if target.col == opp then
                        moves[table.getn(moves) + 1] = { fr=r, fc=c, tr=tr, tc=tc }
                    end
                    break
                end
                moves[table.getn(moves) + 1] = { fr=r, fc=c, tr=tr, tc=tc }
                tr, tc = tr + dr, tc + dc
            end
        end

        if piece.t == PAWN then
            local dir  = col == WHITE and -1 or 1
            local start = col == WHITE and 7 or 2
            local prRow = col == WHITE and 1 or 8
            -- Forward
            if not b[r+dir] or not b[r+dir][c] then
                if r + dir == prRow then
                    for _, pt in ipairs({QUEEN,ROOK,BISHOP,KNIGHT}) do
                        AddIfValid(r+dir, c, pt)
                    end
                else
                    AddIfValid(r+dir, c)
                end
                -- Double push
                if r == start and (not b[r+dir*2] or not b[r+dir*2][c]) then
                    AddIfValid(r+dir*2, c)
                end
            end
            -- Captures
            for _, dc in ipairs({-1,1}) do
                local tc = c + dc
                if tc >= 1 and tc <= 8 then
                    if b[r+dir] and b[r+dir][tc] and b[r+dir][tc].col == opp then
                        if r + dir == prRow then
                            for _, pt in ipairs({QUEEN,ROOK,BISHOP,KNIGHT}) do
                                moves[table.getn(moves) + 1] = { fr=r, fc=c, tr=r+dir, tc=tc, promo=pt }
                            end
                        else
                            AddIfValid(r+dir, tc)
                        end
                    end
                    -- En passant
                    if state.enPassantCol == tc and r == (col == WHITE and 4 or 5) then
                        moves[table.getn(moves) + 1] = { fr=r, fc=c, tr=r+dir, tc=tc }
                    end
                end
            end

        elseif piece.t == KNIGHT then
            for _, d in ipairs({{-2,-1},{-2,1},{-1,-2},{-1,2},{1,-2},{1,2},{2,-1},{2,1}}) do
                AddIfValid(r+d[1], c+d[2])
            end

        elseif piece.t == BISHOP then
            Slide(1,1) Slide(1,-1) Slide(-1,1) Slide(-1,-1)

        elseif piece.t == ROOK then
            Slide(0,1) Slide(0,-1) Slide(1,0) Slide(-1,0)

        elseif piece.t == QUEEN then
            Slide(1,1) Slide(1,-1) Slide(-1,1) Slide(-1,-1)
            Slide(0,1) Slide(0,-1) Slide(1,0) Slide(-1,0)

        elseif piece.t == KING then
            for _, d in ipairs({{0,1},{0,-1},{1,0},{-1,0},{1,1},{1,-1},{-1,1},{-1,-1}}) do
                AddIfValid(r+d[1], c+d[2])
            end
            -- Castling
            local cas = state.castling
            local backR = col == WHITE and 8 or 1
            if r == backR and c == 5 then
                -- Kingside
                local ksKey = col == WHITE and "wK" or "bK"
                if cas[ksKey] and not b[backR][6] and not b[backR][7] then
                    if not IsAttacked(b,backR,5,opp) and not IsAttacked(b,backR,6,opp) and not IsAttacked(b,backR,7,opp) then
                        moves[table.getn(moves) + 1] = { fr=backR, fc=5, tr=backR, tc=7 }
                    end
                end
                -- Queenside
                local qsKey = col == WHITE and "wQ" or "bQ"
                if cas[qsKey] and not b[backR][4] and not b[backR][3] and not b[backR][2] then
                    if not IsAttacked(b,backR,5,opp) and not IsAttacked(b,backR,4,opp) and not IsAttacked(b,backR,3,opp) then
                        moves[table.getn(moves) + 1] = { fr=backR, fc=5, tr=backR, tc=3 }
                    end
                end
            end
        end

        return moves
    end

    -- Filter pseudo-legal to legal (don't leave own king in check)
    local function LegalMoves(state, r, c)
        local pseudo = PseudoMoves(state, r, c)
        local legal  = {}
        local piece  = state.board[r][c]
        if not piece then return legal end
        for _, m in ipairs(pseudo) do
            local nb = ApplyMove(state.board, m)
            if not IsInCheck(nb, piece.col) then
                legal[table.getn(legal) + 1] = m
            end
        end
        return legal
    end

    -- All legal moves for a color
    local function AllLegalMoves(state, col)
        local all = {}
        for r = 1, 8 do
            for c = 1, 8 do
                if state.board[r][c] and state.board[r][c].col == col then
                    local lm = LegalMoves(state, r, c)
                    for _, m in ipairs(lm) do
                        all[table.getn(all) + 1] = m
                    end
                end
            end
        end
        return all
    end

    local function IsCheckmate(state, col)
        return IsInCheck(state.board, col) and table.getn(AllLegalMoves(state, col)) == 0
    end

    local function IsStalemate(state, col)
        return not IsInCheck(state.board, col) and table.getn(AllLegalMoves(state, col)) == 0
    end

    -- Update castling rights after a move
    local function UpdateCastling(cas, move, board)
        local nc = { wK=cas.wK, wQ=cas.wQ, bK=cas.bK, bQ=cas.bQ }
        local piece = board[move.fr][move.fc]
        if not piece then return nc end
        if piece.t == KING then
            if piece.col == WHITE then nc.wK = false nc.wQ = false
            else nc.bK = false nc.bQ = false end
        elseif piece.t == ROOK then
            if move.fr == 8 and move.fc == 1 then nc.wQ = false end
            if move.fr == 8 and move.fc == 8 then nc.wK = false end
            if move.fr == 1 and move.fc == 1 then nc.bQ = false end
            if move.fr == 1 and move.fc == 8 then nc.bK = false end
        end
        -- If a rook is captured
        if move.tr == 8 and move.tc == 1 then nc.wQ = false end
        if move.tr == 8 and move.tc == 8 then nc.wK = false end
        if move.tr == 1 and move.tc == 1 then nc.bQ = false end
        if move.tr == 1 and move.tc == 8 then nc.bK = false end
        return nc
    end

    -- En passant column after a double pawn push, else nil
    local function GetEnPassant(board, move)
        local piece = board[move.fr][move.fc]
        if piece and piece.t == PAWN and math.abs(move.tr - move.fr) == 2 then
            return move.fc
        end
        return nil
    end

    -- =========================================================
    -- Accept popup (same pattern as Battleship)
    -- =========================================================

    local disableChessRequests = false

    local chatTAG = "Chess"
    local myNickname = nil
    local function MyNick()
        return myNickname or GetArmiesTable().armiesTable[GetFocusArmy()].nickname
    end

    local chAcceptDialog = nil
    local chWindow       = nil
    local chGame         = nil
    local pendingChallenge = nil

    local ChAcceptDialog = ClassUI(Popup) {
        __init = function(self, parent, challengerNick, onAccept, onDecline)
            self._done = false
            local content = Group(parent)
            LayoutHelpers.SetDimensions(content, 420, 135)

            local titleText = UIUtil.CreateText(content,
                challengerNick .. " challenges you to Chess!", 16, 'Arial Bold', true)
            LayoutHelpers.AtHorizontalCenterIn(titleText, content)
            LayoutHelpers.AtTopIn(titleText, content, 14)

            local subText = UIUtil.CreateText(content,
                "A friendly game — no units destroyed.", 13, 'Arial', true)
            LayoutHelpers.AtHorizontalCenterIn(subText, content)
            LayoutHelpers.AtTopIn(subText, content, 38)

            self.countdownLabel = UIUtil.CreateText(content, "Auto-declining in 3...", 12, 'Arial', true)
            LayoutHelpers.AtHorizontalCenterIn(self.countdownLabel, content)
            LayoutHelpers.AtTopIn(self.countdownLabel, content, 62)

            local btnAccept  = UIUtil.CreateButtonWithDropshadow(content, '/BUTTON/medium/', "Accept")
            local btnDecline = UIUtil.CreateButtonWithDropshadow(content, '/BUTTON/medium/', "Decline")
            LayoutHelpers.AtBottomIn(btnAccept,  content, 10)
            LayoutHelpers.AtBottomIn(btnDecline, content, 10)
            LayoutHelpers.AtHorizontalCenterIn(btnDecline, content)
            LayoutHelpers.LeftOf(btnAccept, btnDecline, 10)

            local function doDecline()
                if not self._done then self._done = true onDecline() end
                if not IsDestroyed(self) then self:Close() end
            end
            local function doAccept()
                self._done = true onAccept()
                if not IsDestroyed(self) then self:Close() end
            end

            btnAccept.OnClick  = doAccept
            btnDecline.OnClick = doDecline
            Popup.__init(self, parent, content)

            ForkThread(function()
                for i = 3, 1, -1 do
                    if IsDestroyed(self) or self._done then return end
                    self.countdownLabel:SetText("Auto-declining in " .. i .. "...")
                    WaitSeconds(1)
                end
                if not IsDestroyed(self) and not self._done then doDecline() end
            end)
        end,
        OnEscapePressed = function(self) end,
        OnShadowClicked = function(self) end,
        OnDestroy = function(self)
            self.countdownLabel = nil
            Popup.OnDestroy(self)
        end,
    }

    -- =========================================================
    -- Chess board Window
    -- =========================================================

    local WINDOW_W = 8 * CELL + 120   -- board + sidebar
    local WINDOW_H = 8 * CELL + 80    -- board + labels + status

    local ChessWindow = Class(Window) {

        __init = function(self, parent, myColor, oppNick, onMove, onClose)
            self._myColor    = myColor
            self._oppNick    = oppNick
            self._onMove     = onMove
            self._onClose    = onClose
            self._selected   = nil
            self._legalMoves = {}
            self._lastMove   = nil
            self._myTurn     = (myColor == WHITE)
            self._gameOver   = false

            local windowTextures = {
                tl = UIUtil.SkinnableFile('/game/panel/panel_brd_ul.dds'),
                tr = UIUtil.SkinnableFile('/game/panel/panel_brd_ur.dds'),
                tm = UIUtil.SkinnableFile('/game/panel/panel_brd_horz_um.dds'),
                ml = UIUtil.SkinnableFile('/game/panel/panel_brd_vert_l.dds'),
                m  = UIUtil.SkinnableFile('/game/panel/panel_brd_m.dds'),
                mr = UIUtil.SkinnableFile('/game/panel/panel_brd_vert_r.dds'),
                bl = UIUtil.SkinnableFile('/game/panel/panel_brd_ll.dds'),
                bm = UIUtil.SkinnableFile('/game/panel/panel_brd_lm.dds'),
                br = UIUtil.SkinnableFile('/game/panel/panel_brd_lr.dds'),
                borderColor = '00415055'
            }
            Window.__init(self, parent, "Chess vs " .. oppNick, nil, false, false, false, false,
                'ChessWindow', {
                    Left   = parent.Width()  / 2 - WINDOW_W / 2,
                    Right  = parent.Width()  / 2 + WINDOW_W / 2,
                    Top    = parent.Height() / 2 - WINDOW_H / 2,
                    Bottom = parent.Height() / 2 + WINDOW_H / 2,
                }, windowTextures)
            self:SetMinimumResize(200, 200)

            -- Title styling (same as Bingo)
            self._title:SetFont('Arial Black', 14)
            self._title:DisableHitTest()
            LayoutHelpers.AtCenterIn(self._title, self.TitleGroup)

            -- Drag handles (same as Bingo - purely visual, resize is from window border)
            self.DragTL = Bitmap(self, UIUtil.SkinnableFile '/game/drag-handle/drag-handle-ul_btn_up.dds')
            self.DragTR = Bitmap(self, UIUtil.SkinnableFile '/game/drag-handle/drag-handle-ur_btn_up.dds')
            self.DragBL = Bitmap(self, UIUtil.SkinnableFile '/game/drag-handle/drag-handle-ll_btn_up.dds')
            self.DragBR = Bitmap(self, UIUtil.SkinnableFile '/game/drag-handle/drag-handle-lr_btn_up.dds')
            LayoutHelpers.AtLeftTopIn(self.DragTL,     self, -24, -8)
            LayoutHelpers.AtRightTopIn(self.DragTR,    self, -22, -8)
            LayoutHelpers.AtLeftBottomIn(self.DragBL,  self, -24, -8)
            LayoutHelpers.AtRightBottomIn(self.DragBR, self, -22, -8)
            LayoutHelpers.DepthOverParent(self.DragTL, self, 10)
            LayoutHelpers.DepthOverParent(self.DragTR, self, 10)
            LayoutHelpers.DepthOverParent(self.DragBL, self, 10)
            LayoutHelpers.DepthOverParent(self.DragBR, self, 10)
            self.DragTL:DisableHitTest()
            self.DragTR:DisableHitTest()
            self.DragBL:DisableHitTest()
            self.DragBR:DisableHitTest()

            local content = self.ClientGroup

            -- ---- Board uses a Group that fills ClientGroup, same as Bingo ----
            -- boardGroup fills the window content area. LazyVars read from
            -- boardGroup.Width()/Height() which are reactive to window resize.
            local MARGIN  = 20
            local SIDEBAR = 100

            local boardGroup = Group(content)
            LayoutHelpers.FillParent(boardGroup, content)

            self._cellSz = LazyVar(52)
            local cellSz = self._cellSz
            cellSz:Set(function()
                local w = math.floor((boardGroup.Width()  - MARGIN * 2 - SIDEBAR) / 8)
                local h = math.floor((boardGroup.Height() - MARGIN * 2 - 14)      / 8)
                if h < w then return h else return w end
            end)

            self._cells      = {}
            self._pieceIcons = {}

            for r = 1, 8 do
                self._cells[r]      = {}
                self._pieceIcons[r] = {}
                for c = 1, 8 do
                    local cell = Bitmap(boardGroup)
                    local row, col = r, c

                    LayoutHelpers.LayoutFor(cell)
                        :Left(function()
                            local vc = self._myColor == WHITE and (col-1) or (8-col)
                            return boardGroup.Left() + MARGIN + vc * cellSz()
                        end)
                        :Top(function()
                            local vr = self._myColor == WHITE and (row-1) or (8-row)
                            return boardGroup.Top()  + MARGIN + vr * cellSz()
                        end)
                        :Width( function() return cellSz() end)
                        :Height(function() return cellSz() end)
                        :Over(boardGroup, 1)

                    local rc = r + c
                    if rc - math.floor(rc/2)*2 == 0 then
                        cell:SetSolidColor(C_LIGHT)
                    else
                        cell:SetSolidColor(C_DARK)
                    end
                    cell:EnableHitTest()

                    -- Piece icon bitmap (transparent PNG over the cell)
                    local icon = Bitmap(boardGroup)
                    LayoutHelpers.LayoutFor(icon)
                        :Left(  function() return cell.Left()   + math.floor(cellSz() * 0.08) end)
                        :Top(   function() return cell.Top()    + math.floor(cellSz() * 0.06) end)
                        :Width( function() return math.floor(cellSz() * 0.84) end)
                        :Height(function() return math.floor(cellSz() * 0.84) end)
                        :Over(boardGroup, 2)
                    icon:DisableHitTest()
                    icon:SetSolidColor("00000000")  -- start transparent

                    cell.HandleEvent = function(_self, event)
                        if event.Type == "ButtonPress" and event.Modifiers.Left then
                            self:OnCellClick(row, col)
                        end
                        return true
                    end

                    self._cells[r][c]      = cell
                    self._pieceIcons[r][c] = icon
                end
            end

            -- ---- Rank/file labels ----
            local FILES_W = {"a","b","c","d","e","f","g","h"}
            local FILES_B = {"h","g","f","e","d","c","b","a"}
            local RANKS_W = {"8","7","6","5","4","3","2","1"}
            local RANKS_B = {"1","2","3","4","5","6","7","8"}
            local FILES = self._myColor == WHITE and FILES_W or FILES_B
            local RANKS = self._myColor == WHITE and RANKS_W or RANKS_B
            for i = 1, 8 do
                local fi = i
                local fl = UIUtil.CreateText(boardGroup, FILES[i], 9, 'Arial', true)
                LayoutHelpers.LayoutFor(fl)
                    :Left(  function() return boardGroup.Left() + MARGIN + (fi-1)*cellSz() + math.floor(cellSz()/2) - 3 end)
                    :Top(   function() return boardGroup.Top()  + MARGIN + 8 * cellSz() + 2 end)
                    :Width( function() return 10 end)
                    :Height(function() return 12 end)
                    :Over(content, 1)
                fl:DisableHitTest()

                local rl = UIUtil.CreateText(boardGroup, RANKS[i], 9, 'Arial', true)
                LayoutHelpers.LayoutFor(rl)
                    :Left(  function() return boardGroup.Left() + 4 end)
                    :Top(   function() return boardGroup.Top()  + MARGIN + (fi-1)*cellSz() + math.floor(cellSz()/2) - 5 end)
                    :Width( function() return 14 end)
                    :Height(function() return 12 end)
                    :Over(content, 1)
                rl:DisableHitTest()
            end

            -- ---- Side panel (anchored to right/bottom edges) ----
            self.turnLabel = UIUtil.CreateText(content, "Your turn", 13, 'Arial Bold', true)
            LayoutHelpers.AtRightIn(self.turnLabel,  content, 6)
            LayoutHelpers.AtTopIn(self.turnLabel,    content, 20)

            self.statusLabel = UIUtil.CreateText(content, "", 11, 'Arial', true)
            LayoutHelpers.AtRightIn(self.statusLabel, content, 6)
            LayoutHelpers.AtTopIn(self.statusLabel,   content, 38)

            -- No resign button: closing the window is the resign path.
            self.hintLabel = UIUtil.CreateText(content, "Close window to resign", 10, 'Arial', true)
            LayoutHelpers.AtRightIn(self.hintLabel,  content, 6)
            LayoutHelpers.AtBottomIn(self.hintLabel, content, 10)
            self.hintLabel:DisableHitTest()

        end,

        -- Refresh all cell colors and piece labels from game state
        ---@param self ChessWindow
        ---@param state table
        RefreshBoard = function(self, state)
            local b       = state.board
            local kr,  kc  = FindKing(b, self._myColor)
            local okr, okc = FindKing(b, OtherColor(self._myColor))
            local inCheck    = IsInCheck(b, self._myColor)
            local oppInCheck = IsInCheck(b, OtherColor(self._myColor))

            for r = 1, 8 do
                for c = 1, 8 do
                    -- Base square color
                    local base
                    local rc2 = r + c
                    if rc2 - math.floor(rc2/2)*2 == 0 then base = C_LIGHT else base = C_DARK end

                    -- Last move highlight
                    local lm = self._lastMove
                    if lm and ((r==lm.fr and c==lm.fc) or (r==lm.tr and c==lm.tc)) then
                        base = C_LASTMOVE
                    end

                    -- Check highlight for both kings
                    if inCheck    and r == kr  and c == kc  then base = C_CHECK end
                    if oppInCheck and r == okr and c == okc then base = C_CHECK end

                    -- Selection highlight
                    if self._selected and self._selected[1]==r and self._selected[2]==c then
                        base = C_SELECTED
                    end

                    -- Valid move highlight
                    local isMove = false
                    for _, m in ipairs(self._legalMoves) do
                        if m.tr == r and m.tc == c then isMove = true break end
                    end
                    if isMove then base = C_MOVE end

                    self._cells[r][c]:SetSolidColor(base)

                    -- Piece icon texture
                    local piece = b[r][c]
                    local icon  = self._pieceIcons[r][c]
                    if piece then
                        local fname
                        if piece.col == WHITE then
                            fname = PIECE_DIR .. PIECE_FILE_W[piece.t]
                        else
                            fname = PIECE_DIR .. PIECE_FILE_B[piece.t]
                        end
                        icon:SetTexture(fname)
                    else
                        icon:SetSolidColor("00000000")
                    end
                end
            end
        end,

        -- Handle a cell click during the player's turn
        ---@param self ChessWindow
        OnCellClick = function(self, r, c)
            if self._gameOver or not self._myTurn then return end
            if not chGame then return end

            local state = chGame.state
            local b     = state.board
            local piece = b[r][c]

            -- If a piece is selected, check if this is a valid target
            if self._selected then
                local fr, fc = self._selected[1], self._selected[2]
                -- Find matching legal move
                local move = nil
                for _, m in ipairs(self._legalMoves) do
                    if m.tr == r and m.tc == c then
                        move = m
                        break
                    end
                end

                if move then
                    -- Re-verify the move is still legal (extra safety check)
                    local freshMoves = LegalMoves(state, fr, fc)
                    local stillLegal = false
                    for _, fm in ipairs(freshMoves) do
                        if fm.tr == r and fm.tc == c then stillLegal = true break end
                    end
                    if not stillLegal then
                        -- Move became illegal (shouldn't happen but guard anyway)
                        self._selected   = nil
                        self._legalMoves = {}
                        self:RefreshBoard(state)
                        return
                    end
                    -- Promotion
                    if not move.promo then
                        local p = b[fr][fc]
                        if p and p.t == PAWN and (r == 1 or r == 8) then
                            move.promo = QUEEN
                        end
                    end
                    self._selected   = nil
                    self._legalMoves = {}
                    self._onMove(move)
                    return
                end

                -- Clicked own piece — switch selection
                if piece and piece.col == self._myColor then
                    self._selected   = {r, c}
                    self._legalMoves = LegalMoves(state, r, c)
                    self:RefreshBoard(state)
                    return
                end

                -- Clicked empty/enemy with no valid move — deselect
                self._selected   = nil
                self._legalMoves = {}
                self:RefreshBoard(state)
                return
            end

            -- Nothing selected: select own piece
            if piece and piece.col == self._myColor then
                self._selected   = {r, c}
                self._legalMoves = LegalMoves(state, r, c)
                self:RefreshBoard(state)
            end
        end,

        SetMyTurn = function(self, isMyTurn)
            self._myTurn = isMyTurn
            if not IsDestroyed(self) then
                if isMyTurn then
                    self.turnLabel:SetText("YOUR TURN")
                else
                    self.turnLabel:SetText(self._oppNick .. "'s turn")
                end
            end
        end,

        SetStatus = function(self, msg)
            if not IsDestroyed(self) then
                self.statusLabel:SetText(msg)
            end
        end,

        EndGame = function(self, msg)
            self._gameOver = true
            self._selected   = nil
            self._legalMoves = {}
            if not IsDestroyed(self) then
                self.turnLabel:SetText("Game Over")
                self.statusLabel:SetText(msg)
                if self.hintLabel then self.hintLabel:SetText("") end
            end
        end,

        OnClose = function(self)
            if not self._gameOver then
                self._onClose()
            end
            chWindow = nil
            chGame   = nil
            self:Hide()
            self:Destroy()
        end,

        OnEscapePressed = function(self) end,
        OnShadowClicked = function(self) end,

        OnDestroy = function(self)
            chWindow = nil
            self._cells      = nil
            self._pieceIcons = nil
            if self._cellSz then self._cellSz:Destroy() end
            self._cellSz     = nil
            self.turnLabel   = nil
            self.statusLabel = nil
            self.hintLabel   = nil
            self.DragTL      = nil
            self.DragTR      = nil
            self.DragBL      = nil
            self.DragBR      = nil
            Window.OnDestroy(self)
        end,
    }

    -- =========================================================
    -- Game state and logic
    -- =========================================================

    local function NewState()
        return {
            board      = NewBoard(),
            turn       = WHITE,
            castling   = { wK=true, wQ=true, bK=true, bQ=true },
            enPassantCol = nil,
        }
    end

    local function SendMsg(data)
        data[chatTAG] = 1
        data.to = 'all'
        SessionSendChatMessage(data)
    end

    local function EndChessGame(msg, iLost)
        local opp = chGame and chGame.oppNick or nil
        if chGame then chGame.over = true end
        if not IsDestroyed(chWindow) then
            chWindow:EndGame(msg)
        end
        chGame = nil
        if iLost and opp ~= nil then
            MG_Stakes.Pay(opp, "Chess")
        end
    end

    local function ApplyMoveToGame(move)
        local state = chGame.state
        local newCastling = UpdateCastling(state.castling, move, state.board)
        local newEP       = GetEnPassant(state.board, move)
        local newBoard    = ApplyMove(state.board, move)

        chGame.state = {
            board        = newBoard,
            turn         = OtherColor(state.turn),
            castling     = newCastling,
            enPassantCol = newEP,
        }

        -- Update last move highlight
        if not IsDestroyed(chWindow) then
            chWindow._lastMove   = move
            chWindow._selected   = nil
            chWindow._legalMoves = {}
            chWindow:RefreshBoard(chGame.state)
        end
    end

    -- Called when opponent sends a move
    local function OnOpponentMove(move)
        if chGame == nil or chGame.over then return end

        -- Validate move: if it would capture our king, reject (state desynced)
        local state = chGame.state
        local target = state.board[move.tr] and state.board[move.tr][move.tc]
        if target and target.t == KING and target.col == chGame.myColor then
            -- Opponent captured our king - they were in check and moved illegally
            -- Treat as if we won
            EndChessGame("Illegal move by opponent. You win!")
            return
        end

        ApplyMoveToGame(move)

        local myCol   = chGame.myColor
        local newTurn = chGame.state.turn

        if IsCheckmate(chGame.state, myCol) then
            EndChessGame("Checkmate! You lose.", true)
            return
        end
        if IsStalemate(chGame.state, myCol) then
            EndChessGame("Stalemate! Draw.")
            return
        end

        if not IsDestroyed(chWindow) then
            chWindow:SetMyTurn(true)
            if IsInCheck(chGame.state, myCol) then
                chWindow:SetStatus("** YOUR KING IS IN CHECK **")
            else
                chWindow:SetStatus("")
            end
        end
        chGame.myTurn = true
    end

    -- Called when I make a move
    local function OnMyMove(move)
        if chGame == nil or chGame.over then return end
        if not chGame.myTurn then return end

        -- Send move to opponent
        SendMsg({ type = 'chess_move',
            fr = move.fr, fc = move.fc,
            tr = move.tr, tc = move.tc,
            promo = move.promo or 0 })

        ApplyMoveToGame(move)

        local oppCol = OtherColor(chGame.myColor)

        if IsCheckmate(chGame.state, oppCol) then
            SendMsg({ type = 'chess_gameover', result = 'checkmate' })
            EndChessGame("Checkmate! You win!")
            return
        end
        if IsStalemate(chGame.state, oppCol) then
            SendMsg({ type = 'chess_gameover', result = 'stalemate' })
            EndChessGame("Stalemate! Draw.")
            return
        end

        chGame.myTurn = false
        if not IsDestroyed(chWindow) then
            chWindow:SetMyTurn(false)
            if IsInCheck(chGame.state, oppCol) then
                chWindow:SetStatus("** OPPONENT IS IN CHECK **")
            else
                chWindow:SetStatus("")
            end
        end
    end

    -- =========================================================
    -- Start game
    -- =========================================================

    local function StartChessGame(oppNick, iAmWhite)
        if not IsDestroyed(chWindow) then return end

        chGame = {
            oppNick  = oppNick,
            myColor  = iAmWhite and WHITE or BLACK,
            myTurn   = iAmWhite,
            state    = NewState(),
            over     = false,
        }

        local function OnMove(move)
            OnMyMove(move)
        end

        -- Closing the window is the resign path now that the button is gone.
        local function OnWindowClose()
            local opp = chGame and chGame.oppNick or nil
            SendMsg({ type = 'chess_resign' })
            if opp ~= nil then
                MG_Stakes.Pay(opp, "Chess")
            end
        end

        chWindow = ChessWindow(GetFrame(0),
            iAmWhite and WHITE or BLACK,
            oppNick, OnMove, OnWindowClose)

        chWindow:RefreshBoard(chGame.state)

        if iAmWhite then
            chWindow:SetMyTurn(true)
            chWindow:SetStatus("You are White. Your move!")
        else
            chWindow:SetMyTurn(false)
            chWindow:SetStatus("You are Black. Waiting for White...")
        end
    end

    -- =========================================================
    -- Chat handlers
    -- =========================================================

    local chHandlers = {

        chess_challenge = function(sender, data)
            if sender == MyNick() then return end
            if disableChessRequests then return end
            if not IsDestroyed(chWindow) then return end
            if not IsDestroyed(chAcceptDialog) then return end

            chAcceptDialog = ChAcceptDialog(GetFrame(0), sender,
                function()
                    SendMsg({ type = 'chess_accept', target = sender })
                end,
                function()
                    SendMsg({ type = 'chess_decline', target = sender })
                end
            )
        end,

        chess_accept = function(sender, data)
            if data.target ~= MyNick() then return end
            if pendingChallenge == nil then return end
            pendingChallenge = nil
            -- Challenger is White, acceptor is Black
            SendMsg({ type = 'chess_start', target = sender })
            StartChessGame(sender, true)
        end,

        chess_decline = function(sender, data)
            if data.target ~= MyNick() then return end
            if pendingChallenge == nil then return end
            print("Chess: " .. sender .. " declined.")
            pendingChallenge = nil
        end,

        chess_start = function(sender, data)
            if data.target ~= MyNick() then return end
            StartChessGame(sender, false)
        end,

        chess_move = function(sender, data)
            if chGame == nil or chGame.over then return end
            if sender ~= chGame.oppNick then return end
            local move = {
                fr    = data.fr,
                fc    = data.fc,
                tr    = data.tr,
                tc    = data.tc,
                promo = (data.promo and data.promo ~= 0) and data.promo or nil,
            }
            OnOpponentMove(move)
        end,

        chess_resign = function(sender, data)
            if chGame == nil then return end
            if sender ~= chGame.oppNick then return end
            EndChessGame(sender .. " resigned. You win!")
        end,

        chess_gameover = function(sender, data)
            if chGame == nil then return end
            if sender ~= chGame.oppNick then return end
            if data.result == 'checkmate' then
                EndChessGame("Checkmate! You lose.", true)
            elseif data.result == 'stalemate' then
                EndChessGame("Stalemate! Draw.")
            end
        end,
    }

    import('/lua/ui/game/gamemain.lua').RegisterChatFunc(function(sender, data)
        local handler = chHandlers[data.type]
        if handler then handler(sender, data) end
    end, chatTAG)

    local function HandleChess()
        if not IsDestroyed(chWindow) then return end
        if pendingChallenge ~= nil then
            print "Chess: Already waiting for a response."
            return
        end

        pendingChallenge = true
        SendMsg({ type = 'chess_challenge' })
        print "Chess: Challenge sent! Others have 3 seconds to accept..."

        ForkThread(function()
            WaitSeconds(3)
            if pendingChallenge == nil then return end
            pendingChallenge = nil
            print "Chess: No one accepted."
        end)
    end

    -- Single bindable hotkey (plain + every modifier combo via MG_MODIFIERS + combo hook)
    ReUI.Actions.SelectionAction("Minigames - Chess", HandleChess, "Minigames", nil, MG_MODIFIERS)

    ReUI.Core.OnPostCreateUI(function()
        myNickname = GetArmiesTable().armiesTable[GetFocusArmy()].nickname
        local options = ReUI.Options.Mods["Minigames"]
        if options then
            options.disableChessRequests:Bind(function(opt) disableChessRequests = opt() end)
        end
    end)

    end -- CHESS

    -- ===================================================================
    -- MINESWEEPER
    -- ===================================================================
    do

    local UIUtil        = import('/lua/ui/uiutil.lua')
    local Group         = import("/lua/maui/group.lua").Group
    local LayoutHelpers = import("/lua/maui/layouthelpers.lua")
    local Bitmap        = import("/lua/maui/bitmap.lua").Bitmap
    local Window        = import("/lua/maui/window.lua").Window
    local LazyVar       = import('/lua/lazyvar.lua').Create

    -- =========================================================
    -- Options
    -- =========================================================

    local gridSize = 9
    local options  = ReUI.Options.Mods["Minigames"]
    if options and options.gridSize then
        options.gridSize:Bind(function(opt) gridSize = opt() end)
    end

    local hardMode = false
    if options and options.hardMode then
        options.hardMode:Bind(function(opt) hardMode = opt() end)
    end

    -- Mine count: roughly 15% of cells, minimum 1
    local function MineCount(sz)
        local ratio = 0.15
        if hardMode then ratio = 0.25 end
        local count = math.floor(sz * sz * ratio + 0.5)
        if count < 1 then count = 1 end
        return count
    end

    -- =========================================================
    -- Cell states
    -- =========================================================

    local STATE_HIDDEN   = 0
    local STATE_REVEALED = 1
    local STATE_FLAGGED  = 2
    local STATE_MINE     = 3   -- revealed mine (game over)

    -- Colors
    local COLOR_HIDDEN   = "ff2a4a6a"
    local COLOR_REVEALED = "ff1a1a2a"
    local COLOR_HOVER    = "ff3a6a9a"
    local COLOR_FLAG     = "ff8a3a1a"
    local COLOR_MINE     = "ffcc2200"
    local COLOR_SAFE     = "ff1a3a1a"
    local COLOR_GRID     = "ff0a2a3a"

    local NUMBER_COLORS = {
        "ff4488ff",  -- 1 blue
        "ff44bb44",  -- 2 green
        "ffcc4444",  -- 3 red
        "ff2244aa",  -- 4 dark blue
        "ffaa3322",  -- 5 dark red
        "ff44aaaa",  -- 6 cyan
        "ffaa44aa",  -- 7 purple
        "ff888888",  -- 8 grey
    }

    -- =========================================================
    -- Game logic
    -- =========================================================

    local function NewGrid(sz)
        local g = {}
        for r = 1, sz do
            g[r] = {}
            for c = 1, sz do
                g[r][c] = { state = STATE_HIDDEN, mine = false, adj = 0 }
            end
        end
        return g
    end

    local function PlaceMines(grid, sz, mines, skipR, skipC)
        -- Never place a mine on the first-clicked cell or its neighbours
        local safe = {}
        for dr = -1, 1 do
            for dc = -1, 1 do
                local r = skipR + dr
                local c = skipC + dc
                if r >= 1 and r <= sz and c >= 1 and c <= sz then
                    safe[r .. "," .. c] = true
                end
            end
        end

        local placed = 0
        local attempts = 0
        while placed < mines and attempts < 10000 do
            attempts = attempts + 1
            local r = math.random(1, sz)
            local c = math.random(1, sz)
            if not grid[r][c].mine and not safe[r .. "," .. c] then
                grid[r][c].mine = true
                placed = placed + 1
            end
        end

        -- Calculate adjacent mine counts
        for r = 1, sz do
            for c = 1, sz do
                if not grid[r][c].mine then
                    local count = 0
                    for dr = -1, 1 do
                        for dc = -1, 1 do
                            local nr = r + dr
                            local nc = c + dc
                            if nr >= 1 and nr <= sz and nc >= 1 and nc <= sz then
                                if grid[nr][nc].mine then
                                    count = count + 1
                                end
                            end
                        end
                    end
                    grid[r][c].adj = count
                end
            end
        end
    end

    local function FloodReveal(grid, sz, r, c)
        if r < 1 or r > sz or c < 1 or c > sz then return end
        local cell = grid[r][c]
        if cell.state ~= STATE_HIDDEN then return end
        cell.state = STATE_REVEALED
        if cell.adj == 0 and not cell.mine then
            for dr = -1, 1 do
                for dc = -1, 1 do
                    if dr ~= 0 or dc ~= 0 then
                        FloodReveal(grid, sz, r + dr, c + dc)
                    end
                end
            end
        end
    end

    local function CountRevealed(grid, sz)
        local count = 0
        for r = 1, sz do
            for c = 1, sz do
                if grid[r][c].state == STATE_REVEALED then
                    count = count + 1
                end
            end
        end
        return count
    end

    -- =========================================================
    -- Window
    -- =========================================================

    local msWindow = nil

    local WINDOW_W  = 460
    local WINDOW_H  = 460
    local MIN_W     = 280
    local MIN_H     = 300

    local MinesweeperWindow = Class(Window) {

        __init = function(self, parent, sz)
            local windowTextures = {
                tl = UIUtil.SkinnableFile('/game/panel/panel_brd_ul.dds'),
                tr = UIUtil.SkinnableFile('/game/panel/panel_brd_ur.dds'),
                tm = UIUtil.SkinnableFile('/game/panel/panel_brd_horz_um.dds'),
                ml = UIUtil.SkinnableFile('/game/panel/panel_brd_vert_l.dds'),
                m  = UIUtil.SkinnableFile('/game/panel/panel_brd_m.dds'),
                mr = UIUtil.SkinnableFile('/game/panel/panel_brd_vert_r.dds'),
                bl = UIUtil.SkinnableFile('/game/panel/panel_brd_ll.dds'),
                bm = UIUtil.SkinnableFile('/game/panel/panel_brd_lm.dds'),
                br = UIUtil.SkinnableFile('/game/panel/panel_brd_lr.dds'),
                borderColor = '00415055'
            }

            Window.__init(self, parent, "Minesweeper", nil, false, false, false, false,
                'MinesweeperWindow', {
                    Left   = parent.Width()  / 2 - WINDOW_W / 2,
                    Right  = parent.Width()  / 2 + WINDOW_W / 2,
                    Top    = parent.Height() / 2 - WINDOW_H / 2,
                    Bottom = parent.Height() / 2 + WINDOW_H / 2,
                }, windowTextures)
            self:SetMinimumResize(MIN_W, MIN_H)

            self._title:SetFont('Arial Black', 14)
            self._title:DisableHitTest()
            LayoutHelpers.AtCenterIn(self._title, self.TitleGroup)

            -- Drag handles
            self.DragTL = Bitmap(self, UIUtil.SkinnableFile '/game/drag-handle/drag-handle-ul_btn_up.dds')
            self.DragTR = Bitmap(self, UIUtil.SkinnableFile '/game/drag-handle/drag-handle-ur_btn_up.dds')
            self.DragBL = Bitmap(self, UIUtil.SkinnableFile '/game/drag-handle/drag-handle-ll_btn_up.dds')
            self.DragBR = Bitmap(self, UIUtil.SkinnableFile '/game/drag-handle/drag-handle-lr_btn_up.dds')
            LayoutHelpers.AtLeftTopIn(self.DragTL,     self, -24, -8)
            LayoutHelpers.AtRightTopIn(self.DragTR,    self, -22, -8)
            LayoutHelpers.AtLeftBottomIn(self.DragBL,  self, -24, -8)
            LayoutHelpers.AtRightBottomIn(self.DragBR, self, -22, -8)
            LayoutHelpers.DepthOverParent(self.DragTL, self, 10)
            LayoutHelpers.DepthOverParent(self.DragTR, self, 10)
            LayoutHelpers.DepthOverParent(self.DragBL, self, 10)
            LayoutHelpers.DepthOverParent(self.DragBR, self, 10)
            self.DragTL:DisableHitTest()
            self.DragTR:DisableHitTest()
            self.DragBL:DisableHitTest()
            self.DragBR:DisableHitTest()

            local content = self.ClientGroup

            -- Header bar: mine counter + status label
            local PAD = 8
            local HEADER_H = 28

            local headerBg = Bitmap(content)
            LayoutHelpers.LayoutFor(headerBg)
                :Left(function() return content.Left() + PAD end)
                :Right(function() return content.Right() - PAD end)
                :Top(function() return content.Top() + PAD end)
                :Height(function() return HEADER_H end)
                :Over(content, 1)
            headerBg:SetSolidColor("ff0a1a2e")
            headerBg:DisableHitTest()

            self.mineLabel = UIUtil.CreateText(content, "Mines: 0", 13, 'Arial Bold', true)
            LayoutHelpers.AtLeftIn(self.mineLabel, content, PAD * 2)
            LayoutHelpers.LayoutFor(self.mineLabel)
                :Top(function() return content.Top() + PAD + 6 end)
                :Over(content, 2)
            self.mineLabel:DisableHitTest()

            self.statusLabel = UIUtil.CreateText(content, "Left-click: reveal  Right-click: flag", 11, 'Arial', true)
            LayoutHelpers.AtHorizontalCenterIn(self.statusLabel, content)
            LayoutHelpers.LayoutFor(self.statusLabel)
                :Top(function() return content.Top() + PAD + 8 end)
                :Over(content, 2)
            self.statusLabel:DisableHitTest()

            -- New game button
            local btnNew = UIUtil.CreateButtonWithDropshadow(content, '/BUTTON/medium/', "New Game")
            LayoutHelpers.LayoutFor(btnNew)
                :AtRightIn(content, PAD)
                :Top(function() return content.Top() + PAD - 2 end)
                :Over(content, 2)

            -- Board area
            local boardGroup = Group(content)
            LayoutHelpers.LayoutFor(boardGroup)
                :Left(function() return content.Left() + PAD end)
                :Right(function() return content.Right() - PAD end)
                :Top(function() return content.Top() + PAD + HEADER_H + PAD end)
                :Bottom(function() return content.Bottom() - PAD end)
                :Over(content, 1)

            -- Cell size LazyVar
            self._cellSz = LazyVar(32)
            self._cellSz:Set(function()
                local w = math.floor(boardGroup.Width()  / sz)
                local h = math.floor(boardGroup.Height() / sz)
                if h < w then return h else return w end
            end)

            -- Game state
            local grid      = NewGrid(sz)
            local mines     = MineCount(sz)
            local started   = false   -- first click places mines
            local gameOver  = false
            local flagCount = 0
            local cells     = {}      -- cells[r][c] = { bg, txt }

            local function UpdateMineLabel()
                local remaining = mines - flagCount
                self.mineLabel:SetText("Mines: " .. remaining)
            end

            local RefreshCell
            local RefreshAll

            local function ShowAll(won)
                -- First reveal all non-flagged cells normally
                for r = 1, sz do
                    for c = 1, sz do
                        local cell = grid[r][c]
                        if cell.mine and cell.state ~= STATE_FLAGGED then
                            cell.state = STATE_REVEALED
                        end
                    end
                end
                -- RefreshAll will now correctly show mines via STATE_REVEALED + cell.mine
                RefreshAll()
            end

            RefreshCell = function(r, c)
                local cell = grid[r][c]
                local ui   = cells[r][c]
                local state = cell.state
                if state == STATE_HIDDEN then
                    ui.bg:SetSolidColor(COLOR_HIDDEN)
                    ui.txt:SetText("")
                elseif state == STATE_FLAGGED then
                    ui.bg:SetSolidColor(COLOR_FLAG)
                    ui.txt:SetText("F")
                    ui.txt:SetColor("ffff8844")
                elseif state == STATE_REVEALED then
                    if cell.mine then
                        ui.bg:SetSolidColor(COLOR_MINE)
                        ui.txt:SetText("*")
                        ui.txt:SetColor("ffffffff")
                    elseif cell.adj == 0 then
                        ui.bg:SetSolidColor(COLOR_REVEALED)
                        ui.txt:SetText("")
                    else
                        ui.bg:SetSolidColor(COLOR_REVEALED)
                        ui.txt:SetText(tostring(cell.adj))
                        ui.txt:SetColor(NUMBER_COLORS[cell.adj] or "ffffffff")
                    end
                end
            end

            RefreshAll = function()
                for r = 1, sz do
                    for c = 1, sz do
                        RefreshCell(r, c)
                    end
                end
            end

            local function StartNewGame()
                grid      = NewGrid(sz)
                started   = false
                gameOver  = false
                flagCount = 0
                UpdateMineLabel()
                self.statusLabel:SetText("Left-click: reveal  Right-click: flag")
                RefreshAll()
            end

            btnNew.OnClick = function() StartNewGame() end

            -- Build cell UI
            cells = {}
            for r = 1, sz do
                cells[r] = {}
                for c = 1, sz do
                    local fr = r
                    local fc = c

                    local bg = Bitmap(boardGroup)
                    LayoutHelpers.LayoutFor(bg)
                        :Left(function() return boardGroup.Left() + (fc-1) * self._cellSz() + 1 end)
                        :Top(function()  return boardGroup.Top()  + (fr-1) * self._cellSz() + 1 end)
                        :Width(function()  return self._cellSz() - 2 end)
                        :Height(function() return self._cellSz() - 2 end)
                        :Over(boardGroup, 1)
                    bg:SetSolidColor(COLOR_HIDDEN)

                    local txt = UIUtil.CreateText(boardGroup, "", 15, 'Arial Bold', true)
                    LayoutHelpers.LayoutFor(txt)
                        :Left(function()
                            local sz = self._cellSz()
                            return boardGroup.Left() + (fc-1) * sz + math.floor(sz / 2) - 5
                        end)
                        :Top(function()
                            local sz = self._cellSz()
                            return boardGroup.Top() + (fr-1) * sz + math.floor(sz / 2) - 8
                        end)
                        :Width(function() return 14 end)
                        :Height(function() return 16 end)
                        :Over(boardGroup, 2)
                    txt:DisableHitTest()

                    -- Handle all mouse events via HandleEvent
                    bg.HandleEvent = function(bg_self, event)
                        if event.Type == "MouseEnter" then
                            if not gameOver and grid[fr][fc].state == STATE_HIDDEN then
                                bg_self:SetSolidColor(COLOR_HOVER)
                            end
                        elseif event.Type == "MouseExit" then
                            if not gameOver and grid[fr][fc].state == STATE_HIDDEN then
                                bg_self:SetSolidColor(COLOR_HIDDEN)
                            end
                        elseif event.Type == "ButtonPress" then
                            if event.Modifiers.Left then
                                -- Left click: reveal
                                if gameOver then return true end
                                local cell = grid[fr][fc]
                                if cell.state == STATE_FLAGGED then return true end
                                if cell.state == STATE_REVEALED then return true end
                                if not started then
                                    started = true
                                    PlaceMines(grid, sz, mines, fr, fc)
                                end
                                if cell.mine then
                                    cell.state = STATE_REVEALED
                                    gameOver   = true
                                    ShowAll(false)
                                    self.statusLabel:SetText("BOOM! Game over.")
                                    self.statusLabel:SetColor("ffff4444")
                                else
                                    FloodReveal(grid, sz, fr, fc)
                                    local revealed = CountRevealed(grid, sz)
                                    if revealed == sz * sz - mines then
                                        gameOver = true
                                        ShowAll(true)
                                        self.statusLabel:SetText("You win! All clear!")
                                        self.statusLabel:SetColor("ff44ff44")
                                    else
                                        RefreshAll()
                                    end
                                end
                            elseif event.Modifiers.Right then
                                -- Right click: flag
                                if gameOver then return true end
                                local cell = grid[fr][fc]
                                if cell.state == STATE_REVEALED then return true end
                                if cell.state == STATE_HIDDEN then
                                    cell.state = STATE_FLAGGED
                                    flagCount  = flagCount + 1
                                elseif cell.state == STATE_FLAGGED then
                                    cell.state = STATE_HIDDEN
                                    flagCount  = flagCount - 1
                                end
                                UpdateMineLabel()
                                RefreshCell(fr, fc)
                            end
                        end
                        return true
                    end

                    cells[r][c] = { bg = bg, txt = txt }
                end
            end

            UpdateMineLabel()
            RefreshAll()
        end,

        OnClose = function(self)
            msWindow = nil
            self:Hide()
            self:Destroy()
        end,

        OnEscapePressed  = function(self) self:OnClose() end,
        OnShadowClicked  = function(self) end,

        OnDestroy = function(self)
            self._cellSz  = nil
            self.DragTL   = nil
            self.DragTR   = nil
            self.DragBL   = nil
            self.DragBR   = nil
            self.mineLabel  = nil
            self.statusLabel = nil
            Window.OnDestroy(self)
        end,
    }

    -- =========================================================
    -- Hotkey handler
    -- =========================================================

    local function OpenMinesweeper()
        if not IsDestroyed(msWindow) then return end
        msWindow = MinesweeperWindow(GetFrame(0), gridSize)
    end

    -- =========================================================
    -- Register hotkeys (5 modifier combos like other mods)
    -- =========================================================

    -- Single bindable hotkey (plain + every modifier combo)
    ReUI.Actions.SelectionAction("Minigames - Minesweeper", function(_sel) OpenMinesweeper() end, "Minigames", nil, MG_MODIFIERS)

    end -- MINESWEEPER

    -- ===================================================================
    -- BATTLESHIP
    -- ===================================================================
    do

    local UIUtil      = import('/lua/ui/uiutil.lua')
    local Group       = import("/lua/maui/group.lua").Group
    local LayoutHelpers = import("/lua/maui/layouthelpers.lua")
    local Bitmap      = import("/lua/maui/bitmap.lua").Bitmap
    local Popup       = import("/lua/ui/controls/popups/popup.lua").Popup
    local Window      = import("/lua/maui/window.lua").Window
    local LazyVar     = import('/lua/lazyvar.lua').Create

    -- =========================================================
    -- Constants
    -- =========================================================

    local GRID_SIZE   = 8          -- 8x8 board
    local CELL_PX     = 30         -- pixels per cell
    local GRID_PX     = GRID_SIZE * CELL_PX   -- 240px


    -- Ship definitions: { name, size }
    local SHIPS = {
        { name = "Carrier",    size = 5 },
        { name = "Battleship", size = 4 },
        { name = "Cruiser",    size = 3 },
        { name = "Destroyer",  size = 2 },
        { name = "Submarine",  size = 2 },
    }
    local TOTAL_SHIP_CELLS = 5 + 4 + 3 + 2 + 2  -- 16

    -- Cell states (for local board tracking)
    local STATE_EMPTY   = 0
    local STATE_SHIP    = 1
    local STATE_HIT     = 2
    local STATE_MISS    = 3

    -- Colors (FA solid color strings: AARRGGBB)
    local COLOR_WATER       = "ff1a3a5c"   -- dark navy
    local COLOR_SHIP        = "ff44aa44"   -- bright green - clearly visible ships
    local COLOR_HIT         = "ffcc2200"   -- red
    local COLOR_MISS        = "ffaaccdd"   -- light icy blue - clearly distinct from green ships
    local COLOR_HOVER       = "ff2255aa"   -- bright blue hover
    local COLOR_PREVIEW_OK  = "ff228833"   -- darker green preview
    local COLOR_PREVIEW_BAD = "ffaa2222"   -- red invalid preview
    local COLOR_GRID_LINE   = "ff0d2540"   -- subtle grid line
    local COLOR_SUNK        = "ff440000"   -- dark red for sunk ships
    local COLOR_HEADER      = "ff0a1a2e"   -- header background

    -- =========================================================
    -- Shared helpers
    -- =========================================================

    local myNickname = nil

    local function MyNick()
        return myNickname or GetArmiesTable().armiesTable[GetFocusArmy()].nickname
    end


    -- =========================================================
    -- Board helpers
    -- =========================================================

    -- Create a fresh GRID_SIZE x GRID_SIZE board filled with STATE_EMPTY
    local function NewBoard()
        local board = {}
        for r = 1, GRID_SIZE do
            board[r] = {}
            for c = 1, GRID_SIZE do
                board[r][c] = STATE_EMPTY
            end
        end
        return board
    end

    -- Return true if all cells of a ship placement are in-bounds and empty
    local function CanPlace(board, r, c, size, horiz)
        for i = 0, size - 1 do
            local rr = r + (horiz and 0 or i)
            local cc = c + (horiz and i or 0)
            if rr < 1 or rr > GRID_SIZE or cc < 1 or cc > GRID_SIZE then
                return false
            end
            if board[rr][cc] ~= STATE_EMPTY then return false end
        end
        return true
    end

    -- Place a ship on the board (mutates board)
    local function PlaceShip(board, r, c, size, horiz)
        for i = 0, size - 1 do
            local rr = r + (horiz and 0 or i)
            local cc = c + (horiz and i or 0)
            board[rr][cc] = STATE_SHIP
        end
    end

    -- Count cells with a given state
    local function CountState(board, state)
        local n = 0
        for r = 1, GRID_SIZE do
            for c = 1, GRID_SIZE do
                if board[r][c] == state then n = n + 1 end
            end
        end
        return n
    end

    -- =========================================================
    -- Grid widget: a clickable 8x8 bitmap grid
    --
    -- Each cell is a small Bitmap child. Supports:
    --   grid:SetCell(r, c, color)    -- set cell color
    --   grid:SetHoverCallback(fn)    -- fn(r, c) called on hover
    --   grid:SetClickCallback(fn)    -- fn(r, c) called on click
    -- =========================================================

    -- cellSz: LazyVar shared between both grids, recomputes on window resize.
    -- Each grid occupies half the client width minus margins and label space.
    -- Set after the Window is created; passed into CreateGrid.
    local sharedCellSz = LazyVar(30)

    local function CreateGrid(boardGroup, isLeft, clickable)
        local MARGIN   = 16   -- left margin / gap between grids
        local LABEL_W  = 14   -- width of row label column
        local LABEL_H  = 14   -- height of col label row
        local GAP      = 10   -- gap between the two grids

        -- Grid container: positioned and sized via LazyVar
        local container = Group(boardGroup)

        LayoutHelpers.LayoutFor(container)
            :Left(function()
                local sz = sharedCellSz()
                if isLeft then
                    return boardGroup.Left() + MARGIN + LABEL_W
                else
                    return boardGroup.Left() + MARGIN + LABEL_W + GRID_SIZE * sz + GAP + LABEL_W + MARGIN
                end
            end)
            :Top(function()
                return boardGroup.Top() + LABEL_H + 4
            end)
            :Width( function() return GRID_SIZE * sharedCellSz() end)
            :Height(function() return GRID_SIZE * sharedCellSz() end)
            :Over(boardGroup, 1)

        -- Background
        local bg = Bitmap(container)
        LayoutHelpers.FillParent(bg, container)
        bg:SetSolidColor(COLOR_HEADER)
        bg:DisableHitTest()

        local cells = {}
        for r = 1, GRID_SIZE do
            cells[r] = {}
            for c = 1, GRID_SIZE do
                local cell = Bitmap(container)
                local row, col = r, c

                LayoutHelpers.LayoutFor(cell)
                    :Left(  function() return container.Left() + (col-1) * sharedCellSz() + 1 end)
                    :Top(   function() return container.Top()  + (row-1) * sharedCellSz() + 1 end)
                    :Width( function() return sharedCellSz() - 2 end)
                    :Height(function() return sharedCellSz() - 2 end)
                    :Over(container, 2)

                cell:SetSolidColor(COLOR_WATER)
                if clickable then
                    cell:EnableHitTest()
                else
                    cell:DisableHitTest()
                end

                if clickable then
                    cell.HandleEvent = function(self, event)
                        if event.Type == "MouseEnter" then
                            if container._hoverCb then container._hoverCb(row, col) end
                        elseif event.Type == "MouseExit" then
                            if container._hoverExitCb then container._hoverExitCb(row, col) end
                        elseif event.Type == "ButtonPress" and event.Modifiers.Left then
                            if container._clickCb then container._clickCb(row, col) end
                        end
                        return true
                    end
                end

                cells[r][c] = cell
            end
        end

        container._cells = cells
        container._hoverCb = nil
        container._hoverExitCb = nil
        container._clickCb = nil

        function container:SetCell(r, c, color)
            if cells[r] and cells[r][c] then
                cells[r][c]:SetSolidColor(color)
            end
        end
        function container:SetHoverCallback(fn, exitFn)
            self._hoverCb = fn
            self._hoverExitCb = exitFn
        end
        function container:SetClickCallback(fn)
            self._clickCb = fn
        end

        return container
    end

    -- =========================================================
    -- Accept / Decline popup  (same pattern as blackjack)
    -- =========================================================

    local bsAcceptDialog = nil

    local BsAcceptDialog = ClassUI(Popup) {
        __init = function(self, parent, challengerNick, onAccept, onDecline)
            self._done = false
            local content = Group(parent)
            LayoutHelpers.SetDimensions(content, 420, 135)

            local titleText = UIUtil.CreateText(content,
                challengerNick .. " challenges you to Battleship!",
                16, 'Arial Bold', true)
            LayoutHelpers.AtHorizontalCenterIn(titleText, content)
            LayoutHelpers.AtTopIn(titleText, content, 14)

            local subText = UIUtil.CreateText(content,
                "Loser's selected units are destroyed.",
                13, 'Arial', true)
            LayoutHelpers.AtHorizontalCenterIn(subText, content)
            LayoutHelpers.AtTopIn(subText, content, 38)

            self.countdownLabel = UIUtil.CreateText(content, "Auto-declining in 3...", 12, 'Arial', true)
            LayoutHelpers.AtHorizontalCenterIn(self.countdownLabel, content)
            LayoutHelpers.AtTopIn(self.countdownLabel, content, 62)

            local btnAccept  = UIUtil.CreateButtonWithDropshadow(content, '/BUTTON/medium/', "Accept")
            local btnDecline = UIUtil.CreateButtonWithDropshadow(content, '/BUTTON/medium/', "Decline")
            LayoutHelpers.AtBottomIn(btnAccept,  content, 10)
            LayoutHelpers.AtBottomIn(btnDecline, content, 10)
            LayoutHelpers.AtHorizontalCenterIn(btnDecline, content)
            LayoutHelpers.LeftOf(btnAccept, btnDecline, 10)

            local function doDecline()
                if not self._done then
                    self._done = true
                    onDecline()
                end
                if not IsDestroyed(self) then self:Close() end
            end
            local function doAccept()
                self._done = true
                onAccept()
                if not IsDestroyed(self) then self:Close() end
            end

            btnAccept.OnClick  = doAccept
            btnDecline.OnClick = doDecline

            Popup.__init(self, parent, content)

            ForkThread(function()
                for i = 3, 1, -1 do
                    if IsDestroyed(self) or self._done then return end
                    self.countdownLabel:SetText("Auto-declining in " .. i .. "...")
                    WaitSeconds(1)
                end
                if not IsDestroyed(self) and not self._done then doDecline() end
            end)
        end,
        OnEscapePressed = function(self) end,
        OnShadowClicked = function(self) end,
        OnDestroy = function(self)
            self.countdownLabel = nil
            Popup.OnDestroy(self)
        end,
    }

    -- =========================================================
    -- Main Battleship window
    --
    -- Layout (580 wide x 560 tall):
    --   Title bar
    --   [ Your grid 240px ]   [ Opponent grid 240px ]
    --   Status line
    --   Ship list / placement controls
    --   Timer bar
    -- =========================================================

    local WINDOW_W = 580
    local WINDOW_H = 560
    local GRID_TOP = 50    -- y offset of grids from top of content
    local GRID_TOP_C = 28  -- y offset inside ClientGroup (no title bar)
    local MY_GRID_LEFT   = 10
    local OPP_GRID_LEFT  = 330

    local options = ReUI.Options.Mods["Minigames"]
    local disableBsRequests = false

    local bsWindow = nil   -- active battleship popup
    local chatTAG = "Battleship"
    local bsGame  = nil

    local BattleshipWindow = Class(Window) {

        ---@param self BattleshipWindow
        ---@param parent any
        ---@param oppNick string
        ---@param onShot fun(r:number, c:number)        called when player clicks opp grid
        ---@param onReady fun()                         called when placement is done
        __init = function(self, parent, oppNick, onShot, onReady)
            self.oppNick  = oppNick
            self.onShot   = onShot
            self.onReady  = onReady
            self._phase   = "placement"   -- "placement" or "battle"
            self._myTurn  = false

            local windowTextures = {
                tl = UIUtil.SkinnableFile('/game/panel/panel_brd_ul.dds'),
                tr = UIUtil.SkinnableFile('/game/panel/panel_brd_ur.dds'),
                tm = UIUtil.SkinnableFile('/game/panel/panel_brd_horz_um.dds'),
                ml = UIUtil.SkinnableFile('/game/panel/panel_brd_vert_l.dds'),
                m  = UIUtil.SkinnableFile('/game/panel/panel_brd_m.dds'),
                mr = UIUtil.SkinnableFile('/game/panel/panel_brd_vert_r.dds'),
                bl = UIUtil.SkinnableFile('/game/panel/panel_brd_ll.dds'),
                bm = UIUtil.SkinnableFile('/game/panel/panel_brd_lm.dds'),
                br = UIUtil.SkinnableFile('/game/panel/panel_brd_lr.dds'),
                borderColor = '00415055'
            }
            Window.__init(self, parent, "Battleship vs " .. oppNick, nil, false, false, false, false,
                'BattleshipWindow', {
                    Left   = parent.Width()  / 2 - WINDOW_W / 2,
                    Right  = parent.Width()  / 2 + WINDOW_W / 2,
                    Top    = parent.Height() / 2 - WINDOW_H / 2,
                    Bottom = parent.Height() / 2 + WINDOW_H / 2,
                }, windowTextures)
            self:SetMinimumResize(400, 420)

            self._title:SetFont('Arial Black', 14)
            self._title:DisableHitTest()
            LayoutHelpers.AtCenterIn(self._title, self.TitleGroup)

            self.DragTL = Bitmap(self, UIUtil.SkinnableFile '/game/drag-handle/drag-handle-ul_btn_up.dds')
            self.DragTR = Bitmap(self, UIUtil.SkinnableFile '/game/drag-handle/drag-handle-ur_btn_up.dds')
            self.DragBL = Bitmap(self, UIUtil.SkinnableFile '/game/drag-handle/drag-handle-ll_btn_up.dds')
            self.DragBR = Bitmap(self, UIUtil.SkinnableFile '/game/drag-handle/drag-handle-lr_btn_up.dds')
            LayoutHelpers.AtLeftTopIn(self.DragTL,     self, -24, -8)
            LayoutHelpers.AtRightTopIn(self.DragTR,    self, -22, -8)
            LayoutHelpers.AtLeftBottomIn(self.DragBL,  self, -24, -8)
            LayoutHelpers.AtRightBottomIn(self.DragBR, self, -22, -8)
            LayoutHelpers.DepthOverParent(self.DragTL, self, 10)
            LayoutHelpers.DepthOverParent(self.DragTR, self, 10)
            LayoutHelpers.DepthOverParent(self.DragBL, self, 10)
            LayoutHelpers.DepthOverParent(self.DragBR, self, 10)
            self.DragTL:DisableHitTest()
            self.DragTR:DisableHitTest()
            self.DragBL:DisableHitTest()
            self.DragBR:DisableHitTest()

            -- All children go into self.ClientGroup via a boardGroup that fills it
            local content    = self.ClientGroup
            local boardGroup = Group(content)
            LayoutHelpers.FillParent(boardGroup, content)

            -- sharedCellSz: each grid is half the available width (minus margins/labels/gap)
            local MARGIN  = 16
            local LABEL_W = 14
            local LABEL_H = 14
            local GAP     = 10
            self._cellSz  = sharedCellSz  -- keep reference so it isn't GC'd
            sharedCellSz:Set(function()
                local availW = math.floor((boardGroup.Width()  - MARGIN*3 - LABEL_W*2 - GAP) / (GRID_SIZE * 2))
                local availH = math.floor((boardGroup.Height() - LABEL_H - 80) / GRID_SIZE)
                if availH < availW then return availH else return availW end
            end)

            -- ---- Column/row labels for both grids ----
            local COL_LABELS = {"1","2","3","4","5","6","7","8"}
            local ROW_LABELS = {"A","B","C","D","E","F","G","H"}

            local function AddLabels(isLeft)
                for i = 1, GRID_SIZE do
                    local fi = i
                    -- column number above each cell
                    local lc = UIUtil.CreateText(boardGroup, COL_LABELS[i], 9, 'Arial', true)
                    LayoutHelpers.LayoutFor(lc)
                        :Left(function()
                            local sz  = sharedCellSz()
                            local gx  = boardGroup.Left() + MARGIN + LABEL_W
                            if not isLeft then gx = gx + GRID_SIZE*sz + GAP + LABEL_W + MARGIN end
                            return gx + (fi-1)*sz + math.floor(sz/2) - 3
                        end)
                        :Top(function() return boardGroup.Top() + 2 end)
                        :Width(function() return 10 end):Height(function() return 12 end)
                        :Over(boardGroup, 1)
                    lc:DisableHitTest()
                    -- row letter left of each row
                    local lr = UIUtil.CreateText(boardGroup, ROW_LABELS[i], 9, 'Arial', true)
                    LayoutHelpers.LayoutFor(lr)
                        :Left(function()
                            local sz = sharedCellSz()
                            if isLeft then return boardGroup.Left() + MARGIN end
                            return boardGroup.Left() + MARGIN + LABEL_W + GRID_SIZE*sz + GAP
                        end)
                        :Top(function()
                            return boardGroup.Top() + LABEL_H + 4 + (fi-1)*sharedCellSz() + math.floor(sharedCellSz()/2) - 5
                        end)
                        :Width(function() return 12 end):Height(function() return 12 end)
                        :Over(boardGroup, 1)
                    lr:DisableHitTest()
                end
            end
            AddLabels(true)   -- my grid labels
            AddLabels(false)  -- opp grid labels

            -- ---- Column headers ----
            local myHeader = UIUtil.CreateText(boardGroup, "Your Fleet", 12, 'Arial Bold', true)
            LayoutHelpers.LayoutFor(myHeader)
                :Left(function() return boardGroup.Left() + MARGIN + LABEL_W + math.floor(GRID_SIZE * sharedCellSz() / 2) - 28 end)
                :Top( function() return boardGroup.Top() + LABEL_H + 4 + GRID_SIZE * sharedCellSz() + 4 end)
                :Width(function() return 80 end):Height(function() return 14 end)
                :Over(boardGroup, 1)
            myHeader:DisableHitTest()

            local oppHeader = UIUtil.CreateText(boardGroup, oppNick .. "'s Waters", 12, 'Arial Bold', true)
            LayoutHelpers.LayoutFor(oppHeader)
                :Left(function()
                    local sz = sharedCellSz()
                    return boardGroup.Left() + MARGIN*2 + LABEL_W*2 + GRID_SIZE*sz + GAP + math.floor(GRID_SIZE*sz/2) - 35
                end)
                :Top( function() return boardGroup.Top() + LABEL_H + 4 + GRID_SIZE * sharedCellSz() + 4 end)
                :Width(function() return 100 end):Height(function() return 14 end)
                :Over(boardGroup, 1)
            oppHeader:DisableHitTest()

            -- ---- Grids ----
            self.myGrid  = CreateGrid(boardGroup, true,  true)
            self.oppGrid = CreateGrid(boardGroup, false, true)

            -- Disable opp grid hit-test during placement; enabled when battle starts
            -- (handled by SetMyTurn)

            -- ---- Status label ----
            self.statusLabel = UIUtil.CreateText(boardGroup, "Place your ships!", 13, 'Arial', true)
            LayoutHelpers.AtHorizontalCenterIn(self.statusLabel, boardGroup)
            LayoutHelpers.AtBottomIn(self.statusLabel, boardGroup, 56)

            -- ---- Ship placement controls ----
            -- Current ship index, orientation
            self._placeIdx   = 1
            self._placeHoriz = true
            self._myBoard    = NewBoard()   -- STATE_SHIP marks placed cells
            self._placedCount = 0           -- ships placed so far

            self.shipLabel = UIUtil.CreateText(boardGroup,
                "Placing: " .. SHIPS[1].name .. " (size " .. SHIPS[1].size .. ")",
                13, 'Arial', true)
            LayoutHelpers.AtLeftIn(self.shipLabel, boardGroup, 10)
            LayoutHelpers.AtBottomIn(self.shipLabel, boardGroup, 36)

            local btnRotate = UIUtil.CreateButtonWithDropshadow(boardGroup, '/BUTTON/medium/', "Rotate")
            LayoutHelpers.AtLeftIn(btnRotate, boardGroup, 10)
            LayoutHelpers.AtBottomIn(btnRotate, boardGroup, 6)

            local btnReady = UIUtil.CreateButtonWithDropshadow(boardGroup, '/BUTTON/medium/', "Ready!")
            LayoutHelpers.AtLeftIn(btnReady, boardGroup, 120)
            LayoutHelpers.AtBottomIn(btnReady, boardGroup, 6)
            btnReady:Disable()

            self.btnRotate = btnRotate
            self.btnReady  = btnReady

            btnRotate.OnClick = function()
                self._placeHoriz = not self._placeHoriz
            end

            btnReady.OnClick = function()
                if self._placedCount < table.getn(SHIPS) then return end
                btnReady:Disable()
                btnRotate:Disable()
                self.shipLabel:SetText("Fleet deployed. Waiting for opponent...")
                self.onReady()
            end

            -- Opponent grid: shoot on click during battle
            self.oppGrid:SetClickCallback(function(r, c)
                if self._phase ~= "battle" or not self._myTurn then return end
                self.onShot(r, c)
            end)

            -- My grid: handle ship placement clicks
            self.myGrid:SetClickCallback(function(r, c)
                if self._phase ~= "placement" then return end
                self:TryPlaceShip(r, c)
            end)

            -- My grid hover: show placement preview
            self.myGrid:SetHoverCallback(
                function(r, c) self:ShowPreview(r, c) end,
                function(r, c) self:ClearPreview()    end
            )

            -- Opponent grid hover: highlight target cell
            self.oppGrid:SetHoverCallback(
                function(r, c)
                    if self._phase == "battle" and self._myTurn then
                        self.oppGrid:SetCell(r, c, COLOR_HOVER)
                    end
                end,
                function(r, c)
                    -- restore cell color on exit
                    local state = self._oppBoard and self._oppBoard[r][c] or STATE_EMPTY
                    self.oppGrid:SetCell(r, c, self:OppCellColor(state))
                end
            )

            self._oppBoard = NewBoard()   -- tracks hits/misses on opponent's side
            self._previewCells = {}
        end,

        -- Return display color for opponent board cell
        ---@param self BattleshipWindow
        OppCellColor = function(self, state)
            if state == STATE_HIT  then return COLOR_HIT  end
            if state == STATE_MISS then return COLOR_MISS end
            return COLOR_WATER
        end,

        -- Show ship placement preview on my grid
        ---@param self BattleshipWindow
        ShowPreview = function(self, r, c)
            self:ClearPreview()
            if self._phase ~= "placement" then return end
            if self._placeIdx > table.getn(SHIPS) then return end
            local ship = SHIPS[self._placeIdx]
            local ok = CanPlace(self._myBoard, r, c, ship.size, self._placeHoriz)
            local color = ok and COLOR_PREVIEW_OK or COLOR_PREVIEW_BAD
            local preview = {}
            for i = 0, ship.size - 1 do
                local rr = r + (self._placeHoriz and 0 or i)
                local cc = c + (self._placeHoriz and i or 0)
                if rr >= 1 and rr <= GRID_SIZE and cc >= 1 and cc <= GRID_SIZE then
                    self.myGrid:SetCell(rr, cc, color)
                    preview[table.getn(preview) + 1] = {rr, cc}
                end
            end
            self._previewCells = preview
        end,

        -- Clear preview, restoring underlying cell colors
        ---@param self BattleshipWindow
        ClearPreview = function(self)
            for _, pos in ipairs(self._previewCells) do
                local r, c = pos[1], pos[2]
                local state = self._myBoard[r][c]
                self.myGrid:SetCell(r, c, state == STATE_SHIP and COLOR_SHIP or COLOR_WATER)
            end
            self._previewCells = {}
        end,

        -- Try to place the current ship at r,c
        ---@param self BattleshipWindow
        TryPlaceShip = function(self, r, c)
            if self._placeIdx > table.getn(SHIPS) then return end
            local ship = SHIPS[self._placeIdx]
            if not CanPlace(self._myBoard, r, c, ship.size, self._placeHoriz) then
                return
            end
            PlaceShip(self._myBoard, r, c, ship.size, self._placeHoriz)
            -- Paint placed cells
            for i = 0, ship.size - 1 do
                local rr = r + (self._placeHoriz and 0 or i)
                local cc = c + (self._placeHoriz and i or 0)
                self.myGrid:SetCell(rr, cc, COLOR_SHIP)
            end
            self._placeIdx   = self._placeIdx + 1
            self._placedCount = self._placedCount + 1
            self._previewCells = {}
            if self._placeIdx <= table.getn(SHIPS) then
                local next = SHIPS[self._placeIdx]
                self.shipLabel:SetText("Placing: " .. next.name .. " (size " .. next.size .. ")")
            else
                self.shipLabel:SetText("All ships placed!")
                self.btnReady:Enable()
            end
        end,

        -- Switch to battle phase
        ---@param self BattleshipWindow
        StartBattle = function(self)
            self._phase = "battle"
            self.btnRotate:Disable()
            self.btnReady:Disable()
            self.shipLabel:SetText("")
        end,

        -- Set whose turn it is and update UI
        ---@param self BattleshipWindow
        ---@param isMyTurn boolean
        SetMyTurn = function(self, isMyTurn)
            self._myTurn = isMyTurn
            if isMyTurn then
                self.statusLabel:SetText("YOUR TURN — click to fire!")
            else
                self.statusLabel:SetText("Waiting for " .. self.oppNick .. " to fire...")
            end
        end,

        -- Record a shot on MY grid (opponent fired at me)
        ---@param self BattleshipWindow
        ---@param r number
        ---@param c number
        ---@return boolean hit
        RecordIncomingShot = function(self, r, c)
            local state = self._myBoard[r][c]
            local hit = (state == STATE_SHIP)
            self._myBoard[r][c] = hit and STATE_HIT or STATE_MISS
            self.myGrid:SetCell(r, c, hit and COLOR_HIT or COLOR_MISS)
            return hit
        end,

        -- Record a shot on OPPONENT'S grid (I fired)
        ---@param self BattleshipWindow
        ---@param r number
        ---@param c number
        ---@param hit boolean
        RecordOutgoingShot = function(self, r, c, hit)
            self._oppBoard[r][c] = hit and STATE_HIT or STATE_MISS
            self.oppGrid:SetCell(r, c, hit and COLOR_HIT or COLOR_MISS)
        end,

        -- How many of my ship cells are still intact?
        ---@param self BattleshipWindow
        ---@return integer
        MyShipsRemaining = function(self)
            return CountState(self._myBoard, STATE_SHIP)
        end,

        ---@param self BattleshipWindow
        ---@param msg string
        SetStatus = function(self, msg)
            self.statusLabel:SetText(msg)
        end,

        -- Check if the ship occupying cell (r,c) on my board is fully sunk.
        -- Flood-fills orthogonally from (r,c) across HIT cells; sunk if no adjacent SHIP cells remain.
        ---@param self BattleshipWindow
        ---@param r number
        ---@param c number
        ---@return boolean
        IsShipAtSunk = function(self, r, c)
            -- BFS from (r,c) across STATE_HIT cells to find the ship's extent
            local visited = {}
            local queue = {{r, c}}
            local idx = 1
            while idx <= table.getn(queue) do
                local cur = queue[idx]
                idx = idx + 1
                local cr, cc = cur[1], cur[2]
                local key = cr * 100 + cc
                if not visited[key] then
                    visited[key] = true
                    -- If any adjacent cell is still STATE_SHIP, ship is not sunk
                    local dirs = {{-1,0},{1,0},{0,-1},{0,1}}
                    for _, d in ipairs(dirs) do
                        local nr, nc = cr + d[1], cc + d[2]
                        if nr >= 1 and nr <= GRID_SIZE and nc >= 1 and nc <= GRID_SIZE then
                            local s = self._myBoard[nr][nc]
                            if s == STATE_SHIP then return false end
                            if s == STATE_HIT and not visited[nr * 100 + nc] then
                                queue[table.getn(queue) + 1] = {nr, nc}
                            end
                        end
                    end
                end
            end
            return true
        end,

        -- Has this cell on the opponent grid already been shot?
        ---@param self BattleshipWindow
        ---@param r number
        ---@param c number
        ---@return boolean
        OppCellAlreadyShot = function(self, r, c)
            local s = self._oppBoard[r][c]
            return s == STATE_HIT or s == STATE_MISS
        end,

        OnClose = function(self)
            if bsGame ~= nil and not bsGame.gameOver and not bsGame.isSolo then
                local opp = bsGame.oppNick
                SessionSendChatMessage({ [chatTAG] = true, to = 'all', type = 'bs_surrender', target = opp })
                if opp ~= nil then
                    MG_Stakes.Pay(opp, "Battleship")
                end
            end
            bsGame   = nil
            bsWindow = nil
            self:Hide()
            self:Destroy()
        end,

        OnEscapePressed = function(self) end,
        OnShadowClicked = function(self) end,

        OnDestroy = function(self)
            bsWindow = nil
            self.statusLabel  = nil
            self.shipLabel    = nil
            self.btnRotate    = nil
            self.btnReady     = nil
            self.myGrid       = nil
            self.oppGrid      = nil
            self.DragTL       = nil
            self.DragTR       = nil
            self.DragBL       = nil
            self.DragBR       = nil
            Window.OnDestroy(self)
        end,
    }

    -- =========================================================
    -- Chat sync
    -- =========================================================
    --[[
    bsGame fields:
        oppNick         -- string
        myReady         -- bool
        oppReady        -- bool
        myTurn          -- bool (true = I go first = I am challenger)
        gameOver        -- bool
    ]]

    local pendingChallenge = nil   -- set while waiting for accept



    -- -------------------------------------------------------
    -- Game logic
    -- -------------------------------------------------------

    local function EndGame(iWon, reason)
        if bsGame == nil or bsGame.gameOver then return end
        bsGame.gameOver = true
        local opp  = bsGame.oppNick
        local solo = bsGame.isSolo
        if not IsDestroyed(bsWindow) then
            if iWon then
                bsWindow:SetStatus("YOU WIN! " .. reason .. "  —  Close window to dismiss.")
                print("Battleship: You win! " .. reason)
            else
                bsWindow:SetStatus("YOU LOSE! " .. reason .. "  —  Close window to dismiss.")
                print("Battleship: You lose. " .. reason)
            end
        end
        bsGame = nil
        if (not iWon) and (not solo) and opp ~= nil then
            MG_Stakes.Pay(opp, "Battleship")
        end
    end

    -- Called when I fire at (r, c)
    local function FireShot(r, c)
        if bsGame == nil or bsGame.gameOver then return end
        if IsDestroyed(bsWindow) then return end
        if bsWindow:OppCellAlreadyShot(r, c) then return end  -- ignore repeat clicks


        -- Tell opponent I fired at this cell (skip in solo mode)
        if not bsGame.isSolo then
            SessionSendChatMessage({ [chatTAG] = true, to = 'all', type = 'bs_shot', row = r, col = c, target = bsGame.oppNick })
        end

        -- Switch to waiting; opponent will respond with bs_result
        bsGame.myTurn = false
        bsWindow:SetMyTurn(false)
        bsWindow:SetStatus("Fired at " .. string.char(64 + r) .. c .. "! Waiting...")
    end

    -- Called when I receive the result of my shot from the opponent
    local function OnShotResult(hit, r, c, sunk, iLost)
        if bsGame == nil or bsGame.gameOver then return end
        if IsDestroyed(bsWindow) then return end

        bsWindow:RecordOutgoingShot(r, c, hit)

        if iLost then
            -- opponent says all their ships are sunk → I win
            EndGame(true, "All enemy ships sunk!")
            return
        end

        local msg = hit and "HIT at " or "MISS at "
        msg = msg .. string.char(64 + r) .. c
        if sunk then msg = msg .. " — ship sunk!" end

        -- Now it's opponent's turn
        bsGame.myTurn = false
        bsWindow:SetMyTurn(false)
        bsWindow:SetStatus(msg .. "  |  Waiting for " .. bsGame.oppNick .. "...")


    end

    -- Called when the opponent fires at me (I compute hit/miss and send result back)
    local function OnIncomingShot(r, c)
        if bsGame == nil or bsGame.gameOver then return end
        if IsDestroyed(bsWindow) then return end

        -- Count ship cells before the hit to detect if a whole ship was sunk
        local cellsBefore = bsWindow:MyShipsRemaining()
        local hit = bsWindow:RecordIncomingShot(r, c)
        local cellsAfter  = bsWindow:MyShipsRemaining()
        local remaining = cellsAfter
        local iLost = (remaining == 0)

        -- A ship is sunk when a hit reduces a contiguous group to zero.
        -- We track per-ship sinking by storing hit counts per ship index.
        -- Simple approach: the opponent tracks ship health via RecordOutgoingShot.
        -- We just send whether this specific hit finished off a ship:
        -- that happens when cellsBefore > cellsAfter (a cell was removed) AND
        -- we can detect the ship is fully hit. Since we don't track per-ship IDs,
        -- we use a helper: check if the hit cell's ship-group has no STATE_SHIP left.
        local sunkVal = 0
        if hit then
            sunkVal = bsWindow:IsShipAtSunk(r, c) and 1 or 0
        end

        -- Send result back to opponent
        -- SessionSendChatMessage cannot serialize booleans; use 0/1 instead
        local hitVal  = hit   and 1 or 0
        local lostVal = iLost and 1 or 0
        SessionSendChatMessage({ [chatTAG] = true, to = 'all', type = 'bs_result', row = r, col = c, hit = hitVal, sunk = sunkVal, lost = lostVal, target = bsGame.oppNick })

        if iLost then
            EndGame(false, "All your ships have been sunk!")
            return
        end

        local msg = hit and ("Hit at " .. string.char(64+r) .. c .. "!") or ("Miss at " .. string.char(64+r) .. c)
        bsGame.myTurn = true
        bsWindow:SetMyTurn(true)
        bsWindow:SetStatus(msg .. "  |  YOUR TURN")


    end

    -- -------------------------------------------------------
    -- Solo bot game (fallback when nobody accepts the challenge)
    -- -------------------------------------------------------

    local function StartSoloGame()
        if not IsDestroyed(bsWindow) then return end

        -- Place bot ships randomly
        local botBoard = NewBoard()
        local function PlaceBotShips()
            for _, ship in ipairs(SHIPS) do
                local placed = false
                local attempts = 0
                while not placed and attempts < 500 do
                    attempts = attempts + 1
                    local horiz = (Random(0, 1) == 1)
                    local r = math.floor(Random(1, GRID_SIZE))
                    local c = math.floor(Random(1, GRID_SIZE))
                    if CanPlace(botBoard, r, c, ship.size, horiz) then
                        PlaceShip(botBoard, r, c, ship.size, horiz)
                        placed = true
                    end
                end
            end
        end
        PlaceBotShips()

        -- Bot tracks which of the player's cells it has already shot
        local botShotBoard = NewBoard()

        local function BotPickShot()
            local candidates = {}
            for r = 1, GRID_SIZE do
                for c = 1, GRID_SIZE do
                    if botShotBoard[r][c] == STATE_EMPTY then
                        candidates[table.getn(candidates) + 1] = {r, c}
                    end
                end
            end
            if table.getn(candidates) == 0 then return 1, 1 end
            local pick = candidates[math.floor(Random(1, table.getn(candidates)))]
            return pick[1], pick[2]
        end

        bsGame = {
            oppNick  = "Bot",
            myReady  = false,
            oppReady = true,   -- bot is always ready immediately
            myTurn   = true,   -- player always goes first vs bot
            gameOver = false,
            isSolo   = true,
        }

        local function OnReady()
            bsGame.myReady = true
            bsWindow:StartBattle()
            bsWindow:SetMyTurn(true)
        end

        local function OnShot(r, c)
            if bsGame == nil or bsGame.gameOver then return end
            if bsWindow:OppCellAlreadyShot(r, c) then return end

            -- Check if bot's board has a ship there
            local hit = (botBoard[r][c] == STATE_SHIP)
            if hit then botBoard[r][c] = STATE_HIT end
            local botRemaining = CountState(botBoard, STATE_SHIP)
            local iWon = (botRemaining == 0)

            bsWindow:RecordOutgoingShot(r, c, hit)

            if iWon then
                EndGame(true, "All enemy ships sunk!")
                return
            end

            local msg = hit and ("HIT at " .. string.char(64+r) .. c .. "!") or ("MISS at " .. string.char(64+r) .. c)
            bsGame.myTurn = false
            bsWindow:SetMyTurn(false)
            bsWindow:SetStatus(msg .. "  |  Bot is thinking...")

            -- Bot fires back after a short delay
            ForkThread(function()
                WaitSeconds(1)
                if IsDestroyed(bsWindow) or bsGame == nil or bsGame.gameOver then return end

                local br, bc = BotPickShot()
                botShotBoard[br][bc] = STATE_HIT  -- mark as shot regardless of result

                local botHit = bsWindow:RecordIncomingShot(br, bc)
                local myRemaining = bsWindow:MyShipsRemaining()
                local iLost = (myRemaining == 0)

                if iLost then
                    EndGame(false, "Bot sunk all your ships!")
                    return
                end

                local botMsg = botHit and ("Bot HIT " .. string.char(64+br) .. bc .. "!") or ("Bot missed " .. string.char(64+br) .. bc)
                bsGame.myTurn = true
                bsWindow:SetMyTurn(true)
                bsWindow:SetStatus(botMsg .. "  |  YOUR TURN")
            end)
        end

        bsWindow = BattleshipWindow(GetFrame(0), "Bot", OnShot, OnReady)
    end

    -- -------------------------------------------------------
    -- Start a game (called on both clients after bs_start)
    -- -------------------------------------------------------

    local function StartGame(oppNick, iGoFirst)
        if not IsDestroyed(bsWindow) then return end

        bsGame = {
            oppNick      = oppNick,
            myReady      = false,
            oppReady     = false,
            myTurn       = iGoFirst,
            gameOver     = false,
        }

        local function OnReady()
            bsGame.myReady = true
            SessionSendChatMessage({ [chatTAG] = true, to = 'all', type = 'bs_ready', target = oppNick })
            -- If opponent already sent ready, start battle now
            if bsGame.oppReady then
                bsWindow:StartBattle()
                bsWindow:SetMyTurn(bsGame.myTurn)
            else
                bsWindow:SetStatus("Waiting for " .. oppNick .. " to finish placing ships...")
            end
        end

        local function OnShot(r, c)
            FireShot(r, c)
        end

        bsWindow = BattleshipWindow(GetFrame(0), oppNick, OnShot, OnReady)
    end

    -- -------------------------------------------------------
    -- Chat handlers
    -- -------------------------------------------------------

    local bsHandlers = {

        bs_challenge = function(sender, data)
            if sender == MyNick() then return end
            if disableBsRequests then return end
            if not IsDestroyed(bsWindow) then return end
            if not IsDestroyed(bsAcceptDialog) then return end

            bsAcceptDialog = BsAcceptDialog(GetFrame(0), sender,
                function()  -- Accept
                    SessionSendChatMessage({ [chatTAG] = true, to = 'all', type = 'bs_accept', target = sender })
                end,
                function()  -- Decline
                    SessionSendChatMessage({ [chatTAG] = true, to = 'all', type = 'bs_decline', target = sender })
                end
            )
        end,

        bs_accept = function(sender, data)
            if data.target ~= MyNick() then return end
            if pendingChallenge == nil then return end

            pendingChallenge = nil

            -- Challenger goes first
            SessionSendChatMessage({ [chatTAG] = true, to = 'all', type = 'bs_start', target = sender })
            StartGame(sender, true)
        end,

        bs_decline = function(sender, data)
            if data.target ~= MyNick() then return end
            if pendingChallenge == nil then return end
            print("Battleship: " .. sender .. " declined.")
            pendingChallenge = nil
        end,

        bs_start = function(sender, data)
            if data.target ~= MyNick() then return end
            -- Acceptor goes second
            StartGame(sender, false)
        end,

        bs_ready = function(sender, data)
            if bsGame == nil then return end
            if sender ~= bsGame.oppNick then return end
            bsGame.oppReady = true
            if bsGame.myReady then
                -- Both ready: start battle
                if not IsDestroyed(bsWindow) then
                    bsWindow:StartBattle()
                    bsWindow:SetMyTurn(bsGame.myTurn)
                    if not bsGame.myTurn then
                        bsWindow:SetStatus("Waiting for " .. bsGame.oppNick .. " to fire first...")
                    end
                end
            end
        end,

        bs_shot = function(sender, data)
            if bsGame == nil then return end
            if sender ~= bsGame.oppNick then return end
            local r = data.row
            local c = data.col
            if type(r) ~= 'number' or type(c) ~= 'number' then return end
            OnIncomingShot(r, c)
        end,

        bs_result = function(sender, data)
            if bsGame == nil then return end
            if sender ~= bsGame.oppNick then return end
            OnShotResult(data.hit == 1, data.row, data.col, data.sunk == 1, data.lost == 1)
        end,


        bs_surrender = function(sender, data)
            if bsGame == nil then return end
            if sender ~= bsGame.oppNick then return end
            EndGame(true, sender .. " surrendered!")
        end,
    }

    import('/lua/ui/game/gamemain.lua').RegisterChatFunc(function(sender, data)
        local handler = bsHandlers[data.type]
        if handler then handler(sender, data) end
    end, chatTAG)

    -- -------------------------------------------------------
    -- Hotkey handler
    -- -------------------------------------------------------

    local function HandleBattleship()
        if not IsDestroyed(bsWindow) then return end
        if pendingChallenge ~= nil then
            print "Battleship: Already waiting for a response."
            return
        end

        pendingChallenge = true

        SessionSendChatMessage({ [chatTAG] = true, to = 'all', type = 'bs_challenge' })
        print "Battleship: Challenge sent! Others have 3 seconds to accept..."

        ForkThread(function()
            WaitSeconds(3)
            if pendingChallenge == nil then return end
            pendingChallenge = nil
            print "Battleship: No one accepted. Starting solo game vs Bot..."
            StartSoloGame()
        end)
    end

    -- =========================================================
    -- Register hotkeys
    -- =========================================================

    -- Single bindable hotkey (plain + every modifier combo)
    ReUI.Actions.SelectionAction("Minigames - Battleship", HandleBattleship, "Minigames", nil, MG_MODIFIERS)

    -- =========================================================
    -- OnPostCreateUI
    -- =========================================================

    ReUI.Core.OnPostCreateUI(function()
        myNickname = GetArmiesTable().armiesTable[GetFocusArmy()].nickname
        local opts = ReUI.Options.Mods["Minigames"]
        if opts then
            opts.disableBsRequests:Bind(function(opt) disableBsRequests = opt() end)
        end
    end)

    end -- BATTLESHIP

    -- ===================================================================
    -- DRAGONSWEEPER  (singleplayer)
    --
    -- A faithful reimplementation of Daniel Benmergui's "Dragonsweeper":
    -- a 13x10 minesweeper-like board where a revealed empty tile shows the
    -- SUM of the power of the eight monsters around it, and the hero has to
    -- budget hit points and experience to reach and kill the dragon.
    --
    -- All artwork in /nuggetslobby/minigames/dragon/ is original to this mod.
    -- ===================================================================
    do

    local UIUtil        = import('/lua/ui/uiutil.lua')
    local Group         = import("/lua/maui/group.lua").Group
    local LayoutHelpers = import("/lua/maui/layouthelpers.lua")
    local Bitmap        = import("/lua/maui/bitmap.lua").Bitmap
    local Window        = import("/lua/maui/window.lua").Window
    local LazyVar       = import('/lua/lazyvar.lua').Create


    -- =========================================================
    -- Small helpers (FA Lua has no % operator and no # operator)
    -- =========================================================

    local function Mod(a, b) return a - math.floor(a / b) * b end

    local function Shuffle(t)
        local n = table.getn(t)
        for i = n, 2, -1 do
            local j = math.random(1, i)
            local tmp = t[i] ; t[i] = t[j] ; t[j] = tmp
        end
        return t
    end

    -- squared euclidean distance between two tiles
    local function D2(ax, ay, bx, by)
        local dx = ax - bx
        local dy = ay - by
        return dx * dx + dy * dy
    end

    -- distance thresholds, squared, matching the original game exactly
    local R = {
        ADJ8   = 4.0,     -- distance <  2    : the eight surrounding tiles
        NEAR   = 2.25,    -- distance <  1.5  : also the eight surrounding tiles
        ORTHO  = 1.0,     -- distance <= 1    : the four orthogonal tiles
        ORB    = 4.41,    -- distance <  2.1  : the 13-tile plus shape
        GAZER  = 4.0,     -- distance <= 2    : the 13-tile plus shape
        CHEST  = 9.0,     -- distance <  3
        MEDKIT = 12.25,   -- distance <  3.5
    }

    -- =========================================================
    -- Board constants
    -- =========================================================

    -- Board, artwork and window geometry, again gathered into one table to stay
    -- under FA Lua's 32-upvalue ceiling.
    local C = {
        ART      = "/nuggetslobby/minigames/dragon/",
        GW       = 13,
        GH       = 10,
        MAX_HP   = 19,
        WINDOW_W = 600,
        WINDOW_H = 570,
        MIN_W    = 520,
        MIN_H    = 480,
        PAD      = 8,
        HEADER_H = 26,
        HUD_H    = 48,
    }
    C.NTILES = C.GW * C.GH

    -- xp needed to go from <level> to <level>+1; index is min(level, 14)
    local XP_TABLE = { [0] = 0, 4, 5, 7, 9, 9, 10, 12, 12, 12, 15, 18, 21, 21, 25 }

    local function NextLevelXP(level)
        local i = level
        if i > 14 then i = 14 end
        if i < 0 then i = 0 end
        return XP_TABLE[i]
    end

    -- a level is a "half heart" level (no max-hp gain) when it is even
    local function IsHalfHeartLevel(level)
        return Mod(level, 2) == 0
    end

    -- =========================================================
    -- Actor definitions
    -- =========================================================

    -- Every actor id lives in one table. FA Lua allows a function at most 32
    -- upvalues, and one table costs one upvalue where 29 separate locals cost 29.
    local ID = {
        EMPTY    = 'empty',
        RAT      = 'rat',
        BAT      = 'bat',
        SKELETON = 'skeleton',
        GARGOYLE = 'gargoyle',
        SLIME    = 'slime',
        MINOTAUR = 'minotaur',
        GUARD    = 'guard',
        BIGSLIME = 'bigslime',
        GIANT    = 'giant',
        MINEKING = 'mineking',
        MIMIC    = 'mimic',
        DRAGON   = 'dragon',
        RATKING  = 'ratking',
        GAZER    = 'gazer',
        WIZARD   = 'wizard',
        MINE     = 'mine',
        EGG      = 'egg',
        GNOME    = 'gnome',
        WALL     = 'wall',
        CHEST    = 'chest',
        MEDIKIT  = 'medikit',
        TREASURE = 'treasure',
        ORB      = 'orb',
        SPELLORB = 'spellorb',
        SPELLDIS = 'spelldisarm',
        SPELLRAT = 'spellrats',
        SPELLSLI = 'spellslimes',
        CROWN    = 'crown',
    }

    -- power = damage taken when attacking it AND what it adds to neighbour sums
    -- xp    = experience granted when the corpse is collected
    local DEF = {
        [ID.EMPTY]    = { power = 0,   xp = 0,  monster = false, label = "Empty" },
        [ID.RAT]      = { power = 1,   xp = 1,  monster = true,  icon = 'rat',      label = "Rat" },
        [ID.BAT]      = { power = 2,   xp = 2,  monster = true,  icon = 'bat',      label = "Bat" },
        [ID.SKELETON] = { power = 3,   xp = 3,  monster = true,  icon = 'skeleton', label = "Skeleton" },
        [ID.GARGOYLE] = { power = 4,   xp = 4,  monster = true,  icon = 'gargoyle', label = "Gargoyle" },
        [ID.SLIME]    = { power = 5,   xp = 5,  monster = true,  icon = 'slime',    label = "Slime" },
        [ID.MINOTAUR] = { power = 6,   xp = 6,  monster = true,  icon = 'minotaur', label = "Minotaur" },
        [ID.GUARD]    = { power = 7,   xp = 7,  monster = true,  icon = 'guardian', label = "Guardian" },
        [ID.BIGSLIME] = { power = 8,   xp = 8,  monster = true,  icon = 'bigslime', label = "Big Slime" },
        [ID.GIANT]    = { power = 9,   xp = 9,  monster = true,  icon = 'giant',    label = "Giant" },
        [ID.MINEKING] = { power = 10,  xp = 10, monster = true,  icon = 'mineking', label = "Mine King" },
        [ID.MIMIC]    = { power = 11,  xp = 11, monster = true,  icon = 'mimic',    label = "Mimic" },
        [ID.DRAGON]   = { power = 13,  xp = 13, monster = true,  icon = 'dragon',   label = "Dragon" },
        [ID.RATKING]  = { power = 5,   xp = 5,  monster = true,  icon = 'ratking',  label = "Rat King" },
        [ID.GAZER]    = { power = 5,   xp = 5,  monster = true,  icon = 'gazer',    label = "Gazer" },
        [ID.WIZARD]   = { power = 1,   xp = 1,  monster = true,  icon = 'wizard',   label = "Wizard" },
        [ID.MINE]     = { power = 100, xp = 3,  monster = true,  icon = 'mine',     label = "Mine" },
        [ID.EGG]      = { power = 0,   xp = 3,  monster = true,  icon = 'egg',      label = "Dragon Egg" },
        [ID.GNOME]    = { power = 0,   xp = 9,  monster = true,  icon = 'gnome',    label = "Gnome" },
        [ID.WALL]     = { power = 0,   xp = 0,  monster = false, icon = 'wall3',    label = "Wall" },
        [ID.CHEST]    = { power = 0,   xp = 0,  monster = false, icon = 'chest',    label = "Chest" },
        [ID.MEDIKIT]  = { power = 0,   xp = 0,  monster = false, icon = 'medikit',  label = "Medikit" },
        [ID.TREASURE] = { power = 0,   xp = 0,  monster = false, icon = 'gem5',     label = "Treasure" },
        [ID.ORB]      = { power = 0,   xp = 0,  monster = false, icon = 'orb',      label = "Orb" },
        [ID.SPELLORB] = { power = 0,   xp = 0,  monster = false, icon = 'scroll_orb',    label = "Scroll of Sight" },
        [ID.SPELLDIS] = { power = 0,   xp = 0,  monster = false, icon = 'scroll_disarm', label = "Scroll of Disarming" },
        [ID.SPELLRAT] = { power = 0,   xp = 0,  monster = false, icon = 'scroll_rats',   label = "Scroll of Rats" },
        [ID.SPELLSLI] = { power = 0,   xp = 0,  monster = false, icon = 'scroll_slimes', label = "Scroll of Slimes" },
        [ID.CROWN]    = { power = 0,   xp = 0,  monster = false, icon = 'crown',    label = "Crown" },
    }

    -- how a monster is killed, for the death line
    local DEATH_LINE = {
        [ID.MINE]     = "Exploded by a mine.",
        [ID.MINEKING] = "Crushed by the mine king.",
        [ID.DRAGON]   = "Torched by the dragon.",
        [ID.MIMIC]    = "Eaten by the mimic.",
        [ID.RATKING]  = "Killed by the rat king.",
        [ID.RAT]      = "Killed by a rat.",
        [ID.SLIME]    = "Consumed by a slime.",
        [ID.GARGOYLE] = "Petrified by a gargoyle.",
        [ID.MINOTAUR] = "Trampled by a minotaur.",
        [ID.SKELETON] = "Slain by a skeleton.",
        [ID.GIANT]    = "Mauled by a giant.",
        [ID.WIZARD]   = "Zapped by the wizard.",
        [ID.GAZER]    = "Lobotomised by a gazer.",
        [ID.BIGSLIME] = "Liquefied by a big slime.",
        [ID.BAT]      = "Killed by a bat.",
        [ID.GUARD]    = "Killed by a guardian.",
    }

    -- =========================================================
    -- Tile model
    --
    -- Tiles live in a flat array, index = x + y * C.GW + 1, with x and y
    -- zero-based so the coordinates match the original game's rules.
    -- =========================================================

    local function ResetTile(t)
        t.id        = ID.EMPTY
        t.power     = 0
        t.xp        = 0
        t.monster   = false
        t.revealed  = false
        t.defeated  = false
        t.disguised = false
        t.mark      = 0
        t.wallHP    = 0
        t.wallMax   = 0
        t.contains  = nil
        t.who       = nil     -- 'romeo' / 'juliet' / 'g1'.. / pair index
        t.faceX     = nil     -- direction hint target
        t.faceY     = nil
        t.chestX    = nil
        t.chestY    = nil
        return t
    end

    local function SetTile(t, id)
        ResetTile(t)
        local d = DEF[id]
        t.id      = id
        t.power   = d.power
        t.xp      = d.xp
        t.monster = d.monster
        return t
    end

    local function MakeTreasure(t, xp)
        SetTile(t, ID.TREASURE)
        t.xp = xp
        return t
    end

    -- =========================================================
    -- Dungeon generation
    --
    -- The original game places actors in priority layers and then runs a
    -- hill-climbing "happiness" search to satisfy each actor's placement
    -- rule. That search is far too slow for the FA UI thread, so this is a
    -- direct constructive placement that satisfies exactly the same rules:
    --
    --   dragon at the centre of row 4, the egg beside it
    --   wizard on a non-corner edge, ringed by all five big slimes
    --   mine king in a corner
    --   the two giants on one row, mirrored around the centre column
    --   gargoyles in orthogonally adjacent pairs, facing each other
    --   every minotaur guards exactly one chest and faces it
    --   walls come in orthogonal pairs, never touching another pair
    --   one guardian in each quadrant
    --   chests and medikits kept well apart
    --   the starting orb away from the border and away from anything nasty
    --   the gnome next to a medikit
    -- =========================================================

    local function GenerateBoard(relax)
        local tiles = {}
        for y = 0, C.GH - 1 do
            for x = 0, C.GW - 1 do
                local t = { x = x, y = y }
                ResetTile(t)
                tiles[x + y * C.GW + 1] = t
            end
        end

        local function At(x, y)
            if x < 0 or y < 0 or x >= C.GW or y >= C.GH then return nil end
            return tiles[x + y * C.GW + 1]
        end

        local function IsFree(t)
            return t ~= nil and t.id == ID.EMPTY
        end

        local function FreeList()
            local r = {}
            for i = 1, C.NTILES do
                if tiles[i].id == ID.EMPTY then table.insert(r, tiles[i]) end
            end
            return Shuffle(r)
        end

        -- first free tile (in random order) for which pred returns true
        local function TakeFree(pred)
            local list = FreeList()
            for i = 1, table.getn(list) do
                if pred == nil or pred(list[i]) then return list[i] end
            end
            return nil
        end

        local function Neighbours8(t)
            local r = {}
            for dy = -1, 1 do
                for dx = -1, 1 do
                    if dx ~= 0 or dy ~= 0 then
                        local n = At(t.x + dx, t.y + dy)
                        if n ~= nil then table.insert(r, n) end
                    end
                end
            end
            return r
        end

        local function Neighbours4(t)
            local r = {}
            local offs = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
            for i = 1, 4 do
                local n = At(t.x + offs[i][1], t.y + offs[i][2])
                if n ~= nil then table.insert(r, n) end
            end
            return r
        end

        local function CountIdWithin(id, x, y, r2)
            local c = 0
            for i = 1, C.NTILES do
                local t = tiles[i]
                if t.id == id and D2(t.x, t.y, x, y) < r2 then c = c + 1 end
            end
            return c
        end

        local function AnyIdWithin(id, x, y, r2)
            return CountIdWithin(id, x, y, r2) > 0
        end

        local function AllWithId(id)
            local r = {}
            for i = 1, C.NTILES do
                if tiles[i].id == id then table.insert(r, tiles[i]) end
            end
            return r
        end

        local function IsEdge(t)
            return t.x == 0 or t.y == 0 or t.x == C.GW - 1 or t.y == C.GH - 1
        end

        local function IsCorner(t)
            return (t.x == 0 or t.x == C.GW - 1) and (t.y == 0 or t.y == C.GH - 1)
        end

        -- ---------------------------------------------------------
        -- layer 1: dragon + wizard (and the big slimes that ring it)
        -- ---------------------------------------------------------
        local dragon = At(math.floor(C.GW / 2), 4)
        SetTile(dragon, ID.DRAGON)
        dragon.revealed = true

        -- layer 1b: wizard on a non-corner edge whose five neighbours are free
        local wizard = TakeFree(function(t)
            if not IsEdge(t) or IsCorner(t) then return false end
            local ns = Neighbours8(t)
            if table.getn(ns) ~= 5 then return false end
            for i = 1, 5 do
                if not IsFree(ns[i]) then return false end
            end
            return true
        end)
        if wizard == nil then return nil end
        SetTile(wizard, ID.WIZARD)

        -- layer 2: the five big slimes occupy every tile around the wizard
        local wns = Neighbours8(wizard)
        for i = 1, table.getn(wns) do
            SetTile(wns[i], ID.BIGSLIME)
        end

        -- layer 3: mine king in a free corner
        local mk = TakeFree(function(t) return IsCorner(t) end)
        if mk == nil then return nil end
        SetTile(mk, ID.MINEKING)

        -- layer 4: romeo and juliet, same row, mirrored about the centre column
        local centre = math.floor(C.GW / 2)
        local giantOpts = {}
        for y = 0, C.GH - 1 do
            for d = 1, centre do
                table.insert(giantOpts, { y, d })
            end
        end
        Shuffle(giantOpts)
        local placedGiants = false
        for i = 1, table.getn(giantOpts) do
            local y = giantOpts[i][1]
            local d = giantOpts[i][2]
            local a = At(centre - d, y)
            local b = At(centre + d, y)
            if IsFree(a) and IsFree(b) then
                SetTile(a, ID.GIANT) ; a.who = 'romeo'
                SetTile(b, ID.GIANT) ; b.who = 'juliet'
                placedGiants = true
                break
            end
        end
        if not placedGiants then return nil end

        -- ---------------------------------------------------------
        -- layer 5
        -- ---------------------------------------------------------

        -- the dragon egg, next to its parent
        local eggSpot = nil
        local dns = Shuffle(Neighbours8(dragon))
        for i = 1, table.getn(dns) do
            if IsFree(dns[i]) then eggSpot = dns[i] break end
        end
        if eggSpot == nil then return nil end
        SetTile(eggSpot, ID.EGG)

        -- chests, kept at least 3.5 tiles apart so that each minotaur ends up
        -- next to exactly one of them and no chest is crowded by two minotaurs
        local chestSep = R.MEDKIT
        if relax then chestSep = R.CHEST end
        local chests = {}
        for n = 1, 5 do
            local spot = TakeFree(function(t)
                for i = 1, table.getn(chests) do
                    if D2(t.x, t.y, chests[i].x, chests[i].y) < chestSep then return false end
                end
                -- it must have somewhere for its minotaur to stand
                local ns = Neighbours8(t)
                for i = 1, table.getn(ns) do
                    if IsFree(ns[i]) and ns[i].x ~= t.x then return true end
                end
                return false
            end)
            if spot == nil then return nil end
            SetTile(spot, ID.CHEST)
            table.insert(chests, spot)
        end

        -- three of the chests hold a big treasure, two hold a medikit
        Shuffle(chests)
        for i = 1, 5 do
            if i <= 3 then chests[i].contains = 'treasure5' else chests[i].contains = 'medikit' end
        end

        -- one minotaur per chest, standing beside it in a different column
        for i = 1, table.getn(chests) do
            local c = chests[i]
            local ns = Shuffle(Neighbours8(c))
            local spot = nil
            for j = 1, table.getn(ns) do
                if IsFree(ns[j]) and ns[j].x ~= c.x then spot = ns[j] break end
            end
            if spot == nil then return nil end
            SetTile(spot, ID.MINOTAUR)
            spot.chestX = c.x
            spot.chestY = c.y
        end

        -- six walls as three orthogonal pairs, never touching another pair
        local function WallOk(t)
            for i = 1, C.NTILES do
                local w = tiles[i]
                if w.id == ID.WALL and D2(w.x, w.y, t.x, t.y) <= 2 then return false end
            end
            return true
        end
        for n = 1, 3 do
            local placed = false
            local list = FreeList()
            for i = 1, table.getn(list) do
                local a = list[i]
                if WallOk(a) then
                    local ns = Shuffle(Neighbours4(a))
                    for j = 1, table.getn(ns) do
                        local b = ns[j]
                        -- at most one tile of a pair may sit on the border
                        if IsFree(b) and WallOk(b) and not (IsEdge(a) and IsEdge(b)) then
                            SetTile(a, ID.WALL) ; a.wallHP = 3 ; a.wallMax = 3 ; a.contains = 'treasure1'
                            SetTile(b, ID.WALL) ; b.wallHP = 3 ; b.wallMax = 3 ; b.contains = 'treasure1'
                            placed = true
                            break
                        end
                    end
                end
                if placed then break end
            end
            if not placed then return nil end
        end

        -- one guardian per quadrant
        local quads = {
            { 'g1', function(t) return t.x < 6 and t.y < 4 end },
            { 'g2', function(t) return t.x > 6 and t.y < 4 end },
            { 'g3', function(t) return t.x > 6 and t.y > 4 end },
            { 'g4', function(t) return t.x < 6 and t.y > 4 end },
        }
        for i = 1, 4 do
            local name = quads[i][1]
            local test = quads[i][2]
            local spot = TakeFree(test)
            if spot == nil then return nil end
            SetTile(spot, ID.GUARD)
            spot.who = name
        end

        -- four gargoyle pairs; each gargoyle's only gargoyle neighbour is its twin
        local function GargoyleOk(t)
            for i = 1, C.NTILES do
                local g = tiles[i]
                if g.id == ID.GARGOYLE and D2(g.x, g.y, t.x, t.y) <= 2 then return false end
            end
            return true
        end
        for n = 1, 4 do
            local placed = false
            local list = FreeList()
            for i = 1, table.getn(list) do
                local a = list[i]
                if GargoyleOk(a) then
                    local ns = Shuffle(Neighbours4(a))
                    for j = 1, table.getn(ns) do
                        local b = ns[j]
                        if IsFree(b) and GargoyleOk(b) then
                            SetTile(a, ID.GARGOYLE) ; a.who = n ; a.faceX = b.x ; a.faceY = b.y
                            SetTile(b, ID.GARGOYLE) ; b.who = n ; b.faceX = a.x ; b.faceY = a.y
                            placed = true
                            break
                        end
                    end
                end
                if placed then break end
            end
            if not placed then return nil end
        end

        -- gazers and mines, anywhere
        for n = 1, 2 do
            local spot = TakeFree(nil)
            if spot == nil then return nil end
            SetTile(spot, ID.GAZER)
        end
        for n = 1, 9 do
            local spot = TakeFree(nil)
            if spot == nil then return nil end
            SetTile(spot, ID.MINE)
        end

        -- loose medikits, spread out
        local medSep = R.MEDKIT
        if relax then medSep = R.CHEST end
        local medikits = {}
        for n = 1, 5 do
            local spot = TakeFree(function(t)
                for i = 1, table.getn(medikits) do
                    if D2(t.x, t.y, medikits[i].x, medikits[i].y) < medSep then return false end
                end
                return true
            end)
            if spot == nil then return nil end
            SetTile(spot, ID.MEDIKIT)
            table.insert(medikits, spot)
        end

        -- the rat king
        local rk = TakeFree(nil)
        if rk == nil then return nil end
        SetTile(rk, ID.RATKING)

        -- the starting orb: away from the border, and its 13-tile reveal must
        -- not give away anything dangerous or valuable
        local ORB_FORBIDDEN = { ID.DRAGON, ID.GAZER, ID.CHEST, ID.RATKING, ID.MINE, ID.EGG, ID.BIGSLIME }
        local function OrbScore(t)
            local bad = 0
            for i = 1, table.getn(ORB_FORBIDDEN) do
                bad = bad + CountIdWithin(ORB_FORBIDDEN[i], t.x, t.y, R.ORB)
            end
            local walls = CountIdWithin(ID.WALL, t.x, t.y, R.ORB)
            local meds  = CountIdWithin(ID.MEDIKIT, t.x, t.y, R.ORB)
            local s = bad * -2000
            if walls > 2 then s = s + (walls - 2) * -2000 end
            if meds == 1 and walls > 0 then s = s + 2000 end
            return s, bad
        end

        local orbBest = nil
        local orbBestScore = nil
        local orbList = FreeList()
        for i = 1, table.getn(orbList) do
            local t = orbList[i]
            if t.x >= 2 and t.y >= 2 and t.x <= C.GW - 3 and t.y <= C.GH - 3 then
                local s = OrbScore(t)
                if orbBestScore == nil or s > orbBestScore then
                    orbBestScore = s
                    orbBest = t
                end
            end
        end
        if orbBest == nil then
            orbBest = TakeFree(nil)
            if orbBest == nil then return nil end
        elseif not relax then
            local _, bad = OrbScore(orbBest)
            local walls = CountIdWithin(ID.WALL, orbBest.x, orbBest.y, R.ORB)
            if bad > 0 or walls > 2 then return nil end
        end
        SetTile(orbBest, ID.ORB)
        orbBest.revealed = true
        local orbX, orbY = orbBest.x, orbBest.y

        -- ---------------------------------------------------------
        -- layer 6
        -- ---------------------------------------------------------

        -- the gnome always sets up next to a medikit
        local gnome = TakeFree(function(t)
            return AnyIdWithin(ID.MEDIKIT, t.x, t.y, R.NEAR)
        end)
        if gnome == nil then return nil end
        SetTile(gnome, ID.GNOME)

        -- the mimic and the scroll of sight must stay outside the orb's reveal
        local mimic = TakeFree(function(t) return D2(t.x, t.y, orbX, orbY) >= R.ORB end)
        if mimic == nil then return nil end
        SetTile(mimic, ID.MIMIC)
        mimic.disguised = true

        local sorb = TakeFree(function(t) return D2(t.x, t.y, orbX, orbY) >= R.ORB end)
        if sorb == nil then return nil end
        SetTile(sorb, ID.SPELLORB)

        -- the rank and file
        local filler = {
            { ID.RAT, 13 }, { ID.BAT, 12 }, { ID.SKELETON, 10 }, { ID.SLIME, 8 },
        }
        for i = 1, table.getn(filler) do
            local id = filler[i][1]
            for n = 1, filler[i][2] do
                local spot = TakeFree(nil)
                if spot == nil then return nil end
                SetTile(spot, id)
            end
        end

        return tiles
    end

    -- always returns a board: strict rules first, then a relaxed pass
    local function BuildBoard()
        for attempt = 1, 80 do
            local t = GenerateBoard(false)
            if t ~= nil then return t end
        end
        for attempt = 1, 400 do
            local t = GenerateBoard(true)
            if t ~= nil then return t end
        end
        return nil
    end

    -- =========================================================
    -- Persistent stamps (achievements), stored in the FA profile
    -- =========================================================

    local STAMP = {}
    STAMP.IDS   = { 'lovers', 'clear', 'egg', 'pacifist' }
    STAMP.NAME  = {
        lovers   = "The lovers survive",
        clear    = "Board wiped clean",
        egg      = "A future generation",
        pacifist = "Rat pacifist",
    }
    STAMP.SHORT = {
        lovers   = "Lovers",
        clear    = "Clear",
        egg      = "Egg",
        pacifist = "Pacifist",
    }
    STAMP.HINT  = {
        lovers   = "both giants alive",
        clear    = "nothing left on the board",
        egg      = "dragon egg unbroken",
        pacifist = "no rats killed",
    }
    local PREFS_KEY = 'Minigames_DragonsweeperStamps'

    local function LoadStamps()
        local s = {}
        pcall(function()
            local prefs = import('/lua/user/prefs.lua')
            local v = prefs.GetFromCurrentProfile(PREFS_KEY)
            if type(v) == 'table' then
                for i = 1, table.getn(STAMP.IDS) do
                    local id = STAMP.IDS[i]
                    if v[id] == true or v[id] == 1 then s[id] = true end
                end
            end
        end)
        return s
    end

    local function SaveStamps(s)
        pcall(function()
            local prefs = import('/lua/user/prefs.lua')
            prefs.SetToCurrentProfile(PREFS_KEY, s)
            SavePreferences()
        end)
    end

    local function NowSeconds()
        local t = 0
        pcall(function() t = GetSystemTimeSeconds() end)
        return t
    end

    -- =========================================================
    -- Game logic
    -- =========================================================

    local Logic = {}

    Logic.At = function(G, x, y)
        if x < 0 or y < 0 or x >= C.GW or y >= C.GH then return nil end
        return G.tiles[x + y * C.GW + 1]
    end

    -- the number printed on a revealed empty tile: the SUM of the power of the
    -- eight surrounding tiles. A defeated monster still counts until its body
    -- has been collected, exactly as in the original.
    Logic.AttackNumber = function(G, t)
        local s = 0
        for dy = -1, 1 do
            for dx = -1, 1 do
                if dx ~= 0 or dy ~= 0 then
                    local n = Logic.At(G, t.x + dx, t.y + dy)
                    if n ~= nil and n.power > 0 then s = s + n.power end
                end
            end
        end
        return s
    end

    -- a living gazer hides every number within two tiles of itself
    Logic.GazerHides = function(G, t)
        for i = 1, C.NTILES do
            local a = G.tiles[i]
            if a.id == ID.GAZER and not a.defeated then
                if D2(a.x, a.y, t.x, t.y) <= R.GAZER then return true end
            end
        end
        return false
    end

    Logic.FindFirst = function(G, id)
        for i = 1, C.NTILES do
            if G.tiles[i].id == id then return G.tiles[i] end
        end
        return nil
    end

    Logic.GrantXP = function(G, xp)
        G.xp = G.xp + xp
        G.score = G.score + xp
    end

    -- the gnome hops to the hidden empty tile closest to any medikit
    Logic.GnomeJumpTarget = function(G)
        local best = nil
        local bestD = nil
        for i = 1, C.NTILES do
            local c = G.tiles[i]
            if c.id == ID.EMPTY and not c.revealed then
                for j = 1, C.NTILES do
                    local m = G.tiles[j]
                    if m.id == ID.MEDIKIT then
                        local d = D2(c.x, c.y, m.x, m.y)
                        if bestD == nil or d < bestD then
                            bestD = d
                            best = c
                        end
                    end
                end
            end
        end
        return best
    end

    Logic.MaxScore = function(G)
        local total = 0
        for i = 1, C.NTILES do
            local t = G.tiles[i]
            total = total + t.xp
            if t.id ~= ID.MINE and t.contains ~= nil then
                if t.contains == 'treasure1' then total = total + 1
                elseif t.contains == 'treasure5' then total = total + 5 end
            end
        end
        return total
    end

    Logic.New = function()
        local G = {}
        G.tiles       = BuildBoard()
        G.level       = 1
        G.maxHP       = 6
        G.hp          = 6
        G.xp          = 0
        G.score       = 0
        G.ratsKilled  = 0
        G.status      = 'playing'
        G.message     = "Find and slay the dragon."
        G.lastId      = nil
        G.lastWho     = nil
        G.lastIdx     = nil
        G.stampsSaved = false
        G.minesOff    = false
        G.startTime   = NowSeconds()
        G.endTime     = 0
        G.runStamps   = {}
        G.maxScore    = 0
        if G.tiles ~= nil then G.maxScore = Logic.MaxScore(G) end
        return G
    end

    Logic.CanLevelUp = function(G)
        return G.status == 'playing' and G.hp > 0 and G.xp >= NextLevelXP(G.level)
    end

    Logic.LevelUp = function(G)
        if not Logic.CanLevelUp(G) then return false end
        G.xp = G.xp - NextLevelXP(G.level)
        G.level = G.level + 1
        if G.maxHP < C.MAX_HP and not IsHalfHeartLevel(G.level) then
            G.maxHP = G.maxHP + 1
        end
        G.hp = G.maxHP
        G.message = "Level " .. G.level .. "! Fully healed."
        return true
    end

    Logic.Win = function(G)
        G.status  = 'won'
        G.endTime = NowSeconds()

        local living = 0
        local giants = 0
        local eggs   = 0
        for i = 1, C.NTILES do
            local a = G.tiles[i]
            if a.id ~= ID.EMPTY and a.id ~= ID.DRAGON and a.id ~= ID.CROWN then
                living = living + 1
            end
            if a.id == ID.GIANT and not a.defeated then giants = giants + 1 end
            if a.id == ID.EGG   and not a.defeated then eggs   = eggs   + 1 end
        end

        if living == 0        then table.insert(G.runStamps, 'clear')    end
        if giants == 2        then table.insert(G.runStamps, 'lovers')   end
        if eggs == 1          then table.insert(G.runStamps, 'egg')      end
        if G.ratsKilled == 0  then table.insert(G.runStamps, 'pacifist') end
    end

    -- one click on one tile; mirrors the original's turn order exactly
    Logic.Click = function(G, t)
        if G.status ~= 'playing' then return end
        G.message = nil

        -- the gnome never fights if it has anywhere to run
        if t.id == ID.GNOME then
            local target = Logic.GnomeJumpTarget(G)
            if target ~= nil then
                local oldMark = target.mark
                SetTile(target, ID.GNOME)
                target.mark = oldMark
                SetTile(t, ID.EMPTY)
                G.message = "The gnome slips away."
            end
        end

        if t.id == ID.CROWN then
            Logic.Win(G)

        elseif t.id == ID.SPELLSLI then
            if t.revealed then
                local found = 0
                for i = 1, C.NTILES do
                    local a = G.tiles[i]
                    if a.id == ID.SLIME or a.id == ID.BIGSLIME then
                        a.revealed = true
                        found = found + 1
                    end
                end
                SetTile(t, ID.EMPTY)
                G.message = "Every slime is revealed (" .. found .. ")."
            end

        elseif t.id == ID.SPELLRAT then
            if t.revealed then
                local found = 0
                for i = 1, C.NTILES do
                    local a = G.tiles[i]
                    if a.id == ID.RAT then
                        a.revealed = true
                        found = found + 1
                    end
                end
                SetTile(t, ID.EMPTY)
                G.message = "Every rat is revealed (" .. found .. ")."
            end

        elseif t.id == ID.SPELLDIS then
            if t.revealed then
                local found = 0
                for i = 1, C.NTILES do
                    local a = G.tiles[i]
                    if a.id == ID.MINE and not a.defeated then
                        a.defeated = true
                        a.power = 0
                        found = found + 1
                    end
                end
                SetTile(t, ID.EMPTY)
                if found > 0 then
                    G.minesOff = true
                    G.message = found .. " mines are disarmed."
                else
                    G.message = "Nothing left to disarm."
                end
            end

        elseif t.id == ID.SPELLORB then
            if t.revealed then
                local cands = {}
                for i = 1, C.NTILES do
                    if not G.tiles[i].revealed then table.insert(cands, G.tiles[i]) end
                end
                Shuffle(cands)

                local pick = nil
                for i = 1, table.getn(cands) do
                    local a = cands[i]
                    for j = 1, C.NTILES do
                        local b = G.tiles[j]
                        if (not b.revealed) and b.id == ID.MINE and D2(a.x, a.y, b.x, b.y) < R.NEAR then
                            pick = a
                            break
                        end
                    end
                end
                if pick == nil and table.getn(cands) > 0 then pick = cands[1] end

                SetTile(t, ID.EMPTY)
                if pick ~= nil then
                    for i = 1, C.NTILES do
                        local b = G.tiles[i]
                        if (not b.revealed) and D2(b.x, b.y, pick.x, pick.y) < R.NEAR then
                            b.revealed = true
                        end
                    end
                    G.message = "The scroll uncovers a patch of the lair."
                else
                    G.message = "There is nothing left to uncover."
                end
            end

        elseif t.id == ID.TREASURE then
            if t.revealed then
                Logic.GrantXP(G, t.xp)
                G.message = "Picked up " .. t.xp .. " experience."
                SetTile(t, ID.EMPTY)
            end

        elseif t.id == ID.WALL then
            if t.revealed then
                if G.hp == 1 then
                    G.message = "Too weak to swing at the wall."
                else
                    G.hp = G.hp - 1
                    t.wallHP = t.wallHP - 1
                    if t.wallHP <= 0 then
                        local c = t.contains
                        if c == 'treasure1' then MakeTreasure(t, 1)
                        elseif c == 'treasure5' then MakeTreasure(t, 5)
                        elseif c == 'medikit' then SetTile(t, ID.MEDIKIT)
                        else SetTile(t, ID.EMPTY) end
                        G.message = "The wall comes down."
                    else
                        G.message = "The wall holds. " .. t.wallHP .. " left."
                    end
                end
            end

        elseif t.id == ID.CHEST then
            if t.revealed then
                local c = t.contains
                if c == 'medikit' then SetTile(t, ID.MEDIKIT)
                elseif c == 'treasure1' then MakeTreasure(t, 1)
                else MakeTreasure(t, 5) end
                G.message = "The chest creaks open."
            end

        elseif t.id == ID.ORB then
            if t.revealed then
                local ox, oy = t.x, t.y
                SetTile(t, ID.EMPTY)
                local found = 0
                for i = 1, C.NTILES do
                    local b = G.tiles[i]
                    if (not b.revealed) and D2(b.x, b.y, ox, oy) < R.ORB then
                        b.revealed = true
                        found = found + 1
                    end
                end
                if found > 0 then G.message = "The orb lights up the lair."
                else G.message = "The orb fizzles out." end
            end

        elseif t.monster then
            if t.disguised and not t.revealed then
                -- the mimic sits perfectly still
            elseif not t.defeated then
                if t.disguised then
                    t.disguised = false
                    G.message = "It was a mimic!"
                end
                G.hp = G.hp - t.power
                if G.hp > 0 then
                    t.defeated = true
                    if G.message == nil then
                        G.message = DEF[t.id].label .. " defeated. " .. t.power .. " damage."
                    end
                end
                if t.id == ID.RAT then G.ratsKilled = G.ratsKilled + 1 end
            elseif G.hp > 0 and t.revealed then
                Logic.GrantXP(G, t.xp)
                local gained = t.xp
                if t.id == ID.DRAGON then
                    SetTile(t, ID.CROWN)
                    G.message = "The dragon is slain. Take the crown!"
                elseif t.id == ID.RATKING then
                    SetTile(t, ID.SPELLRAT)
                    G.message = "The rat king drops a scroll."
                elseif t.id == ID.WIZARD then
                    SetTile(t, ID.SPELLSLI)
                    G.message = "The wizard drops a scroll."
                elseif t.id == ID.GIANT then
                    SetTile(t, ID.MEDIKIT)
                    G.message = "The giant leaves a medikit."
                elseif t.id == ID.MINEKING then
                    SetTile(t, ID.SPELLDIS)
                    G.message = "The mine king drops a scroll."
                else
                    SetTile(t, ID.EMPTY)
                    G.message = "Picked up " .. gained .. " experience."
                end
            end

        elseif t.id == ID.MEDIKIT then
            if t.revealed then
                if G.hp < G.maxHP then
                    G.hp = G.maxHP
                    G.message = "Fully healed."
                else
                    G.message = "Already at full health; the medikit is wasted."
                end
                SetTile(t, ID.EMPTY)
            end
        end

        if not t.revealed then
            t.revealed = true
        end

        G.lastId  = t.id
        G.lastWho = t.who
        G.lastIdx = t.x + t.y * C.GW + 1

        if G.hp <= 0 then
            G.hp = 0
            G.status = 'dead'
            for i = 1, C.NTILES do
                if G.tiles[i].id == ID.MIMIC then G.tiles[i].disguised = false end
            end
        end
    end

    -- the line shown when the run ends
    Logic.DeathLine = function(G)
        if G.lastWho == 'romeo'  then return "Mauled by Romeo." end
        if G.lastWho == 'juliet' then return "Mauled by Juliet." end
        local line = DEATH_LINE[G.lastId]
        if line ~= nil then return line end
        return "Jorge has fallen."
    end

    -- =========================================================
    -- Monsternomicon contents
    -- =========================================================

    local NOMICON_ROWS = {
        ID.RAT, ID.BAT, ID.SKELETON, ID.GARGOYLE, ID.SLIME,
        ID.MINOTAUR, ID.GUARD, ID.BIGSLIME, ID.GIANT, ID.MINEKING,
        ID.RATKING, ID.GAZER, ID.WIZARD, ID.MIMIC, ID.MINE,
        ID.CHEST, ID.GNOME, ID.MEDIKIT, ID.SPELLORB, ID.SPELLDIS,
    }

    -- counts follow the original book exactly: items still locked inside other
    -- things, and monsters that will drop them, are counted up front
    Logic.NomiconCount = function(G, id)
        local count = 0
        for i = 1, C.NTILES do
            local a = G.tiles[i]
            if a.id == id then count = count + 1
            elseif id == ID.SPELLORB and a.contains == 'spellorb' then count = count + 1
            elseif id == ID.MEDIKIT  and a.contains == 'medikit'  then count = count + 1
            elseif id == ID.SPELLDIS and a.id == ID.MINEKING       then count = count + 1
            elseif id == ID.MEDIKIT  and a.id == ID.GIANT          then count = count + 1
            elseif id == ID.SPELLRAT and a.id == ID.RATKING        then count = count + 1
            elseif id == ID.SPELLSLI and a.id == ID.WIZARD         then count = count + 1
            end
        end
        return count
    end

    Logic.NomiconPower = function(G, id)
        if id == ID.MINE then
            for i = 1, C.NTILES do
                local a = G.tiles[i]
                if a.id == ID.MINE and a.power == 0 then return 0 end
            end
        end
        return DEF[id].power
    end

    -- =========================================================
    -- Colours
    -- =========================================================

    local COL = {
        SUM    = "fff2e6c8",   -- the neighbour-power sum on an empty tile
        HIDDEN = "ffc8a0ff",   -- a gazer is hiding this number
        POWER  = "fff0a038",   -- a living monster's power
        XP     = "fff2ce52",   -- experience waiting to be picked up
        MARK   = "ffffe84a",   -- a player's own mark
        TEXT   = "ffd8d8d8",
        WARN   = "ffff6644",
        GOOD   = "ff66dd66",
        PANEL  = "ee141018",
        PANEL2 = "ff1e1a26",

    -- =========================================================
    }

    -- =========================================================
    -- Window
    -- =========================================================

    local dsWindow = nil

    local MARK_ICON = { [13] = 'mark_mine', [14] = 'mark_question', [15] = 'mark_flag' }

    local DragonsweeperWindow = Class(Window) {

        __init = function(self, parent)
            local windowTextures = {
                tl = UIUtil.SkinnableFile('/game/panel/panel_brd_ul.dds'),
                tr = UIUtil.SkinnableFile('/game/panel/panel_brd_ur.dds'),
                tm = UIUtil.SkinnableFile('/game/panel/panel_brd_horz_um.dds'),
                ml = UIUtil.SkinnableFile('/game/panel/panel_brd_vert_l.dds'),
                m  = UIUtil.SkinnableFile('/game/panel/panel_brd_m.dds'),
                mr = UIUtil.SkinnableFile('/game/panel/panel_brd_vert_r.dds'),
                bl = UIUtil.SkinnableFile('/game/panel/panel_brd_ll.dds'),
                bm = UIUtil.SkinnableFile('/game/panel/panel_brd_lm.dds'),
                br = UIUtil.SkinnableFile('/game/panel/panel_brd_lr.dds'),
                borderColor = '00415055'
            }

            Window.__init(self, parent, "Dragonsweeper", nil, false, false, false, false,
                'DragonsweeperWindow', {
                    Left   = parent.Width()  / 2 - C.WINDOW_W / 2,
                    Right  = parent.Width()  / 2 + C.WINDOW_W / 2,
                    Top    = parent.Height() / 2 - C.WINDOW_H / 2,
                    Bottom = parent.Height() / 2 + C.WINDOW_H / 2,
                }, windowTextures)
            self:SetMinimumResize(C.MIN_W, C.MIN_H)

            self._title:SetFont('Arial Black', 14)
            self._title:DisableHitTest()
            LayoutHelpers.AtCenterIn(self._title, self.TitleGroup)

            -- Drag handles
            self.DragTL = Bitmap(self, UIUtil.SkinnableFile '/game/drag-handle/drag-handle-ul_btn_up.dds')
            self.DragTR = Bitmap(self, UIUtil.SkinnableFile '/game/drag-handle/drag-handle-ur_btn_up.dds')
            self.DragBL = Bitmap(self, UIUtil.SkinnableFile '/game/drag-handle/drag-handle-ll_btn_up.dds')
            self.DragBR = Bitmap(self, UIUtil.SkinnableFile '/game/drag-handle/drag-handle-lr_btn_up.dds')
            LayoutHelpers.AtLeftTopIn(self.DragTL,     self, -24, -8)
            LayoutHelpers.AtRightTopIn(self.DragTR,    self, -22, -8)
            LayoutHelpers.AtLeftBottomIn(self.DragBL,  self, -24, -8)
            LayoutHelpers.AtRightBottomIn(self.DragBR, self, -22, -8)
            LayoutHelpers.DepthOverParent(self.DragTL, self, 10)
            LayoutHelpers.DepthOverParent(self.DragTR, self, 10)
            LayoutHelpers.DepthOverParent(self.DragBL, self, 10)
            LayoutHelpers.DepthOverParent(self.DragBR, self, 10)
            self.DragTL:DisableHitTest()
            self.DragTR:DisableHitTest()
            self.DragBL:DisableHitTest()
            self.DragBR:DisableHitTest()

            local content = self.ClientGroup

            -- -------------------------------------------------
            -- forward declarations (FA Lua only sees locals below their line)
            -- -------------------------------------------------
            local G
            local cells
            local RefreshTile, RefreshAll, RefreshHUD, RefreshBook
            local CloseMarkPanel, OpenMarkPanel
            local StartNewGame

            local stamps = LoadStamps()

            -- -------------------------------------------------
            -- header
            -- -------------------------------------------------
            local headerBg = Bitmap(content)
            LayoutHelpers.LayoutFor(headerBg)
                :Left(function() return content.Left() + C.PAD end)
                :Right(function() return content.Right() - C.PAD end)
                :Top(function() return content.Top() + C.PAD end)
                :Height(function() return C.HEADER_H end)
                :Over(content, 1)
            headerBg:SetSolidColor("ff0a1a2e")
            headerBg:DisableHitTest()

            self.scoreLabel = UIUtil.CreateText(content, "Lv 1   Score 0", 12, 'Arial Bold', true)
            self.scoreLabel:SetColor(COL.TEXT)
            LayoutHelpers.AtLeftIn(self.scoreLabel, content, C.PAD * 2)
            LayoutHelpers.LayoutFor(self.scoreLabel)
                :Top(function() return content.Top() + C.PAD + 6 end)
                :Over(content, 3)
            self.scoreLabel:DisableHitTest()

            self.statusLabel = UIUtil.CreateText(content, "", 12, 'Arial', true)
            self.statusLabel:SetColor(COL.TEXT)
            LayoutHelpers.AtHorizontalCenterIn(self.statusLabel, content)
            LayoutHelpers.LayoutFor(self.statusLabel)
                :Top(function() return content.Top() + C.PAD + 6 end)
                :Over(content, 3)
            self.statusLabel:DisableHitTest()

            local btnNew = UIUtil.CreateButtonWithDropshadow(content, '/BUTTON/medium/', "New Game")
            LayoutHelpers.LayoutFor(btnNew)
                :AtRightIn(content, C.PAD)
                :Top(function() return content.Top() + C.PAD - 2 end)
                :Over(content, 4)

            -- -------------------------------------------------
            -- board area
            -- -------------------------------------------------
            local boardGroup = Group(content)
            LayoutHelpers.LayoutFor(boardGroup)
                :Left(function() return content.Left() + C.PAD end)
                :Right(function() return content.Right() - C.PAD end)
                :Top(function() return content.Top() + C.PAD + C.HEADER_H + C.PAD end)
                :Bottom(function() return content.Bottom() - C.PAD - C.HUD_H end)
                :Over(content, 1)

            self._cell = LazyVar(30)
            self._cell:Set(function()
                local w = math.floor(boardGroup.Width() / C.GW)
                local h = math.floor(boardGroup.Height() / C.GH)
                if h < w then return h else return w end
            end)

            self._bx = LazyVar(0)
            self._bx:Set(function()
                return boardGroup.Left() + math.floor((boardGroup.Width() - self._cell() * C.GW) / 2)
            end)
            self._by = LazyVar(0)
            self._by:Set(function()
                return boardGroup.Top() + math.floor((boardGroup.Height() - self._cell() * C.GH) / 2)
            end)

            local cellVar = self._cell
            local bxVar   = self._bx
            local byVar   = self._by

            -- -------------------------------------------------
            -- HUD
            -- -------------------------------------------------
            local hudBg = Bitmap(content)
            LayoutHelpers.LayoutFor(hudBg)
                :Left(function() return content.Left() + C.PAD end)
                :Right(function() return content.Right() - C.PAD end)
                :Bottom(function() return content.Bottom() - C.PAD end)
                :Height(function() return C.HUD_H - C.PAD end)
                :Over(content, 1)
            hudBg:SetSolidColor("ff0a1a2e")
            hudBg:DisableHitTest()

            local heroBtn = Bitmap(content)
            heroBtn:SetTexture(C.ART .. 'hero.png')
            LayoutHelpers.LayoutFor(heroBtn)
                :Left(function() return content.Left() + C.PAD + 4 end)
                :Bottom(function() return content.Bottom() - C.PAD - 4 end)
                :Width(function() return 34 end)
                :Height(function() return 34 end)
                :Over(content, 3)

            local bookBtn = Bitmap(content)
            bookBtn:SetTexture(C.ART .. 'book.png')
            LayoutHelpers.LayoutFor(bookBtn)
                :Right(function() return content.Right() - C.PAD - 6 end)
                :Bottom(function() return content.Bottom() - C.PAD - 6 end)
                :Width(function() return 28 end)
                :Height(function() return 28 end)
                :Over(content, 3)

            -- hearts (index 1..C.MAX_HP-1; heart 0 is never drawn, as in the original)
            local hearts = {}
            for i = 1, C.MAX_HP - 1 do
                local hi = i
                local b = Bitmap(content)
                b:SetTexture(C.ART .. 'heart_empty.png')
                b:DisableHitTest()
                LayoutHelpers.LayoutFor(b)
                    :Left(function() return content.Left() + C.PAD + 44 + (hi - 1) * 15 end)
                    :Top(function() return content.Bottom() - C.PAD - 42 end)
                    :Width(function() return 15 end)
                    :Height(function() return 15 end)
                    :Over(content, 3)
                hearts[i] = b
            end

            -- experience pips
            local pips = {}
            for i = 1, 25 do
                local pi = i
                local b = Bitmap(content)
                b:SetTexture(C.ART .. 'xp_off.png')
                b:DisableHitTest()
                LayoutHelpers.LayoutFor(b)
                    :Left(function() return content.Left() + C.PAD + 44 + (pi - 1) * 12 end)
                    :Top(function() return content.Bottom() - C.PAD - 25 end)
                    :Width(function() return 13 end)
                    :Height(function() return 13 end)
                    :Over(content, 3)
                pips[i] = b
            end

            -- -------------------------------------------------
            -- tiles
            -- -------------------------------------------------
            local backVariant = {}
            for i = 1, C.NTILES do
                backVariant[i] = 'tile_hidden' .. tostring(Mod(i * 7 + math.floor(i / C.GW) * 3, 4) + 1)
            end

            cells = {}
            for i = 1, C.NTILES do
                local idx = i
                local cx  = Mod(i - 1, C.GW)
                local cy  = math.floor((i - 1) / C.GW)

                local bg = Bitmap(boardGroup)
                bg:SetTexture(C.ART .. backVariant[i] .. '.png')
                LayoutHelpers.LayoutFor(bg)
                    :Left(function() return bxVar() + cx * cellVar() end)
                    :Top(function()  return byVar() + cy * cellVar() end)
                    :Width(function()  return cellVar() end)
                    :Height(function() return cellVar() end)
                    :Over(boardGroup, 1)

                local icon = Bitmap(boardGroup)
                icon:DisableHitTest()
                icon:SetTexture(C.ART .. 'dot.png')
                LayoutHelpers.LayoutFor(icon)
                    :Left(function() return bxVar() + cx * cellVar() + 1 end)
                    :Top(function()  return byVar() + cy * cellVar() + 1 end)
                    :Width(function()  return cellVar() - 2 end)
                    :Height(function() return cellVar() - 2 end)
                    :Over(boardGroup, 2)
                icon:Hide()

                local arrow = Bitmap(boardGroup)
                arrow:DisableHitTest()
                arrow:SetTexture(C.ART .. 'dot.png')
                LayoutHelpers.LayoutFor(arrow)
                    :Left(function() return bxVar() + (cx + 1) * cellVar() - math.floor(cellVar() * 0.5) - 1 end)
                    :Top(function()  return byVar() + cy * cellVar() + 1 end)
                    :Width(function()  return math.floor(cellVar() * 0.5) end)
                    :Height(function() return math.floor(cellVar() * 0.5) end)
                    :Over(boardGroup, 3)
                arrow:Hide()

                local num = UIUtil.CreateText(boardGroup, "", 14, 'Arial Black', true)
                num:DisableHitTest()
                num:SetColor(COL.SUM)
                LayoutHelpers.LayoutFor(num)
                    :Left(function()
                        return bxVar() + cx * cellVar() + math.floor(cellVar() / 2) - math.floor(num.Width() / 2)
                    end)
                    :Top(function()
                        return byVar() + cy * cellVar() + math.floor(cellVar() / 2) - math.floor(num.Height() / 2)
                    end)
                    :Over(boardGroup, 4)

                local pow = UIUtil.CreateText(boardGroup, "", 11, 'Arial Black', true)
                pow:DisableHitTest()
                pow:SetColor(COL.POWER)
                LayoutHelpers.LayoutFor(pow)
                    :Left(function()
                        return bxVar() + cx * cellVar() + math.floor(cellVar() / 2) - math.floor(pow.Width() / 2)
                    end)
                    :Top(function()
                        return byVar() + (cy + 1) * cellVar() - pow.Height() - 1
                    end)
                    :Over(boardGroup, 4)

                bg.HandleEvent = function(ctrl, event)
                    local t = G.tiles[idx]
                    if event.Type == "MouseEnter" then
                        if G.status == 'playing' and not (t.revealed and t.id == ID.EMPTY) then
                            if t.revealed then ctrl:SetTexture(C.ART .. 'tile_hover_open.png')
                            else ctrl:SetTexture(C.ART .. 'tile_hover.png') end
                        end
                    elseif event.Type == "MouseExit" then
                        RefreshTile(idx)
                    elseif event.Type == "ButtonPress" then
                        if G.status ~= 'playing' then return true end
                        local wantMark = event.Modifiers.Right
                            or (event.Modifiers.Left and event.Modifiers.Shift)
                        if wantMark then
                            if not t.revealed then OpenMarkPanel(idx) end
                            return true
                        end
                        if event.Modifiers.Left then
                            CloseMarkPanel()
                            if t.revealed and t.id == ID.EMPTY then return true end
                            Logic.Click(G, t)
                            RefreshAll()
                        end
                    end
                    return true
                end

                cells[i] = { bg = bg, icon = icon, arrow = arrow, num = num, pow = pow }
            end

            -- -------------------------------------------------
            -- marker palette
            -- -------------------------------------------------
            local MARK_SLOT = 26
            local markTile  = nil

            local markGX = LazyVar(0)
            local markGY = LazyVar(0)

            local markPanel = Group(content)
            LayoutHelpers.LayoutFor(markPanel)
                :Left(function() return content.Left() end)
                :Right(function() return content.Right() end)
                :Top(function() return content.Top() end)
                :Bottom(function() return content.Bottom() end)
                :Over(content, 20)

            local markCatcher = Bitmap(markPanel)
            markCatcher:SetSolidColor("01000000")
            LayoutHelpers.FillParent(markCatcher, markPanel)
            LayoutHelpers.DepthOverParent(markCatcher, markPanel, 1)
            markCatcher.HandleEvent = function(ctrl, event)
                if event.Type == "ButtonPress" then CloseMarkPanel() end
                return true
            end

            local markSlots = {}
            for k = 1, 16 do
                local sk = k
                local col = Mod(k - 1, 4)
                local row = math.floor((k - 1) / 4)

                local sb = Bitmap(markPanel)
                sb:SetTexture(C.ART .. 'tile_sel.png')
                LayoutHelpers.LayoutFor(sb)
                    :Left(function() return markGX() + col * MARK_SLOT end)
                    :Top(function()  return markGY() + row * MARK_SLOT end)
                    :Width(function()  return MARK_SLOT - 1 end)
                    :Height(function() return MARK_SLOT - 1 end)
                    :Over(markPanel, 3)

                local si = Bitmap(markPanel)
                si:DisableHitTest()
                si:SetTexture(C.ART .. 'dot.png')
                LayoutHelpers.LayoutFor(si)
                    :Left(function() return markGX() + col * MARK_SLOT + 3 end)
                    :Top(function()  return markGY() + row * MARK_SLOT + 3 end)
                    :Width(function()  return MARK_SLOT - 7 end)
                    :Height(function() return MARK_SLOT - 7 end)
                    :Over(markPanel, 4)
                si:Hide()

                local st = UIUtil.CreateText(markPanel, "", 12, 'Arial Black', true)
                st:DisableHitTest()
                st:SetColor(COL.MARK)
                LayoutHelpers.LayoutFor(st)
                    :Left(function()
                        return markGX() + col * MARK_SLOT + math.floor(MARK_SLOT / 2) - math.floor(st.Width() / 2)
                    end)
                    :Top(function()
                        return markGY() + row * MARK_SLOT + math.floor(MARK_SLOT / 2) - math.floor(st.Height() / 2)
                    end)
                    :Over(markPanel, 5)

                if sk <= 12 then
                    st:SetText(tostring(sk))
                elseif MARK_ICON[sk] ~= nil then
                    si:SetTexture(C.ART .. MARK_ICON[sk] .. '.png')
                    si:Show()
                else
                    st:SetText("X")
                    st:SetColor(COL.WARN)
                end

                sb.HandleEvent = function(ctrl, event)
                    if event.Type == "ButtonPress" then
                        if markTile ~= nil then
                            local t = G.tiles[markTile]
                            local want = sk
                            if sk == 16 then want = 0 end
                            if t.mark == want then want = 0 end
                            t.mark = want
                            local mt = markTile
                            CloseMarkPanel()
                            RefreshTile(mt)
                        end
                    end
                    return true
                end

                markSlots[k] = { bg = sb, icon = si, txt = st }
            end
            markPanel:Hide()

            CloseMarkPanel = function()
                markTile = nil
                markPanel:Hide()
            end

            OpenMarkPanel = function(idx)
                local t = G.tiles[idx]
                markTile = idx

                local w = 4 * MARK_SLOT
                local h = 4 * MARK_SLOT
                local cs = cellVar()
                local x = bxVar() + (t.x + 1) * cs
                local y = byVar() + t.y * cs - math.floor(h / 2) + math.floor(cs / 2)
                if x + w > content.Right() - C.PAD then x = bxVar() + t.x * cs - w end
                if x < content.Left() + C.PAD then x = content.Left() + C.PAD end
                local lowest = content.Bottom() - C.PAD - C.HUD_H
                if y + h > lowest then y = lowest - h end
                if y < content.Top() + C.PAD + C.HEADER_H + C.PAD then y = content.Top() + C.PAD + C.HEADER_H + C.PAD end
                markGX:Set(x)
                markGY:Set(y)

                if t.mark == 0 then markSlots[16].bg:Hide() ; markSlots[16].txt:Hide()
                else markSlots[16].bg:Show() ; markSlots[16].txt:Show() end

                markPanel:Show()
            end

            -- -------------------------------------------------
            -- Monsternomicon
            -- -------------------------------------------------
            local bookPanel = Group(content)
            LayoutHelpers.LayoutFor(bookPanel)
                :Left(function() return content.Left() + C.PAD end)
                :Right(function() return content.Right() - C.PAD end)
                :Top(function() return content.Top() + C.PAD + C.HEADER_H + C.PAD end)
                :Bottom(function() return content.Bottom() - C.PAD - C.HUD_H end)
                :Over(content, 30)

            local bookBg = Bitmap(bookPanel)
            bookBg:SetSolidColor(COL.PANEL2)
            LayoutHelpers.FillParent(bookBg, bookPanel)
            LayoutHelpers.DepthOverParent(bookBg, bookPanel, 1)
            bookBg.HandleEvent = function(ctrl, event) return true end

            local bookTitle = UIUtil.CreateText(bookPanel, "Monsternomicon", 15, 'Arial Black', true)
            bookTitle:SetColor("fff2ce52")
            bookTitle:DisableHitTest()
            LayoutHelpers.AtHorizontalCenterIn(bookTitle, bookPanel)
            LayoutHelpers.LayoutFor(bookTitle):Top(function() return bookPanel.Top() + 6 end):Over(bookPanel, 3)

            local BOOK_RULES = {
                "Jorge must slay the dragon.",
                "A number is the SUM of the",
                "power of the 8 tiles around it.",
                "Clicking a monster fights it",
                "at once: you lose hearts equal",
                "to its power. Click the body",
                "to take its experience.",
                "Click Jorge to level up and heal.",
                "Living on 1 hit point is fine.",
                "Right-click a tile to mark it.",
            }

            local bookRuleLines = {}
            for i = 1, table.getn(BOOK_RULES) do
                local li = i
                local tx = UIUtil.CreateText(bookPanel, BOOK_RULES[i], 11, 'Arial', true)
                tx:SetColor(COL.TEXT)
                tx:DisableHitTest()
                LayoutHelpers.LayoutFor(tx)
                    :Left(function() return bookPanel.Left() + 14 end)
                    :Top(function() return bookPanel.Top() + 32 + (li - 1) * 14 end)
                    :Over(bookPanel, 3)
                bookRuleLines[i] = tx
            end

            local bookStampTitle = UIUtil.CreateText(bookPanel, "Stamps", 12, 'Arial Black', true)
            bookStampTitle:SetColor("fff2ce52")
            bookStampTitle:DisableHitTest()
            LayoutHelpers.LayoutFor(bookStampTitle)
                :Left(function() return bookPanel.Left() + 14 end)
                :Top(function() return bookPanel.Top() + 32 + table.getn(BOOK_RULES) * 14 + 8 end)
                :Over(bookPanel, 3)

            local bookStampLines = {}
            for i = 1, table.getn(STAMP.IDS) do
                local li = i
                local tx = UIUtil.CreateText(bookPanel, "", 10, 'Arial', true)
                tx:SetColor(COL.TEXT)
                tx:DisableHitTest()
                LayoutHelpers.LayoutFor(tx)
                    :Left(function() return bookPanel.Left() + 14 end)
                    :Top(function() return bookPanel.Top() + 32 + table.getn(BOOK_RULES) * 14 + 26 + (li - 1) * 14 end)
                    :Over(bookPanel, 3)
                bookStampLines[i] = tx
            end

            -- the creature list, two columns of ten
            local bookRows = {}
            for i = 1, table.getn(NOMICON_ROWS) do
                local ri  = i
                local col = 0
                local row = i - 1
                if i > 10 then col = 1 ; row = i - 11 end

                local ic = Bitmap(bookPanel)
                ic:DisableHitTest()
                ic:SetTexture(C.ART .. (DEF[NOMICON_ROWS[i]].icon or 'dot') .. '.png')
                LayoutHelpers.LayoutFor(ic)
                    :Left(function() return bookPanel.Left() + math.floor(bookPanel.Width() * 0.45) + col * math.floor(bookPanel.Width() * 0.26) + 32 end)
                    :Top(function() return bookPanel.Top() + 34 + row * 22 end)
                    :Width(function() return 20 end)
                    :Height(function() return 20 end)
                    :Over(bookPanel, 3)

                local pw = UIUtil.CreateText(bookPanel, "", 11, 'Arial Bold', true)
                pw:SetColor(COL.POWER)
                pw:DisableHitTest()
                LayoutHelpers.LayoutFor(pw)
                    :Left(function() return bookPanel.Left() + math.floor(bookPanel.Width() * 0.45) + col * math.floor(bookPanel.Width() * 0.26) end)
                    :Top(function() return bookPanel.Top() + 37 + row * 22 end)
                    :Over(bookPanel, 3)

                local ct = UIUtil.CreateText(bookPanel, "", 11, 'Arial Bold', true)
                ct:SetColor(COL.TEXT)
                ct:DisableHitTest()
                LayoutHelpers.LayoutFor(ct)
                    :Left(function() return bookPanel.Left() + math.floor(bookPanel.Width() * 0.45) + col * math.floor(bookPanel.Width() * 0.26) + 58 end)
                    :Top(function() return bookPanel.Top() + 37 + row * 22 end)
                    :Over(bookPanel, 3)

                bookRows[i] = { icon = ic, power = pw, count = ct }
            end

            local bookHint = UIUtil.CreateText(bookPanel, "Click the book again to close", 10, 'Arial', true)
            bookHint:SetColor("ff888888")
            bookHint:DisableHitTest()
            LayoutHelpers.AtHorizontalCenterIn(bookHint, bookPanel)
            LayoutHelpers.LayoutFor(bookHint):Bottom(function() return bookPanel.Bottom() - 4 end):Over(bookPanel, 3)
            bookPanel:Hide()

            -- -------------------------------------------------
            -- end-of-run panel
            -- -------------------------------------------------
            local endPanel = Group(content)
            LayoutHelpers.LayoutFor(endPanel)
                :Left(function() return content.Left() + C.PAD + 40 end)
                :Right(function() return content.Right() - C.PAD - 40 end)
                :Top(function() return content.Top() + C.PAD + C.HEADER_H + C.PAD + 30 end)
                :Height(function() return 232 end)
                :Over(content, 25)

            local endBg = Bitmap(endPanel)
            endBg:SetSolidColor(COL.PANEL)
            LayoutHelpers.FillParent(endBg, endPanel)
            LayoutHelpers.DepthOverParent(endBg, endPanel, 1)
            endBg.HandleEvent = function(ctrl, event) return true end

            local endTitle = UIUtil.CreateText(endPanel, "", 16, 'Arial Black', true)
            endTitle:DisableHitTest()
            LayoutHelpers.AtHorizontalCenterIn(endTitle, endPanel)
            LayoutHelpers.LayoutFor(endTitle):Top(function() return endPanel.Top() + 12 end):Over(endPanel, 3)

            local endLines = {}
            for i = 1, 9 do
                local li = i
                local tx = UIUtil.CreateText(endPanel, "", 12, 'Arial', true)
                tx:SetColor(COL.TEXT)
                tx:DisableHitTest()
                LayoutHelpers.AtHorizontalCenterIn(tx, endPanel)
                LayoutHelpers.LayoutFor(tx)
                    :Top(function() return endPanel.Top() + 42 + (li - 1) * 17 end)
                    :Over(endPanel, 3)
                endLines[i] = tx
            end
            endPanel:Hide()

            local xpExtra = UIUtil.CreateText(content, "", 11, 'Arial Bold', true)
            xpExtra:SetColor(COL.XP)
            xpExtra:DisableHitTest()
            LayoutHelpers.LayoutFor(xpExtra)
                :Left(function() return content.Left() + C.PAD + 44 + 25 * 12 + 6 end)
                :Top(function() return content.Bottom() - C.PAD - 23 end)
                :Over(content, 3)

            -- -------------------------------------------------
            -- rendering
            -- -------------------------------------------------

            RefreshTile = function(i)
                if G == nil or G.tiles == nil then return end
                local t  = G.tiles[i]
                local ui = cells[i]
                local showAll  = (G.status == 'dead')
                local revealed = t.revealed or showAll

                ui.num:SetText("")
                ui.pow:SetText("")

                if not revealed then
                    ui.bg:SetTexture(C.ART .. backVariant[i] .. '.png')
                    ui.arrow:Hide()
                    if t.mark > 0 then
                        local mi = MARK_ICON[t.mark]
                        if mi ~= nil then
                            ui.icon:SetTexture(C.ART .. mi .. '.png')
                            ui.icon:SetAlpha(1.0, false)
                            ui.icon:Show()
                        else
                            ui.icon:Hide()
                            ui.num:SetText(tostring(t.mark))
                            ui.num:SetColor(COL.MARK)
                        end
                    else
                        ui.icon:Hide()
                    end
                    return
                end

                if t.id == ID.EMPTY then
                    ui.bg:SetTexture(C.ART .. 'tile_open.png')
                    ui.icon:Hide()
                    ui.arrow:Hide()
                    if Logic.GazerHides(G, t) then
                        ui.num:SetText("?")
                        ui.num:SetColor(COL.HIDDEN)
                    else
                        local n = Logic.AttackNumber(G, t)
                        if n > 0 then
                            ui.num:SetText(tostring(n))
                            ui.num:SetColor(COL.SUM)
                        end
                    end
                    return
                end

                -- anything that can be picked up gets the lit tile back
                if t.xp > 0 and ((not t.monster) or t.defeated) then
                    ui.bg:SetTexture(C.ART .. 'tile_item.png')
                else
                    ui.bg:SetTexture(C.ART .. 'tile_open.png')
                end

                local tex = DEF[t.id].icon
                if t.id == ID.WALL then
                    if t.wallHP >= 3 then tex = 'wall3'
                    elseif t.wallHP == 2 then tex = 'wall2'
                    else tex = 'wall1' end
                elseif t.id == ID.MIMIC and t.disguised then
                    tex = 'chest'
                elseif t.id == ID.DRAGON and t.defeated then
                    tex = 'dragon_dead'
                elseif t.id == ID.EGG and t.defeated then
                    tex = 'egg_cracked'
                elseif t.id == ID.MINE then
                    if showAll and G.lastIdx == i then tex = 'mine_boom'
                    elseif t.defeated then tex = 'mine_off' end
                elseif t.id == ID.GIANT and t.who == 'juliet' then
                    tex = 'giant2'
                elseif t.id == ID.TREASURE then
                    if t.xp <= 1 then tex = 'gem1'
                    elseif t.xp <= 3 then tex = 'gem3'
                    else tex = 'gem5' end
                end
                if tex == nil then tex = 'dot' end

                ui.icon:SetTexture(C.ART .. tex .. '.png')
                ui.icon:Show()
                if t.defeated then ui.icon:SetAlpha(0.55, false) else ui.icon:SetAlpha(1.0, false) end

                -- direction hints: the gargoyle looks at its twin, the minotaur at
                -- the chest it guards, the rat towards its king, and the surviving
                -- giant mourns its partner
                ui.arrow:Hide()
                if not t.defeated then
                    local ax, ay = nil, nil
                    if t.id == ID.GARGOYLE and t.faceX ~= nil then
                        ax = t.faceX
                        ay = t.faceY
                    elseif t.id == ID.MINOTAUR and t.chestX ~= nil then
                        local c = Logic.At(G, t.chestX, t.chestY)
                        if c ~= nil and c.id == ID.CHEST then
                            ax = t.chestX
                            ay = t.chestY
                        end
                    elseif t.id == ID.RAT then
                        local k = Logic.FindFirst(G, ID.RATKING)
                        if k ~= nil and k.x ~= t.x then
                            ax = k.x
                            ay = t.y
                        end
                    elseif t.id == ID.GIANT then
                        local alone = true
                        for j = 1, C.NTILES do
                            local o = G.tiles[j]
                            if o.id == ID.GIANT and o ~= t and not o.defeated then alone = false end
                        end
                        if alone then
                            ui.arrow:SetTexture(C.ART .. 'heart_half.png')
                            ui.arrow:Show()
                        end
                    end
                    if ax ~= nil then
                        local dx = ax - t.x
                        local dy = ay - t.y
                        local name = nil
                        if math.abs(dx) >= math.abs(dy) then
                            if dx > 0 then name = 'arrow_r' elseif dx < 0 then name = 'arrow_l' end
                        else
                            if dy > 0 then name = 'arrow_d' elseif dy < 0 then name = 'arrow_u' end
                        end
                        if name ~= nil then
                            ui.arrow:SetTexture(C.ART .. name .. '.png')
                            ui.arrow:Show()
                        end
                    end
                end

                if t.defeated then
                    if t.xp > 0 then
                        ui.pow:SetText("+" .. tostring(t.xp))
                        ui.pow:SetColor(COL.XP)
                    end
                elseif t.monster then
                    if (not t.disguised) and t.id ~= ID.GNOME then
                        ui.pow:SetText(tostring(t.power))
                        ui.pow:SetColor(COL.POWER)
                    end
                elseif t.id == ID.TREASURE then
                    ui.pow:SetText("+" .. tostring(t.xp))
                    ui.pow:SetColor(COL.XP)
                end
            end

            RefreshHUD = function()
                if G == nil then return end

                self.scoreLabel:SetText("Lv " .. tostring(G.level) .. "   Score " .. tostring(G.score))

                local msg = G.message
                if G.status == 'dead' then
                    msg = Logic.DeathLine(G) .. "   Click Jorge to try again."
                    self.statusLabel:SetColor(COL.WARN)
                elseif G.status == 'won' then
                    msg = "The dragon is slain."
                    self.statusLabel:SetColor(COL.GOOD)
                else
                    self.statusLabel:SetColor(COL.TEXT)
                end
                if msg == nil then msg = "" end
                self.statusLabel:SetText(msg)

                if G.status == 'dead' then heroBtn:SetTexture(C.ART .. 'hero_dead.png')
                elseif Logic.CanLevelUp(G) then heroBtn:SetTexture(C.ART .. 'hero_power.png')
                elseif G.hp <= 1 then heroBtn:SetTexture(C.ART .. 'hero_hurt.png')
                else heroBtn:SetTexture(C.ART .. 'hero.png') end

                for i = 1, C.MAX_HP - 1 do
                    local b = hearts[i]
                    if i < G.hp then
                        b:Show() ; b:SetTexture(C.ART .. 'heart_full.png')
                    elseif i < G.maxHP then
                        b:Show() ; b:SetTexture(C.ART .. 'heart_empty.png')
                    elseif i == G.maxHP and IsHalfHeartLevel(G.level) then
                        b:Show() ; b:SetTexture(C.ART .. 'heart_half.png')
                    else
                        b:Hide()
                    end
                end

                local need = NextLevelXP(G.level)
                local have = G.xp
                if have > need then have = need end
                for i = 1, 25 do
                    if i <= need then
                        pips[i]:Show()
                        if i <= have then pips[i]:SetTexture(C.ART .. 'xp_on.png')
                        else pips[i]:SetTexture(C.ART .. 'xp_off.png') end
                    else
                        pips[i]:Hide()
                    end
                end
                if G.xp > need then xpExtra:SetText("+" .. tostring(G.xp - need))
                else xpExtra:SetText("") end
            end

            RefreshBook = function()
                if G == nil or G.tiles == nil then return end
                for i = 1, table.getn(NOMICON_ROWS) do
                    local id = NOMICON_ROWS[i]
                    local p  = Logic.NomiconPower(G, id)
                    local c  = Logic.NomiconCount(G, id)
                    bookRows[i].power:SetText("P" .. tostring(p))
                    if id == ID.GAZER then
                        bookRows[i].count:SetText("x ?")
                    else
                        bookRows[i].count:SetText("x " .. tostring(c))
                    end
                    if id == ID.MINE then
                        if p == 0 then bookRows[i].icon:SetTexture(C.ART .. 'mine_off.png')
                        else bookRows[i].icon:SetTexture(C.ART .. 'mine.png') end
                    end
                end
                for i = 1, table.getn(STAMP.IDS) do
                    local sid  = STAMP.IDS[i]
                    local mark = "[ ]  "
                    if stamps[sid] then mark = "[x]  " end
                    bookStampLines[i]:SetText(mark .. STAMP.SHORT[sid] .. " - " .. STAMP.HINT[sid])
                    if stamps[sid] then bookStampLines[i]:SetColor(COL.GOOD)
                    else bookStampLines[i]:SetColor(COL.TEXT) end
                end
            end

            local function RefreshEnd()
                if G == nil then return end
                if G.status ~= 'won' then
                    endPanel:Hide()
                    return
                end

                if not G.stampsSaved then
                    G.stampsSaved = true
                    local changed = false
                    for i = 1, table.getn(G.runStamps) do
                        local sid = G.runStamps[i]
                        if not stamps[sid] then
                            stamps[sid] = true
                            changed = true
                        end
                    end
                    if changed then SaveStamps(stamps) end
                end

                endTitle:SetText("THE DRAGON IS SLAIN")
                endTitle:SetColor(COL.GOOD)

                local secs = math.floor(G.endTime - G.startTime)
                if secs < 0 then secs = 0 end
                local mins = math.floor(secs / 60)
                local rem  = secs - mins * 60
                local remS = tostring(rem)
                if rem < 10 then remS = "0" .. remS end

                local lines = {}
                table.insert(lines, "Score " .. tostring(G.score) .. " out of " .. tostring(G.maxScore))
                table.insert(lines, "Time " .. tostring(mins) .. ":" .. remS)
                table.insert(lines, "")
                if table.getn(G.runStamps) == 0 then
                    table.insert(lines, "No stamps this run.")
                else
                    table.insert(lines, "Stamps earned:")
                    for i = 1, table.getn(G.runStamps) do
                        table.insert(lines, "   " .. STAMP.NAME[G.runStamps[i]])
                    end
                end

                for i = 1, table.getn(endLines) do
                    if lines[i] ~= nil then endLines[i]:SetText(lines[i])
                    else endLines[i]:SetText("") end
                end
                endPanel:Show()
            end

            RefreshAll = function()
                if G == nil or G.tiles == nil then return end
                for i = 1, C.NTILES do
                    RefreshTile(i)
                end
                RefreshHUD()
                RefreshEnd()
                if not bookPanel:IsHidden() then RefreshBook() end
            end

            -- -------------------------------------------------
            -- controls
            -- -------------------------------------------------

            heroBtn.HandleEvent = function(ctrl, event)
                if event.Type == "ButtonPress" and event.Modifiers.Left then
                    CloseMarkPanel()
                    if G == nil then return true end
                    if G.status == 'dead' then
                        StartNewGame()
                    elseif Logic.CanLevelUp(G) then
                        Logic.LevelUp(G)
                        RefreshAll()
                    end
                end
                return true
            end

            bookBtn.HandleEvent = function(ctrl, event)
                if event.Type == "ButtonPress" and event.Modifiers.Left then
                    CloseMarkPanel()
                    if bookPanel:IsHidden() then
                        RefreshBook()
                        bookPanel:Show()
                    else
                        bookPanel:Hide()
                    end
                end
                return true
            end

            StartNewGame = function()
                CloseMarkPanel()
                bookPanel:Hide()
                endPanel:Hide()
                G = Logic.New()
                if G.tiles == nil then
                    self.statusLabel:SetText("Could not build a lair. Press New Game again.")
                    self.statusLabel:SetColor(COL.WARN)
                    return
                end
                RefreshAll()
            end

            btnNew.OnClick = function() StartNewGame() end

            StartNewGame()
        end,

        OnClose = function(self)
            dsWindow = nil
            self:Hide()
            self:Destroy()
        end,

        OnEscapePressed = function(self) self:OnClose() end,
        OnShadowClicked = function(self) end,

        OnDestroy = function(self)
            self._cell       = nil
            self._bx         = nil
            self._by         = nil
            self.DragTL      = nil
            self.DragTR      = nil
            self.DragBL      = nil
            self.DragBR      = nil
            self.scoreLabel  = nil
            self.statusLabel = nil
            Window.OnDestroy(self)
        end,
    }

    -- =========================================================
    -- Hotkey handler
    -- =========================================================

    local function OpenDragonsweeper()
        if not IsDestroyed(dsWindow) then return end
        pcall(function() math.randomseed(math.floor(NowSeconds() * 1000)) end)
        dsWindow = DragonsweeperWindow(GetFrame(0))
    end

    -- Single bindable hotkey (plain + every modifier combo)
    ReUI.Actions.SelectionAction("Minigames - Dragonsweeper", function(_sel) OpenDragonsweeper() end, "Minigames", nil, MG_MODIFIERS)

    end -- DRAGONSWEEPER

end
