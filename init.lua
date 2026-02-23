--[[
============================================================
 Blackjack.lua
 Created by Cannonballdex™

 Description:
   Blackjack mini-game for MacroQuest (MQNext).

 Features / Rules:
   • Dealer peek (checks for blackjack on Ace/10 upcard)
   • Insurance (including “Even Money” when player has blackjack vs dealer Ace)
   • Late surrender (first action only, after dealer peek)
   • Split up to MAX_HANDS (including optional resplit aces)
   • Split aces: one card only (configurable)
   • Double down (configurable: allow after split)
   • Blackjack payout (3:2 default)
   • Dealer soft-17 behavior configurable

 Betting Rules:
   • Minimum bet: 100
   • Maximum bet: 10,000
   • Bet increments: 100

 UI:
   • Bet slider with [-] and [+]
   • Buttons: Start / Hit / Stand / Double / Split / Surrender / Insurance
   • Last round results are ALWAYS visible under Status (no dropdown)
   • If bankroll drops below minimum bet, UI offers a Reset button.

 Commands:
   /lua run blackjack
   /blackjack help

============================================================
]]

local function ensure_package(package_name, require_name)
    local ok, lib = pcall(require, require_name)
    if ok then return lib end
    local packageMan = require('mq/PackageMan')
    return packageMan.InstallAndLoad(package_name, require_name)
end

ensure_package('luafilesystem', 'lfs')

local mq = require('mq')
local ImGui = require('ImGui')
local lfs = require('lfs')

-- ============================================================
-- RULES (tweak here)
-- ============================================================
local DEFAULT_BANKROLL = 100000
local DEFAULT_MAX_BET  = 10000
local DEFAULT_LAST_BET = 1000

local BLACKJACK_PAYOUT_MULT = 1.5 -- 3:2 (set 1.0 for 1:1)
local DEALER_HITS_SOFT_17   = false

local MAX_HANDS             = 4
local ALLOW_DOUBLE          = true
local ALLOW_DOUBLE_AFTER_SPLIT = true
local ALLOW_SURRENDER       = true -- late surrender
local ALLOW_INSURANCE       = true
local ALLOW_SPLIT           = true
local ALLOW_RESPLIT_ACES    = true
local SPLIT_ACES_ONE_CARD_ONLY = true

-- Betting constraints requested
local BET_MIN  = 100
local BET_STEP = 100

-- ============================================================
-- Utilities
-- ============================================================
local function tell(msg)
    mq.cmdf('/echo \ay[Blackjack]\ax %s', msg)
end

local function normalize_path(p)
    return (tostring(p or ""):gsub("\\", "/"))
end

local function joinPath(a, b)
    a = normalize_path(a)
    b = normalize_path(b)
    if a == "" then return b end
    if a:sub(-1) == "/" then return a .. b end
    return a .. "/" .. b
end

