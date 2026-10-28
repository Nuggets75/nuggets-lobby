-- Nuggets custom lobby: Liar's Dice bot. Imported as /nuggetslobby/liarsdice/bot.lua.
-- Decides a move from what one player can know: their own dice, how many dice are on the
-- table and the current bid. Also plays for a human whose turn timer runs out.
--
-- It works out how likely a bid is: the player's own dice that count, plus the chance
-- that each unknown die counts (1 in 6, or 1 in 3 when ones are wild and the bid is not
-- on ones). It calls Liar on unlikely bids, Spot on when an exact count is likely, and
-- otherwise raises to the most likely bid it may make. A little randomness and the odd
-- bluff keep it from being predictable.

local Rules = import('/nuggetslobby/liarsdice/rules.lua')

local function Choose(n, k)
    if k < 0 or k > n then return 0 end
    local r = 1
    for i = 1, k do
        r = r * (n - k + i) / i
    end
    return r
end

--- P(X = k) for X ~ Binomial(n, p)
function Exactly(n, p, k)
    if k < 0 or k > n then return 0 end
    return Choose(n, k) * math.pow(p, k) * math.pow(1 - p, n - k)
end

--- P(X >= k) for X ~ Binomial(n, p)
function AtLeast(n, p, k)
    if k <= 0 then return 1 end
    if k > n then return 0 end
    local sum = 0
    for j = k, n do sum = sum + Exactly(n, p, j) end
    if sum > 1 then sum = 1 end
    return sum
end

--- How likely a bid (q, f) holds, and how likely it is exactly right, for this view.
--- view = { settings, dice = { my dice }, total = dice on the table, bid = nil | { q, f } }
function Estimate(view, q, f)
    local wild = Rules.Wild(view.settings)
    local mine = 0
    for i = 1, table.getn(view.dice) do
        if Rules.Counts(view.dice[i], f, wild) then mine = mine + 1 end
    end
    local unknown = view.total - table.getn(view.dice)
    local p = 1 / 6
    if wild and f ~= 1 then p = 2 / 6 end
    return AtLeast(unknown, p, q - mine), Exactly(unknown, p, q - mine), mine
end

local function MinQuantity(view, f)
    local q = 1
    if view.bid ~= nil then
        if f > view.bid.f then q = view.bid.q else q = view.bid.q + 1 end
    end
    if q > view.total then return nil end
    return q
end

--- A legal move for this view. rand() returns a number from 0 to 1 (math.random).
--- Returns { kind = 'bid', q, f } | { kind = 'liar' } | { kind = 'spot' }.
function Decide(view, rand)
    rand = rand or math.random
    local wild = Rules.Wild(view.settings)
    local canSpot = Rules.SpotOnAllowed(view.settings)

    -- the most likely legal raise, per face at its smallest legal quantity
    local best = nil
    for f = 1, Rules.FACES do
        local q = MinQuantity(view, f)
        if q ~= nil then
            local p, _, mine = Estimate(view, q, f)
            -- ones are a poor bid when they are wild for everything else
            if wild and f == 1 then p = p * 0.8 end
            -- a little noise so equal choices do not always go the same way
            local score = p + rand() * 0.06 + mine * 0.01
            if best == nil or score > best.score then
                best = { q = q, f = f, p = p, score = score }
            end
        end
    end

    if view.bid == nil then
        -- opening: the face I have most of, at about what the table should hold
        local face, most = 6, -1
        for f = 1, Rules.FACES do
            if not (wild and f == 1) then
                local _, _, mine = Estimate(view, 1, f)
                if mine > most or (mine == most and rand() < 0.5) then face, most = f, mine end
            end
        end
        local unknown = view.total - table.getn(view.dice)
        local p = 1 / 6
        if wild then p = 2 / 6 end
        local expected = most + unknown * p
        local q = math.floor(expected * (0.55 + rand() * 0.3))
        if q < 1 then q = 1 end
        if q > view.total then q = view.total end
        return { kind = 'bid', q = q, f = face }
    end

    local pBid, pExact = Estimate(view, view.bid.q, view.bid.f)

    if canSpot and pExact >= 0.27 + rand() * 0.1 and pBid >= 0.45 then
        return { kind = 'spot' }
    end
    if best == nil then
        -- nothing higher is possible
        if canSpot and pExact >= 0.2 then return { kind = 'spot' } end
        return { kind = 'liar' }
    end
    local doubt = 0.38 + rand() * 0.2
    if pBid < doubt and best.p < pBid + 0.3 then
        return { kind = 'liar' }
    end
    if best.p < 0.2 and pBid < 0.55 and rand() < 0.75 then
        return { kind = 'liar' }
    end
    return { kind = 'bid', q = best.q, f = best.f }
end
