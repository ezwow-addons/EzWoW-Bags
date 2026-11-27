local _, ns = ...
function ns.CategoryName(id)
    for _, c in ipairs(ns.cfg.custom) do if c.id == id then return c.name end end
    return ns.T(id)
end
function ns.CategoryConfig(id)
    local cfg = ns.cfg.categories[id]
    if type(cfg) ~= "table" then cfg = {}; ns.cfg.categories[id] = cfg end
    return cfg
end
function ns.Price(id)
    local market = ns.db.markets[ns.market]
    return market and market.items and market.items[id]
end
function ns.BuildModel(snapshot, query)
    local predicate, err = ns.Search.Compile(query)
    if not predicate then return {}, err end
    local sections, map = {}, {}
    for _, raw in ipairs(snapshot and snapshot.items or {}) do
        local e = ns.Enrich(ns.Copy(raw))
        if predicate(e) then
            local cat = ns.Category(e)
            if ns.CategoryConfig(cat).disabled then cat = "other" end
            local cfg = ns.CategoryConfig(cat)
            if not cfg.hidden and (not ns.filterCategory or ns.filterCategory == cat) then
                local section = map[cat]
                if not section then
                    section = { id = cat, name = ns.CategoryName(cat), items = {}, count = 0, value = 0, priced = 0, pinned = cfg.pinned }
                    map[cat] = section; sections[#sections + 1] = section
                end
                section.count = section.count + e.count
                local price = ns.Price(e.id)
                if price then section.value = section.value + price.unit * e.count; section.priced = section.priced + e.count end
                -- every stack is its own icon (2026-11-21: combined stacks handed over only their first stack at
                -- the mailbox and in trade, so stacks are never combined)
                e.sources = { raw }; section.items[#section.items + 1] = e
            end
        end
    end
    local function sortItems(a, b)
        if ns.cfg.itemSort == "quality" and a.quality ~= b.quality then return a.quality > b.quality end
        if a.name ~= b.name then return a.name < b.name end
        if a.quality ~= b.quality then return a.quality > b.quality end
        if a.bag ~= b.bag then return a.bag < b.bag end
        return a.slot < b.slot
    end
    for _, s in ipairs(sections) do table.sort(s.items, sortItems) end
    -- The main sections keep their place even while empty (a whole view, not a search or one category),
    -- so the sections after them never move up or down (2026-11-26)
    if (query == nil or query == "") and not ns.filterCategory then
        for _, id in ipairs(ns.MAIN_SECTIONS) do
            local cfg = ns.CategoryConfig(id)
            if not map[id] and not cfg.hidden and not cfg.disabled then
                local section = { id = id, name = ns.CategoryName(id), items = {}, count = 0, value = 0, priced = 0, pinned = cfg.pinned }
                map[id] = section; sections[#sections + 1] = section
            end
        end
    end
    table.sort(sections, function(a, b)
        if not not a.pinned ~= not not b.pinned then return a.pinned == true end
        local ra, rb = ns.SectionRank(a.id), ns.SectionRank(b.id)
        if ra ~= rb then return ra < rb end
        return tostring(a.id) < tostring(b.id)
    end)
    return sections
end

-- A fixed section order, so a count that changes never moves a section (2026-11-26, user: consumables,
-- equipment, materials, quest, other, keys last). Pinned sections still come first.
ns.MAIN_SECTIONS = { "consumable", "equipment", "materials", "quest", "other" }
local SECTION_RANK = { consumable = 1, equipment = 2, materials = 3, quest = 4, other = 5, recipe = 6, junk = 7, new = 900, keys = 1000 }
-- The sections in rows across the side-by-side columns (UI/Window.lua lines the headers of a row up);
-- the keys always on a row of their own (user, 2026-11-26)
function ns.SectionRows(sections, lanes)
    lanes = math.max(1, tonumber(lanes) or 1)
    local rows, row = {}, {}
    for _, section in ipairs(sections) do
        if section.id == "keys" then
            if #row > 0 then rows[#rows + 1] = row end
            rows[#rows + 1], row = { section }, {}
        else
            row[#row + 1] = section
            if #row >= lanes then rows[#rows + 1], row = row, {} end
        end
    end
    if #row > 0 then rows[#rows + 1] = row end
    return rows
end
function ns.SectionRank(id)
    local rank = SECTION_RANK[id]
    if rank then return rank end
    -- the player's own categories, in the order they were made, after the game's ones
    for i, c in ipairs(ns.cfg and ns.cfg.custom or {}) do if c.id == id then return 100 + i end end
    return 800
end
