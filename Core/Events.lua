local _, ns = ...
-- every EzWoW line on the game's tooltips can be turned off at once (Game Menu >
-- Options > AddOns > EzWoW - Data Sharing; Libs/EzWoWShare TooltipLinesOn)
local function ezTipsOn()
    local share = _G.EzWoW_Share
    if type(share) ~= "table" or type(share.TooltipLinesOn) ~= "function" then return true end
    local ok, on = pcall(share.TooltipLinesOn)
    return not ok or on ~= false
end
local frame = CreateFrame("Frame")
local events = { "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_LOGOUT", "BAG_UPDATE_DELAYED", "BAG_UPDATE", "ITEM_LOCK_CHANGED",
    "GET_ITEM_INFO_RECEIVED", "ITEM_DATA_LOAD_RESULT", "PLAYER_MONEY", "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "PLAYERBANKSLOTS_CHANGED", "BAG_CONTAINER_UPDATE", "BANK_TABS_CHANGED",
    "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "AUCTION_ITEM_LIST_UPDATE", "REPLICATE_ITEM_LIST_UPDATE",
    "MERCHANT_SHOW", "MERCHANT_CLOSED", "MAIL_SHOW", "MAIL_CLOSED", "TRADE_SHOW", "TRADE_CLOSED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_EQUIPMENT_CHANGED", "BAG_UPDATE_COOLDOWN",
    "QUEST_ACCEPTED", "QUEST_REMOVED" }
for _, event in ipairs(events) do pcall(frame.RegisterEvent, frame, event) end
-- Default bag replacement. The Blizzard bag functions are never replaced (other default UI code
-- calls them); they are post-hooked, and the default bag frames are kept out of sight (below).
-- Post-hooks of nested calls run before the outer one, so the hooks only record what happened and
-- the last (outermost) call of the same frame decides once on the next update: B, Shift+B and
-- the bag buttons toggle this window exactly once even when the default code opens bags internally.
local bagHook = { pending = nil, openedBy = nil }
local function padUI() return ns.GamePad ~= nil and ns.GamePad.IsActive ~= nil and ns.GamePad.IsActive() == true end
local function inCombat() return InCombatLockdown and InCombatLockdown() end
local function locked(f) return inCombat() and type(f.IsProtected) == "function" and f:IsProtected() end
local function frameToken(f)
    if type(f) ~= "table" then return nil end
    local name = type(f.GetName) == "function" and f:GetName()
    return name or f
end
-- The default bag windows are never shown or hidden from addon code (2026-11-28): the game's bag code then
-- runs as addon code and leaves its bag state tainted; opening the bank later reads that state
-- (BankFrame:OnShow -> OpenAllBags) and the bank type it then writes stays tainted, so every item used from
-- a bag after that is blocked ("[ADDON_ACTION_FORBIDDEN] EzWoW-Bags: UNKNOWN()", taint log: field bankType)
-- until the interface is reloaded. Instead, while closed, they are moved under a hidden frame: the game opens
-- and closes them as usual but out of sight, and this window opens in their place through the hooks below.
-- They are moved only while closed (moved while open they would show or hide). The gamepad UI's navigation
-- needs the same (Libs/EzWoWGamePad: shown or hidden from addon code it stays broken until a reload).
local parking = CreateFrame("Frame"); parking:Hide()
local parkedFrom = {}
local function combinedBags()
    local f = _G.ContainerFrameCombinedBags
    return type(f) == "table" and type(f.SetParent) == "function" and f or nil