local function ensure_dir_recursive(path)
    path = normalize_path(path)
    if path == "" then return true end

    local attr = lfs.attributes(path)
    if attr and attr.mode == "directory" then return true end
    if attr and attr.mode ~= "directory" then
        tell(("Path exists but is not a directory: %s"):format(path))
        return false
    end

    local parts = {}
    for part in path:gmatch("[^/]+") do
        parts[#parts + 1] = part
    end

    local built = parts[1] or ""
    if built:match("^%a:$") then
        for i = 2, #parts do
            built = built .. "/" .. parts[i]
            if not lfs.attributes(built) then
                if not lfs.mkdir(built) then
                    tell(("Failed to create directory: %s"):format(built))
                    return false
                end
            end
        end
        return true
    end

    built = parts[1] or ""
    if built ~= "" and not lfs.attributes(built) then
        if not lfs.mkdir(built) then
            tell(("Failed to create directory: %s"):format(built))
            return false
        end
    end

    for i = 2, #parts do
        built = built .. "/" .. parts[i]
        if not lfs.attributes(built) then
            if not lfs.mkdir(built) then
                tell(("Failed to create directory: %s"):format(built))
                return false
            end
        end
    end

    return true
end

local function get_config_dir()
    if mq.TLO.MacroQuest.ConfigDir then
        local d = tostring(mq.TLO.MacroQuest.ConfigDir() or "")
        d = normalize_path(d)
        if d ~= "" and d ~= "nil" then return d end
    end

    local base = normalize_path(tostring(mq.TLO.MacroQuest.Path() or ""))
    if base ~= "" and base ~= "nil" then
        return joinPath(base, "config")
    end

    return "."
end

local function roundDownToStep(x, step)
    step = step or 1
    x = math.floor(tonumber(x) or 0)
    if step <= 1 then return x end
    return x - (x % step)
end

-- ============================================================
-- Config (per-character)
-- ============================================================
local charName = tostring(mq.TLO.Me.CleanName() or "unknown")
local CONFIG_DIR = joinPath(get_config_dir(), "blackjack")
ensure_dir_recursive(CONFIG_DIR)
local CONFIG_PATH = joinPath(CONFIG_DIR, ("blackjack_%s.lua"):format(charName))

local function saveConfig(cfg)
    local f, err = io.open(CONFIG_PATH, "w")
    if not f then
        tell(("Failed to save config: %s | Path: %s"):format(tostring(err), normalize_path(CONFIG_PATH)))
        return false
    end
    f:write("return {\n")
    f:write(("  bankroll = %d,\n"):format(tonumber(cfg.bankroll) or DEFAULT_BANKROLL))
    f:write(("  maxBet   = %d,\n"):format(DEFAULT_MAX_BET)) -- forced
    f:write(("  lastBet  = %d,\n"):format(tonumber(cfg.lastBet) or DEFAULT_LAST_BET))
    f:write("}\n")
    f:close()
    return true
end

local function loadConfig()
    local cfg = { bankroll = DEFAULT_BANKROLL, maxBet = DEFAULT_MAX_BET, lastBet = DEFAULT_LAST_BET }
    local chunk = loadfile(CONFIG_PATH)
    if chunk then
        local ok, loaded = pcall(chunk)
        if ok and type(loaded) == "table" then
            cfg.bankroll = tonumber(loaded.bankroll) or cfg.bankroll
            cfg.lastBet  = tonumber(loaded.lastBet)  or cfg.lastBet
        end
    else
        saveConfig(cfg)
    end

    cfg.maxBet = DEFAULT_MAX_BET
    if cfg.bankroll < 0 then cfg.bankroll = 0 end

    cfg.lastBet = roundDownToStep(cfg.lastBet, BET_STEP)
    if cfg.lastBet < BET_MIN then cfg.lastBet = BET_MIN end
    if cfg.lastBet > cfg.maxBet then cfg.lastBet = cfg.maxBet end
    if cfg.bankroll > 0 and cfg.lastBet > cfg.bankroll then
        cfg.lastBet = roundDownToStep(cfg.bankroll, BET_STEP)
        if cfg.lastBet < BET_MIN then cfg.lastBet = BET_MIN end
    end

    saveConfig(cfg)
    return cfg
end

local cfg = loadConfig()

-- ============================================================
-- Cards / Hand logic
-- ============================================================
local function createDeck()
    local deck = {}
    local ranks = {"A","2","3","4","5","6","7","8","9","10","J","Q","K"}
    local suits = {"♠","♥","♦","♣"} -- If your UI can’t render: {"S","H","D","C"}

    for _, s in ipairs(suits) do
        for _, r in ipairs(ranks) do
            deck[#deck+1] = r .. s
        end
    end

    for i = #deck, 2, -1 do
        local j = math.random(i)
        deck[i], deck[j] = deck[j], deck[i]
    end
    return deck
end

local function dealCard(deck)
    return table.remove(deck, 1)
end

local function cardRank(card)
    return card:match("^(%d+)") or card:match("^(%a)")
end

local function isTenValue(card)
    local r = cardRank(card)
    return (r == "10" or r == "J" or r == "Q" or r == "K")
end

local function isAce(card)
    return cardRank(card) == "A"
end

local function calculateHandValue(hand)
    local value, aces = 0, 0
    for _, card in ipairs(hand) do
        local r = cardRank(card)
        if r == "A" then
            value = value + 11
            aces = aces + 1
        elseif r == "K" or r == "Q" or r == "J" then
            value = value + 10
        else
            value = value + tonumber(r)
        end
    end
    while value > 21 and aces > 0 do
        value = value - 10
        aces = aces - 1
    end
    return value
end

local function isSoft17(hand)
    local total = 0
    local aces = 0
    for _, card in ipairs(hand) do
        local r = cardRank(card)
        if r == "A" then
            total = total + 11
            aces = aces + 1
        elseif r == "K" or r == "Q" or r == "J" then
            total = total + 10
        else
            total = total + tonumber(r)
        end
    end
    if total ~= 17 then return false end
    return aces > 0
end

local function isBlackjack(hand)
    return (#hand == 2 and calculateHandValue(hand) == 21)
end

local function handToString(hand)
    return table.concat(hand, ", ")
end

-- ============================================================
-- Game state
-- ============================================================
local deck = nil
local dealerHand = {}

local playerHands = {}
local handBets = {}
local handDone = {}
local handDoubled = {}
local handSurrendered = {}
local handIsSplitAce = {}
local handResult = {}
local handNet = {}

local currentHandIndex = 1
local inRound = false
local running = true

-- Insurance
local insuranceOffered = false
local insuranceTaken = false
local insuranceBet = 0
local evenMoneyTaken = false

-- first-action gating
local handFirstAction = {}

-- Last round summary (for GUI)
local lastRound = {
    exists = false,
    summaryLines = {},
}

-- Next round bet
local currentBet = cfg.lastBet
if currentBet > cfg.bankroll then currentBet = cfg.bankroll end
currentBet = roundDownToStep(currentBet, BET_STEP)
if currentBet < BET_MIN then currentBet = BET_MIN end
if currentBet > cfg.maxBet then currentBet = cfg.maxBet end

-- GUI state
local showGUI = true
local guiTitle = "Blackjack (MQNext) by Cannonballdex™"

-- ============================================================
-- Betting helpers
-- ============================================================
local function clampBet(x)
    x = roundDownToStep(x, BET_STEP)
    if x < BET_MIN then x = BET_MIN end
    if x > cfg.maxBet then x = cfg.maxBet end

    if x > cfg.bankroll then
        x = roundDownToStep(cfg.bankroll, BET_STEP)
        if x < BET_MIN then
            return 0 -- can't afford minimum
        end
    end

    return x
end

local function setBet(amount)
    local clamped = clampBet(amount)
    if clamped < BET_MIN then
        tell(("Not enough bankroll to bet the minimum (%d). Type \at/blackjack reset\ax to restart at %d."):format(BET_MIN, DEFAULT_BANKROLL))
        return
    end
    currentBet = clamped
    cfg.lastBet = clamped
    saveConfig(cfg)
    tell(("Bet set to %d (Min %d / Max %d). Bankroll: %d"):format(currentBet, BET_MIN, cfg.maxBet, cfg.bankroll))
end

local function recordLastRound(lines)
    lastRound.exists = true
    lastRound.summaryLines = lines or {}
end

local function resetBankroll()
    cfg.bankroll = DEFAULT_BANKROLL
    cfg.lastBet = DEFAULT_LAST_BET
    saveConfig(cfg)
    setBet(cfg.lastBet)
    tell("Bankroll reset to 100,000 and bet set to 1,000.")
end

local function endRound(msg)
    inRound = false
    insuranceOffered = false
    insuranceTaken = false
    insuranceBet = 0
    evenMoneyTaken = false
    if msg then tell(msg) end
end

-- ============================================================
-- Resolution helpers
-- ============================================================
local function dealerValue()
    return calculateHandValue(dealerHand)
end

local function currentHand()
    return playerHands[currentHandIndex]
end

local function currentValue()
    return calculateHandValue(currentHand())
end

local function allHandsDone()
    for i = 1, #handDone do
        if not handDone[i] then return false end
    end
    return true
end

local function advanceToNextHand()
    for i = currentHandIndex + 1, #playerHands do
        if not handDone[i] then
            currentHandIndex = i
            return
        end
    end
    for i = 1, #playerHands do
        if not handDone[i] then
            currentHandIndex = i
            return
        end
    end
end

local function applyNetToBankroll(net)
    cfg.bankroll = cfg.bankroll + net
    if cfg.bankroll < 0 then cfg.bankroll = 0 end
    saveConfig(cfg)

    -- Keep next bet sane after bankroll changes
    if cfg.bankroll >= BET_MIN then
        currentBet = clampBet(currentBet)
        if currentBet < BET_MIN then currentBet = clampBet(cfg.lastBet) end
        if currentBet < BET_MIN then currentBet = clampBet(cfg.bankroll) end
        if currentBet < BET_MIN then currentBet = BET_MIN end
    end
end

local function payoutForHand(i, dealerFinalValue, dealerBusted, dealerHasBJ)
    if handNet[i] ~= nil then return end

    local bet = handBets[i] or 0
    local h = playerHands[i]
    local pv = calculateHandValue(h)

    if handSurrendered[i] then
        local loss = math.floor(bet / 2)
        handResult[i] = "surrender"
        handNet[i] = -loss
        return
    end

    if pv > 21 then
        handResult[i] = "bust"
        handNet[i] = -bet
        return
    end

    local playerBJ = isBlackjack(h)
    local splitAce = handIsSplitAce[i] == true
    if playerBJ and splitAce then playerBJ = false end

    if dealerHasBJ then
        if playerBJ then
            handResult[i] = "push"
            handNet[i] = 0
        else
            handResult[i] = "lose"
            handNet[i] = -bet
        end
        return
    end

    if playerBJ then
        handResult[i] = "blackjack"
        local win = math.floor(bet * BLACKJACK_PAYOUT_MULT + 0.5)
        handNet[i] = win
        return
    end

    if dealerBusted then
        handResult[i] = "win"
        handNet[i] = bet
        return
    end

    if pv > dealerFinalValue then
        handResult[i] = "win"
        handNet[i] = bet
    elseif pv < dealerFinalValue then
        handResult[i] = "lose"
        handNet[i] = -bet
    else
        handResult[i] = "push"
        handNet[i] = 0
    end
end

local function resolveInsurance(dealerHasBJ)
    if not insuranceTaken or insuranceBet <= 0 then return 0 end
    if dealerHasBJ then
        return insuranceBet * 2
    end
    return -insuranceBet
end

local function buildRoundSummaryLines(netTotal, dealerFinalValue, dealerStr)
    local lines = {}
    lines[#lines+1] = ("Last Round: Net %s%d"):format(netTotal >= 0 and "+" or "", netTotal)
    lines[#lines+1] = ("Dealer: %s (%d)"):format(dealerStr, dealerFinalValue)

    for i = 1, #playerHands do
        local h = playerHands[i]
        local pv = calculateHandValue(h)
        local bet = handBets[i] or 0
        local res = handResult[i] or "?"
        local net = handNet[i] or 0
        lines[#lines+1] = ("Hand %d: %s (%d) | Bet %d | %s | Net %s%d"):format(
            i, handToString(h), pv, bet, res, net >= 0 and "+" or "", net
        )
    end
    return lines
end

local function dealerPlay()
    while true do
        local dv = dealerValue()
        if dv > 21 then break end

        if dv < 17 then
            dealerHand[#dealerHand+1] = dealCard(deck)
        elseif dv == 17 and DEALER_HITS_SOFT_17 and isSoft17(dealerHand) then
            dealerHand[#dealerHand+1] = dealCard(deck)
        else
            break
        end
    end
end

local function resolveRoundFinal(dealerHasBJ)
    local anyLive = false
    for i = 1, #playerHands do
        local pv = calculateHandValue(playerHands[i])
        if not handSurrendered[i] and pv <= 21 then
            anyLive = true
            break
        end
    end

    if anyLive and not dealerHasBJ then
        dealerPlay()
    end

    local dVal = dealerValue()
    local dealerBusted = (dVal > 21)
    local dealerStr = handToString(dealerHand)

    local netTotal = 0
    for i = 1, #playerHands do
        payoutForHand(i, dVal, dealerBusted, dealerHasBJ)
        netTotal = netTotal + (handNet[i] or 0)
    end

    local insNet = resolveInsurance(dealerHasBJ)
    if insNet ~= 0 then netTotal = netTotal + insNet end

    applyNetToBankroll(netTotal)

    local lines = buildRoundSummaryLines(netTotal, dVal, dealerStr)
    if insuranceTaken then
        lines[#lines+1] = ("Insurance: Bet %d | Net %s%d"):format(insuranceBet, insNet >= 0 and "+" or "", insNet)
    end
    recordLastRound(lines)

    tell(("Dealer: %s (%d)"):format(dealerStr, dVal))
    tell(("Round complete. Net %s%d. Bankroll now: %d"):format(netTotal >= 0 and "+" or "", netTotal, cfg.bankroll))

    if cfg.bankroll < BET_MIN then
        endRound(("Bankroll below %d. Type \at/blackjack reset\ax to restart at %d."):format(BET_MIN, DEFAULT_BANKROLL))
    else
        endRound("Adjust bet and Start again.")
    end
end

-- ============================================================
-- Dealer peek + insurance offering
-- ============================================================
local function dealerPeekNeeded()
    local up = dealerHand[1]
    if not up then return false end
    return isAce(up) or isTenValue(up)
end

local function dealerHasBlackjack()
    return isBlackjack(dealerHand)
end

local function maybeOfferInsurance()
    if not ALLOW_INSURANCE then return end
    if not dealerHand[1] then return end
    if isAce(dealerHand[1]) then
        insuranceOffered = true
        insuranceTaken = false
        insuranceBet = 0
        evenMoneyTaken = false
        tell("Dealer shows an Ace. Insurance is available.")
    end
end

local function takeInsurance(isEvenMoney)
    if not insuranceOffered or insuranceTaken then
        tell("Insurance is not available right now.")
        return
    end

    local baseBet = handBets[1] or 0
    local maxIns = roundDownToStep(math.floor(baseBet / 2), BET_STEP)
    if maxIns < BET_STEP then
        tell("Insurance not possible with this bet.")
        insuranceOffered = false
        return
    end

    if cfg.bankroll < maxIns then
        tell("Not enough bankroll to take insurance.")
        return
    end

    insuranceTaken = true
    insuranceBet = maxIns
    evenMoneyTaken = isEvenMoney == true
    insuranceOffered = false

    tell(("Insurance taken for %d."):format(insuranceBet))
end

local function declineInsurance()
    insuranceOffered = false
    insuranceTaken = false
    insuranceBet = 0
    evenMoneyTaken = false
end

-- ============================================================
-- Action availability checks
-- ============================================================
local function canHit()
    if not inRound then return false end
    if handDone[currentHandIndex] then return false end
    if handSurrendered[currentHandIndex] then return false end
    if handIsSplitAce[currentHandIndex] and SPLIT_ACES_ONE_CARD_ONLY then return false end
    return true
end

local function canStand()
    if not inRound then return false end
    if handDone[currentHandIndex] then return false end
    return true
end

local function canDouble()
    if not inRound or not ALLOW_DOUBLE then return false end
    if handDone[currentHandIndex] then return false end
    if not handFirstAction[currentHandIndex] then return false end
    local h = currentHand()
    if #h ~= 2 then return false end
    if #playerHands > 1 and not ALLOW_DOUBLE_AFTER_SPLIT then return false end
    local bet = handBets[currentHandIndex] or 0
    return cfg.bankroll >= bet
end

local function canSurrender()
    if not inRound or not ALLOW_SURRENDER then return false end
    if handDone[currentHandIndex] then return false end
    if not handFirstAction[currentHandIndex] then return false end
    local h = currentHand()
    if #h ~= 2 then return false end
    return true
end

local function canSplit()
    if not inRound or not ALLOW_SPLIT then return false end
    if #playerHands >= MAX_HANDS then return false end
    if handDone[currentHandIndex] then return false end
    if not handFirstAction[currentHandIndex] then return false end
    local h = currentHand()
    if #h ~= 2 then return false end

    local r1 = cardRank(h[1])
    local r2 = cardRank(h[2])
    if r1 ~= r2 then return false end

    local bet = handBets[currentHandIndex] or 0
    if cfg.bankroll < bet then return false end

    if r1 == "A" and not ALLOW_RESPLIT_ACES and #playerHands > 1 then
        return false
    end

    return true
end

-- ============================================================
-- Player actions
-- ============================================================
local function standCurrent()
    handDone[currentHandIndex] = true
    if allHandsDone() then
        resolveRoundFinal(false)
    else
        advanceToNextHand()
        tell(("Now playing hand %d/%d."):format(currentHandIndex, #playerHands))
    end
end

local function doStand()
    if not canStand() then return end
    handFirstAction[currentHandIndex] = false
    standCurrent()
end

local function doHit()
    if not canHit() then return end

    handFirstAction[currentHandIndex] = false
    local h = currentHand()
    h[#h+1] = dealCard(deck)
    local v = calculateHandValue(h)
    tell(("Hand %d: %s (%d)"):format(currentHandIndex, handToString(h), v))

    if v > 21 then
        tell(("\arBust (hand %d).\ax"):format(currentHandIndex))
        handDone[currentHandIndex] = true
        if allHandsDone() then
            resolveRoundFinal(false)
        else
            advanceToNextHand()
            tell(("Now playing hand %d/%d."):format(currentHandIndex, #playerHands))
        end
        return
    end

    if v == 21 then
        tell(("21 on hand %d. Auto-stand."):format(currentHandIndex))
        standCurrent()
    end
end

local function doDouble()
    if not canDouble() then
        tell("Double not allowed.")
        return
    end

    handFirstAction[currentHandIndex] = false
    handDoubled[currentHandIndex] = true
    handBets[currentHandIndex] = (handBets[currentHandIndex] or 0) * 2
    tell(("Hand %d doubled. New bet: %d"):format(currentHandIndex, handBets[currentHandIndex]))

    local h = currentHand()
    h[#h+1] = dealCard(deck)
    local v = calculateHandValue(h)
    tell(("Hand %d: %s (%d)"):format(currentHandIndex, handToString(h), v))

    handDone[currentHandIndex] = true
    if allHandsDone() then
        resolveRoundFinal(false)
    else
        advanceToNextHand()
        tell(("Now playing hand %d/%d."):format(currentHandIndex, #playerHands))
    end
end

local function doSurrender()
    if not canSurrender() then
        tell("Surrender not allowed.")
        return
    end

    handFirstAction[currentHandIndex] = false
    handSurrendered[currentHandIndex] = true
    handDone[currentHandIndex] = true
    tell(("Hand %d surrendered."):format(currentHandIndex))

    if allHandsDone() then
        resolveRoundFinal(false)
    else
        advanceToNextHand()
        tell(("Now playing hand %d/%d."):format(currentHandIndex, #playerHands))
    end
end

local function doSplit()
    if not canSplit() then
        tell("Split not allowed.")
        return
    end

    handFirstAction[currentHandIndex] = false

    local idx = currentHandIndex
    local h = playerHands[idx]
    local bet = handBets[idx]

    local c2 = table.remove(h, 2)
    local newHand = { c2 }

    table.insert(playerHands, idx + 1, newHand)
    table.insert(handBets, idx + 1, bet)
    table.insert(handDone, idx + 1, false)
    table.insert(handDoubled, idx + 1, false)
    table.insert(handSurrendered, idx + 1, false)
    table.insert(handIsSplitAce, idx + 1, false)
    table.insert(handResult, idx + 1, nil)
    table.insert(handNet, idx + 1, nil)
    table.insert(handFirstAction, idx + 1, true)

    handFirstAction[idx] = true

    h[#h+1] = dealCard(deck)
    newHand[#newHand+1] = dealCard(deck)

    local r = cardRank(h[1])
    if r == "A" then
        handIsSplitAce[idx] = true
        handIsSplitAce[idx + 1] = true
    end

    tell("Split!")
    tell(("Hand %d: %s (%d) | Bet %d"):format(idx, handToString(h), calculateHandValue(h), handBets[idx]))
    tell(("Hand %d: %s (%d) | Bet %d"):format(idx+1, handToString(newHand), calculateHandValue(newHand), handBets[idx+1]))

    if r == "A" and SPLIT_ACES_ONE_CARD_ONLY then
        handDone[idx] = true
        handDone[idx + 1] = true
        tell("Split Aces: one card only. Standing both hands.")
        if allHandsDone() then
            resolveRoundFinal(false)
        else
            advanceToNextHand()
        end
        return
    end

    currentHandIndex = idx
end

-- ============================================================
-- Round start / Dealer peek
-- ============================================================
local function startGame()
    if inRound then
        tell("Already in a round.")
        return
    end

    if cfg.bankroll < BET_MIN then
        tell(("Bankroll is below the minimum bet (%d). Type \at/blackjack reset\ax to restart at %d."):format(BET_MIN, DEFAULT_BANKROLL))
        return
    end

    local bet = clampBet(currentBet)
    if bet < BET_MIN then
        tell(("Set a bet (min %d)."):format(BET_MIN))
        return
    end
    currentBet = bet

    deck = createDeck()
    dealerHand = {}

    playerHands = { {} }
    handBets = { currentBet }
    handDone = { false }
    handDoubled = { false }
    handSurrendered = { false }
    handIsSplitAce = { false }
    handResult = { nil }
    handNet = { nil }
    handFirstAction = { true }

    currentHandIndex = 1

    insuranceOffered = false
    insuranceTaken = false
    insuranceBet = 0
    evenMoneyTaken = false

    inRound = true

    local h = playerHands[1]
    h[#h+1] = dealCard(deck)
    dealerHand[#dealerHand+1] = dealCard(deck)
    h[#h+1] = dealCard(deck)
    dealerHand[#dealerHand+1] = dealCard(deck)

    tell(("New round. Bet: %d | Bankroll: %d"):format(currentBet, cfg.bankroll))
    tell(("Your hand: %s (%d)"):format(handToString(h), calculateHandValue(h)))
    tell(("Dealer shows: %s"):format(dealerHand[1]))

    maybeOfferInsurance()

    if dealerPeekNeeded() then
        if dealerHasBlackjack() then
            tell("Dealer peeks... BLACKJACK!")
            resolveRoundFinal(true)
            return
        else
            tell("Dealer peeks... no blackjack.")
        end
    end

    if isBlackjack(playerHands[1]) then
        if insuranceOffered and isAce(dealerHand[1]) then
            tell("You have Blackjack. Dealer shows Ace: You may take Even Money (Insurance) or play it out.")
        else
            resolveRoundFinal(false)
        end
    end
end

-- ============================================================
-- Help / Commands
-- ============================================================
local function showHelp()
    tell("Commands:")
    tell("  /blackjack start")
    tell("  /blackjack bet <amount>   (min 100, max 10000, step 100)")
    tell("  /blackjack hit | stand")
    tell("  /blackjack double")
    tell("  /blackjack split")
    tell("  /blackjack surrender")
    tell("  /blackjack insurance | noinsurance | evenmoney")
    tell("  /blackjack status")
    tell("  /blackjack gui")
    tell("  /blackjack reset")
    tell("  /blackjack quit")
end

local function showStatus()
    tell(("Bankroll: %d | Next Bet: %d | Min: %d | Max: %d | Step: %d"):format(cfg.bankroll, currentBet, BET_MIN, cfg.maxBet, BET_STEP))
    if inRound then
        tell(("Dealer shows: %s"):format(dealerHand[1] or "?"))
        tell(("Current hand %d/%d: %s (%d) | Bet %d"):format(
            currentHandIndex, #playerHands,
            handToString(currentHand()), currentValue(),
            handBets[currentHandIndex] or 0
        ))
        if insuranceOffered then
            tell("Insurance offered: /blackjack insurance | /blackjack noinsurance | /blackjack evenmoney")
        end
    end
end

mq.bind('/blackjack', function(...)
    local args = {...}
    local cmd = (args[1] or ""):lower()

    if cmd == "" or cmd == "help" then
        showHelp()
        return
    end

    if cmd == "start" then
        startGame()
        return
    end

    if cmd == "bet" then
        setBet(args[2])
        return
    end

    if cmd == "gui" then
        showGUI = not showGUI
        tell("GUI " .. (showGUI and "shown." or "hidden."))
        return
    end

    if cmd == "reset" then
        resetBankroll()
        return
    end

    if cmd == "quit" then
        tell("Stopping blackjack script.")
        running = false
        return
    end

    if cmd == "status" then
        showStatus()
        return
    end

    -- Insurance decisions
    if cmd == "insurance" then
        takeInsurance(false)
        return
    elseif cmd == "evenmoney" then
        takeInsurance(true)
        return
    elseif cmd == "noinsurance" then
        declineInsurance()
        return
    end

    -- Acting declines insurance automatically
    if insuranceOffered then
        declineInsurance()
    end

    if cmd == "hit" then
        doHit()
    elseif cmd == "stand" then
        doStand()
    elseif cmd == "double" then
        doDouble()
    elseif cmd == "split" then
        doSplit()
    elseif cmd == "surrender" then
        doSurrender()
    else
        tell("Unknown command. Use /blackjack help")
    end
end)

-- ============================================================
-- GUI
-- ============================================================
local function drawGUI()
    if not showGUI then return end

    local began = false
    local ok, err = pcall(function()
        local open = true
        open, showGUI = ImGui.Begin(guiTitle, open, ImGuiWindowFlags.AlwaysAutoResize)
        began = true
        if not showGUI then return end

        ImGui.Text(("Character: %s"):format(charName))
        ImGui.Text(("Bankroll: %d"):format(cfg.bankroll))
        ImGui.Text(("Bet: min %d | max %d | step %d"):format(BET_MIN, cfg.maxBet, BET_STEP))
        ImGui.Separator()

        -- Bet controls: [-] [slider] [+] + Set/All-In
        ImGui.Text('Bet:')
        ImGui.SameLine()

        local betMin = BET_MIN
        local betMax = cfg.maxBet
        if cfg.bankroll < betMax then betMax = cfg.bankroll end
        betMax = roundDownToStep(betMax, BET_STEP)

        local canBet = (betMax >= betMin)

        currentBet = roundDownToStep(currentBet, BET_STEP)
        if currentBet < betMin then currentBet = betMin end
        if currentBet > betMax then currentBet = betMax end

        ImGui.BeginDisabled(not canBet)

        if ImGui.Button("-##betminus") then
            currentBet = currentBet - BET_STEP
            if currentBet < betMin then currentBet = betMin end
        end

        ImGui.SameLine()
        ImGui.PushItemWidth(180)
        if canBet then
            currentBet, _ = ImGui.SliderInt('##SliderInt_Bet', currentBet, betMin, betMax, "%d")
            currentBet = roundDownToStep(currentBet, BET_STEP)
        else
            local tmp = betMin
            tmp, _ = ImGui.SliderInt('##SliderInt_Bet', tmp, betMin, betMin, "%d")
            currentBet = betMin
        end
        ImGui.PopItemWidth()
        ImGui.SameLine()

        if ImGui.Button("+##betplus") then
            currentBet = currentBet + BET_STEP
            if currentBet > betMax then currentBet = betMax end
        end

        ImGui.SameLine()
        if ImGui.Button("Set Bet") then
            setBet(currentBet)
        end

        ImGui.SameLine()
        if ImGui.Button("All-In") then
            setBet(roundDownToStep(math.min(cfg.bankroll, cfg.maxBet), BET_STEP))
        end

        ImGui.EndDisabled()

        if not canBet then
            ImGui.Separator()
            ImGui.Text(("Not enough bankroll for minimum bet (%d)."):format(BET_MIN))
            ImGui.Text(("Reset to %d?"):format(DEFAULT_BANKROLL))
            if ImGui.Button("Reset Bankroll##resetbankroll") then
                resetBankroll()
            end
        end

        -- Last round results ALWAYS visible (height reduced by ~20% from prior 120 -> 96)
        ImGui.Separator()
        ImGui.Text("Last Round Results:")
        local resultsHeight = 96
        ImGui.BeginChild("##LastRoundResults", 0, resultsHeight, true)
        if lastRound.exists and lastRound.summaryLines and #lastRound.summaryLines > 0 then
            for _, line in ipairs(lastRound.summaryLines) do
            -- Green for wins / positive net
            if line:find("Net %+")
                or line:find("blackjack")
                or line:find("| win")
            then
                ImGui.PushStyleColor(ImGuiCol.Text, 0.2, 1.0, 0.2, 1.0)
                ImGui.Text(line)
                ImGui.PopStyleColor()

            -- Red for losses
            elseif line:find("Net %-")
                or line:find("| lose")
                or line:find("bust")
                or line:find("surrender")
            then
                ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.25, 0.25, 1.0)
                ImGui.Text(line)
                ImGui.PopStyleColor()

            -- Normal color for push / neutral lines
            else
                ImGui.Text(line)
            end
        end
        else
            ImGui.Text("No rounds played yet.")
        end
        ImGui.EndChild()
        ImGui.Separator()
        ImGui.Text(inRound and "Status: In Round" or "Status: Idle")
        ImGui.Separator()

        if inRound then
            ImGui.Text(("Dealer shows: %s"):format(dealerHand[1] or "?"))
            ImGui.Separator()

            for i = 1, #playerHands do
                local h = playerHands[i]
                local v = calculateHandValue(h)
                local bet = handBets[i] or 0
                local label = (i == currentHandIndex) and ">>" or "  "
                local flags = ""
                if handSurrendered[i] then flags = flags .. " SURRENDER" end
                if handDoubled[i] then flags = flags .. " DOUBLE" end
                if handIsSplitAce[i] then flags = flags .. " SPLIT-ACE" end
                ImGui.Text(("%s Your Hand %d: %s (%d) | Bet: %d%s"):format(label, i, handToString(h), v, bet, flags))
            end

            if insuranceOffered then
                ImGui.Separator()
                ImGui.Text("Insurance offered (dealer shows Ace).")
                if ImGui.Button("Take Insurance") then takeInsurance(false) end
                ImGui.SameLine()
                if ImGui.Button("No Insurance") then declineInsurance() end
                ImGui.SameLine()
                local emDisabled = not isBlackjack(playerHands[1])
                ImGui.BeginDisabled(emDisabled)
                if ImGui.Button("Even Money") then takeInsurance(true) end
                ImGui.EndDisabled()
            end
        end

        ImGui.Separator()

        ImGui.BeginDisabled((not canBet) and (not inRound))
        if ImGui.Button("Start") then startGame() end
        ImGui.EndDisabled()

        ImGui.SameLine()

        ImGui.BeginDisabled(not inRound or insuranceOffered)

        ImGui.BeginDisabled(not canHit())
        if ImGui.Button("Hit") then doHit() end
        ImGui.EndDisabled()

        ImGui.SameLine()
        ImGui.BeginDisabled(not canStand())
        if ImGui.Button("Stand") then doStand() end
        ImGui.EndDisabled()

        ImGui.SameLine()
        ImGui.BeginDisabled(not canDouble())
        if ImGui.Button("Double") then doDouble() end
        ImGui.EndDisabled()

        ImGui.SameLine()
        ImGui.BeginDisabled(not canSplit())
        if ImGui.Button("Split") then doSplit() end
        ImGui.EndDisabled()

        ImGui.SameLine()
        ImGui.BeginDisabled(not canSurrender())
        if ImGui.Button("Surrender") then doSurrender() end
        ImGui.EndDisabled()

        ImGui.EndDisabled()

        ImGui.SameLine()
        if ImGui.Button("Quit") then running = false end

        ImGui.Separator()
        ImGui.Text(("Config: %s"):format(normalize_path(CONFIG_PATH)))
    end)

    if began then ImGui.End() end
    if not ok then tell(("GUI error: %s"):format(tostring(err))) end
end

mq.imgui.init(guiTitle, drawGUI)

-- ============================================================
-- Startup loop
-- ============================================================
math.randomseed(os.time())
tell(("Loaded. Bankroll: %d, Max Bet: %d, Min Bet: %d, Step: %d"):format(cfg.bankroll, cfg.maxBet, BET_MIN, BET_STEP))
tell(("Config: %s"):format(normalize_path(CONFIG_PATH)))
tell("Use /blackjack start (or GUI). /blackjack help for commands.")

while running do
    mq.delay(50)
end