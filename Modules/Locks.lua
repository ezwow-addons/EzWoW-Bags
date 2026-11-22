local _, ns = ...
-- Locked items (by item ID) are never sold to vendors, moved by bulk actions or put up for auction
-- by this addon. Locks are kept per character; an account-wide list applies to every character.
local L = {}; ns.Locks = L
local ACCOUNT = "*"
local function lists()
    if not ns.db then return nil end
    if type(ns.db.locks) ~= "table" then ns.db.locks = {} end
    return ns.db.locks
end
local function list(key, create)
    local all = lists()
    if not all then return nil end
    local t = all[key]
    if type(t) ~= "table" then
        if not create then return nil end
        t = {}; all[key] = t
    end
    return t
end
-- Returns "char", "account" or nil.
function L.Kind(id, charKey)
    id = tonumber(id)
    if not id or not ns.cfg or not ns.cfg.itemLock then return nil end
    local own = list(charKey or ns.player, false)
    if own and own[id] then return "char" end
    local account = list(ACCOUNT, false)
    if account and account[id] then return "account" end
    return nil
end
function L.IsLocked(id, charKey) return L.Kind(id, charKey) ~= nil end
-- accountWide: toggles the account-wide lock instead of this character's.
function L.Toggle(id, accountWide)
    id = tonumber(id)
    if not id or not ns.cfg.itemLock then return end
    local t = list(accountWide and ACCOUNT or ns.player, true)
    if t[id] then t[id] = nil else t[id] = true end
    -- A character lock and an account lock of the same item: unlocking removes both.
    if not t[id] then
        local other = list(accountWide and ns.player or ACCOUNT, false)
        if other then other[id] = nil end
    end
    local name = ns.API.Info(id) or ("#" .. id)
    local key = t[id] and (accountWide and "lockAccountOn" or "lockOn") or "lockOff"
    ns.Print(string.format(ns.Text(key), name))
    ns.viewDirty = true
end
function L.ClearAll()
    local all = lists()
    if not all then return end
    all[ns.player], all[ACCOUNT] = nil, nil
    ns.viewDirty = true
end
function L.Count()
    local n = 0
    for _, key in ipairs({ ns.player, ACCOUNT }) do
        for _ in pairs(list(key, false) or {}) do n = n + 1 end
    end
    return n
end

-----------------------------------------------------------------------------
-- A locked item sold to a merchant anyway (a right-click or a drop on the
-- merchant by mistake, or another addon's junk selling) is bought straight
-- back. The game's own click cannot be stopped without breaking it, so the
-- sale is undone instead (2026-11-22). New rows of the merchant's buyback list
-- are found by comparing it with the last look; one row is bought back at a
-- time (the list changes and this runs again). A row that is still there right
-- after its buyback (it did not go through) is left alone, so it cannot loop.
-----------------------------------------------------------------------------
local RETRY_AFTER = 3          -- seconds a buyback may take before its row still being there counts as failed
local atMerchant, seen, scheduled = false, nil, false
local pending                  -- the buyback on its way: { link, at }
local schedule

local function callSafe(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a = pcall(fn, ...)
    if ok then return a end
    return nil
end
local function idOfLink(link)
    if type(link) ~= "string" or (type(issecretvalue) == "function" and issecretvalue(link)) then return nil end
    return tonumber(link:match("item:(%d+)"))
end
local function buybackRows()
    local rows = {}
    local n = tonumber(callSafe(GetNumBuybackItems)) or 0
    for i = 1, math.min(n, 50) do
        local link = callSafe(GetBuybackItemLink, i)
        rows[i] = type(link) == "string" and link or false
    end
    return rows
end
local function without(rows, index)
    local out = {}
    for j, link in ipairs(rows) do if j ~= index then out[#out + 1] = link end end
    return out
end
-- indexes of the rows in `rows` that were not in `before` (the same link may be there more than once)
function L.NewBuybackRows(before, rows)
    local left = {}
    for _, link in ipairs(before or {}) do
        if link then left[link] = (left[link] or 0) + 1 end
    end
    local new = {}
    for i, link in ipairs(rows or {}) do
        if link then
            if (left[link] or 0) > 0 then left[link] = left[link] - 1 else new[#new + 1] = i end
        end
    end
    return new
end
local function bagsHaveRoom()
    local getFree = C_Container and C_Container.GetContainerNumFreeSlots or _G.GetContainerNumFreeSlots
    if type(getFree) ~= "function" then return true end
    for bag = 0, (NUM_BAG_SLOTS or 4) + 1 do
        local free = callSafe(getFree, bag)
        if type(free) == "number" and free > 0 then return true end
    end
    return false
end

function L.CheckBuyback()
    if not atMerchant or type(BuybackItem) ~= "function" then return end
    local rows = buybackRows()
    if not seen then seen = rows; return end
    local new = L.NewBuybackRows(seen, rows)
    seen = rows
    local now = GetTime and GetTime() or 0
    if pending then
        local again
        for k = #new, 1, -1 do
            if rows[new[k]] == pending.link then again = k; break end
        end
        if not again then
            pending = nil                                  -- it went through
        elseif now - pending.at < RETRY_AFTER then
            -- not through yet (the bags may change first): keep expecting the row to go, look again later
            seen = without(rows, new[again])
            if C_Timer and C_Timer.After then C_Timer.After(RETRY_AFTER, function() schedule() end) end
            return
        else
            ns.Print(string.format(ns.Text("lockBuybackFailed"), pending.link))
            pending = nil
            table.remove(new, again)                       -- left in the list; not tried again
        end
    end
    -- newest first (the list keeps the latest sale last); one at a time
    for k = #new, 1, -1 do
        local i = new[k]
        local link = rows[i]
        local id = idOfLink(link)
        if id and L.IsLocked(id) then
            if not bagsHaveRoom() then
                ns.Print(string.format(ns.Text("lockBuybackFailed"), link))
            elseif pcall(BuybackItem, i) then
                pending = { link = link, at = now }
                seen = without(rows, i)                    -- expected next look
                ns.Print(string.format(ns.Text("lockBoughtBack"), link))
                return
            end
        end
    end
end

schedule = function()
    if scheduled or not atMerchant then return end
    scheduled = true
    local function run() scheduled = false; L.CheckBuyback() end
    if C_Timer and C_Timer.After then C_Timer.After(0.1, run) else run() end
end

local watch = CreateFrame("Frame")
for _, event in ipairs({ "MERCHANT_SHOW", "MERCHANT_CLOSED", "MERCHANT_UPDATE", "BAG_UPDATE_DELAYED" }) do
    pcall(watch.RegisterEvent, watch, event)
end
watch:SetScript("OnEvent", function(_, event)
    if event == "MERCHANT_SHOW" then
        atMerchant = true
        seen, pending = nil, nil
        L.CheckBuyback()           -- the first look: what was sold before this visit stays as it is
    elseif event == "MERCHANT_CLOSED" then
        atMerchant, seen, pending = false, nil, nil
    else
        schedule()
    end
end)
