-- Sparkmack's Market Probe – WoW Forever.
-- Sparkmack's Kurstidende – finansavisen fra 1890 for WoW Forever. Sparkmack, en sleip og pengegrisk goblin,
-- sender budet sitt til AH etter dagens kurser. «Send ut budet» = full skanning, «Send til trykken!» skriver til disk (reload),
-- og watcheren på PC-en laster opp. Addonen kjøper, poster og kansellerer ingenting.

local ADDON = "Sparkmack"
local VERSION = "1.8.0"
local KEEP_SCANS = 5          -- ringbuffer: de fem siste skanningene
local BATCH = 500             -- rader per bilde når skanningen leses
local WAIT_SECONDS = 30       -- så lenge vi venter på serveren før reserveløsningen
local COOLDOWN = 900          -- full skanning maks hvert 15. minutt
local DB

-- ── Tekst ────────────────────────────────────────────────────────────────
local function msg(s)
  DEFAULT_CHAT_FRAME:AddMessage("|cffffd100Sparkmack|r: " .. s)
end

local LINES = {
  ready = { "Sparkmack her! Åpne AH, så sender vi budet etter dagens kurser. Provisjonen tar vi senere.",
            "Tid er penger, kompis! Åpne AH og send ut budet." },
  start = { "Budet løper til auksjonshuset! Tid er penger, kompis!",
            "Budet sniker seg inn bak disken. Ingen så noe, ingen sier noe.",
            "Mynter! Jeg lukter mynter! Budet er på vei." },
  reading = { "%d auksjoner! Så mange godtroende selgere …",
              "Budet noterer %d auksjoner. Sparkmack gnir seg i hendene." },
  done = { "Ferdig! Kjempekupp: %d auksjoner, %d varer. Send det til trykken før noen andre gjør det!",
           "Ferdig! %d auksjoner og %d varer notert. Send det til trykken, kompis!" },
  aborted = { "Hvem stengte AH?! Budet rakk å stikke av med litt av notatene." },
  busy = { "Budet er allerede ute og snoker. Grådighet tar tid!" },
  closed = { "Ingen AH, ingen business. Åpne auksjonshuset, kompis." },
  cached = { "Serveren er gjerrig, men budet har %d auksjoner i lomma fra forrige tur. Vi tar dem!" },
  noanswer = { "Serveren sier ingenting. Noen har nok nettopp skannet – prøv igjen om noen minutter, kompis." },
  cooldown = { "Budet hviler beina – klar om %d min. Løpegutter er ikke gratis, vet du.",
               "Budet er utslitt! Gi ham %d min. Tid er penger, men bud er dyrere." },
  unsaved = { "Du har ferske kurser som ikke er sendt til trykken! Send dem før du logger ut, kompis." },
  broke = { "Lommeboka er for lett, kompis! Depositen er %s, og du har bare %s. Ingenting er lagt ut.",
            "Ingen penger, ingen business! Depositen koster %s – du har %s. Ingenting er lagt ut." },
}