end
local function blizzardBagFrames()
    local list = {}
    local combined = combinedBags()
    if combined then list[#list + 1] = combined end
    for i = 1, math.max(tonumber(NUM_CONTAINER_FRAMES) or 0, 13) do
        local f = _G["ContainerFrame" .. i]
        if type(f) == "table" and type(f.SetParent) == "function" then list[#list + 1] = f end
    end
    return list
end
local function isParked(f) return f:GetParent() == parking end
local function parked()
    local f = combinedBags()
    return f ~= nil and isParked(f)
end
local function setParent(f, parent)
    local keep = FrameUtil and FrameUtil.SetParentMaintainRenderLayering
    if type(keep) == "function" then pcall(keep, f, parent) else pcall(f.SetParent, f, parent) end
end
local function unpark(f)
    setParent(f, parkedFrom[f] or UIParent)
    parkedFrom[f] = nil
end
function ns.SyncBagParking()
    local want = ns.cfg.replace and ns.window
    for _, f in ipairs(blizzardBagFrames()) do
        if not locked(f) and not f:IsShown() then
            if want and not isParked(f) then
                parkedFrom[f] = f:GetParent()
                setParent(f, parking)
            elseif not want and isParked(f) then
                unpark(f)
            end
        end
    end
end
-- Closing this window: the items seen are no longer new (as when the default window closes). The default
-- bags the game opened out of sight stay open there; the game's next bag command closes them, and the hooks
-- open this window for it (a toggle follows this window, not the default bags).
local function clearNewItems()
    local items, getSlots = C_NewItems, C_Container and C_Container.GetContainerNumSlots
    if not (items and type(items.RemoveNewItem) == "function" and type(getSlots) == "function") then return end
    for bag = 0, math.max(tonumber(NUM_TOTAL_BAG_FRAMES) or 4, 4) do
        local ok, slots = pcall(getSlots, bag)
        for slot = 1, ok and tonumber(slots) or 0 do pcall(items.RemoveNewItem, bag, slot) end
    end
end
-- the default bags are on screen (gamepad UI, not moved away yet): they are left to the game
local function padLeavesBags() return padUI() and not parked() end
-- the gamepad moves in the EzWoW windows (Libs/EzWoWGamePad), not in a game window
local function padOnWindow()
    local pad = ns.GamePad
    local nav = pad and pad.nav
    if type(nav) ~= "table" or type(nav.IsGamePadButtonEnabled) ~= "function" then return false end
    local ok, on = pcall(nav.IsGamePadButtonEnabled, nav)
    return (ok and on == true) or pad.boundSecure == true
end
local function resolveBagHook(self)
    self:SetScript("OnUpdate", nil)
    local p = bagHook.pending; bagHook.pending = nil
    local w = ns.window
    -- ns.Show/ns.Hide wait for the end of combat when the window is protected.
    if not p or not ns.cfg.replace or not w or padLeavesBags() then return end
    if p.kind == "toggle" then
        bagHook.openedBy = nil
        -- Gamepad: the gamepad's bag command (p.takePad; not the character screen opening its bags)
        -- gives this window the gamepad even from a game window that holds it (bank, vendor...), as
        -- the default bags take it. Already open there, the command moves the gamepad here instead
        -- of closing it (then B closes it).
        local takePad = p.takePad and padUI() and not inCombat() and ns.GamePad.EnterHUD
        if p.wasShown and takePad and w:IsShown() and not padOnWindow() then
            pcall(ns.GamePad.EnterHUD, false)
            return
        end
        if p.wasShown then ns.Hide() else
            ns.Show("bags")
            if takePad and w:IsShown() and not padOnWindow() then pcall(ns.GamePad.EnterHUD, false) end
        end
    elseif p.kind == "open" then
        -- Same rule as the default UI: only an opener that found the bags closed may close them again.
        if not w:IsShown() then bagHook.openedBy = p.source; ns.Show("bags") end
    elseif p.kind == "close" then
        local owner = bagHook.openedBy
        if p.source and owner ~= true and owner ~= p.source then return end
        bagHook.openedBy = nil
        ns.Hide()
    end
end
local resolver = CreateFrame("Frame")
local function noteBagCall(kind, source, takePad)
    if not ns.cfg.replace or not ns.window or padLeavesBags() then return end
    local p = bagHook.pending
    if not p then
        p = { wasShown = ns.window:IsShown() }; bagHook.pending = p
        resolver:SetScript("OnUpdate", resolveBagHook)
    end
    p.kind, p.source, p.takePad = kind, source, takePad
end
-- Player bags 0-4 and the reagent bag. On the old bank layout bag 5 is a bank bag, so it is left alone there.
local function playerBag(id)
    if type(id) ~= "number" then return false end
    if id >= 0 and id <= 4 then return true end
    return id == ns.API.ReagentBag() and ns.API.ModernBank() and true or false
end
-- Called at login, when the option changes and after combat.
function ns.ApplyBagReplacement()
    ns.SyncBagParking()
    if not ns.cfg.replace then
        bagHook.pending, bagHook.openedBy = nil, nil; resolver:SetScript("OnUpdate", nil)
    end
end
local function replaceBags()
    local function hook(name, handler)
        if type(_G[name]) == "function" then pcall(hooksecurefunc, name, handler) end
    end
    hook("ToggleBag", function(id) if playerBag(id) then noteBagCall("toggle") end end)
    hook("ToggleBackpack", function() noteBagCall("toggle") end)
    -- (true: the gamepad's bag commands; the gamepad character screen opens its bags with
    -- ToggleBackpack, which wraps the call below and so decides last)
    hook("ToggleAllBags", function() noteBagCall("toggle", nil, true) end)
    -- (the gamepad UI's Bags entry of the Start menu calls this one directly)
    hook("ToggleBackpack_Combined", function() noteBagCall("toggle", nil, true) end)
    hook("OpenBackpack", function(f) noteBagCall("open", frameToken(f)) end)
    hook("OpenAllBags", function(f) noteBagCall("open", frameToken(f)) end)
    hook("CloseBackpack", function(f) noteBagCall("close", frameToken(f)) end)
    hook("CloseAllBags", function(f) noteBagCall("close", frameToken(f)) end)
    -- a full-screen game frame takes the default bags in (a new parent): moved away again while closed
    hook("ContainerFrame_SetFullScreenFrame", function() ns.SyncBagParking() end)
    hook("ContainerFrame_ClearFullScreenFrame", function() ns.SyncBagParking() end)
    if ns.window then pcall(ns.window.HookScript, ns.window, "OnHide", clearNewItems) end
    -- The game also closes its bags by hiding the window itself (closing the gamepad character
    -- screen does): while moved away, that closes this window too, as it would the default bags.
    -- Only when it was open (the game hides it while closed too); inside a toggle or a close
    -- call that call decides instead (the outermost call wins, see resolveBagHook).
    local bags = combinedBags()
    if bags then
        pcall(hooksecurefunc, bags, "Show", function() if parked() then bagHook.parkedOpen = true end end)
        pcall(hooksecurefunc, bags, "Hide", function()
            local was = bagHook.parkedOpen; bagHook.parkedOpen = nil
            if was and parked() then noteBagCall("close") end
        end)
    end
    ns.ApplyBagReplacement()
end
local function tooltips()
    GameTooltip:HookScript("OnTooltipCleared", function(tip) ns.ClearTooltipItem(tip) end)
    local function secret(value) return issecretvalue and issecretvalue(value) end
    local function append(tip, data)
        if not ezTipsOn() then return end
        -- Mainline passes tooltip data; tip:GetItem() may be missing on this client.
        local id = type(data) == "table" and not secret(data.id) and tonumber(data.id) or nil
        if not id and type(tip.GetItem) == "function" then
            local ok, _, link = pcall(tip.GetItem, tip)
            if ok and type(link) == "string" and not secret(link) then id = tonumber(link:match("item:(%d+)")) end
        end
        if id then ns.AddTooltipInfo(tip, id) end
    end
    if TooltipDataProcessor and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tip, data) if tip == GameTooltip then append(tip, data) end end)
    else pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetItem", append) end
end
local function init()
    ns.InitDB()
    ns.History.Init()
    ns.Auction.SyncPrices()
    ns.ScanStorage("bags")
    ns.CreateWindow()
    if ns.cfg.position and #ns.cfg.position == 4 then
        local p = ns.cfg.position
        ns.window:ClearAllPoints(); ns.window:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    elseif ns.cfg.growUp then
        ns.window:ClearAllPoints(); ns.window:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -40, 100)
    end
    replaceBags(); tooltips(); ns.Auction.InstallHook()
    SLASH_EZWOWBAGS1, SLASH_EZWOWBAGS2 = "/ezbags", "/ezb"
    SlashCmdList.EZWOWBAGS = function(text)
        text = (text or ""):lower():match("^%s*(.-)%s*$")
        if text == "settings" then ns.ToggleOptions()
        elseif text == "bank" then ns.Show("bank")
        elseif text == "scan" then ns.Auction.Start("full")
        elseif text == "debug" then
            local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
            local ok, version = false, nil
            if type(getMeta) == "function" then ok, version = pcall(getMeta, ns.name, "Version") end
            ns.Print((ok and version or "?") .. " · bank=" .. (ns.API.ModernBank() and "tabs" or "legacy") .. " · keyring=" .. ns.API.Keyring()
                .. " · legacyAH=" .. tostring(type(QueryAuctionItems) == "function")
                .. " · replicate=" .. tostring(C_AuctionHouse and type(C_AuctionHouse.ReplicateItems) == "function" or false)
                .. " · nativeRows=" .. ns.Auction.NativeCount())
            ns.Print(ns.Auction.status or "—")
            local job = ns.Auction.job
            if job then ns.Print("waiting=" .. tostring(job.waiting) .. " · reading=" .. tostring(job.reading) .. " · index=" .. tostring(job.index) .. "/" .. tostring(job.count) .. " · retries=" .. tostring(job.retryPass)) end
        else ns.Toggle() end
    end
    ns.ready = true
    ns.WarmSecureSlots("bags")
