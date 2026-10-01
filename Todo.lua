-- «Å gjøre» for WoW Forever – Lua-speilet av web/todo.js. Ren Lua 5.1, ingen WoW-API.
-- Tekstene skal være ORD FOR ORD like som i todo.js; scripts/test_parity.py passer på det.
--
-- Forventet netto for en post:
--   netto = P(salg) · antall · (pris · (1 − AH-cut) − vendor) − (1 − P(salg)) · deposit

local T = {}
SparkmackTodo = T

local floor, ceil, abs, max, min = math.floor, math.ceil, math.abs, math.max, math.min
local function round(x) return floor(x + 0.5) end   -- samme som Math.round i JS
local function clamp01(x) return max(0, min(1, x)) end

function T.money(cu)
  cu = cu or 0
  local neg = cu < 0
  cu = abs(round(cu))
  local g, s, c = floor(cu / 10000), floor((cu % 10000) / 100), cu % 100
  local out = {}
  if g > 0 then out[#out + 1] = g .. "g" end
  if s > 0 then out[#out + 1] = s .. "s" end
  if c > 0 or #out == 0 then out[#out + 1] = c .. "c" end
  return (neg and "−" or "") .. table.concat(out, " ")
end
local money = T.money

function T.deposit(vendor, qty, factor, rate)
  return floor(rate * (vendor or 0) * qty) * factor
end
local deposit = T.deposit

function T.ratePerHour(item)
  if item.sold == nil or not (item.hours and item.hours >= 2) then return nil end
  return item.sold / item.hours
end

-- Konkurrentenes auksjoner: alle i skanningen minus mine egne (samme pris og antall, én for én)
function T.competitors(listings, mine)
  local left = {}
  for i, l in ipairs(listings or {}) do left[i] = { price = l[1], qty = l[2], tl = l[3] } end
  for _, a in ipairs(mine) do
    for i, l in ipairs(left) do
      if l.price == a.buyout_unit and l.qty == a.qty then table.remove(left, i) break end
    end
  end
  table.sort(left, function(x, y) return x.price < y.price end)
  return left
end

local function bestPost(q, price, item, cfg, rate)
  local best
  for _, d in ipairs(cfg.durations) do
    local p = cfg.pUnknown
    if rate ~= nil then p = clamp01((rate * d.hours) / q) end
    local dep = deposit(item.vendor_price, q, d.factor, cfg.depositRate)
    local net = p * q * (price * (1 - cfg.ahCut) - (item.vendor_price or 0)) - (1 - p) * dep
    if not best or net > best.net then best = { net = net, p = p, dep = dep, hours = d.hours } end
  end
  return best
end

function T.settingsFrom(s)
  s = s or {}
  local function num(v, d) return tonumber(v) or d end
  return {
    ahCut = num(s.ah_cut, 0.05),
    undercut = num(s.undercut_copper, 1),
    depositRate = num(s.deposit_rate, 0.05),
    durations = s.durations or { { hours = 2, factor = 1 }, { hours = 8, factor = 4 }, { hours = 24, factor = 12 } },
    pUnknown = num(s.p_unknown, 0.3),
    maxStockDays = num(s.max_stock_days, 1),
    repostPerDay = num(s.repost_per_day, 1),
    minGain = num(s.min_gain_copper, 100),
  }
end

local function copy(t, extra)
  local o = {}
  for k, v in pairs(t) do o[k] = v end
  for k, v in pairs(extra or {}) do o[k] = v end
  return o
end

function T.build(input)
  local cfg = T.settingsFrom(input.settings)
  local out = {}
  local mineBy, bagsBy, bankBy = {}, {}, {}
  for _, a in ipairs(input.mine or {}) do
    local k = a.item_id .. ":" .. a.variant
    mineBy[k] = mineBy[k] or {}
    table.insert(mineBy[k], a)
  end
  for _, i in ipairs(input.inventory or {}) do
    local by = i.place == "bank" and bankBy or bagsBy
    local k = i.item_id .. ":" .. i.variant
    by[k] = (by[k] or 0) + i.count
  end

  local items = input.items or {}
  local keys = {}
  for k in pairs(items) do keys[#keys + 1] = k end
  table.sort(keys)

  for _, key in ipairs(keys) do
    local item = items[key]
    local mine = mineBy[key] or {}
    local comp = T.competitors(item.listings, mine)
    local rate = T.ratePerHour(item)
    local measured = rate ~= nil
    local vendor = item.vendor_price or 0
    local floorPrice = ceil(vendor / (1 - cfg.ahCut))
    local cheapest = #comp > 0 and comp[1].price or nil
    local base = { key = key, item_id = item.item_id, variant = item.variant, name = item.name, quality = item.quality, measured = measured }

    -- POST: varer i bagen som ikke ligger ute
    local inBags = bagsBy[key] or 0
    if inBags > 0 then
      local target
      if cheapest ~= nil then target = cheapest - cfg.undercut
      elseif item.med7 and item.med7 ~= 0 then target = round(item.med7) end
      if target == nil then
        -- ingen pris å gå etter – ikke noe råd
      elseif target < floorPrice then
        out[#out + 1] = copy(base, { action = "HOLD", qty = inBags, price = target, gain = 0,
          reason = "AH-prisen (" .. money(target) .. ") er under vendor-verdien. Behold eller selg til vendor." })
      elseif item.med7 and item.med7 ~= 0 and target < item.med7 * 0.5 then
        -- Samme vern som utleggingen: aldri under halve 7-dagers median (noen dumper)
        out[#out + 1] = copy(base, { action = "HOLD", qty = inBags, price = target, gain = 0,
          reason = "Billigste nå (" .. money(target + cfg.undercut) .. ") er under halve 7-dagers median ("
            .. money(round(item.med7)) .. "). Noen dumper – vent til prisen tar seg opp." })
      else
        local cap
        if measured then cap = max(1, ceil(rate * 24 * cfg.maxStockDays))
        else cap = (item.stack_size and item.stack_size ~= 0) and item.stack_size or inBags end
        local q = min(inBags, cap)
        local b = bestPost(q, target, item, cfg, rate)
        if b.net >= cfg.minGain then
          local bank = bankBy[key] and (" " .. bankBy[key] .. " til i banken.") or ""
          local reason = (cheapest ~= nil and ("1c under billigste (" .. money(cheapest) .. ").") or "Ingen andre ute – 7-dagers median.")
            .. " Varighet " .. b.hours .. " t."
            .. (measured and "" or " Omsetningen er ukjent ennå.")
            .. (q < inBags and (" Legg ut " .. q .. " av " .. inBags .. ": mer enn ett døgns omsetning blir liggende.") or "")
            .. bank
          out[#out + 1] = copy(base, { action = "POST", qty = q, price = target, hours = b.hours, deposit = b.dep,
            gain = round(b.net), p_sale = b.p, reason = reason })
        end
      end
    end

    -- REPOST / HOLD: egne auksjoner som ikke er billigst
    for _, a in ipairs(mine) do
      local aheadQty, aheadN = 0, 0
      for _, l in ipairs(comp) do
        if l.price < a.buyout_unit then aheadQty = aheadQty + l.qty aheadN = aheadN + 1 end
      end
      if aheadN > 0 then
        local tLeft = (a.time_left_s or 0) / 3600
        local newPrice = cheapest - cfg.undercut
        local row = copy(base, { character = a.character, auction_id = a.auction_id, qty = a.qty, price = a.buyout_unit, new_price = newPrice })
        if (item.reposts_24h or 0) >= cfg.repostPerDay then
          out[#out + 1] = copy(row, { action = "HOLD", gain = 0,
            reason = "Allerede lagt ut eller omprisset i dag. Maks " .. cfg.repostPerDay .. " per vare per døgn – omprising koster deposit." })
        elseif newPrice < floorPrice then
          out[#out + 1] = copy(row, { action = "HOLD", gain = 0,
            reason = "Å matche " .. money(cheapest) .. " gir mindre enn vendor-verdien. La den stå." })
        elseif item.med7 and item.med7 ~= 0 and newPrice < item.med7 * 0.5 then
          out[#out + 1] = copy(row, { action = "HOLD", gain = 0,
            reason = "Å matche " .. money(cheapest) .. " er under halve 7-dagers median (" .. money(round(item.med7))
              .. "). Noen dumper – la den stå." })
        elseif measured and aheadQty <= rate * tLeft * 0.5 then
          out[#out + 1] = copy(row, { action = "HOLD", gain = 0,
            reason = "Bare " .. aheadQty .. " stk foran deg, ventes solgt på " .. max(1, round(aheadQty / rate)) .. " t. La den stå." })
        else
          local oldDur = cfg.durations[#cfg.durations]
          for _, d in ipairs(cfg.durations) do if d.hours >= tLeft then oldDur = d break end end
          local depOld = deposit(vendor, a.qty, oldDur.factor, cfg.depositRate)
          local pStay = cfg.pUnknown * 0.5
          if measured then pStay = clamp01((rate * tLeft - aheadQty) / a.qty) end
          local eStay = pStay * (a.qty * (a.buyout_unit * (1 - cfg.ahCut) - vendor) + depOld)
          local b = bestPost(a.qty, newPrice, item, cfg, rate)
          local gain = b.net - eStay
          if gain >= cfg.minGain then
            out[#out + 1] = copy(row, { action = "REPOST", price = newPrice, old_price = a.buyout_unit, hours = b.hours,
              deposit = b.dep + depOld, gain = round(gain), p_sale = b.p,
              reason = aheadQty .. " stk ligger billigere. Ny pris " .. money(newPrice) .. " gir " .. money(gain) .. " mer i forventning, "
                .. "etter tapt deposit (" .. money(depOld) .. ")." .. (measured and "" or " Omsetningen er antatt.") })
          else
            out[#out + 1] = copy(row, { action = "HOLD", gain = 0,
              reason = "Omprising koster mer enn den gir (" .. money(gain) .. "). La den stå." })
          end
        end
      end
    end
  end

  -- Handlinger først, størst gevinst øverst; likt → rekkefølgen de ble laget i (samme regel i todo.js)
  local order = { POST = 0, REPOST = 0, HOLD = 1 }
  for i, x in ipairs(out) do x.seq = i end
  table.sort(out, function(a, b)
    if order[a.action] ~= order[b.action] then return order[a.action] < order[b.action] end
    if a.gain ~= b.gain then return a.gain > b.gain end
    return a.seq < b.seq
  end)
  return out
end

return T