local function say(key, ...)
  local list = LINES[key]
  local line = list[math.random(#list)]
  msg(select("#", ...) > 0 and line:format(...) or line)
end

local PAPER_SOUND = {
  open = { "IG_SPELLBOOK_OPEN", 829 },
  close = { "IG_SPELLBOOK_CLOSE", 830 },
  turn = { "IG_ABILITY_PAGE_TURN", 836 },
}
local function paperSound(kind)
  local def = PAPER_SOUND[kind]
  if not (def and PlaySound) then return end
  local id = (SOUNDKIT and SOUNDKIT[def[1]]) or def[2]
  pcall(PlaySound, id, "SFX")
end

local function logError(where, err)
  if DB then
    DB.errors = DB.errors or {}
    if #DB.errors >= 20 then table.remove(DB.errors, 1) end
    DB.errors[#DB.errors + 1] = { at = time(), where = where, err = tostring(err) }
  end
  msg("Tannhjulene skar seg i " .. where .. ": " .. tostring(err))
end

-- ── Klient ───────────────────────────────────────────────────────────────
local function isModern()
  if IsUsingLegacyAuctionClient and IsUsingLegacyAuctionClient() then return false end
  return C_AuctionHouse ~= nil and C_AuctionHouse.ReplicateItems ~= nil
end

local function ahFrame()
  if isModern() then return AuctionHouseFrame end
  return AuctionFrame
end

local function ahOpen()
  local f = ahFrame()
  return f ~= nil and f:IsShown()
end

local function itemInfo(...)
  local fn = GetItemInfo or (C_Item and C_Item.GetItemInfo)
  if fn then return fn(...) end
end

local function regionName()
  if GetCurrentRegionName then
    local ok, r = pcall(GetCurrentRegionName)
    if ok and r then return r end
  end
  return ""
end

local function isBeta()
  for _, fn in ipairs({ IsBetaBuild, IsTestBuild }) do
    if fn then
      local ok, r = pcall(fn)
      if ok and r then return true end
    end
  end
  return (GetRealmName() or ""):find("Beta") ~= nil
end

-- item:itemId:enchant:gem1:gem2:gem3:gem4:suffixId:unique:linkLevel:specId:modMask:context:numBonus:bonus1:...
-- WoW Forever legger tilfeldig suffiks («of the Whale») i bonusID-ene. Variant = suffixId hvis satt,
-- ellers bonusID-ene sortert og skilt med «/». «0» = ingen variant.
local function parseLink(link)
  if not link then return nil, nil end
  local body = link:match("|Hitem:([^|]+)|h")
  if not body then return nil, nil end
  local f, i = {}, 0
  for part in (body .. ":"):gmatch("([^:]*):") do
    i = i + 1
    f[i] = part
  end
  local suffix = tonumber(f[7])
  if suffix and suffix ~= 0 then return tonumber(f[1]), tostring(suffix) end
  local nBonus = tonumber(f[13]) or 0
  if nBonus > 0 then
    local ids = {}
    for k = 14, 13 + nBonus do ids[#ids + 1] = tonumber(f[k]) or 0 end
    table.sort(ids)
    return tonumber(f[1]), table.concat(ids, "/")
  end
  return tonumber(f[1]), "0"
end

-- ── Panelet ──────────────────────────────────────────────────────────────
local ui = {}
local refreshTodo   -- «Å gjøre»-lista; settes lenger ned
local idleStatus, statusTicker   -- statuslinja når ingenting skjer; settes lenger ned
local updateOpenButton           -- knappen ved AH som åpner avisen igjen; settes lenger ned
local function setStatus(text, progress)
  if ui.status then ui.status:SetText(text) end
  if ui.bar and progress then
    ui.bar:SetValue(progress)
    local busy = progress > 0 and progress < 1
    for _, x in ipairs({ ui.bar, ui.track }) do if busy then x:Show() else x:Hide() end end
  end
end

-- ── Varedata ─────────────────────────────────────────────────────────────
-- Navn, kvalitet, vendor-pris og stack. Fylles når klienten har varen i cache; resten ber vi om.
local pendingItems = {}
local function rememberItem(itemId)
  if not itemId or itemId == 0 then return end
  local known = DB.items[itemId]
  if known and known[1] then return end
  local name, _, quality, _, _, _, _, stack, _, _, vendor = itemInfo(itemId)
  if name then
    DB.items[itemId] = { name, quality or -1, vendor or 0, stack or 1 }
    pendingItems[itemId] = nil
  else
    pendingItems[itemId] = true
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, itemId) end
  end
end

-- ── Skanning ─────────────────────────────────────────────────────────────
local function scanApi()
  if isModern() then
    local A = C_AuctionHouse
    return {
      first = 0,
      count = function() return A.GetNumReplicateItems() or 0 end,
      info = function(i) return A.GetReplicateItemInfo(i) end,
      link = function(i) return A.GetReplicateItemLink(i) end,
      timeLeft = function(i) return A.GetReplicateItemTimeLeft(i) end,
    }
  end
  return {
    first = 1,
    count = function() return (GetNumAuctionItems("list")) end,
    info = function(i) return GetAuctionItemInfo("list", i) end,
    link = function(i) return GetAuctionItemLink("list", i) end,
    timeLeft = function(i) return GetAuctionItemTimeLeft("list", i) end,
  }
end

local scan

local function finishScan(aborted)
  local s = scan
  scan = nil
  if aborted and #s.lines == 0 then
    say("aborted")
    setStatus("Avbrutt – budet kom tomhendt tilbake", 0)
    return
  end
  local record = {
    key = s.key, realm = s.realm, faction = s.faction, region = s.region, beta = s.beta,
    character = s.character, kind = s.kind, started = s.started, finished = time(),
    rows = #s.lines, version = VERSION, complete = not aborted,
    data = table.concat(s.lines, "\n"),
  }
  table.insert(DB.scans, record)
  if not aborted and record.rows > 0 then DB.scanCount = (DB.scanCount or 0) + 1 end
  while #DB.scans > KEEP_SCANS do table.remove(DB.scans, 1) end
  DB.unsaved = true
  local distinct = 0
  for _ in pairs(s.distinct) do distinct = distinct + 1 end
  if aborted then
    say("aborted")
    setStatus(("Avbrutt – %d auksjoner notert"):format(record.rows), 0)
  else
    say("done", record.rows, distinct)
    if PlaySound and SOUNDKIT and SOUNDKIT.LOOT_WINDOW_COIN_SOUND then pcall(PlaySound, SOUNDKIT.LOOT_WINDOW_COIN_SOUND) end
    setStatus(("Notert: %d auksjoner, %d varer – til trykken!"):format(record.rows, distinct), 1)
  end
  if ui.save and ui.save.paint then ui.save.locked = true ui.save.paint(true) end
  if refreshTodo then refreshTodo() end
end

local function processRows(startIndex)
  if not scan then return end
  if not ahOpen() then finishScan(true) return end
  local api = scan.api
  local last = math.min(startIndex + BATCH - 1, scan.lastIndex)
  for i = startIndex, last do
    local _, _, count, _, _, _, _, minBid, _, buyout, bidAmount, _, _, owner, _, _, itemId = api.info(i)
    local linkId, variant = parseLink(api.link(i))
    itemId = itemId or linkId
    if itemId and itemId ~= 0 then
      local qty = (count and count > 0) and count or 1
      local bid = (bidAmount and bidAmount > 0) and bidAmount or (minBid or 0)
      scan.lines[#scan.lines + 1] = table.concat({
        itemId, variant or "0", qty, math.floor((buyout or 0) / qty), bid, api.timeLeft(i) or 0,
        ((owner or ""):gsub(",", "")),
      }, ",")
      if not scan.distinct[itemId .. ":" .. (variant or "0")] then
        scan.distinct[itemId .. ":" .. (variant or "0")] = true
        rememberItem(itemId)
      end
    end
  end
  if last < scan.lastIndex then
    local done = (last - api.first + 1) / math.max(1, scan.batch)
    setStatus(("Budet noterer … %d %%"):format(math.floor(done * 100)), done)
    C_Timer.After(0, function() processRows(last + 1) end)
  else
    finishScan(false)
  end
end

local function onScanData()
  if not scan or not scan.waiting then return end
  scan.waiting = false
  if isModern() and scan.kind == "replicate" then DB.lastAnswer = time() end
  scan.batch = scan.api.count() or 0
  scan.lastIndex = scan.api.first + scan.batch - 1
  say("reading", scan.batch)
  setStatus(("%d auksjoner funnet – teller mynter …"):format(scan.batch), 0)
  processRows(scan.api.first)
end

local function cachedCount()
  return (C_AuctionHouse and C_AuctionHouse.GetNumReplicateItems and C_AuctionHouse.GetNumReplicateItems()) or 0
end

-- Serveren svarer ikke innenfor 15-minuttersgrensen. Da ligger ofte forrige resultat i klienten.
local function waitForServer(s)
  C_Timer.After(1, function()
    if scan ~= s or not s.waiting then return end
    s.waited = (s.waited or 0) + 1
    if s.waited < WAIT_SECONDS then
      setStatus(("Budet venter ved disken … %d s"):format(s.waited), s.waited / WAIT_SECONDS * 0.2)
      waitForServer(s)
      return
    end
    local cached = cachedCount()
    if cached > 0 then
      s.kind = "replicate-cached"
      say("cached", cached)
      onScanData()
    else
      scan = nil
      say("noanswer")
      setStatus("Ingen svar fra serveren – prøv igjen om noen minutter", 0)
    end
  end)
end

local function newScan(kind)
  local realm, character = GetRealmName() or "?", UnitName("player") or "?"
  local now = time()
  DB.seq = (DB.seq or 0) + 1  -- to skanninger i samme sekund skal ikke få samme nøkkel
  scan = {
    key = character .. "-" .. realm .. "-" .. now .. "-" .. DB.seq, realm = realm, faction = UnitFactionGroup("player") or "?",
    region = regionName(), beta = isBeta(), character = character, kind = kind, started = now,
    api = scanApi(), lines = {}, distinct = {}, waiting = true,
  }
end

local function startScan()
  if scan then say("busy") return end
  if not ahOpen() then say("closed") return end
  if isModern() and DB.lastAnswer and time() - DB.lastAnswer < COOLDOWN then
    local cached = cachedCount()
    if cached > 0 then
      newScan("replicate-cached")
      say("cached", cached)
      onScanData()
      return
    end
    local left = math.ceil((COOLDOWN - (time() - DB.lastAnswer)) / 60)
    say("cooldown", left)
    setStatus(("Budet hviler – klar om %d min"):format(left), 0)
    return
  end
  if isModern() then
    newScan("replicate")
    C_AuctionHouse.ReplicateItems()
  else
    local _, canGetAll = CanSendAuctionQuery()
    if not canGetAll then
      say("cooldown", 15)
      return
    end
    newScan("getAll")
    QueryAuctionItems("", nil, nil, 0, nil, nil, true, false, nil)
  end
  say("start")
  setStatus("Budet er inne bak disken – venter på svar …", 0)
  waitForServer(scan)
end

-- ── Egne auksjoner og beholdning (til «Å gjøre») ─────────────────────────
-- Lagres per karakter i DB.state[«Karakter-Realm»]: owned, bags og bank, hver med tidspunkt og linjer.
local function charState()
  local realm, character = GetRealmName() or "?", UnitName("player") or "?"
  local key = character .. "-" .. realm
  DB.state[key] = DB.state[key] or {}
  local st = DB.state[key]
  st.realm, st.character, st.faction, st.region, st.beta = realm, character, UnitFactionGroup("player") or "?", regionName(), isBeta()
  return st
end

-- «auctionId,itemId,variant,qty,buyoutUnit,bid,timeLeftS,status». buyoutAmount er pris per stk.
local function snapshotOwned()
  local A = C_AuctionHouse
  if not (A and A.GetNumOwnedAuctions and A.GetOwnedAuctionInfo) then return end
  local lines, now, seen = {}, time(), {}
  for i = 1, A.GetNumOwnedAuctions() or 0 do
    local a = A.GetOwnedAuctionInfo(i)
    if a and a.auctionID then
      local itemId, variant = parseLink(a.itemLink)
      itemId = itemId or (a.itemKey and a.itemKey.itemID)
      lines[#lines + 1] = table.concat({ a.auctionID, itemId or 0, variant or "0", a.quantity or 1,
        a.buyoutAmount or 0, a.bidAmount or 0, a.timeLeftSeconds or 0, a.status or 0 }, ",")
      rememberItem(itemId)
      -- Når auksjonen ble sett første gang: «maks én omprising per vare per døgn»
      DB.firstSeen[a.auctionID] = DB.firstSeen[a.auctionID] or now
      seen[a.auctionID] = true
    end
  end
  for id, t in pairs(DB.firstSeen) do
    if not seen[id] and now - t > 3 * 86400 then DB.firstSeen[id] = nil end
  end
  charState().owned = { taken = now, rows = table.concat(lines, "\n"), count = #lines }
end

local function bagItem(bag, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if not info then return nil end
    return info.hyperlink, info.stackCount or 1, info.isBound
  end
  local _, count, _, _, _, _, link, _, _, _, bound = GetContainerItemInfo(bag, slot)
  return link, count or 1, bound
end

local function bagSlots(bag)
  if C_Container and C_Container.GetContainerNumSlots then return C_Container.GetContainerNumSlots(bag) or 0 end
  return GetContainerNumSlots and GetContainerNumSlots(bag) or 0
end

-- «itemId,variant,count» for alt som ikke er soulbound
local function readBags(bags)
  local lines = {}
  for _, bag in ipairs(bags) do
    for slot = 1, bagSlots(bag) do
      local link, count, bound = bagItem(bag, slot)
      if link and not bound then
        local itemId, variant = parseLink(link)
        if itemId then
          lines[#lines + 1] = itemId .. "," .. (variant or "0") .. "," .. count
          rememberItem(itemId)
        end
      end
    end
  end
  return lines
end

local function snapshotBags()
  local bags = {}
  for b = 0, (NUM_BAG_SLOTS or 4) do bags[#bags + 1] = b end
  local lines = readBags(bags)
  charState().bags = { taken = time(), rows = table.concat(lines, "\n"), count = #lines }
end

local function snapshotBank()
  local bags = { (Enum and Enum.BagIndex and Enum.BagIndex.Bank) or BANK_CONTAINER or -1 }
  local first = (NUM_BAG_SLOTS or 4) + 1
  for b = first, first + (NUM_BANKBAGSLOTS or 7) - 1 do bags[#bags + 1] = b end
  local lines = readBags(bags)
  charState().bank = { taken = time(), rows = table.concat(lines, "\n"), count = #lines }
end

local function saveAndReload()
  pcall(snapshotBags)
  ReloadUI()
end

-- ── «Å gjøre» i spillet ──────────────────────────────────────────────────
-- Samme regler som nettsiden (Todo.lua speiler web/todo.js ord for ord). Grunnverdier fra Data.lua,
-- konkurrenter fra siste skanning av dette markedet, egne auksjoner og bag/bank fra DB.state.
-- Hver knapp gjør én handling på ett klikk. Ingenting skjer uten klikk.
local listingCache = {}

local function marketData()
  local key = (GetRealmName() or "?") .. "|" .. (UnitFactionGroup("player") or "?")
  return SparkmackData and SparkmackData.markets and SparkmackData.markets[key]
end

local function eachLine(rows, fn)
  for line in ((rows or "") .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then fn(line) end
  end
end

-- Siste skanning for dette markedet, gruppert per «itemId:variant» og sortert på pris
local function latestListings()
  local realm, faction = GetRealmName(), UnitFactionGroup("player")
  local s
  for i = #DB.scans, 1, -1 do
    if DB.scans[i].realm == realm and DB.scans[i].faction == faction then s = DB.scans[i] break end
  end
  if not s then return nil end
  if listingCache.key ~= s.key then
    local by = {}
    eachLine(s.data, function(line)
      local id, v, q, p, _, tl = line:match("^(%d+),([^,]*),(%d+),(%d+),(%d+),(%d+)")
      if id and tonumber(p) > 0 then
        local k = id .. ":" .. v
        by[k] = by[k] or {}
        by[k][#by[k] + 1] = { tonumber(p), tonumber(q), tonumber(tl) }
      end
    end)
    for _, t in pairs(by) do table.sort(t, function(a, b) return a[1] < b[1] end) end
    listingCache.key, listingCache.by, listingCache.scan = s.key, by, s
  end
  return listingCache.by, listingCache.scan
end

-- Samme form som wow.todo_input() gir nettsiden
local function todoInput()
  local by, scanRec = latestListings()
  if not by then return nil end
  local md = marketData()
  local st = charState()
  local mine, inv, keys, now = {}, {}, {}, time()
  eachLine(st.owned and st.owned.rows, function(line)
    local aid, id, v, q, p, _, tl, status = line:match("^(%d+),(%d+),([^,]*),(%d+),(%d+),(%d+),(%d+),(%d+)")
    if aid and status == "0" then
      mine[#mine + 1] = { auction_id = tonumber(aid), item_id = tonumber(id), variant = v, qty = tonumber(q),
        buyout_unit = tonumber(p), time_left_s = tonumber(tl), character = st.character }
      keys[id .. ":" .. v] = true
    end
  end)
  for _, place in ipairs({ "bags", "bank" }) do
    eachLine(st[place] and st[place].rows, function(line)
      local id, v, c = line:match("^(%d+),([^,]*),(%d+)")
      if id then
        inv[#inv + 1] = { item_id = tonumber(id), variant = v, count = tonumber(c), place = place, character = st.character }
        keys[id .. ":" .. v] = true
      end
    end)
  end
  local items = {}
  for k in pairs(keys) do
    local id, v = k:match("^(%d+):(.*)$")
    local known = DB.items[tonumber(id)] or {}
    local b = md and md.items and md.items[k]
    local reposts = 0
    for _, a in ipairs(mine) do
      if a.item_id .. ":" .. a.variant == k and DB.firstSeen[a.auction_id] and now - DB.firstSeen[a.auction_id] < 86400 then
        reposts = reposts + 1
      end
    end
    local item = { item_id = tonumber(id), variant = v, name = known[1], quality = known[2], listings = by[k] or {},
      reposts_24h = reposts }
    if b then  -- grunnverdier fra databasen, som nettsiden bruker
      item.vendor_price, item.sold, item.hours, item.med7 = b[1], b[3], b[4], b[5]
      if b[2] and b[2] ~= 0 then item.stack_size = b[2] end
    else       -- varen er ikke i databasen ennå: det spillet selv vet
      item.vendor_price, item.stack_size = known[3], known[4]
    end
    items[k] = item
  end
  return { settings = md and md.settings or {}, items = items, mine = mine, inventory = inv }, md, scanRec
end

-- Finn en bagplass med varen
local function findInBags(itemId, variant)
  for bag = 0, (NUM_BAG_SLOTS or 4) do
    for slot = 1, bagSlots(bag) do
      local link, count, bound = bagItem(bag, slot)
      if link and not bound then
        local id, v = parseLink(link)
        if id == itemId and (v or "0") == variant then return bag, slot, count end
      end
    end
  end
end

local function durationId(settings, hours)
  for _, d in ipairs((settings and settings.durations) or {}) do
    if d.hours == hours then return d.id end
  end
  return ({ [2] = 1, [8] = 2, [24] = 3 })[hours] or 3
end

-- Handlinger mot AH. Sparkmack sier aldri at noe er gjort før spillet har bekreftet det:
-- «Sender …» ved klikket, «Bekreftet» når auksjonen er opprettet/kansellert, spillets egen feilmelding hvis det sier nei,
-- og beskjed etter PENDING_TIMEOUT sekunder uten svar. Én handling om gangen.
local PENDING_TIMEOUT = 10
local pending

local function finishPending(ok, text)
  local p = pending
  pending = nil
  if not p then return end
  msg(text)
  setStatus(ok and "Bekreftet av spillet" or "Ikke gjort – se chatten", ok and 1 or 0)
  if ok then p.row.done = true elseif p.button then p.button:Enable() end
  if ok and p.kind == "post" and p.dep then
    DB.posts = DB.posts or {}
    table.insert(DB.posts, { item_id = p.row.item_id, qty = p.qty, dep = p.dep, t = time() })
    while #DB.posts > 300 do table.remove(DB.posts, 1) end
  end
  if refreshTodo then refreshTodo() end
end

local function startPending(kind, row, button, extra)
  pending = { kind = kind, row = row, button = button, at = time(), id = (extra and extra.auctionID) or nil,
    bagBefore = extra and extra.bagBefore, label = extra and extra.label, dep = extra and extra.dep, qty = extra and extra.qty }
  local mine = pending
  C_Timer.After(PENDING_TIMEOUT, function()
    if pending == mine then
      finishPending(false, "Fikk ikke svar fra spillet på " .. PENDING_TIMEOUT .. " s – sjekk fanen «Auctions» før du prøver igjen.")
    end
  end)
end

local function bagCount(itemId, variant)
  local n = 0
  for bag = 0, (NUM_BAG_SLOTS or 4) do
    for slot = 1, bagSlots(bag) do
      local link, count, bound = bagItem(bag, slot)
      if link and not bound then
        local id, v = parseLink(link)
        if id == itemId and (v or "0") == variant then n = n + count end
      end
    end
  end
  return n
end

-- POST: ett klikk = én utlegging. Vern: aldri under vendor-verdien eller under halve 7-dagers median,
-- og aldri uten penger til depositen.
local function doPost(row, settings, button)
  local A = C_AuctionHouse
  if not ahOpen() then say("closed") return false end
  if pending then msg("Vent litt – forrige handling venter fortsatt på svar fra spillet.") return false end
  local bag, slot = findInBags(row.item_id, row.variant)
  if not bag then msg("Fant ikke " .. (row.name or "varen") .. " i bagen.") return false end
  local cfg = SparkmackTodo.settingsFrom(settings)
  local unit = row.price
  if A.SupportsCopperValues and not A.SupportsCopperValues() then unit = math.floor(unit / 100) * 100 end
  local vendor = (DB.items[row.item_id] or {})[3] or 0
  local item = (marketData() or {}).items and marketData().items[row.key]
  local med7 = item and item[5]
  if unit < math.ceil(vendor / (1 - cfg.ahCut)) or (med7 and unit < med7 * 0.5) then
    msg("Stopper: " .. SparkmackTodo.money(unit) .. " er for lavt for " .. (row.name or "varen") .. ". Ingenting er lagt ut.")
    return false
  end
  local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
  local dur = durationId(settings, row.hours)
  local commodity = Enum and Enum.ItemCommodityStatus and A.GetItemCommodityStatus(loc) == Enum.ItemCommodityStatus.Commodity
  local qty = commodity and row.qty or 1
  -- Depositen slik spillet selv regner den, mot gullet du har
  local dep
  if commodity and A.CalculateCommodityDeposit then dep = A.CalculateCommodityDeposit(row.item_id, dur, qty)
  elseif A.CalculateItemDeposit then dep = A.CalculateItemDeposit(loc, dur, qty) end
  dep = dep or row.deposit or 0
  if GetMoney() < dep then
    say("broke", SparkmackTodo.money(dep), SparkmackTodo.money(GetMoney()))
    setStatus("For lite gull til depositen", 0)
    return false
  end
  local label = ("%d × %s %s"):format(qty, row.name or ("vare #" .. row.item_id), SparkmackTodo.money(unit))
  startPending("post", row, button, { bagBefore = bagCount(row.item_id, row.variant), label = label, dep = dep, qty = qty })
  local needsConfirm
  if commodity then
    needsConfirm = A.PostCommodity(loc, dur, qty, unit)
    if needsConfirm and AuctionHouseFrame and AuctionHouseFrame.CommoditiesSellFrame and AuctionHouseFrame.CommoditiesSellFrame.CachePendingPost then
      AuctionHouseFrame.CommoditiesSellFrame:CachePendingPost(loc, dur, qty, unit)
    end
  else
    needsConfirm = A.PostItem(loc, dur, qty, nil, unit)
    if needsConfirm and AuctionHouseFrame and AuctionHouseFrame.ItemSellFrame and AuctionHouseFrame.ItemSellFrame.CachePendingPost then
      AuctionHouseFrame.ItemSellFrame:CachePendingPost(loc, dur, qty, nil, unit)
    end
  end
  if needsConfirm then
    msg("Spillet vil ha bekreftelse på " .. label .. " – trykk «Accept» i vinduet som dukker opp.")
  else
    msg("Sender " .. label .. " til disken … venter på svar fra spillet.")
  end
  setStatus("Venter på svar fra spillet …", 0.5)
  return true
end

-- REPOST steg 1: kanseller. Varen kommer i posten; hent den, så foreslår Sparkmack å legge den ut igjen.
local function doCancel(row, button)
  local A = C_AuctionHouse
  if not ahOpen() then say("closed") return false end
  if pending then msg("Vent litt – forrige handling venter fortsatt på svar fra spillet.") return false end
  if A.CanCancelAuction and not A.CanCancelAuction(row.auction_id) then msg("Den auksjonen kan ikke kanselleres nå.") return false end
  local cost = A.GetCancelCost and A.GetCancelCost(row.auction_id) or 0
  if cost > 0 and GetMoney() < cost then
    say("broke", SparkmackTodo.money(cost), SparkmackTodo.money(GetMoney()))
    return false
  end
  startPending("cancel", row, button, { auctionID = row.auction_id, label = row.name or ("vare #" .. row.item_id) })
  A.CancelAuction(row.auction_id)
  msg("Sender kansellering av " .. (row.name or "auksjonen") .. " … venter på svar fra spillet.")
  setStatus("Venter på svar fra spillet …", 0.5)
  return true
end

-- Svar fra spillet på handlingen som venter
local function onActionEvent(event, a1, a2)
  if not pending then return end
  if event == "AUCTION_HOUSE_POST_ERROR" then
    finishPending(false, "Spillet sa nei til utleggingen. Ingenting ble lagt ut.")
  elseif event == "UI_ERROR_MESSAGE" then
    -- Kan gjelde noe annet enn AH («Out of range» o.l.): vent 2 s på bekreftelse før vi melder feil
    local text = (type(a2) == "string" and a2) or (type(a1) == "string" and a1) or "ukjent feil"
    local mine = pending
    C_Timer.After(2, function()
      if pending == mine then finishPending(false, "Spillet sa nei: «" .. text .. "». Ingenting ble gjort.") end
    end)
  elseif pending.kind == "post" and event == "AUCTION_HOUSE_AUCTION_CREATED" then
    finishPending(true, "Bekreftet! " .. pending.label .. " ligger ute. Cha-ching!")
    if PlaySound and SOUNDKIT and SOUNDKIT.LOOT_WINDOW_COIN_SOUND then pcall(PlaySound, SOUNDKIT.LOOT_WINDOW_COIN_SOUND) end
  elseif pending.kind == "post" and event == "BAG_UPDATE_DELAYED" and pending.bagBefore
      and bagCount(pending.row.item_id, pending.row.variant) < pending.bagBefore then
    finishPending(true, "Bekreftet! " .. pending.label .. " har forlatt bagen og ligger ute.")
  elseif pending.kind == "cancel" and event == "AUCTION_CANCELED" and (a1 == nil or a1 == pending.id) then
    finishPending(true, "Bekreftet: " .. pending.label .. " er kansellert. Varen kommer i posten.")
  end
end

-- ── Handelsprotokollen: salg, kjøp, utløpte og kansellerte auksjoner fra postkassen ──
-- Én hendelse per AH-brev. Brevet har ingen fast id, så en hendelse kjennes igjen på type, vare, antall, beløp og
-- når brevet kom (regnet fra dager igjen). Samme brev lest to ganger gir aldri to hendelser.
local MAIL_DAYS = 30

local function subjectPattern(fmt, fallback)
  local p = (fmt or fallback):gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
  return "^" .. p:gsub("%%s", "(.+)") .. "$"
end

local function nameToId(name)
  if not name then return nil end
  for id, v in pairs(DB.items) do
    if type(v) == "table" and v[1] == name then return id end
  end
end

local function isDuplicate(ev)
  local list = DB.ledger
  for i = #list, math.max(1, #list - 400), -1 do
    local e = list[i]
    if e.kind == ev.kind and e.name == ev.name and e.qty == ev.qty and e.gross == ev.gross and math.abs(e.at - ev.at) < 600 then
      return true
    end
  end
  return false
end

-- Tapt deposit for en utløpt/kansellert auksjon: fra våre egne utlegginger (eldste som passer), ellers ukjent
local function depositFor(itemId, qty, at)
  for i, p in ipairs(DB.posts or {}) do
    if p.item_id == itemId and p.qty == qty and p.t <= at + 60 and at - p.t < 3 * 86400 then
      table.remove(DB.posts, i)
      return p.dep
    end
  end
end

local function readMailbox()
  if not (GetInboxNumItems and GetInboxHeaderInfo) then return 0 end
  local st = charState()
  local now = time()
  local pats = {
    { "expired", subjectPattern(AUCTION_EXPIRED_MAIL_SUBJECT, "Auction expired: %s") },
    { "cancelled", subjectPattern(AUCTION_REMOVED_MAIL_SUBJECT, "Auction cancelled: %s") },
  }
  local added = 0
  for i = 1, GetInboxNumItems() or 0 do
    local _, _, _, subject, _, _, daysLeft = GetInboxHeaderInfo(i)
    local ev
    local invType, itemName, bid, deposit, consignment, count
    if GetInboxInvoiceInfo then
      local r = { GetInboxInvoiceInfo(i) }
      invType, itemName, bid, deposit, consignment, count = r[1], r[2], r[4], r[6], r[7], r[11]
    end
    if invType == "seller" then
      ev = { kind = "sold", name = itemName, gross = bid or 0, cut = consignment or 0, deposit = deposit, qty = count }
      ev.net = ev.gross - ev.cut
    elseif invType == "buyer" then
      ev = { kind = "bought", name = itemName, gross = bid or 0, cut = 0, qty = count }
      ev.net = -ev.gross
    elseif subject then
      for _, pk in ipairs(pats) do
        local nm = subject:match(pk[2])
        if nm then ev = { kind = pk[1], name = nm, gross = 0, cut = 0, net = 0 } break end
      end
    end
    if ev and ev.name then
      local id = parseLink(GetInboxItemLink and GetInboxItemLink(i, 1))
      local cnt
      if GetInboxItem then cnt = select(4, GetInboxItem(i, 1)) end
      ev.qty = ev.qty or cnt or tonumber(ev.name:match("%((%d+)%)%s*$")) or 1
      ev.name = (ev.name:gsub("%s*%(%d+%)%s*$", ""))
      ev.item_id = id or nameToId(ev.name)
      ev.at = math.floor(now - (MAIL_DAYS - (daysLeft or MAIL_DAYS)) * 86400)
      if not isDuplicate(ev) then
        if ev.kind == "expired" or ev.kind == "cancelled" then
          ev.deposit = depositFor(ev.item_id, ev.qty, ev.at)
          if ev.deposit then ev.net = -ev.deposit end
        end
        DB.ledgerSeq = (DB.ledgerSeq or 0) + 1
        ev.id = st.character .. "-" .. st.realm .. "-L" .. DB.ledgerSeq
        ev.character, ev.realm, ev.faction = st.character, st.realm, st.faction
        table.insert(DB.ledger, ev)
        added = added + 1
      end
    end
  end
  while #DB.ledger > 1000 do table.remove(DB.ledger, 1) end
  if added > 0 then DB.unsaved = true end
  return added
end

-- Protokollen for markedet du står i, nyeste først
local function ledgerHere()
  local realm, faction = GetRealmName(), UnitFactionGroup("player")
  local out = {}
  for _, e in ipairs(DB.ledger or {}) do
    if e.realm == realm and e.faction == faction then out[#out + 1] = e end
  end
  table.sort(out, function(a, b) return a.at > b.at end)
  return out
end

-- ── Sparkmack's Kurstidende: eget, flyttbart vindu i stil med en finansavis fra 1890 ──
-- Faner: NYHETER (rådene) og TIL AUKSJON (dine auksjoner). Plassering huskes i SparkmackDB.ui.
local ROWS_PER_PAGE = 7
local ROW_H = 62
local GAZETTE_W = 500
local INK = { 0.17, 0.11, 0.05 }          -- blekk
local INK_SOFT = { 0.36, 0.27, 0.16 }     -- blekk, dempet
local PAPER = { 0.86, 0.79, 0.63 }        -- avispapir
local HEAD_FONT = "Fonts\\MORPHEUS.TTF"
local BODY_FONT = "Fonts\\FRIZQT__.TTF"
local OXBLOOD = { 0.48, 0.1, 0.06 }       -- hover: dyp rød blekk
local ACTION_TEXT = { POST = "|cff1d5a1dLEGG UT (POST)|r", REPOST = "|cff1d3f78OMPRIS (REPOST)|r", HOLD = "|cff5a4a3aLA STÅ|r" }
local QUALITY_INK = { [0] = "5a5a5a", [1] = "2b1c0c", [2] = "1d5a1d", [3] = "10407a", [4] = "5a2080", [5] = "8a4a00" }
local WEEKDAY = { "søndag", "mandag", "tirsdag", "onsdag", "torsdag", "fredag", "lørdag" }
local MONTH = { "januar", "februar", "mars", "april", "mai", "juni", "juli", "august", "september", "oktober", "november", "desember" }

local function itemIcon(itemId)
  if C_Item and C_Item.GetItemIconByID then
    local ok, icon = pcall(C_Item.GetItemIconByID, itemId)
    if ok and icon then return icon end
  end
  if GetItemIcon then
    local ok, icon = pcall(GetItemIcon, itemId)
    if ok and icon then return icon end
  end
  return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function inkName(name, quality)
  return "|cff" .. (QUALITY_INK[quality or 1] or QUALITY_INK[1]) .. (name or "?") .. "|r"
end

local function timeLeft(sec)
  sec = sec or 0
  if sec >= 3600 then return math.floor(sec / 3600 + 0.5) .. " t" end
  return math.max(1, math.floor(sec / 60 + 0.5)) .. " min"
end

local function font(fs, path, size, color)
  if fs.SetFont then fs:SetFont(path, size, "") end
  if fs.SetTextColor then fs:SetTextColor(color[1], color[2], color[3]) end
  if fs.SetShadowOffset then fs:SetShadowOffset(0, 0) end
end

local function rule(parent, y, thick)
  local t = parent:CreateTexture(nil, "ARTWORK")
  t:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y)
  t:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -14, y)
  t:SetHeight(thick or 1)
  t:SetColorTexture(INK[1], INK[2], INK[3], 0.85)
  return t
end

local function datelineText(md, scanRec)
  local now = date("*t")
  local d = ("%s %d. %s %d"):format(WEEKDAY[now.wday] or "", now.day, MONTH[now.month] or "", now.year)
  local kurs = scanRec and ("kurs fra kl. " .. date("%H:%M", scanRec.started)) or "ingen kurs ennå"
  return ("Nr. %d  ·  %s  ·  %s  ·  Pris 1 kobber"):format(DB.scanCount or 0, d, kurs)
end

local function inkButton(parent, name, w, h, text, size)
  local b = CreateFrame("Button", name, parent)
  b:SetSize(w, h)
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints(b)
  b.bg:SetColorTexture(INK[1], INK[2], INK[3], 0)
  for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
    local e = b:CreateTexture(nil, "BORDER")
    if side == "TOP" or side == "BOTTOM" then
      e:SetPoint(side .. "LEFT", b, side .. "LEFT", 0, 0) e:SetPoint(side .. "RIGHT", b, side .. "RIGHT", 0, 0) e:SetHeight(1)
    else
      e:SetPoint("TOP" .. side, b, "TOP" .. side, 0, 0) e:SetPoint("BOTTOM" .. side, b, "BOTTOM" .. side, 0, 0) e:SetWidth(1)
    end
    e:SetColorTexture(INK[1], INK[2], INK[3], 0.9)
  end
  local fs = b:CreateFontString(nil, "OVERLAY")
  font(fs, HEAD_FONT, size or 14, INK)
  fs:SetPoint("CENTER", b, "CENTER", 0, 0)
  if b.SetFontString then b:SetFontString(fs) end
  b.label = fs
  local function paint(hot)
    if hot then
      b.bg:SetColorTexture(OXBLOOD[1], OXBLOOD[2], OXBLOOD[3], 0.95)
      fs:SetTextColor(PAPER[1], PAPER[2], PAPER[3])
    else
      b.bg:SetColorTexture(INK[1], INK[2], INK[3], 0)
      fs:SetTextColor(INK[1], INK[2], INK[3])
    end
  end
  b:SetScript("OnEnter", function() if b:IsEnabled() ~= false then paint(true) end end)
  b:SetScript("OnLeave", function() paint(b.locked) end)
  b:SetScript("OnEnable", function() b:SetAlpha(1) end)
  b:SetScript("OnDisable", function() b:SetAlpha(0.4) paint(false) end)
  b.paint = paint
  if text then b:SetText(text) end
  return b
end

local function bookmarkButton(parent, name, text)
  local b = CreateFrame("Button", name, parent)
  b:SetSize(30, 84)
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints(b)
  b.bg:SetColorTexture(INK[1], INK[2], INK[3], 0.95)
  for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
    local e = b:CreateTexture(nil, "BORDER")
    if side == "TOP" or side == "BOTTOM" then
      e:SetPoint(side .. "LEFT", b, side .. "LEFT", 0, 0) e:SetPoint(side .. "RIGHT", b, side .. "RIGHT", 0, 0) e:SetHeight(2)
    else
      e:SetPoint("TOP" .. side, b, "TOP" .. side, 0, 0) e:SetPoint("BOTTOM" .. side, b, "BOTTOM" .. side, 0, 0) e:SetWidth(2)
    end
    e:SetColorTexture(1, 0.82, 0, 0.55)
  end
  local fs = b:CreateFontString(nil, "OVERLAY")
  font(fs, HEAD_FONT, 26, PAPER)
  fs:SetPoint("CENTER", b, "CENTER", 1, 0)
  if b.SetFontString then b:SetFontString(fs) end
  b.label = fs
  b:SetScript("OnEnter", function() b.bg:SetColorTexture(OXBLOOD[1], OXBLOOD[2], OXBLOOD[3], 1) end)
  b:SetScript("OnLeave", function() b.bg:SetColorTexture(INK[1], INK[2], INK[3], 0.95) end)
  b:SetText(text)
  return b
end

-- Sidetall nederst på hvert blad, som i en avis
local function folio(p, n)
  local f = p:CreateFontString(nil, "OVERLAY")
  font(f, HEAD_FONT, 14, INK_SOFT)
  f:SetPoint("BOTTOM", p, "BOTTOM", 0, 12)
  f:SetText("— Side " .. n .. " —")
  return f
end

local function savePosition(frame)
  local point, _, relPoint, x, y = frame:GetPoint()
  DB.ui = DB.ui or {}
  DB.ui.gazette = { point = point, relPoint = relPoint, x = x, y = y }
end

-- Tresnitt: fargeløst ikon tonet i blekkbrunt, rundt (medaljong) når klienten kan maske
local ENGRAVING_FALLBACK = "Interface\\Icons\\INV_Misc_Coin_02"
local function engraving(parent, tex, size, alpha)
  local t = parent:CreateTexture(nil, "ARTWORK")
  t:SetSize(size, size)
  local ok = true
  if GetFileIDFromPath then
    local fine, id = pcall(GetFileIDFromPath, tex)
    ok = fine and id ~= nil
  end
  t:SetTexture(ok and tex or ENGRAVING_FALLBACK)
  if t.SetDesaturated then t:SetDesaturated(true) end
  t:SetVertexColor(0.66, 0.48, 0.27)
  t:SetAlpha(alpha or 0.9)
  if t.SetMask then pcall(t.SetMask, t, "Interface\\CharacterFrame\\TempPortraitAlphaMask") end
  return t
end

-- Snirklet ornamentstrek: linje – ruter – linje, med små ruter i endene
local function ornament(parent, y, inset)
  inset = inset or 40
  local function line(p1, x1, p2, x2)
    local l = parent:CreateTexture(nil, "ARTWORK")
    l:SetPoint("TOPLEFT", parent, p1, x1, y)
    l:SetPoint("TOPRIGHT", parent, p2, x2, y)
    l:SetHeight(1)
    l:SetColorTexture(INK[1], INK[2], INK[3], 0.85)
  end
  local function diamond(anchor, x, sz)
    local d = parent:CreateTexture(nil, "ARTWORK")
    d:SetSize(sz, sz)
    d:SetPoint("CENTER", parent, anchor, x, y)
    d:SetColorTexture(INK[1], INK[2], INK[3], 0.9)
    if d.SetRotation then pcall(d.SetRotation, d, math.pi / 4) end
  end
  line("TOPLEFT", inset, "TOP", -14, 0)
  line("TOP", 14, "TOPRIGHT", -inset, 0)
  diamond("TOP", 0, 8)
  diamond("TOP", -9, 3)
  diamond("TOP", 9, 3)
  diamond("TOPLEFT", inset - 4, 4)
  diamond("TOPRIGHT", -inset + 4, 4)
end

-- Skalering: håndtak nede i høyre hjørne, eller Ctrl + musehjul. Øvre venstre hjørne står stille.
local function setGazetteScale(t, scale)
  scale = math.max(0.6, math.min(1.6, scale))
  local left, top = t:GetLeft(), t:GetTop()
  local oldEff = t:GetEffectiveScale()
  t:SetScale(scale)
  if left and top and oldEff then
    local eff = t:GetEffectiveScale()
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * oldEff / eff, top * oldEff / eff)
    savePosition(t)
  end
  DB.ui = DB.ui or {}
  DB.ui.scale = scale
  if ui.spread then ui.spread:SetScale(scale) end
end

-- Tooltip på varer: spillets egen, pluss kursnotering fra Kurstidende (Data.lua og siste skanning)
local function showItemTooltip(owner, itemId, key)
  if not (GameTooltip and itemId) then return end
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  if GameTooltip.SetItemByID then pcall(GameTooltip.SetItemByID, GameTooltip, itemId) end
  key = key or (itemId .. ":0")
  local md = marketData()
  local b = md and md.items and md.items[key]
  local by = latestListings()
  local cheapest = by and by[key] and by[key][1] and by[key][1][1]
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Sparkmack's Kurstidende", 1, 0.82, 0)
  if b and b[5] then
    GameTooltip:AddDoubleLine("7-dagers median", SparkmackTodo.money(b[5]), 0.9, 0.9, 0.9, 1, 1, 1)
  end
  if cheapest then
    local line = SparkmackTodo.money(cheapest)
    if b and b[5] and b[5] > 0 then
      local pct = math.floor((cheapest / b[5] - 1) * 100 + 0.5)
      line = line .. (pct < 0 and ("  (" .. -pct .. " % under)") or pct > 0 and ("  (" .. pct .. " % over)") or "  (som medianen)")
    end
    GameTooltip:AddDoubleLine("Billigste nå", line, 0.9, 0.9, 0.9, 1, 1, 1)
  end
  if b and b[3] and b[4] and b[4] >= 2 then
    GameTooltip:AddDoubleLine("Omsetning", ("ca. %d stk per døgn"):format(math.floor(b[3] / b[4] * 24 + 0.5)), 0.9, 0.9, 0.9, 1, 1, 1)
  else
    GameTooltip:AddDoubleLine("Omsetning", "ikke målt ennå", 0.9, 0.9, 0.9, 0.7, 0.7, 0.7)
  end
  GameTooltip:Show()
end

local function hideTooltip() if GameTooltip then GameTooltip:Hide() end end

local function drawPaper(t)
  local paper = t:CreateTexture(nil, "BACKGROUND")
  paper:SetAllPoints(t)
  paper:SetColorTexture(PAPER[1], PAPER[2], PAPER[3], 1)
  local grain = t:CreateTexture(nil, "BACKGROUND", nil, 1)
  grain:SetAllPoints(t)
  grain:SetTexture("Interface\\QuestFrame\\QuestBG")
  grain:SetTexCoord(0.02, 0.58, 0.08, 0.66)
  grain:SetVertexColor(1, 0.93, 0.8)
  grain:SetAlpha(0.55)
  for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
    local e = t:CreateTexture(nil, "BORDER")
    if side == "TOP" or side == "BOTTOM" then
      e:SetPoint(side .. "LEFT", t, side .. "LEFT", 0, 0) e:SetPoint(side .. "RIGHT", t, side .. "RIGHT", 0, 0) e:SetHeight(2)
    else
      e:SetPoint("TOP" .. side, t, "TOP" .. side, 0, 0) e:SetPoint("BOTTOM" .. side, t, "BOTTOM" .. side, 0, 0) e:SetWidth(2)
    end
    e:SetColorTexture(0.35, 0.24, 0.1, 1)
  end
end

local LEDGER_TEXT = { sold = "|cff1d5a1dSOLGT|r", bought = "|cff1d3f78KJØPT|r", expired = "|cff8a2a1aUTLØPT|r",
  cancelled = "|cff5a4a3aKANSELLERT|r" }
local SHORT_DAY = { "søn", "man", "tir", "ons", "tor", "fre", "lør" }
local BOOK_TRADES = 8      -- Hovedboken: siste handler
local BORS_DEALS = 6       -- Børsen: kupp på torget
local BORS_TOP = 7         -- Børsen: mest omsatt

local function whenText(at)
  local d, today = date("*t", at), date("*t")
  local clock = date("%H:%M", at)
  if d.year == today.year and d.yday == today.yday then return "i dag " .. clock end
  if d.year == today.year and d.yday == today.yday - 1 then return "i går " .. clock end
  return ("%s. %d. %s %s"):format(SHORT_DAY[d.wday], d.day, (MONTH[d.month] or ""):sub(1, 3), clock)
end

local function sectionHead(p, text, y, x)
  x = x or 16
  local h = p:CreateFontString(nil, "OVERLAY")
  font(h, HEAD_FONT, 18, INK)
  h:SetPoint("TOPLEFT", p, "TOPLEFT", x, y)
  h:SetText(text)
  local l = p:CreateTexture(nil, "ARTWORK")
  l:SetPoint("TOPLEFT", p, "TOPLEFT", x - 2, y - 22)
  l:SetPoint("TOPRIGHT", p, "TOPRIGHT", -14, y - 22)
  l:SetHeight(1)
  l:SetColorTexture(INK[1], INK[2], INK[3], 0.85)
  return h
end

local function smallRow(p, y, name, x)
  x = x or 16
  local w = GAZETTE_W - x - 16
  local r = CreateFrame("Frame", name, p)
  r:SetSize(w, 32)
  r:SetPoint("TOPLEFT", p, "TOPLEFT", x, y)
  r.icon = r:CreateTexture(nil, "ARTWORK")
  r.icon:SetSize(24, 24)
  r.icon:SetPoint("LEFT", r, "LEFT", 0, 0)
  r.line = r:CreateFontString(nil, "OVERLAY")
  font(r.line, HEAD_FONT, 14, INK)
  r.line:SetPoint("TOPLEFT", r, "TOPLEFT", 32, -1)
  r.line:SetWidth(w - 32)
  r.line:SetJustifyH("LEFT")
  r.reason = r:CreateFontString(nil, "OVERLAY")
  font(r.reason, BODY_FONT, 10, INK_SOFT)
  r.reason:SetPoint("TOPLEFT", r.line, "BOTTOMLEFT", 0, -1)
  r.reason:SetWidth(w - 32)
  r.reason:SetJustifyH("LEFT")
  if r.EnableMouse then r:EnableMouse(true) end
  r:SetScript("OnEnter", function()
    r.line:SetTextColor(OXBLOOD[1], OXBLOOD[2], OXBLOOD[3])
    if r.itemId then showItemTooltip(r, r.itemId, r.itemKey) end
  end)
  r:SetScript("OnLeave", function() r.line:SetTextColor(INK[1], INK[2], INK[3]) hideTooltip() end)
  r:Hide()
  return r
end

local function emptyText(p, y, x)
  local e = p:CreateFontString(nil, "OVERLAY")
  font(e, BODY_FONT, 12, INK)
  e:SetPoint("TOPLEFT", p, "TOPLEFT", x or 16, y)
  e:SetWidth(GAZETTE_W - (x or 16) - 16)
  e:SetJustifyH("LEFT")
  return e
end

-- Et avisblad med eget hode: tittel, undertittel, ornament og datolinje
local function pageHead(p, title, subtitle)
  local mast = p:CreateFontString(nil, "OVERLAY")
  font(mast, HEAD_FONT, 30, INK)
  mast:SetPoint("TOP", p, "TOP", 0, -18)
  mast:SetText(title)
  local sub = p:CreateFontString(nil, "OVERLAY")
  font(sub, BODY_FONT, 10, INK_SOFT)
  sub:SetPoint("TOP", mast, "BOTTOM", 0, -3)
  sub:SetText(subtitle)
  ornament(p, -72, 72)
  local dl = p:CreateFontString(nil, "OVERLAY")
  font(dl, BODY_FONT, 11, INK)
  dl:SetPoint("TOP", p, "TOP", 0, -79)
  rule(p, -96, 1)
  rule(p, -99, 2)
  return dl
end

-- Oppslaget: Børsen (venstre) og Hovedboken (høyre). Eget vindu; forsiden skjules mens det er oppe.
local function buildSpread(H)
  local sp = CreateFrame("Frame", "SparkmackSpread", UIParent)
  sp:SetSize(GAZETTE_W * 2, H)
  sp:SetFrameStrata("HIGH")
  sp:SetClampedToScreen(true)
  sp:SetMovable(true)
  sp:EnableMouse(true)
  sp:RegisterForDrag("LeftButton")
  sp:SetScript("OnDragStart", function(self) self:StartMoving() end)
  sp:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  if sp.EnableMouseWheel then sp:EnableMouseWheel(true) end
  sp:SetScript("OnMouseWheel", function(_, delta)
    if IsControlKeyDown and IsControlKeyDown() and ui.todo then setGazetteScale(ui.todo, (DB.ui and DB.ui.scale or 1) + delta * 0.05) end
  end)

  local bors = CreateFrame("Frame", "SparkmackBorsen", sp)
  bors:SetSize(GAZETTE_W, H)
  bors:SetPoint("TOPLEFT", sp, "TOPLEFT", 0, 0)
  drawPaper(bors)
  local book = CreateFrame("Frame", "SparkmackHovedbok", sp)
  book:SetSize(GAZETTE_W, H)
  book:SetPoint("TOPLEFT", bors, "TOPRIGHT", 0, 0)
  drawPaper(book)
  -- Brettet midt i oppslaget: svak skygge på begge sider
  for _, side in ipairs({ { bors, "RIGHT" }, { book, "LEFT" } }) do
    local f = side[1]:CreateTexture(nil, "ARTWORK")
    f:SetPoint("TOP" .. side[2], side[1], "TOP" .. side[2], 0, 0)
    f:SetPoint("BOTTOM" .. side[2], side[1], "BOTTOM" .. side[2], 0, 0)
    f:SetWidth(8)
    f:SetColorTexture(0.25, 0.16, 0.06, 0.25)
  end

  -- Børsen: tilbake-pil innenfor venstre kant, så innholdet starter litt lenger inn
  local IN = 16
  local back = bookmarkButton(bors, "SparkmackBackButton", "<")
  back:SetPoint("RIGHT", bors, "LEFT", 1, 0)
  if sp.SetClampRectInsets then sp:SetClampRectInsets(-30, 0, 0, 0) end   -- bokmerket skal aldri havne utenfor skjermen
  folio(bors, 2)
  local borsDate = pageHead(bors, "Børsen", "KURSER OG KUPP FRA TORGET · BILAG TIL SPARKMACK'S KURSTIDENDE")
  sectionHead(bors, "Kupp på torget", -110, IN)
  local deals = {}
  for i = 1, BORS_DEALS do deals[i] = smallRow(bors, -138 - (i - 1) * 34, "SparkmackDealRow" .. i, IN) end
  local dealsEmpty = emptyText(bors, -142, IN)
  local topY = -138 - BORS_DEALS * 34 - 10
  sectionHead(bors, "Mest omsatt", topY, IN)
  local top = {}
  for i = 1, BORS_TOP do top[i] = smallRow(bors, topY - 28 - (i - 1) * 34, "SparkmackTopRow" .. i, IN) end
  local topEmpty = emptyText(bors, topY - 32, IN)

  -- Hovedboken: regnskap, netto per dag og siste handler
  local close = CreateFrame("Button", "SparkmackSpreadClose", book, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", book, "TOPRIGHT", 2, 2)
  close:SetScript("OnClick", function() paperSound("close") sp:Hide() DB.ui = DB.ui or {} DB.ui.gazetteHidden = true updateOpenButton() end)
  local bookDate = pageHead(book, "Hovedboken", "SPARKMACKS HANDELSPROTOKOLL")
  folio(book, 3)
  sectionHead(book, "Ukens regnskap", -110)
  local stats = {}
  for i, label in ipairs({ "I dag", "7 dager", "Solgt (7 d)", "AH-cut og tapt deposit" }) do
    local col = CreateFrame("Frame", nil, book)
    col:SetSize((GAZETTE_W - 32) / 4, 40)
    col:SetPoint("TOPLEFT", book, "TOPLEFT", 16 + (i - 1) * (GAZETTE_W - 32) / 4, -138)
    local l = col:CreateFontString(nil, "OVERLAY")
    font(l, BODY_FONT, 10, INK_SOFT)
    l:SetPoint("TOPLEFT", col, "TOPLEFT", 0, 0)
    l:SetText(label)
    local v = col:CreateFontString("SparkmackStat" .. i, "OVERLAY")
    font(v, HEAD_FONT, 17, INK)
    v:SetPoint("TOPLEFT", l, "BOTTOMLEFT", 0, -3)
    stats[i] = v
  end
  sectionHead(book, "Netto per dag", -186)
  local chartTop, chartH = -222, 80
  local zero = book:CreateTexture(nil, "ARTWORK")
  zero:SetHeight(1)
  zero:SetColorTexture(INK[1], INK[2], INK[3], 0.6)
  local bars = {}
  local slot = (GAZETTE_W - 32) / 7
  for i = 1, 7 do
    local bar = book:CreateTexture(nil, "ARTWORK")
    bar:SetWidth(slot * 0.5)
    local val = book:CreateFontString(nil, "OVERLAY")
    font(val, BODY_FONT, 9, INK)
    local day = book:CreateFontString(nil, "OVERLAY")
    font(day, BODY_FONT, 10, INK_SOFT)
    day:SetPoint("TOP", book, "TOPLEFT", 16 + (i - 0.5) * slot, chartTop - chartH - 6)
    bars[i] = { bar = bar, val = val, day = day, x = 16 + (i - 0.5) * slot }
  end
  sectionHead(book, "Siste handler", -330)
  local trades = {}
  for i = 1, BOOK_TRADES do trades[i] = smallRow(book, -358 - (i - 1) * 34, "SparkmackLedgerRow" .. i) end
  local tradesEmpty = emptyText(book, -362)

  ui.spread = sp
  ui.book = { page = book, date = bookDate, stats = stats, bars = bars, zero = zero, chartTop = chartTop, chartH = chartH,
    trades = trades, tradesEmpty = tradesEmpty }
  ui.bors = { page = bors, date = borsDate, deals = deals, dealsEmpty = dealsEmpty, top = top, topEmpty = topEmpty, back = back }
  if DB.ui and DB.ui.scale then sp:SetScale(DB.ui.scale) end
  sp:Hide()
  return sp
end

local function refreshSpread()
  if not (ui.spread and ui.spread:IsShown()) then return end
  local md = marketData()
  local _, scanRec = latestListings()
  ui.book.date:SetText(datelineText(md, scanRec))
  ui.bors.date:SetText(datelineText(md, scanRec))

  -- Hovedboken: regnskap og søyler
  local L = ui.book
  local list = ledgerHere()
  local now = time()
  local today0 = now - (tonumber(date("%H", now)) * 3600 + tonumber(date("%M", now)) * 60 + tonumber(date("%S", now)))
  local dayNet, todayNet, weekNet, soldWeek, costWeek = {}, 0, 0, 0, 0
  for i = 1, 7 do dayNet[i] = 0 end
  for _, e in ipairs(list) do
    local ago = math.floor((today0 - e.at) / 86400) + 1   -- 0 = i dag, 1 = i går …
    if e.at >= today0 then ago = 0 end
    if ago <= 6 then
      dayNet[7 - ago] = dayNet[7 - ago] + (e.net or 0)
      weekNet = weekNet + (e.net or 0)
      if e.kind == "sold" then soldWeek = soldWeek + (e.gross or 0) costWeek = costWeek + (e.cut or 0) end
      if (e.kind == "expired" or e.kind == "cancelled") and e.deposit then costWeek = costWeek + e.deposit end
    end
    if ago == 0 then todayNet = todayNet + (e.net or 0) end
  end
  local function signed(v) return (v > 0 and "+" or "") .. SparkmackTodo.money(v) end
  L.stats[1]:SetText(signed(todayNet))
  L.stats[2]:SetText(signed(weekNet))
  L.stats[3]:SetText(SparkmackTodo.money(soldWeek))
  L.stats[4]:SetText(SparkmackTodo.money(costWeek))
  local maxPos, maxNeg = 0, 0
  for i = 1, 7 do maxPos = math.max(maxPos, dayNet[i]) maxNeg = math.max(maxNeg, -dayNet[i]) end
  local span = math.max(1, maxPos + maxNeg)
  local zeroY = L.chartTop - L.chartH * (maxPos / span)
  if maxPos == 0 and maxNeg == 0 then zeroY = L.chartTop - L.chartH end
  L.zero:ClearAllPoints()
  L.zero:SetPoint("TOPLEFT", L.page, "TOPLEFT", 16, zeroY)
  L.zero:SetPoint("TOPRIGHT", L.page, "TOPRIGHT", -16, zeroY)
  for i = 1, 7 do
    local b, v = L.bars[i], dayNet[i]
    local h = math.max(1, L.chartH * math.abs(v) / span)
    b.bar:ClearAllPoints()
    if v >= 0 then
      b.bar:SetPoint("BOTTOM", L.page, "TOPLEFT", b.x, zeroY)
      b.bar:SetColorTexture(INK[1], INK[2], INK[3], v == 0 and 0.25 or 0.85)
    else
      b.bar:SetPoint("TOP", L.page, "TOPLEFT", b.x, zeroY)
      b.bar:SetColorTexture(OXBLOOD[1], OXBLOOD[2], OXBLOOD[3], 0.9)
    end
    b.bar:SetHeight(h)
    b.val:ClearAllPoints()
    b.val:SetPoint(v >= 0 and "BOTTOM" or "TOP", L.page, "TOPLEFT", b.x, v >= 0 and (zeroY + h + 2) or (zeroY - h - 2))
    b.val:SetText(v ~= 0 and SparkmackTodo.money(v) or "")
    b.day:SetText(SHORT_DAY[tonumber(date("%w", now - (7 - i) * 86400)) + 1])
  end
  for _, r in ipairs(L.trades) do r:Hide() end
  L.tradesEmpty:SetText(#list == 0 and "Hovedboken er tom. Åpne postkassen, så fører budet inn salg, kjøp og utløpte auksjoner." or "")
  for i = 1, math.min(BOOK_TRADES, #list) do
    local e, r = list[i], L.trades[i]
    local known = e.item_id and DB.items[e.item_id] or {}
    r.icon:SetTexture(itemIcon(e.item_id or 0))
    r.itemId, r.itemKey = e.item_id, e.item_id and (e.item_id .. ":0")
    local amount = e.kind == "sold" and ("+" .. SparkmackTodo.money(e.net)) or e.kind == "bought" and SparkmackTodo.money(e.net)
      or (e.deposit and ("−" .. SparkmackTodo.money(e.deposit) .. " deposit") or "deposit ukjent")
    r.line:SetText(("%s  %s  %d ×   %s"):format(LEDGER_TEXT[e.kind] or e.kind, inkName(e.name, known[2]), e.qty or 1, amount))
    local detail = e.kind == "sold" and ("Brutto %s · AH-cut %s · %s"):format(SparkmackTodo.money(e.gross), SparkmackTodo.money(e.cut), whenText(e.at))
      or e.kind == "bought" and ("Betalt %s · %s"):format(SparkmackTodo.money(e.gross), whenText(e.at))
      or ("Varen ligger i posten · %s"):format(whenText(e.at))
    r.reason:SetText(detail)
    r:Show()
  end

  -- Børsen: kupp på torget (flagg i Data.lua) og mest omsatt (solgt per døgn)
  local B = ui.bors
  for _, r in ipairs(B.deals) do r:Hide() end
  for _, r in ipairs(B.top) do r:Hide() end
  local found, busy = {}, {}
  for key, b in pairs(md and md.items or {}) do
    if b[6] == "billig" or b[6] == "dump" then found[#found + 1] = { key = key, b = b, ratio = (b[7] or 0) / math.max(1, b[5] or 1) } end
    if b[3] and b[4] and b[4] >= 2 and b[3] > 0 then busy[#busy + 1] = { key = key, b = b, perDay = b[3] / b[4] * 24 } end
  end
  table.sort(found, function(x, y) return x.ratio < y.ratio end)
  table.sort(busy, function(x, y) return x.perDay > y.perDay end)
  B.dealsEmpty:SetText(#found == 0 and "Ingen kupp ennå. Sparkmack trenger tre dagers kurser for å vite hva som er billig, kompis." or "")
  for i = 1, math.min(BORS_DEALS, #found) do
    local d, r = found[i], B.deals[i]
    local id = tonumber(d.key:match("^(%d+)"))
    local known = DB.items[id] or {}
    r.icon:SetTexture(itemIcon(id))
    r.itemId, r.itemKey = id, d.key
    r.line:SetText(("%s  %s  %s"):format(d.b[6] == "dump" and "|cff8a2a1aDUMP|r" or "|cff1d5a1dBILLIG NÅ|r",
      inkName(known[1] or ("Vare #" .. id), known[2]), SparkmackTodo.money(d.b[7] or 0)))
    r.reason:SetText(("7-dagers median %s · %d %% under"):format(SparkmackTodo.money(d.b[5] or 0), math.floor((1 - d.ratio) * 100 + 0.5)))
    r:Show()
  end
  B.topEmpty:SetText(#busy == 0 and "Omsetningen måles når budet har vært ute minst to ganger samme døgn." or "")
  for i = 1, math.min(BORS_TOP, #busy) do
    local d, r = busy[i], B.top[i]
    local id = tonumber(d.key:match("^(%d+)"))
    local known = DB.items[id] or {}
    r.icon:SetTexture(itemIcon(id))
    r.itemId, r.itemKey = id, d.key
    r.line:SetText(("%s  ca. %d stk per døgn"):format(inkName(known[1] or ("Vare #" .. id), known[2]), math.floor(d.perDay + 0.5)))
    r.reason:SetText(("Billigste nå %s · 7-dagers median %s"):format(SparkmackTodo.money(d.b[7] or 0), SparkmackTodo.money(d.b[5] or 0)))
    r:Show()
  end
end

-- Bla om: forsiden skjules, oppslaget legges slik at Hovedboken havner der forsiden var (eller mot høyre hvis
-- det ikke er plass til Børsen på venstre side av skjermen). Pila på Børsen blar tilbake.
local function openSpread()
  if not (ui.spread and ui.todo) then return end
  local left, top = ui.todo:GetLeft(), ui.todo:GetTop()
  ui.spread:SetScale(ui.todo:GetScale() or 1)
  ui.spread:ClearAllPoints()
  if left and top then
    local x = left - GAZETTE_W
    if x < 30 then x = left end   -- ikke plass til Børsen og bokmerket til venstre: legg oppslaget mot høyre
    ui.spread:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, top)
  else
    ui.spread:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  end
  ui.todo:Hide()
  ui.spread:Show()
  refreshSpread()
end

local function closeSpread()
  if ui.spread then ui.spread:Hide() end
  if ui.todo then
    ui.todo:Show()
    if refreshTodo then refreshTodo() end
  end
end

local function ensureTodoFrame()
  if not ui.todo then
    local W, TOP_ROWS = GAZETTE_W, 218
    local ROWS_END = TOP_ROWS + ROWS_PER_PAGE * ROW_H
    local t = CreateFrame("Frame", "SparkmackTodoFrame", UIParent)
    t:SetSize(W, ROWS_END + 58)
    if t.SetClampRectInsets then t:SetClampRectInsets(0, 30, 0, 0) end   -- bokmerket til høyre skal være på skjermen
    t:SetFrameStrata("HIGH")
    t:SetClampedToScreen(true)
    t:SetMovable(true)
    t:EnableMouse(true)
    t:RegisterForDrag("LeftButton")
    t:SetScript("OnDragStart", function(self) self:StartMoving() end)
    t:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() savePosition(self) end)
    if t.EnableMouseWheel then t:EnableMouseWheel(true) end
    t:SetScript("OnMouseWheel", function(self, delta)
      if IsControlKeyDown and IsControlKeyDown() then setGazetteScale(self, (DB.ui and DB.ui.scale or 1) + delta * 0.05) end
    end)

    -- Papir: sepia under, pergament over, mørk kant
    local paper = t:CreateTexture(nil, "BACKGROUND")
    paper:SetAllPoints(t)
    paper:SetColorTexture(PAPER[1], PAPER[2], PAPER[3], 1)
    local grain = t:CreateTexture(nil, "BACKGROUND", nil, 1)
    grain:SetAllPoints(t)
    grain:SetTexture("Interface\\QuestFrame\\QuestBG")
    grain:SetTexCoord(0.02, 0.58, 0.08, 0.66)   -- uten den grå, slitte toppkanten i QuestBG
    grain:SetVertexColor(1, 0.93, 0.8)
    grain:SetAlpha(0.55)
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
      local e = t:CreateTexture(nil, "BORDER")
      if side == "TOP" or side == "BOTTOM" then
        e:SetPoint(side .. "LEFT", t, side .. "LEFT", 0, 0) e:SetPoint(side .. "RIGHT", t, side .. "RIGHT", 0, 0) e:SetHeight(2)
      else
        e:SetPoint("TOP" .. side, t, "TOP" .. side, 0, 0) e:SetPoint("BOTTOM" .. side, t, "BOTTOM" .. side, 0, 0) e:SetWidth(2)
      end
      e:SetColorTexture(0.35, 0.24, 0.1, 1)
    end

    local close = CreateFrame("Button", "SparkmackTodoClose", t, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", t, "TOPRIGHT", 2, 2)
    close:SetScript("OnClick", function() paperSound("close") t:Hide() DB.ui = DB.ui or {} DB.ui.gazetteHidden = true updateOpenButton() end)

    buildSpread(ROWS_END + 58)
    local turn = bookmarkButton(t, "SparkmackTurnButton", ">")
    turn:SetPoint("LEFT", t, "RIGHT", -1, 0)
    turn:SetScript("OnClick", function() paperSound("turn") openSpread() end)
    ui.bors.back:SetScript("OnClick", function() paperSound("turn") closeSpread() end)

    -- Avishode: medaljonger «Tid» (lommeur) og «penger» (mynter) på hver side av tittelen
    local ear = t:CreateFontString(nil, "OVERLAY")
    font(ear, BODY_FONT, 11, INK_SOFT)
    ear:SetPoint("TOPLEFT", t, "TOPLEFT", 16, -12)
    ear:SetText("Grundlagt 1890")
    local motto = t:CreateFontString(nil, "OVERLAY")
    font(motto, BODY_FONT, 11, INK_SOFT)
    motto:SetPoint("TOPRIGHT", t, "TOPRIGHT", -34, -12)
    motto:SetText("«Tid er penger, kompis!»")
    t.motto = motto
    local watch = engraving(t, "Interface\\Icons\\INV_Misc_PocketWatch_01", 46)
    watch:SetPoint("TOPLEFT", t, "TOPLEFT", 16, -30)
    local coins = engraving(t, "Interface\\Icons\\INV_Misc_Coin_02", 46)
    coins:SetPoint("TOPRIGHT", t, "TOPRIGHT", -16, -30)
    t.watch, t.coins = watch, coins
    local mast = t:CreateFontString(nil, "OVERLAY")
    font(mast, HEAD_FONT, 33, INK)
    mast:SetPoint("TOP", t, "TOP", 0, -28)
    mast:SetText("Sparkmack's Kurstidende")
    local sub = t:CreateFontString(nil, "OVERLAY")
    font(sub, BODY_FONT, 11, INK_SOFT)
    sub:SetPoint("TOP", mast, "BOTTOM", 0, -3)
    sub:SetText("FINANS- OG HANDELSBLAD FOR AUKSJONSHUSET")
    ornament(t, -88, 72)
    local dateline = t:CreateFontString(nil, "OVERLAY")
    font(dateline, BODY_FONT, 11, INK)
    dateline:SetPoint("TOP", t, "TOP", 0, -95)
    rule(t, -112, 1)
    rule(t, -115, 2)

    -- Redaksjonen: status, framdrift, «Send ut budet» og «Send til trykken!»
    local status = t:CreateFontString("SparkmackStatusText", "OVERLAY")
    font(status, BODY_FONT, 12, INK)
    status:SetPoint("TOPLEFT", t, "TOPLEFT", 16, -126)
    status:SetWidth(180)
    status:SetJustifyH("LEFT")
    status:SetText("Klar til å sende ut budet.")
    local track = t:CreateTexture(nil, "ARTWORK")
    track:SetPoint("TOPLEFT", t, "TOPLEFT", 16, -150)
    track:SetSize(180, 4)
    track:Hide()
    track:SetColorTexture(INK[1], INK[2], INK[3], 0.15)
    local bar = CreateFrame("StatusBar", "SparkmackProgressBar", t)
    bar:SetPoint("TOPLEFT", track, "TOPLEFT", 0, 0)
    bar:SetSize(180, 4)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(OXBLOOD[1], OXBLOOD[2], OXBLOOD[3])
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    bar:Hide()
    local scanButton = inkButton(t, "SparkmackScanButton", 118, 30, "Send ut budet", 16)
    scanButton:SetPoint("TOPRIGHT", t, "TOPRIGHT", -168, -123)
    scanButton:SetScript("OnClick", function()
      local ok, err = pcall(startScan)
      if not ok then logError("Send ut budet", err) end
    end)
    local saveButton = inkButton(t, "SparkmackSaveButton", 146, 30, "Send til trykken!", 16)
    saveButton:SetPoint("TOPRIGHT", t, "TOPRIGHT", -16, -123)
    saveButton:SetScript("OnClick", saveAndReload)
    ui.status, ui.bar, ui.track, ui.scan, ui.save = status, bar, track, scanButton, saveButton
    rule(t, -164, 1)

    -- Faner med et lite tresnitt: aktiv i mørkt blekk, inaktiv dempet, oksblod på hover. Ingen strek under.
    local tabs = {}
    local tabDefs = { { id = "todo", text = "NYHETER", icon = "Interface\\Icons\\INV_Misc_Note_01" },
                      { id = "sale", text = "TIL AUKSJON", icon = "Interface\\Icons\\INV_Misc_Bag_10" } }
    for i, def in ipairs(tabDefs) do
      local b = CreateFrame("Button", i == 1 and "SparkmackTabTodo" or "SparkmackTabSale", t)
      b:SetSize(160, 26)
      b:SetPoint("TOPLEFT", t, "TOPLEFT", 16 + (i - 1) * 170, -168)
      b.icon = engraving(b, def.icon, 20, 0.85)
      b.icon:SetPoint("LEFT", b, "LEFT", 0, 0)
      b.label = b:CreateFontString(nil, "OVERLAY")
      font(b.label, HEAD_FONT, 20, INK)
      b.label:SetPoint("LEFT", b, "LEFT", 26, 0)
      b.label:SetText(def.text)
      b.id = def.id
      b:SetScript("OnEnter", function() b.label:SetTextColor(OXBLOOD[1], OXBLOOD[2], OXBLOOD[3]) end)
      b:SetScript("OnLeave", function()
        local c = ui.tab == def.id and INK or INK_SOFT
        b.label:SetTextColor(c[1], c[2], c[3])
      end)
      b:SetScript("OnClick", function()
        if ui.tab ~= def.id then paperSound("turn") end
        ui.tab = def.id ui.page = 1 refreshTodo()
      end)
      tabs[def.id] = b
    end
    local summary = t:CreateFontString(nil, "OVERLAY")
    font(summary, BODY_FONT, 11, INK_SOFT)
    summary:SetPoint("TOP", t, "TOP", 0, -199)   -- sentrert på egen linje under fanene
    summary:SetJustifyH("CENTER")
    rule(t, -194, 1)

    local empty = t:CreateFontString(nil, "OVERLAY")
    font(empty, BODY_FONT, 13, INK)
    empty:SetPoint("TOPLEFT", t, "TOPLEFT", 16, -228)
    empty:SetWidth(W - 32)
    empty:SetJustifyH("LEFT")

    -- Notisene
    local rows = {}
    for i = 1, ROWS_PER_PAGE do
      local r = CreateFrame("Frame", nil, t)
      r:SetSize(W - 32, ROW_H)
      r:SetPoint("TOPLEFT", t, "TOPLEFT", 16, -TOP_ROWS - (i - 1) * ROW_H)
      r.hl = r:CreateTexture(nil, "BACKGROUND")
      r.hl:SetAllPoints(r)
      r.hl:SetColorTexture(0.45, 0.3, 0.12, 0)
      r.icon = r:CreateTexture(nil, "ARTWORK")
      r.icon:SetSize(36, 36)
      r.icon:SetPoint("TOPLEFT", r, "TOPLEFT", 0, -7)
      r.line = r:CreateFontString(nil, "OVERLAY")
      font(r.line, HEAD_FONT, 17, INK)
      r.line:SetPoint("TOPLEFT", r, "TOPLEFT", 44, -5)
      r.line:SetWidth(W - 32 - 44 - 112)
      r.line:SetJustifyH("LEFT")
      r.reason = r:CreateFontString(nil, "OVERLAY")
      font(r.reason, BODY_FONT, 12, INK_SOFT)
      r.reason:SetPoint("TOPLEFT", r.line, "BOTTOMLEFT", 0, -3)
      r.reason:SetWidth(W - 32 - 44 - 112)
      r.reason:SetJustifyH("LEFT")
      r.sep = r:CreateTexture(nil, "ARTWORK")
      r.sep:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 0, 0)
      r.sep:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", 0, 0)
      r.sep:SetHeight(1)
      r.sep:SetColorTexture(INK[1], INK[2], INK[3], 0.3)
      r.button = inkButton(r, "SparkmackTodoButton" .. i, 104, 28, nil, 15)
      r.button:SetPoint("RIGHT", r, "RIGHT", 0, 4)
      if r.EnableMouse then r:EnableMouse(true) end
      r:SetScript("OnEnter", function()
        r.hl:SetColorTexture(0.45, 0.3, 0.12, 0.12)
        r.line:SetTextColor(OXBLOOD[1], OXBLOOD[2], OXBLOOD[3])
        if r.itemId then showItemTooltip(r, r.itemId, r.itemKey) end
      end)
      r:SetScript("OnLeave", function()
        r.hl:SetColorTexture(0.45, 0.3, 0.12, 0)
        r.line:SetTextColor(INK[1], INK[2], INK[3])
        hideTooltip()
      end)
      rows[i] = r
    end

    -- Blaing i lista (bare når den trengs) rett over bunnstreken; sidetall og kursgrunnlag under
    local function textButton(name, label)
      local b = CreateFrame("Button", name, t)
      b:SetSize(72, 16)
      local fs = b:CreateFontString(nil, "OVERLAY")
      font(fs, HEAD_FONT, 13, INK)
      fs:SetPoint("CENTER", b, "CENTER", 0, 0)
      if b.SetFontString then b:SetFontString(fs) end
      b.label = fs
      b:SetScript("OnEnter", function() fs:SetTextColor(OXBLOOD[1], OXBLOOD[2], OXBLOOD[3]) end)
      b:SetScript("OnLeave", function() fs:SetTextColor(INK[1], INK[2], INK[3]) end)
      b:SetText(label)
      return b
    end
    local pagerY = -ROWS_END - 4
    local nextb = textButton("SparkmackPageNext", "neste ›")
    nextb:SetPoint("TOPRIGHT", t, "TOPRIGHT", -14, pagerY)
    nextb:SetScript("OnClick", function() paperSound("turn") ui.page = (ui.page or 1) + 1 refreshTodo() end)
    local pageText = t:CreateFontString(nil, "OVERLAY")
    font(pageText, BODY_FONT, 11, INK_SOFT)
    pageText:SetPoint("RIGHT", nextb, "LEFT", -4, 0)
    local prev = textButton("SparkmackPagePrev", "‹ forrige")
    prev:SetPoint("RIGHT", pageText, "LEFT", -4, 0)
    prev:SetScript("OnClick", function() paperSound("turn") ui.page = math.max(1, (ui.page or 1) - 1) refreshTodo() end)
    rule(t, pagerY - 20, 2)
    folio(t, 1)
    local basis = t:CreateFontString("SparkmackBasisText", "OVERLAY")
    font(basis, BODY_FONT, 9, INK_SOFT)
    basis:SetPoint("BOTTOMLEFT", t, "BOTTOMLEFT", 16, 14)
    ui.basis = basis

    local grip = CreateFrame("Button", "SparkmackTodoGrip", t)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", -4, 4)
    grip.tex = grip:CreateTexture(nil, "OVERLAY")
    grip.tex:SetAllPoints(grip)
    grip.tex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip.tex:SetVertexColor(0.45, 0.32, 0.16)
    grip:SetScript("OnMouseDown", function()
      local x = GetCursorPosition()
      grip.startX, grip.startScale = x, DB.ui and DB.ui.scale or 1
      grip:SetScript("OnUpdate", function()
        local cx = GetCursorPosition()
        local screenW = W * UIParent:GetEffectiveScale()
        setGazetteScale(t, grip.startScale + (cx - grip.startX) / screenW)
      end)
    end)
    grip:SetScript("OnMouseUp", function() grip:SetScript("OnUpdate", nil) end)

    ui.todo, ui.todoInfo, ui.todoEmpty, ui.todoRows = t, dateline, empty, rows
    ui.tabs, ui.summary, ui.pageText, ui.prev, ui.next = tabs, summary, pageText, prev, nextb
    ui.tab, ui.page = "todo", 1

    if DB.ui and DB.ui.scale then t:SetScale(DB.ui.scale) end
    local pos = DB.ui and DB.ui.gazette
    if pos and pos.point then
      t:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    elseif AuctionHouseFrame and AuctionHouseFrame.GetRight then
      t:SetPoint("TOPLEFT", UIParent, "TOPLEFT", (AuctionHouseFrame:GetRight() or 700) + 8, -80)
    else
      t:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
    end
  end
  -- Ved AH er det alltid forsiden som ligger øverst: der sitter budet og trykken
  if ui.spread and ui.spread:IsShown() then ui.spread:Hide() end
  ui.todo:Show()
  if updateOpenButton then updateOpenButton() end
  if idleStatus then idleStatus() end          -- riktig status hver gang avisen åpnes
  if ui.needTicker == nil then ui.needTicker = true end
  if ui.needTicker and statusTicker then
    ui.needTicker = false
    statusTicker()
  end
end

-- Én notis
local function fillRow(r, icon, line, reason, buttonText, onClick, itemId, itemKey)
  r.itemId, r.itemKey = itemId, itemKey
  r.icon:SetTexture(icon)
  r.line:SetText(line)
  r.reason:SetText(reason or "")
  if buttonText then
    r.button:SetText(buttonText)
    r.button:SetScript("OnClick", onClick)
    r.button:Enable()
    r.button:Show()
  else
    r.button:Hide()
  end
  r:Show()
end

local function pageOf(list)
  local pages = math.max(1, math.ceil(#list / ROWS_PER_PAGE))
  ui.page = math.min(math.max(1, ui.page or 1), pages)
  ui.pageText:SetText(("%d av %d"):format(ui.page, pages))
  local many = pages > 1
  for _, x in ipairs({ ui.prev, ui.next, ui.pageText }) do if many then x:Show() else x:Hide() end end
  if ui.page > 1 then ui.prev:Enable() else ui.prev:Disable() end
  if ui.page < pages then ui.next:Enable() else ui.next:Disable() end
  local first = (ui.page - 1) * ROWS_PER_PAGE
  return first, math.min(#list, first + ROWS_PER_PAGE)
end

-- «Til auksjon»: dine auksjoner i dette markedet, med status mot billigste konkurrent
local function saleList(input)
  local out, total = {}, 0
  local cfgMine = {}
  for _, a in ipairs(input and input.mine or {}) do cfgMine[#cfgMine + 1] = a end
  local st = charState()
  eachLine(st.owned and st.owned.rows, function(line)
    local aid, id, v, q, p, _, tl, status = line:match("^(%d+),(%d+),([^,]*),(%d+),(%d+),(%d+),(%d+),(%d+)")
    if aid then
      local key = id .. ":" .. v
      local item = input and input.items[key] or {}
      local mine = {}
      for _, a in ipairs(cfgMine) do if a.item_id .. ":" .. a.variant == key then mine[#mine + 1] = a end end
      local comp = SparkmackTodo.competitors(item.listings or {}, mine)
      local cheapest = comp[1] and comp[1].price
      local x = { item_id = tonumber(id), variant = v, qty = tonumber(q), price = tonumber(p), time_left_s = tonumber(tl),
        sold = status == "1", name = (DB.items[tonumber(id)] or {})[1], quality = (DB.items[tonumber(id)] or {})[2] }
      if x.sold then
        x.status = "|cff1d5a1dSolgt|r – pengene venter i posten"
      elseif cheapest and cheapest < x.price then
        x.status = "|cff8a2a1aUnderbudt|r – billigste er " .. SparkmackTodo.money(cheapest)
      else
        x.status = "Billigst på torget"
      end
      if not x.sold then total = total + x.qty * x.price end
      out[#out + 1] = x
    end
  end)
  table.sort(out, function(a, b) return (a.qty * a.price) > (b.qty * b.price) end)
  return out, total
end

refreshTodo = function()
  refreshSpread()
  if not ui.todo or not ui.todo:IsShown() then return end
  local input, md, scanRec = todoInput()
  local rows = ui.todoRows
  for _, r in ipairs(rows) do r:Hide() end
  ui.todoInfo:SetText(datelineText(md, scanRec))
  local basis = md or marketData()   -- Data.lua finnes også før første skanning
  if ui.basis then ui.basis:SetText(basis and ("Kursgrunnlag v" .. (basis.version or "–")) or "Kursgrunnlag mangler") end
  for id, b in pairs(ui.tabs) do
    local c = id == ui.tab and INK or INK_SOFT
    b.label:SetTextColor(c[1], c[2], c[3])
  end
  if DB.unsaved then
    ui.save.locked = true
    ui.save.paint(true)
  end
  ui.todoEmpty:SetText("")

  if ui.tab == "sale" then
    local list, total = saleList(input)
    ui.summary:SetText(("%d auksjoner ute · verdi %s"):format(#list, SparkmackTodo.money(total)))
    if #list == 0 then
      ui.todoEmpty:SetText("Ingenting på auksjon. Åpne fanen «Auctions» ved AH én gang, så noterer budet dine auksjoner.")
      pageOf(list)
      return
    end
    local first, last = pageOf(list)
    for i = first + 1, last do
      local x = list[i]
      fillRow(rows[i - first], itemIcon(x.item_id),
        ("%s  %d × %s"):format(inkName(x.name or ("Vare #" .. x.item_id), x.quality), x.qty, SparkmackTodo.money(x.price)),
        x.status .. ("  ·  %s igjen  ·  i alt %s"):format(timeLeft(x.time_left_s), SparkmackTodo.money(x.qty * x.price)),
        nil, nil, x.item_id, x.item_id .. ":" .. x.variant)
    end
    return
  end

  if not input then
    ui.summary:SetText("")
    ui.todoEmpty:SetText("Ingen kurser fra dette markedet ennå. Send ut budet, kompis!")
    pageOf({})
    return
  end
  local list = SparkmackTodo.build(input)
  local acts, gain = 0, 0
  for _, x in ipairs(list) do if x.action ~= "HOLD" then acts = acts + 1 gain = gain + x.gain end end
  ui.summary:SetText(("%d råd · forventet %s"):format(acts, SparkmackTodo.money(gain)))
  if #list == 0 then
    ui.todoEmpty:SetText(md and "Ingenting å gjøre akkurat nå. Du er billigst, og ingenting i bagen lønner seg. Hvil vingene, kompis."
      or "Mangler grunnverdier (Data.lua). Send til trykken, så skriver watcheren dem.")
    pageOf(list)
    return
  end
  local first, last = pageOf(list)
  for i = first + 1, last do
    local x = list[i]
    local price = x.action == "REPOST" and (SparkmackTodo.money(x.old_price) .. " → " .. SparkmackTodo.money(x.price))
      or SparkmackTodo.money(x.price)
    local line = ("%s  %s  %d × %s%s"):format(ACTION_TEXT[x.action], inkName(x.name or ("Vare #" .. x.item_id), x.quality),
      x.qty, price, x.gain > 0 and ("  |cff1d5a1d+" .. SparkmackTodo.money(x.gain) .. "|r") or "")
    local r = rows[i - first]
    if x.action == "POST" and not x.done then
      fillRow(r, itemIcon(x.item_id), line, x.reason, "Legg ut", function()
        local ok, sent = pcall(doPost, x, input.settings, r.button)
        if not ok then logError("Legg ut", sent) elseif sent then r.button:Disable() end
      end, x.item_id, x.key)
    elseif x.action == "REPOST" and not x.done then
      fillRow(r, itemIcon(x.item_id), line, x.reason, "Kanseller", function()
        local ok, sent = pcall(doCancel, x, r.button)
        if not ok then logError("Kanseller", sent) elseif sent then r.button:Disable() end
      end, x.item_id, x.key)
    else
      fillRow(r, itemIcon(x.item_id), line, x.reason, nil, nil, x.item_id, x.key)
    end
  end
end

-- Hva statuslinja sier når budet ikke er ute og ingen handling venter på svar
idleStatus = function()
  if scan or pending or not ui.status then return end
  if DB.unsaved then
    setStatus("Ferske kurser venter – send dem til trykken!", 1)
    return
  end
  local left = DB.lastAnswer and (COOLDOWN - (time() - DB.lastAnswer)) or 0
  if isModern() and left > 0 then
    local m = math.ceil(left / 60)
    setStatus(m <= 1 and "Budet hviler beina – klar om under ett minutt." or ("Budet hviler beina – klar om %d min."):format(m), 0)
  else
    setStatus("Klar til å sende ut budet.", 0)
  end
end

statusTicker = function()
  if C_Timer.NewTicker then
    C_Timer.NewTicker(5, function() if ui.todo and ui.todo:IsShown() then idleStatus() end end)
    return
  end
  C_Timer.After(5, function()   -- eldre klienter: egne tidtakere, stopper når avisen er lukket
    if ui.todo and ui.todo:IsShown() then idleStatus() statusTicker() else ui.needTicker = true end
  end)
end

-- Knappen rett til høyre for AH-vinduet: åpner avisen igjen når den er lukket og AH fortsatt er åpent
updateOpenButton = function()
  local ah = ahFrame()
  if not ah then return end
  if not ui.open then
    local b = CreateFrame("Button", "SparkmackOpenButton", ah)
    b:SetSize(40, 40)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(b)
    bg:SetColorTexture(PAPER[1], PAPER[2], PAPER[3], 1)
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
      local e = b:CreateTexture(nil, "BORDER")
      if side == "TOP" or side == "BOTTOM" then
        e:SetPoint(side .. "LEFT", b, side .. "LEFT", 0, 0) e:SetPoint(side .. "RIGHT", b, side .. "RIGHT", 0, 0) e:SetHeight(2)
      else
        e:SetPoint("TOP" .. side, b, "TOP" .. side, 0, 0) e:SetPoint("BOTTOM" .. side, b, "BOTTOM" .. side, 0, 0) e:SetWidth(2)
      end
      e:SetColorTexture(0.35, 0.24, 0.1, 1)
    end
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", b, "TOPLEFT", 4, -4)
    b.icon:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -4, 4)
    local tex = "Interface\\Icons\\INV_Misc_Book_09"
    if GetFileIDFromPath then
      local ok, id = pcall(GetFileIDFromPath, tex)
      if not (ok and id) then tex = "Interface\\Icons\\INV_Misc_Note_01" end
    end
    b.icon:SetTexture(tex)
    if b.icon.SetDesaturated then b.icon:SetDesaturated(true) end
    b.icon:SetVertexColor(0.66, 0.48, 0.27)
    b:SetScript("OnEnter", function()
      b.icon:SetVertexColor(OXBLOOD[1] + 0.3, OXBLOOD[2] + 0.15, OXBLOOD[3] + 0.1)
      if GameTooltip then
        GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Sparkmack's Kurstidende", 1, 0.82, 0)
        GameTooltip:AddLine("Åpne avisen igjen", 1, 1, 1)
        GameTooltip:Show()
      end
    end)
    b:SetScript("OnLeave", function() b.icon:SetVertexColor(0.66, 0.48, 0.27) hideTooltip() end)
    b:SetScript("OnClick", function()
      DB.ui = DB.ui or {}
      DB.ui.gazetteHidden = false
      paperSound("open")
      ensureTodoFrame()
      refreshTodo()
    end)
    ui.open = b
  end
  ui.open:SetParent(ah)
  ui.open:ClearAllPoints()
  ui.open:SetPoint("TOPLEFT", ah, "TOPRIGHT", 6, -4)
  local shown = (ui.todo and ui.todo:IsShown()) or (ui.spread and ui.spread:IsShown())
  if ahOpen() and not shown then ui.open:Show() else ui.open:Hide() end
end

local function toggleGazette()
  if ui.todo and ui.todo:IsShown() then
    ui.todo:Hide()
    DB.ui = DB.ui or {}
    DB.ui.gazetteHidden = true
  else
    DB.ui = DB.ui or {}
    DB.ui.gazetteHidden = false
    ensureTodoFrame()
    refreshTodo()
  end
  updateOpenButton()
end

-- ── Hendelser ────────────────────────────────────────────────────────────
local handle
local f = CreateFrame("Frame")
for _, e in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_LOGOUT", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
  "AUCTION_ITEM_LIST_UPDATE", "REPLICATE_ITEM_LIST_UPDATE", "GET_ITEM_INFO_RECEIVED", "OWNED_AUCTIONS_UPDATED",
  "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "BAG_UPDATE_DELAYED", "UI_ERROR_MESSAGE", "AUCTION_HOUSE_AUCTION_CREATED",
  "AUCTION_HOUSE_POST_ERROR", "AUCTION_CANCELED", "MAIL_INBOX_UPDATE" }) do
  pcall(f.RegisterEvent, f, e)
end
f:SetScript("OnEvent", function(_, event, ...)
  local ok, err = pcall(handle, event, ...)
  if not ok then logError(event, err) end
end)

handle = function(event, arg1, arg2)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    SparkmackDB = SparkmackDB or {}
    DB = SparkmackDB
    DB.scans = DB.scans or {}
    DB.items = DB.items or {}
    DB.state = DB.state or {}
    DB.firstSeen = DB.firstSeen or {}
    DB.ledger = DB.ledger or {}
    DB.scanCount = DB.scanCount or #DB.scans
    DB.version = VERSION
  elseif not DB then
    return
  elseif event == "PLAYER_LOGIN" then
    -- Etter reload er kursene skrevet til disk; watcheren tar det herfra
    DB.unsaved = false
    say("ready")
    C_Timer.After(5, function() pcall(snapshotBags) end)
  elseif event == "PLAYER_LOGOUT" then
    DB.unsaved = false
    pcall(snapshotBags)
  elseif event == "AUCTION_HOUSE_SHOW" then
    paperSound("open")
    -- Avisen åpnes alltid ved AH: der sitter knappene for budet og trykken
    ensureTodoFrame()
    pcall(snapshotBags)
    refreshTodo()
    -- Be om egne auksjoner (lesing, ingen handling). Svaret kommer som OWNED_AUCTIONS_UPDATED.
    if C_AuctionHouse and C_AuctionHouse.QueryOwnedAuctions then pcall(C_AuctionHouse.QueryOwnedAuctions, {}) end
  elseif event == "OWNED_AUCTIONS_UPDATED" then
    snapshotOwned()
    refreshTodo()
  elseif event == "UI_ERROR_MESSAGE" or event == "AUCTION_HOUSE_AUCTION_CREATED" or event == "AUCTION_HOUSE_POST_ERROR"
      or event == "AUCTION_CANCELED" then
    onActionEvent(event, arg1, arg2)
  elseif event == "BAG_UPDATE_DELAYED" then
    onActionEvent(event, arg1, arg2)
    if ahOpen() then
      pcall(snapshotBags)
      refreshTodo()
    end
  elseif event == "BANKFRAME_OPENED" or event == "BANKFRAME_CLOSED" then
    snapshotBank()
  elseif event == "AUCTION_HOUSE_CLOSED" then
    if scan and scan.waiting then scan = nil end
    if DB.unsaved then say("unsaved") end
  elseif event == "AUCTION_ITEM_LIST_UPDATE" or event == "REPLICATE_ITEM_LIST_UPDATE" then
    onScanData()
  elseif event == "MAIL_INBOX_UPDATE" then
    local added = readMailbox()
    if added > 0 then
      msg(("Budet har ført %d nye handler inn i protokollen."):format(added))
      if refreshTodo then refreshTodo() end
    end
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    if arg1 and pendingItems[arg1] and arg2 ~= false then rememberItem(arg1) end
  end
end

SLASH_SPARKMACK1 = "/sparkmack"
SLASH_SPARKMACK2 = "/spm"
SlashCmdList.SPARKMACK = function(input)
  local cmd = (input or ""):lower():match("^%s*(%S*)")
  if cmd == "skann" or cmd == "scan" then
    startScan()
  elseif cmd == "lagre" or cmd == "save" then
    saveAndReload()
  elseif cmd == "avis" or cmd == "gazette" then
    toggleGazette()
  else
    local last = DB.scans[#DB.scans]
    msg(("v%s · %d skanninger notert%s · /spm skann · /spm lagre · /spm avis"):format(VERSION, #DB.scans,
      last and (", siste " .. date("%H:%M", last.started) .. " (" .. last.rows .. " auksjoner)") or ""))
  end
end