end
frame:SetScript("OnEvent", function(_, event, arg, success)
    if event == "PLAYER_LOGIN" then init(); return end
    if not ns.ready then return end
    if event == "BAG_UPDATE_DELAYED" or event == "BAG_UPDATE" or event == "ITEM_LOCK_CHANGED"
        or event == "PLAYERBANKSLOTS_CHANGED" or event == "BAG_CONTAINER_UPDATE" or event == "BANK_TABS_CHANGED" or event == "PLAYER_EQUIPMENT_CHANGED"
        or event == "QUEST_ACCEPTED" or event == "QUEST_REMOVED" then
        ns.Dirty()
        -- A new or bigger bag (or bank tab) needs more item buttons; built out of combat.
        if event == "BAG_CONTAINER_UPDATE" or event == "BANK_TABS_CHANGED" then
            ns.WarmSecureSlots("bags"); ns.WarmSecureSlots("bank")
        end
    elseif event == "BAG_UPDATE_COOLDOWN" then ns.viewDirty = true
    elseif event == "GET_ITEM_INFO_RECEIVED" or event == "ITEM_DATA_LOAD_RESULT" then
        -- (C_Item.RequestLoadItemDataByID answers only with ITEM_DATA_LOAD_RESULT on this client, 2026-11-22)
        if success ~= false then
            ns.PriceCatalog.MetadataReady(arg)
            if ns.waitingInventory[arg] then ns.waitingInventory[arg] = nil; ns.Dirty() end
            if ns.visiblePriceWaiting and ns.visiblePriceWaiting[arg] then ns.visiblePriceWaiting[arg] = nil; ns.viewDirty = true end
        end
    elseif event == "PLAYER_MONEY" then
        local char = ns.db.characters[ns.player]; if char then char.money = GetMoney() end; ns.Refresh(true)
    elseif event == "BANKFRAME_OPENED" then
        local wasShown = ns.window:IsShown()
        -- the window stays on the tab it shows (bags, bank or prices); the bank tab is
        -- one click away. Opened by the bank itself, it starts on the tab used last.
        ns.state.bank = true; ns.ScanStorage("bank"); ns.WarmSecureSlots("bank")
        if wasShown then ns.Refresh() else ns.Show() end
        -- Opened for the bank: closing the bank (with any frame argument) closes it again.
        if ns.cfg.replace and not wasShown then bagHook.openedBy = true end
    elseif event == "BANKFRAME_CLOSED" then
        -- Never rescan now: bank APIs may already return zero slots after the close event.
        ns.state.bank = false; ns.moveQueue = nil; ns.Refresh()
    elseif event == "AUCTION_HOUSE_SHOW" then ns.state.auction = true; ns.Refresh()
    elseif event == "AUCTION_HOUSE_CLOSED" then ns.state.auction = false; ns.Auction.replicaReady = nil; ns.Auction.Stop()
    elseif event == "AUCTION_ITEM_LIST_UPDATE" then ns.Auction.Results(false)
    elseif event == "REPLICATE_ITEM_LIST_UPDATE" then ns.Auction.Results(true)
    elseif event == "PLAYER_REGEN_DISABLED" then ns.moveQueue = nil; ns.Refresh()
    elseif event == "PLAYER_REGEN_ENABLED" then
        ns.AfterCombat()
        ns.WarmSecureSlots("bags"); ns.WarmSecureSlots("bank")
    elseif event == "PLAYER_LOGOUT" then ns.ScanStorage("bags"); if ns.state.bank then ns.ScanStorage("bank") end
    elseif event == "MERCHANT_SHOW" then ns.state.merchant = true; ns.Merchant.OnShow()
    elseif event == "MERCHANT_CLOSED" then ns.state.merchant = false; ns.Merchant.OnClosed(); ns.moveQueue = nil; ns.Refresh()
    elseif event == "MAIL_SHOW" then ns.state.mail = true
    elseif event == "MAIL_CLOSED" then ns.state.mail = false; ns.moveQueue = nil; ns.Refresh()
    elseif event == "TRADE_SHOW" then ns.state.trade = true
    elseif event == "TRADE_CLOSED" then ns.state.trade = false; ns.moveQueue = nil; ns.Refresh() end
end)
local elapsed, scanElapsed, shareElapsed = 0, 0, 0
frame:SetScript("OnUpdate", function(_, dt)
    if not ns.ready then return end
    elapsed, scanElapsed, shareElapsed = elapsed + dt, scanElapsed + dt, shareElapsed + dt
    -- an item on the cursor (a drag): the bag change after it is put down is laid out in full
    if ns.NoHoldFor and ns.API.CursorBusy() then ns.NoHoldFor(1) end
    ns.PriceCatalog.Tick()
    ns.History.Tick()
    if ns.priceScrollDirty then ns.priceScrollDirty = false; ns.Refresh() end
    if ns.Auction.syncWork then ns.Auction.SyncPrices(); shareElapsed = 0
    elseif shareElapsed >= 1 then shareElapsed = 0; ns.Auction.SyncPrices() end
    if elapsed >= .15 then
        elapsed = 0
        -- (the gamepad UI turned on or off, the default bags closed by the game)
        ns.SyncBagParking()
        ns.TickMove()
        if ns.dirty then
            -- (the game's sort moves items over a few moments: no holding in place until it settles)
            if ns.noHoldUntil and GetTime() < ns.noHoldUntil then ns.NoHoldFor(1.5) end
            ns.dirty = false; ns.ScanStorage("bags")
            if ns.state.bank then ns.ScanStorage("bank") end
            ns.viewDirty = true
        end
        if ns.viewDirty then ns.viewDirty = false; ns.Refresh(true)
        -- icons kept in place while the mouse was over the window: laid out again once it left
        elseif ns.holdPending and not ns.HoldPlaces() then ns.holdPending = false; ns.Refresh() end
    end
    if scanElapsed >= .1 then scanElapsed = 0; ns.Auction.Tick() end
end)
ns.eventFrame = frame
