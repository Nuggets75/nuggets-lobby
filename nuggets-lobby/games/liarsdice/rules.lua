-- Nuggets custom lobby: Liar's Dice rules. Imported as /nuggetslobby/liarsdice/rules.lua.
-- No UI and no network: the table host runs these, the tests drive them directly.
--
-- Rules (the Liar's Bar rulesets):
--   Everyone rolls their dice in secret. In turn, players bid "at least Q dice show face
--   F" across ALL dice on the table. A bid must be higher than the last one: more dice,
--   or the same number of dice with a higher face. Instead of bidding, the player whose
--   turn it is can call:
--     Liar!    - everyone shows their dice. If the bid holds (count >= Q) the caller loses,
--                otherwise the bidder loses.
--     Spot on! - (Traditional only) the caller claims the count is exactly Q. If right,
--                everyone else loses; if wrong, the caller loses.
--   Traditional ruleset: ones are wild and count as every face, except in a bid on ones.
--   Basic ruleset: no wild ones, no Spot on.
--   Losing costs a life (everyone keeps their dice) or a die (classic), as the host sets.
--   Out of lives or dice = out of the game. Last player left wins.
--   The next round starts with the player who lost (the first one after the caller when
--   several lost); if that player is out, with the next player still in.

MIN_PLAYERS = 2
MAX_PLAYERS = 8
FACES = 6

-- allowed values for every table setting, in the order the window cycles through them
CHOICES = {
    ruleset = { 'traditional', 'basic' },
    lose    = { 'lives', 'dice' },
    lives   = { 1, 2, 3, 4, 5 },
    dice    = { 3, 4, 5, 6 },
    timer   = { 15, 20, 30, 45, 60, 90 },  -- seconds per turn (a player who runs out has a move made for them)
}

DEFAULTS = { ruleset = 'traditional', lose = 'lives', lives = 3, dice = 5, timer = 30 }

local function Contains(list, value)
    for i = 1, table.getn(list) do
        if list[i] == value then return true end
    end
    return false
end

--- A copy of `settings` with every value replaced by its default when not allowed.
function NormalizeSettings(settings)
    local out = {}
    for key, default in DEFAULTS do
        local value = default
        if type(settings) == 'table' and Contains(CHOICES[key], settings[key]) then
            value = settings[key]
        end
        out[key] = value
    end
    return out
end

function Wild(settings) return settings.ruleset == 'traditional' end
function SpotOnAllowed(settings) return settings.ruleset == 'traditional' end

--- Does `face` count for a bid on `bidFace`?
function Counts(face, bidFace, wild)
    if face == bidFace then return true end
    return wild and face == 1 and bidFace ~= 1
end

--- How many dice on the table count for a bid on `bidFace`.
--- Returns total, natural (dice showing the face) and wild (ones counted in).
function CountFace(hands, bidFace, wild)
    local natural, wilds = 0, 0
    for _, hand in hands do
        for i = 1, table.getn(hand) do
            local d = hand[i]
            if d == bidFace then
                natural = natural + 1
            elseif wild and d == 1 and bidFace ~= 1 then
                wilds = wilds + 1
            end
        end
    end
    return natural + wilds, natural, wilds
end

--- Is bid (q, f) higher than `prev` ({ q, f }) or a valid opening when `prev` is nil?
function IsHigher(q, f, prev)
    if prev == nil then return true end
    if q > prev.q then return true end
    return q == prev.q and f > prev.f
end

----------------------------------------------------------------------------
-- Game state
----------------------------------------------------------------------------
-- state = {
--   settings, phase = 'bidding' | 'reveal' | 'over',
--   players = { { name, bot, lives, dice, out, left }, ... }   (seat order = turn order)
--   round, turn (player index), starter (index), bid = nil | { q, f, by },
--   history = { { by, q, f } | { by, call = 'liar' | 'spot' }, ... }   (this round)
--   hands = { [index] = { d1, d2, ... } }   (secret: only the host has them)
--   result = nil | the last challenge (see Resolve), winner = nil | index
-- }

function IsIn(player) return not player.out end

function ActiveCount(state)
    local n = 0
    for i = 1, table.getn(state.players) do
        if IsIn(state.players[i]) then n = n + 1 end
    end
    return n
end

--- The first player still in, starting AT index i and going round the table.
function ActiveFrom(state, i)
    local n = table.getn(state.players)
    if n == 0 then return nil end
    for k = 0, n - 1 do
        local idx = i + k
        while idx > n do idx = idx - n end
        if IsIn(state.players[idx]) then return idx end
    end
    return nil
end

--- The next player still in after index i.
function NextActive(state, i)
    local n = table.getn(state.players)
    if n == 0 then return nil end
    local start = i + 1
    if start > n then start = 1 end
    local idx = ActiveFrom(state, start)
    if idx == i and not IsIn(state.players[i]) then return nil end
    return idx
end

--- How many dice player p rolls this round.
function DiceOf(state, p)
    if state.settings.lose == 'dice' then return p.dice end
    return state.settings.dice
end

function TotalDice(state)
    local total = 0
    for i = 1, table.getn(state.players) do
        local p = state.players[i]
        if IsIn(p) then total = total + DiceOf(state, p) end
    end
    return total
end

--- The smallest quantity that is a legal bid on `face` now; nil if none fits.
function MinQuantity(state, face)
    local total = TotalDice(state)
    local q = 1
    if state.bid ~= nil then
        if face > state.bid.f then q = state.bid.q else q = state.bid.q + 1 end
    end
    if q > total then return nil end
    return q
end

--- Is (q, f) a legal bid now? Returns true, or false and a reason.
function ValidBid(state, q, f)
    if type(q) ~= 'number' or type(f) ~= 'number' then return false, 'bad bid' end
    if q ~= math.floor(q) or f ~= math.floor(f) then return false, 'bad bid' end
    if f < 1 or f > FACES then return false, 'no such face' end
    if q < 1 then return false, 'bid at least one die' end
    if q > TotalDice(state) then return false, 'more dice than on the table' end
    if not IsHigher(q, f, state.bid) then return false, 'bid must be higher' end
    return true
end

--- Can anyone still bid higher than the current bid?
function AnyHigherBid(state)
    for f = 1, FACES do
        if MinQuantity(state, f) ~= nil then return true end
    end
    return false
end

--- A new game. `seats` = { { name = ..., bot = true/false }, ... }, 2 to 8 of them.
function NewGame(settings, seats, rand)
    local s = NormalizeSettings(settings)
    local state = {
        settings = s, phase = 'bidding', players = {}, round = 0, turn = nil,
        starter = 1, bid = nil, history = {}, hands = {}, result = nil, winner = nil,
    }
    for i = 1, table.getn(seats) do
        table.insert(state.players, {
            name = seats[i].name, bot = seats[i].bot and true or false,
            lives = s.lives, dice = s.dice, out = false, left = false,
        })
    end
    state.starter = (rand or math.random)(table.getn(state.players))
    return state
end

--- Rolls everyone's dice and opens the bidding with the starter.
function StartRound(state, rand)
    rand = rand or math.random
    state.round = state.round + 1
    state.bid = nil
    state.history = {}
    state.hands = {}
    state.result = nil
    for i = 1, table.getn(state.players) do
        local p = state.players[i]
        if IsIn(p) then
            local hand = {}
            for k = 1, DiceOf(state, p) do hand[k] = rand(FACES) end
            state.hands[i] = hand
        end
    end
    state.turn = ActiveFrom(state, state.starter)
    state.phase = 'bidding'
end

local function CopyHands(state)
    local copy = {}
    for i, hand in state.hands do
        local h = {}
        for k = 1, table.getn(hand) do h[k] = hand[k] end
        copy[i] = h
    end
    return copy
end

-- Takes a life or a die from player i. Returns true when that put them out.
local function Lose(state, i)
    local p = state.players[i]
    if p.out then return false end
    if state.settings.lose == 'dice' then
        p.dice = p.dice - 1
        if p.dice <= 0 then p.dice = 0; p.out = true end
    else
        p.lives = p.lives - 1
        if p.lives <= 0 then p.lives = 0; p.out = true end
    end
    return p.out
end

-- Ends the game when one player is left (or none, which cannot happen in play).
local function CheckOver(state)
    if ActiveCount(state) <= 1 then
        state.phase = 'over'
        state.winner = ActiveFrom(state, 1)
        state.turn = nil
        return true
    end
    return false
end

--- Settles a Liar or Spot on call by player `caller` against the current bid.
local function Resolve(state, caller, kind)
    local bid = state.bid
    local wild = Wild(state.settings)
    local count, natural, wilds = CountFace(state.hands, bid.f, wild)
    local losers = {}
    local held = count >= bid.q
    if kind == 'liar' then
        if held then table.insert(losers, caller) else table.insert(losers, bid.by) end
    else
        if count == bid.q then
            -- everyone else loses, in turn order after the caller
            local idx = NextActive(state, caller)
            while idx ~= nil and idx ~= caller do
                table.insert(losers, idx)
                idx = NextActive(state, idx)
            end
        else
            table.insert(losers, caller)
        end
    end
    local eliminated = {}
    for k = 1, table.getn(losers) do
        if Lose(state, losers[k]) then table.insert(eliminated, losers[k]) end
    end
    state.result = {
        kind = kind, caller = caller, bidder = bid.by, q = bid.q, f = bid.f,
        count = count, natural = natural, wilds = wilds, held = held,
        exact = (count == bid.q), losers = losers, eliminated = eliminated,
        hands = CopyHands(state), round = state.round,
    }
    -- the first loser starts the next round (or the next player still in)
    state.starter = ActiveFrom(state, losers[1]) or 1
    state.turn = nil
    if not CheckOver(state) then
        state.phase = 'reveal'
    end
end

--- Player `seat` acts. action = { kind = 'bid', q = .., f = .. } | { kind = 'liar' } | { kind = 'spot' }.
--- Returns true, or false and a reason. Nothing changes when it is refused.
function Act(state, seat, action)
    if state.phase ~= 'bidding' then return false, 'not bidding now' end
    if seat ~= state.turn then return false, 'not your turn' end
    if type(action) ~= 'table' then return false, 'bad action' end
    local kind = action.kind
    if kind == 'bid' then
        local ok, why = ValidBid(state, action.q, action.f)
        if not ok then return false, why end
        state.bid = { q = action.q, f = action.f, by = seat }
        table.insert(state.history, { by = seat, q = action.q, f = action.f })
        state.turn = NextActive(state, seat)
        return true
    elseif kind == 'liar' or kind == 'spot' then
        if state.bid == nil then return false, 'nothing to call yet' end
        if kind == 'spot' and not SpotOnAllowed(state.settings) then return false, 'no Spot on in this ruleset' end
        table.insert(state.history, { by = seat, call = kind })
        Resolve(state, seat, kind)
        return true
    end
    return false, 'bad action'
end

--- Player i leaves (or drops) mid-game: they are out. Returns what the table must do:
---   'over'    - one player left, game over
---   'reroll'  - they were in this round's bidding: roll a new round
---   nil       - nothing else to do (game not running, or they were already out)
function Leave(state, i)
    local p = state.players[i]
    if p == nil or p.out then
        if p then p.left = true end
        return nil
    end
    p.out = true
    p.left = true
    if CheckOver(state) then return 'over' end
    if state.phase == 'bidding' then
        state.starter = ActiveFrom(state, i) or 1
        return 'reroll'
    end
    if state.phase == 'reveal' and state.starter == i then
        state.starter = ActiveFrom(state, i) or 1
    end
    return nil
end

--- Same seats, fresh lives and dice, for "Play again".
function Restart(state, rand)
    local seats = {}
    for i = 1, table.getn(state.players) do
        local p = state.players[i]
        if not p.left then table.insert(seats, { name = p.name, bot = p.bot }) end
    end
    return NewGame(state.settings, seats, rand)
end
