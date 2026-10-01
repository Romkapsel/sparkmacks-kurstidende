-- Sparkmack's Market Probe – WoW Forever.
-- Sparkmack's Kurstidende – finansavisen fra 1890 for WoW Forever. Sparkmack, en sleip og pengegrisk goblin,
-- sender budet sitt til AH etter dagens kurser. «Send ut budet» = full skanning, «Send til trykken!» skriver til disk (reload),
-- og watcheren på PC-en laster opp. Addonen kjøper, poster og kansellerer ingenting.

local ADDON = "Sparkmack"
local VERSION = "1.13.1"
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
local ui = { qty = {} }   -- qty: antallet du har valgt per vare («itemId:variant»)
local refreshTodo   -- «Å gjøre»-lista; settes lenger ned
local recordHistory -- egen kursbok; settes lenger ned

-- Beløp med gull-, sølv- og kobbermynt, slik spillet selv viser penger. Todo.lua skriver «1g 23s 45c» ord for ord
-- likt nettsiden (paritetstesten); bokstavene byttes med mynter først når teksten vises.
local COIN = {
  g = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t",
  s = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t",
  c = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t",
}
local function coinify(text)
  if type(text) ~= "string" then return text end
  return (text:gsub("%f[%w](%d+)([gsc])%f[^%w]", function(n, unit) return n .. COIN[unit] end))
end
local function coins(copper) return coinify(SparkmackTodo.money(copper)) end
local idleStatus, statusTicker   -- statuslinja når ingenting skjer; settes lenger ned
-- Ferske priser: «itemId:variant» → { at = tid, listings = {{pris, antall, tidsbøtte}, …} } fra et søk på én vare
-- (vårt eget eller Auctionators). Bare i minnet – gjelder dette AH-besøket.
local fresh = {}
local priceCheck              -- søket som venter på svar fra serveren
local updateOpenButton           -- knappen ved AH som åpner avisen igjen; settes lenger ned
-- Linjer i et tekstfelt (heltall, så plasseringen ikke hopper når avisen skaleres)
local function textLines(fs)
  local t = fs.GetText and fs:GetText()
  if not t or t == "" then return 0 end
  local n = fs.GetNumLines and fs:GetNumLines()
  return (type(n) == "number" and n >= 1) and n or 1
end

-- Statusteksten og framdriftsstreken under den sentreres sammen midt på «Send ut budet»-knappene
local STATUS_MID, STATUS_LINE_H = -140, 14
local function layoutStatus()
  local st, track = ui.status, ui.track
  if not (st and track and ui.todo) then return end
  local busy = track:IsShown()
  local textH = math.max(1, textLines(st)) * STATUS_LINE_H
  local total = textH + (busy and 8 or 0)
  local top = STATUS_MID + total / 2
  st:ClearAllPoints()
  st:SetPoint("TOPLEFT", ui.todo, "TOPLEFT", 16, top)
  track:ClearAllPoints()
  track:SetPoint("TOPLEFT", ui.todo, "TOPLEFT", 16, top - textH - 4)
end

local function setStatus(text, progress)
  if ui.status then ui.status:SetText(text) end
  if ui.bar and progress then
    ui.bar:SetValue(progress)
    local busy = progress > 0 and progress < 1
    for _, x in ipairs({ ui.bar, ui.track }) do if busy then x:Show() else x:Hide() end end
  end
  layoutStatus()
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
  if recordHistory then
    local ok, err = pcall(recordHistory, record)
    if not ok then logError("kursbok", err) end
  end
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

local function marketKey(realm, faction) return (realm or "?") .. "|" .. (faction or "?") end

-- Grunnverdiene watcheren skrev (bare hos den som har nettsiden)
local function dataLua()
  local key = marketKey(GetRealmName(), UnitFactionGroup("player"))
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

-- Egen kursbok: addonen regner 7-dagers median og omsetning av sine egne skanninger, med samme metode som
-- databasen (wow.aggregate_scan og wow.base_values). Brukes når Data.lua ikke har noe for markedet – altså hos
-- kompiser uten watcher og nettside. Lagres per marked, per døgn (UTC), per vare som
-- «billigste,sum av medianer,antall skanninger,solgt,minutter målt». Åtte døgn beholdes.
local HIST_DAYS = 8
local MIN_LEFT = { [1] = 0, [2] = 30, [3] = 120, [4] = 720 }   -- tidsbøttene: kan ikke ha utløpt før dette (min)

local function previousScan(rec)
  for i = #DB.scans, 1, -1 do
    local p = DB.scans[i]
    if p.realm == rec.realm and p.faction == rec.faction and p.complete and p.kind ~= "replicate-cached"
      and p.key ~= rec.key and (p.started or 0) < rec.started then return p end
  end
end

local function unpackDay(v)
  local mn, ms, mc, so, gp = (v or ",,,,"):match("^([^,]*),([^,]*),([^,]*),([^,]*),([^,]*)$")
  return tonumber(mn), tonumber(ms) or 0, tonumber(mc) or 0, tonumber(so) or 0, tonumber(gp)
end

recordHistory = function(rec)
  if not rec.complete or rec.kind == "replicate-cached" or (rec.rows or 0) == 0 then return end
  DB.hist = DB.hist or {}
  local mk = marketKey(rec.realm, rec.faction)
  local H = DB.hist[mk] or { days = {} }
  DB.hist[mk] = H
  if H.lastKey == rec.key then return end
  local prev = previousScan(rec)
  local gap = prev and math.floor((rec.started - prev.started) / 60 + 0.5)
  if gap and gap > 24 * 60 then prev, gap = nil, nil end

  -- Denne skanningen: priser per vare, og «signaturer» (vare, antall, pris) til salgsanslaget
  local cur, curSig = {}, {}
  eachLine(rec.data, function(line)
    local id, v, q, p = line:match("^(%d+),([^,]*),(%d+),(%d+)")
    if id then
      local k = id .. ":" .. v
      local c = cur[k]
      if not c then c = {} cur[k] = c end
      p = tonumber(p)
      if p > 0 then c[#c + 1] = p end
      if prev then local sig = k .. "|" .. tonumber(q) .. "|" .. p curSig[sig] = (curSig[sig] or 0) + 1 end
    end
  end)

  -- Salgsanslag: forsvant siden forrige skanning og kunne ikke ha utløpt → solgt,
  -- med mindre samme vare og antall dukket opp til en ny pris (omprising)
  local sold = {}
  if prev then
    local prevSig = {}
    eachLine(prev.data, function(line)
      local id, v, q, p, _, tl = line:match("^(%d+),([^,]*),(%d+),(%d+),(%d+),(%d+)")
      if id then
        local sig = id .. ":" .. v .. "|" .. tonumber(q) .. "|" .. tonumber(p)
        local e = prevSig[sig]
        if not e then e = { 0, 0 } prevSig[sig] = e end
        e[1] = e[1] + 1
        if (MIN_LEFT[tonumber(tl)] or 0) > gap then e[2] = e[2] + 1 end
      end
    end)
    local gone, fresh = {}, {}
    for sig, e in pairs(prevSig) do
      local n = e[2] - (curSig[sig] or 0)
      if n > 0 then local kq = sig:match("^(.*)|") gone[kq] = (gone[kq] or 0) + n end
    end
    for sig, n in pairs(curSig) do
      local e = prevSig[sig]
      n = n - (e and e[1] or 0)
      if n > 0 then local kq = sig:match("^(.*)|") fresh[kq] = (fresh[kq] or 0) + n end
    end
    for kq, n in pairs(gone) do
      local k, q = kq:match("^(.*)|(%d+)$")
      local left = n - math.min(n, fresh[kq] or 0)
      if left > 0 then sold[k] = (sold[k] or 0) + left * tonumber(q) end
    end
  end

  local day = date("!%Y-%m-%d", rec.started)
  local D = H.days[day] or {}
  H.days[day] = D
  local function add(k, prices)
    local mn, ms, mc, so, gp = unpackDay(D[k])
    if prices and #prices > 0 then
      table.sort(prices)
      mn = math.min(mn or prices[1], prices[1])
      ms, mc = ms + prices[math.ceil(#prices / 2)], mc + 1
    end
    if prev then so, gp = so + (sold[k] or 0), (gp or 0) + gap end
    D[k] = (mn or "") .. "," .. ms .. "," .. mc .. "," .. so .. "," .. (gp or "")
  end
  for k, prices in pairs(cur) do add(k, prices) end
  for k, n in pairs(sold) do if not cur[k] and n > 0 then add(k, nil) end end   -- utsolgt: sterkeste salgssignal
  local oldest = date("!%Y-%m-%d", rec.started - (HIST_DAYS - 1) * 86400)
  for d in pairs(H.days) do if d < oldest then H.days[d] = nil end end
  H.lastKey, H.lastAt, H.version = rec.key, rec.started, (H.version or 0) + 1
end

-- Medianen slik Postgres' percentile_cont(0.5) regner den
local function medianCont(list)
  if #list == 0 then return nil end
  table.sort(list)
  local pos = (#list - 1) * 0.5 + 1
  local lo = math.floor(pos)
  return list[lo] + (list[math.min(lo + 1, #list)] - list[lo]) * (pos - lo)
end

-- Kursboka i samme form som Data.lua: «itemId:variant» → {vendor, stack, solgt, timer, 7-dagers median, flagg, billigste nå}
local ownCache = {}
local function ownMarket()
  local mk = marketKey(GetRealmName(), UnitFactionGroup("player"))
  local H = DB.hist and DB.hist[mk]
  if not (H and H.lastAt and next(H.days)) then return nil end
  if ownCache.mk == mk and ownCache.v == H.version then return ownCache.m end
  local today = date("!%Y-%m-%d", H.lastAt)
  local from7 = date("!%Y-%m-%d", H.lastAt - 7 * 86400)
  local acc, ndays = {}, 0
  for d, D in pairs(H.days) do
    if d > from7 then ndays = ndays + 1 end
    for k, v in pairs(D) do
      local mn, ms, mc, so, gp = unpackDay(v)
      local a = acc[k]
      if not a then a = { meds = {}, mins = {}, sold = 0 } acc[k] = a end
      if d > from7 then
        if mc > 0 then a.meds[#a.meds + 1] = math.floor(ms / mc + 0.5) end
        if gp then a.sold, a.gap = a.sold + so, (a.gap or 0) + gp end
      end
      if mn and d >= from7 and d < today then a.mins[#a.mins + 1] = mn end
    end
  end
  local by = latestListings()
  local items = {}
  for k, a in pairs(acc) do
    local known = DB.items[tonumber(k:match("^(%d+)"))] or {}
    local med7 = medianCont(a.meds)
    local minNow = by and by[k] and by[k][1] and by[k][1][1]
    local flag
    if #a.mins >= 3 and minNow then
      local m = medianCont(a.mins)
      if minNow <= m * 0.8 then flag = "billig" elseif minNow >= m * 1.25 then flag = "dyrt" end
    end
    items[k] = { known[3] or 0, known[4] or 0, a.gap and a.sold or nil, a.gap and math.floor(a.gap / 60 * 1000 + 0.5) / 1000 or nil,
      med7 and math.floor(med7 * 10 + 0.5) / 10 or nil, flag, minNow }
  end
  local m = { own = true, days = ndays, settings = {}, items = items }
  ownCache.mk, ownCache.v, ownCache.m = mk, H.version, m
  return m
end

-- Data.lua når den har noe for markedet (samme tall som nettsiden), ellers egen kursbok
local function marketData()
  local md = dataLua()
  if md and md.items and next(md.items) then return md end
  return ownMarket() or md
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
    local listings = by[k] or {}
    if fresh[k] and (not scanRec or fresh[k].at >= (scanRec.started or 0)) then listings = fresh[k].listings end
    local item = { item_id = tonumber(id), variant = v, name = known[1], quality = known[2], listings = listings,
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

-- ── Fersk pris før du legger ut ──────────────────────────────────────────
-- Skanningen blir fort gammel. Før «Legg ut» eller «Kanseller» spør Sparkmack serveren om dagens priser på akkurat
-- den varen (samme søk som AH-vinduet og Auctionator gjør når du trykker på en vare). Synlige råd sjekkes i bakgrunnen
-- mens avisen er oppe; er prisen eldre enn FRESH_SECONDS når du klikker, blir klikket en prissjekk i stedet for en
-- utlegging, og raden viser den nye prisen før du klikker igjen. Søk Auctionator gjør på varevarer fanges også opp.
-- Spillet krever ett klikk per utlegging, og søket svarer først etter klikket – så søk og utlegging kan ikke skje
-- i samme klikk. Derfor sjekkes prisen når musa kommer over «Legg ut» (HOVER_SECONDS), synlige råd hvert
-- BACKGROUND_SECONDS, og et klikk legger bare ut hvis prisen er sjekket siste POST_SECONDS.
local FRESH_SECONDS = 60       -- «Kanseller» og hva raden kaller fersk
local POST_SECONDS = 15        -- «Legg ut»: maks alder på prisen
local HOVER_SECONDS = 5        -- musa over «Legg ut»: sjekk på nytt hvis eldre enn dette
local BACKGROUND_SECONDS = 30  -- synlige råd sjekkes i bakgrunnen så ofte
local LOOKUP_TIMEOUT = 6
local lookupQueue, tried = {}, {}

local function canLookup()
  local A = C_AuctionHouse
  return isModern() and A and (A.SendSearchQuery or A.SendSellSearchQuery) ~= nil and A.GetNumCommoditySearchResults ~= nil
end

local function isFresh(key, maxAge)
  return fresh[key] ~= nil and time() - fresh[key].at <= (maxAge or FRESH_SECONDS)
end

local function bandOf(seconds)
  if not seconds then return 4 end
  if seconds <= 1800 then return 1 elseif seconds <= 7200 then return 2 elseif seconds <= 43200 then return 3 end
  return 4
end

local function storeFresh(key, listings)
  table.sort(listings, function(a, b) return a[1] < b[1] end)
  fresh[key] = { at = time(), listings = listings }
end

local function readCommodity(itemId)
  local A, out = C_AuctionHouse, {}
  for i = 1, (A.GetNumCommoditySearchResults(itemId) or 0) do
    local r = A.GetCommoditySearchResultInfo(itemId, i)
    if r and (r.unitPrice or 0) > 0 then out[#out + 1] = { r.unitPrice, r.quantity or 1, bandOf(r.timeLeftSeconds) } end
  end
  return out
end

-- Varer (ikke varevarer): samme vare kan ha ulike suffiks, så lenken må stemme med varianten.
-- buyoutAmount regnes per stk, som for egne auksjoner.
local function readItems(itemKey, variant)
  local A, out = C_AuctionHouse, {}
  for i = 1, (A.GetNumItemSearchResults and A.GetNumItemSearchResults(itemKey) or 0) do
    local r = A.GetItemSearchResultInfo(itemKey, i)
    if r and (r.buyoutAmount or 0) > 0 then
      local _, v = parseLink(r.itemLink)
      if not r.itemLink or (v or "0") == variant then
        out[#out + 1] = { r.buyoutAmount, r.quantity or 1, (r.timeLeft or 3) + 1 }
      end
    end
  end
  return out
end

-- itemKey til søket: fra varen i bagen (riktig suffiks), fra egen auksjon, ellers bare vare-ID
local function itemKeyFor(row)
  local A = C_AuctionHouse
  if row.action == "POST" and A.GetItemKeyFromItem then
    local bag, slot = findInBags(row.item_id, row.variant)
    if bag then
      local ok, key = pcall(A.GetItemKeyFromItem, ItemLocation:CreateFromBagAndSlot(bag, slot))
      if ok and key then return key end
    end
  end
  if row.auction_id and A.GetNumOwnedAuctions then
    for i = 1, (A.GetNumOwnedAuctions() or 0) do
      local a = A.GetOwnedAuctionInfo(i)
      if a and a.auctionID == row.auction_id and a.itemKey then return a.itemKey end
    end
  end
  return A.MakeItemKey and A.MakeItemKey(row.item_id) or { itemID = row.item_id, itemLevel = 0, itemSuffix = 0 }
end

local sendNextLookup

local function finishLookup(job, listings)
  if priceCheck ~= job then return end
  priceCheck = nil
  if listings then storeFresh(job.key, listings) end
  for _, cb in ipairs(job.done) do pcall(cb, listings ~= nil) end
  if refreshTodo then refreshTodo() end
  sendNextLookup()
end

sendNextLookup = function()
  if priceCheck or scan or not ahOpen() then return end
  local A = C_AuctionHouse
  if A.IsThrottledMessageSystemReady and not A.IsThrottledMessageSystemReady() then
    C_Timer.After(1, sendNextLookup)   -- serveren vil ha pust; AUCTION_HOUSE_THROTTLED_SYSTEM_READY kommer også
    return
  end
  local job = table.remove(lookupQueue, 1)
  if not job then return end
  priceCheck = job
  tried[job.key] = time()
  local order = Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0
  local send = A.SendSearchQuery or A.SendSellSearchQuery
  local ok = pcall(send, job.itemKey, { { sortOrder = order, reverseSort = false } }, false)
  if not ok then finishLookup(job, nil) return end
  C_Timer.After(LOOKUP_TIMEOUT, function() finishLookup(job, nil) end)
end

-- Be om fersk pris på en rad. Klikk går først i køen; bakgrunnssjekker hopper over det som nylig er prøvd.
local function requestPrice(row, urgent, done)
  if not canLookup() then return false end
  local job
  if priceCheck and priceCheck.key == row.key then job = priceCheck end
  for _, j in ipairs(lookupQueue) do if j.key == row.key then job = j end end
  if not job then
    if not urgent and tried[row.key] and time() - tried[row.key] < BACKGROUND_SECONDS then return false end
    job = { key = row.key, itemId = row.item_id, variant = row.variant or "0", itemKey = itemKeyFor(row), done = {} }
    if urgent then table.insert(lookupQueue, 1, job) else lookupQueue[#lookupQueue + 1] = job end
  elseif urgent and job ~= priceCheck then
    for i, j in ipairs(lookupQueue) do if j == job then table.remove(lookupQueue, i) break end end
    table.insert(lookupQueue, 1, job)
  end
  if urgent then job.urgent = true end
  if done then job.done[#job.done + 1] = done end
  sendNextLookup()
  return true
end

-- Rådene som står på siden nå: sjekk dem som har gammel pris
local function freshenVisible()
  if not (ui.visibleRows and ahOpen() and canLookup()) or scan then return end
  for _, x in ipairs(ui.visibleRows) do
    if not isFresh(x.key, BACKGROUND_SECONDS) then requestPrice(x, false) end
  end
end

local function onSearchResults(event, arg1)
  if not canLookup() then return end
  local job = priceCheck
  if event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
    local itemId = arg1
    if not itemId then return end
    if job and job.itemId == itemId then
      finishLookup(job, readCommodity(itemId))
    else   -- noen andre (AH-vinduet, Auctionator) søkte på en varevare: ta med prisen
      storeFresh(itemId .. ":0", readCommodity(itemId))
    end
  elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
    local itemKey = arg1
    if job and itemKey and itemKey.itemID == job.itemId then finishLookup(job, readItems(itemKey, job.variant)) end
  end
end

-- Klikk på en rad med gammel pris: sjekk prisen, vis den nye, og la neste klikk gjøre handlingen
local function checkPending(key)
  if priceCheck and priceCheck.key == key then return true end
  for _, j in ipairs(lookupQueue) do if j.key == key then return true end end
  return false
end

local function checkFirst(row, button, verb, maxAge)
  if not canLookup() then return false end
  -- En pris som er på vei (f.eks. fra musa over knappen) går foran den vi har: vent på den
  if not checkPending(row.key) and isFresh(row.key, maxAge) then return false end
  if button and button.Disable then button:Disable() end
  local name = row.name or ("vare #" .. row.item_id)
  setStatus("Sjekker dagens pris på " .. name .. " …", 0.5)
  requestPrice(row, true, function(ok)
    if button and button.Enable then button:Enable() end
    if ok then
      local f = fresh[row.key]
      local cheapest = f and f.listings[1] and f.listings[1][1]
      msg(("Fersk pris på %s: %s. Se over raden og trykk «%s» igjen – ingenting er gjort ennå.")
        :format(name, cheapest and ("billigste nå " .. coins(cheapest)) or "ingen andre har den ute", verb))
    else
      msg("Fikk ikke sjekket prisen på " .. name .. " – ingenting er gjort. Prøv igjen om litt.")
    end
    if idleStatus then idleStatus() end
  end)
  return true
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

local function isCommodityInBags(itemId, variant)
  local A = C_AuctionHouse
  local bag, slot = findInBags(itemId, variant)
  if not (bag and A and A.GetItemCommodityStatus and Enum and Enum.ItemCommodityStatus) then return false end
  local ok, st = pcall(A.GetItemCommodityStatus, ItemLocation:CreateFromBagAndSlot(bag, slot))
  return ok and st == Enum.ItemCommodityStatus.Commodity
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
    msg("Stopper: " .. coins(unit) .. " er for lavt for " .. (row.name or "varen") .. ". Ingenting er lagt ut.")
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
    say("broke", coins(dep), coins(GetMoney()))
    setStatus("For lite gull til depositen", 0)
    return false
  end
  local label = ("%d × %s %s"):format(qty, row.name or ("vare #" .. row.item_id), coins(unit))
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
    say("broke", coins(cost), coins(GetMoney()))
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
local ROWS_PER_PAGE = 6
local ROW_H = 84          -- plass per notis på en side (6 × 84); hver notis er så høy som innholdet + luft
local ROW_PAD = 10        -- luft over og under innholdet i en notis (= over og under streken mellom dem)
local BTN_W, BTN_H = 108, 30   -- «Legg ut» / «Kanseller»
local CAP_GAP = 2         -- fra toppen av tekstfeltet til toppen av bokstavene: ikonet flukter med teksten
local TOP_ROWS = 218      -- første notis starter her (under linja med antall råd)
local GAZETTE_W = 500
local INK = { 0.17, 0.11, 0.05 }          -- blekk
local INK_SOFT = { 0.36, 0.27, 0.16 }     -- blekk, dempet
local PAPER = { 0.86, 0.79, 0.63 }        -- avispapir
-- Morpheus bare i avishodet og seksjonstitlene: der er det pynt. Alt med tall, varenavn og store bokstaver står i
-- Friz Quadrata – i Morpheus ligner S på 8.
local HEAD_FONT = "Fonts\\MORPHEUS.TTF"   -- bare avisnavnet, som frakturen øverst på en gammel avis
-- Rubrikker (sidetitler, seksjoner, faner): Nimrod – WoWs egen avis-serif – i versaler, som overskriftene i en
-- avis fra 1890. Mangler den i klienten, Friz Quadrata (en ukjent fontsti gir usynlig tekst).
local function firstFont(candidates)
  if not GetFileIDFromPath then return candidates[#candidates] end
  for _, f in ipairs(candidates) do
    local ok, id = pcall(GetFileIDFromPath, f)
    if ok and id then return f end
  end
  return candidates[#candidates]
end
local TITLE_FONT = firstFont({ "Fonts\\NIM_____.ttf", "Fonts\\FRIZQT__.TTF" })
-- Skriftskala: avisnavn 33 (Morpheus) · sidetittel 26 · rubrikk og faner 16 · varenavn 15 (forsiden) / 14 (side 2–3)
-- · merkelapp 12 – alt i Nimrod. Tall og detaljer i Friz Quadrata: pris 13, grunn 11.
local SIZE = { page = 26, rubric = 16, headline = 15, smallHeadline = 14, tag = 12 }
local BODY_FONT = "Fonts\\FRIZQT__.TTF"
local OXBLOOD = { 0.48, 0.1, 0.06 }       -- hover: dyp rød blekk
local ACTION_TEXT = { POST = "|cff1d5a1dLEGG UT|r", REPOST = "|cff1d3f78OMPRIS|r", HOLD = "|cff5a4a3aLA STÅ|r" }
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

-- Knapp som en annonseramme i avisen: tykk ytre strek, tynn indre linje og svak trykksverte i bunnen.
-- Hover: oksblod med papirfarget tekst. Valgfritt tresnitt-ikon til venstre (b:SetIcon).
local function inkButton(parent, name, w, h, text, size)
  local b = CreateFrame("Button", name, parent)
  b:SetSize(w, h)
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints(b)
  local function frameLines(inset, thick, alpha)
    local lines = {}
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
      local e = b:CreateTexture(nil, "BORDER")
      if side == "TOP" or side == "BOTTOM" then
        local y = side == "TOP" and -inset or inset
        e:SetPoint(side .. "LEFT", b, side .. "LEFT", inset, y) e:SetPoint(side .. "RIGHT", b, side .. "RIGHT", -inset, y)
        e:SetHeight(thick)
      else
        local x = side == "LEFT" and inset or -inset
        e:SetPoint("TOP" .. side, b, "TOP" .. side, x, -inset) e:SetPoint("BOTTOM" .. side, b, "BOTTOM" .. side, x, inset)
        e:SetWidth(thick)
      end
      e:SetColorTexture(INK[1], INK[2], INK[3], alpha)
      lines[#lines + 1] = e
    end
    return lines
  end
  frameLines(0, 2, 0.9)
  b.inner = frameLines(4, 1, 0.55)
  local fs = b:CreateFontString(nil, "OVERLAY")
  font(fs, TITLE_FONT, (size or 14) - 1, INK)
  fs:SetPoint("CENTER", b, "CENTER", 0, 0)
  if b.SetFontString then b:SetFontString(fs) end
  b.label = fs
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(h - 12, h - 12)
  b.icon:SetPoint("LEFT", b, "LEFT", 9, 0)
  if b.icon.SetDesaturated then b.icon:SetDesaturated(true) end
  if b.icon.SetMask then pcall(b.icon.SetMask, b.icon, "Interface\\CharacterFrame\\TempPortraitAlphaMask") end
  b.icon:Hide()
  local function paint(hot)
    local text, line = hot and PAPER or INK, hot and PAPER or INK
    if hot then
      b.bg:SetColorTexture(OXBLOOD[1], OXBLOOD[2], OXBLOOD[3], 0.95)
      b.icon:SetVertexColor(PAPER[1], PAPER[2], PAPER[3])
    else
      b.bg:SetColorTexture(0.45, 0.33, 0.18, 0.14)   -- svak trykksverte
      b.icon:SetVertexColor(0.55, 0.38, 0.2)
    end
    fs:SetTextColor(text[1], text[2], text[3])
    for _, e in ipairs(b.inner) do e:SetColorTexture(line[1], line[2], line[3], hot and 0.7 or 0.55) end
  end
  -- Ikon til venstre (tresnitt i blekkbrunt), eller nil for bare tekst. Teksten sentreres i plassen som er igjen.
  function b:SetIcon(tex)
    fs:ClearAllPoints()
    -- En sti spillet ikke kjenner krasjer beta-klienten (ASSERT fileDataID) i stedet for å vise et tomt ikon:
    -- sjekk stien først, og vis bare tekst hvis den ikke finnes.
    if type(tex) == "string" and GetFileIDFromPath then
      local ok, id = pcall(GetFileIDFromPath, tex)
      if not (ok and id) then tex = nil end
    end
    if tex then
      b.icon:SetTexture(tex)
      b.icon:Show()
      fs:SetPoint("CENTER", b, "CENTER", (h - 12) / 2 + 2, 0)
    else
      b.icon:Hide()
      fs:SetPoint("CENTER", b, "CENTER", 0, 0)
    end
  end
  b:SetScript("OnEnter", function()
    if b:IsEnabled() ~= false then paint(true) end
    if b.onHover then pcall(b.onHover) end
  end)
  b:SetScript("OnLeave", function() paint(b.locked) end)
  b:SetScript("OnMouseDown", function() if b:IsEnabled() ~= false then b.label:SetPoint("CENTER", b, "CENTER", b.icon:IsShown() and ((h - 12) / 2 + 3) or 1, -1) end end)
  b:SetScript("OnMouseUp", function() b:SetIcon(b.icon:IsShown() and b.icon:GetTexture() or nil) end)
  b:SetScript("OnEnable", function() b:SetAlpha(1) end)
  b:SetScript("OnDisable", function() b:SetAlpha(0.4) paint(false) end)
  b.paint = paint
  paint(false)
  if text then b:SetText(text) end
  return b
end

-- Bla-knappen på siden av avisen: den runde, gylne pila fra spellboken, like stor som medaljongene i
-- avishodet. text = "<" (bla tilbake) eller ">" (bla fram).
local BOOKMARK_SIZE = 48
local function bookmarkButton(parent, name, text)
  local b = CreateFrame("Button", name, parent)
  b:SetSize(BOOKMARK_SIZE, BOOKMARK_SIZE)
  local base = "Interface\\Buttons\\UI-SpellbookIcon-" .. (text == "<" and "Prev" or "Next") .. "Page-"
  b.arrow = b:CreateTexture(nil, "ARTWORK")
  b.arrow:SetAllPoints(b)
  b.arrow:SetTexture(base .. "Up")
  local glow = b:CreateTexture(nil, "HIGHLIGHT")
  glow:SetAllPoints(b)
  glow:SetTexture("Interface\\Buttons\\UI-Common-MouseHilight")
  glow:SetBlendMode("ADD")
  b:SetScript("OnMouseDown", function() b.arrow:SetTexture(base .. "Down") end)
  b:SetScript("OnMouseUp", function() b.arrow:SetTexture(base .. "Up") end)
  return b
end

-- Sidetall nederst på hvert blad, som i en avis
local FOOT_Y = 17   -- midt mellom bunnstreken (34 over kanten) og kanten
local function folio(p, n)
  local f = p:CreateFontString(nil, "OVERLAY")
  font(f, BODY_FONT, 11, INK_SOFT)
  f:SetPoint("CENTER", p, "BOTTOM", 0, FOOT_Y)
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

-- Skalering: håndtak nede i høyre hjørne, eller Ctrl + musehjul – på forsiden og på oppslaget (side 2–3).
-- Øvre venstre hjørne på det vinduet du ser på, står stille.
local function scaleKeepingCorner(f, scale)
  local left, top = f:GetLeft(), f:GetTop()
  local oldEff = f:GetEffectiveScale()
  f:SetScale(scale)
  if left and top and oldEff then
    local eff = f:GetEffectiveScale()
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * oldEff / eff, top * oldEff / eff)
    return true
  end
end

local function setGazetteScale(t, scale)
  scale = math.max(0.6, math.min(1.6, scale))
  if t and scaleKeepingCorner(t, scale) then savePosition(t) end
  local sp = ui.spread
  if sp then
    if sp:IsShown() then scaleKeepingCorner(sp, scale) else sp:SetScale(scale) end
  end
  DB.ui = DB.ui or {}
  DB.ui.scale = scale
  if ui.relayout and C_Timer and C_Timer.After then C_Timer.After(0, ui.relayout) end
end

-- Håndtaket: dra hjørnet, så følger hjørnet musa (width = bredden på vinduet håndtaket sitter på)
local function makeGrip(parent, name, width)
  local grip = CreateFrame("Button", name, parent)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -4, 4)
  grip.tex = grip:CreateTexture(nil, "OVERLAY")
  grip.tex:SetAllPoints(grip)
  grip.tex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip.tex:SetVertexColor(0.45, 0.32, 0.16)
  grip:SetScript("OnMouseDown", function()
    local x = GetCursorPosition()
    grip.startX, grip.startScale = x, DB.ui and DB.ui.scale or 1
    grip:SetScript("OnUpdate", function()
      local cx = GetCursorPosition()
      local screenW = width * UIParent:GetEffectiveScale()
      setGazetteScale(ui.todo, grip.startScale + (cx - grip.startX) / screenW)
    end)
  end)
  grip:SetScript("OnMouseUp", function() grip:SetScript("OnUpdate", nil) end)
  return grip
end

-- Klikk på en vare: søk den opp i AH hvis det er åpent (det du ellers ville limt inn), ellers vis navnet
-- ferdig markert, så Ctrl+C kopierer det. Addons kan ikke skrive til Windows' utklippstavle selv.
local function itemNameOf(id, shown)
  if shown and shown ~= "" then return shown end   -- navnet som står på raden
  local known = id and DB.items and DB.items[id]
  if known and known[1] then return known[1] end
  local fn = GetItemInfo or (C_Item and C_Item.GetItemInfo)
  return id and fn and fn(id) or nil
end

local function ahSearchBox()
  local ah = AuctionHouseFrame
  local bar = type(ah) == "table" and ah.IsShown and ah:IsShown() and ah.SearchBar
  if type(bar) == "table" and type(bar.SearchBox) == "table" then return "modern", bar end
  if type(AuctionFrame) == "table" and AuctionFrame.IsShown and AuctionFrame:IsShown() and type(BrowseName) == "table" then
    return "legacy", BrowseName
  end
end

local copyBox
local function showCopyBox(name, owner)
  if not copyBox then
    local f = CreateFrame("Frame", "SparkmackCopyBox", UIParent)
    f:SetSize(260, 52)
    f:SetFrameStrata("DIALOG")
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetColorTexture(PAPER[1], PAPER[2], PAPER[3], 1)
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
      local e = f:CreateTexture(nil, "BORDER")
      if side == "TOP" or side == "BOTTOM" then
        e:SetPoint(side .. "LEFT", f, side .. "LEFT", 0, 0) e:SetPoint(side .. "RIGHT", f, side .. "RIGHT", 0, 0) e:SetHeight(1)
      else
        e:SetPoint("TOP" .. side, f, "TOP" .. side, 0, 0) e:SetPoint("BOTTOM" .. side, f, "BOTTOM" .. side, 0, 0) e:SetWidth(1)
      end
      e:SetColorTexture(INK[1], INK[2], INK[3], 0.9)
    end
    local hint = f:CreateFontString(nil, "OVERLAY")
    font(hint, BODY_FONT, 10, INK_SOFT)
    hint:SetPoint("TOP", f, "TOP", 0, -6)
    hint:SetText("Ctrl+C kopierer · Enter eller Esc lukker")
    local edit = CreateFrame("EditBox", "SparkmackCopyEdit", f)
    edit:SetSize(240, 20)
    edit:SetPoint("BOTTOM", f, "BOTTOM", 0, 8)
    if edit.SetAutoFocus then edit:SetAutoFocus(false) end
    if edit.SetJustifyH then edit:SetJustifyH("CENTER") end
    font(edit, BODY_FONT, 13, INK)
    local ebg = edit:CreateTexture(nil, "BACKGROUND")
    ebg:SetAllPoints(edit)
    ebg:SetColorTexture(1, 1, 1, 0.35)
    -- Feltet skal bare vise navnet: skriver du i det, settes navnet tilbake
    edit:SetScript("OnTextChanged", function(self, userInput)
      if userInput and f.name then self:SetText(f.name) self:HighlightText() end
    end)
    edit:SetScript("OnEnterPressed", function() f:Hide() end)
    edit:SetScript("OnEscapePressed", function() f:Hide() end)
    edit:SetScript("OnEditFocusLost", function() f:Hide() end)
    f.edit = edit
    f:Hide()
    copyBox = f
  end
  copyBox.name = name
  copyBox:ClearAllPoints()
  if owner then copyBox:SetPoint("BOTTOMLEFT", owner, "TOPLEFT", 40, -4) else copyBox:SetPoint("CENTER", UIParent, "CENTER", 0, 0) end
  copyBox:Show()
  copyBox.edit:SetText(name)
  copyBox.edit:SetFocus()
  copyBox.edit:HighlightText()
end

local function searchOrCopy(id, owner, shown)
  local name = itemNameOf(id, shown)
  if not name then return end
  local kind, box = ahSearchBox()
  if kind == "modern" then
    local ah = AuctionHouseFrame
    if ah.SetDisplayMode and AuctionHouseFrameDisplayMode and AuctionHouseFrameDisplayMode.Buy then
      pcall(ah.SetDisplayMode, ah, AuctionHouseFrameDisplayMode.Buy)
    end
    box.SearchBox:SetText(name)
    if box.StartSearch then pcall(box.StartSearch, box) end
  elseif kind == "legacy" then
    box:SetText(name)
    if AuctionFrameBrowse_Search then pcall(AuctionFrameBrowse_Search) end
  else
    showCopyBox(name, owner)
  end
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
    GameTooltip:AddDoubleLine("7-dagers median", coins(b[5]), 0.9, 0.9, 0.9, 1, 1, 1)
  end
  if cheapest then
    local line = coins(cheapest)
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
  GameTooltip:AddLine(ahSearchBox() and "Klikk: søk opp varen i AH" or "Klikk: kopier navnet", 0.6, 0.6, 0.6)
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

-- Seksjonsrubrikk: versaler i Nimrod med dobbel strek under (tykk, så tynn), som spaltetitlene i en gammel avis
local function sectionHead(p, text, y, x)
  x = x or 16
  local h = p:CreateFontString(nil, "OVERLAY")
  font(h, TITLE_FONT, SIZE.rubric, INK)
  h:SetPoint("TOPLEFT", p, "TOPLEFT", x, y - 2)
  h:SetText(text)
  for _, l in ipairs({ { 21, 2, 0.9 }, { 25, 1, 0.7 } }) do
    local t = p:CreateTexture(nil, "ARTWORK")
    t:SetPoint("TOPLEFT", p, "TOPLEFT", x - 2, y - l[1])
    t:SetPoint("TOPRIGHT", p, "TOPRIGHT", -14, y - l[1])
    t:SetHeight(l[2])
    t:SetColorTexture(INK[1], INK[2], INK[3], l[3])
  end
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
  font(r.line, TITLE_FONT, SIZE.smallHeadline, INK)
  r.line:SetPoint("TOPLEFT", r, "TOPLEFT", 32, -1)
  r.line:SetWidth(w - 32)
  r.line:SetJustifyH("LEFT")
  r.reason = r:CreateFontString(nil, "OVERLAY")
  font(r.reason, BODY_FONT, 11, INK_SOFT)
  r.reason:SetPoint("TOPLEFT", r.line, "BOTTOMLEFT", 0, -1)
  r.reason:SetWidth(w - 32)
  r.reason:SetJustifyH("LEFT")
  if r.EnableMouse then r:EnableMouse(true) end
  r:SetScript("OnEnter", function()
    r.line:SetTextColor(OXBLOOD[1], OXBLOOD[2], OXBLOOD[3])
    if r.itemId then showItemTooltip(r, r.itemId, r.itemKey) end
  end)
  r:SetScript("OnLeave", function() r.line:SetTextColor(INK[1], INK[2], INK[3]) hideTooltip() end)
  r:SetScript("OnMouseUp", function(_, button) if button == "LeftButton" and r.itemId then searchOrCopy(r.itemId, r, r.itemName) end end)
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
  font(mast, TITLE_FONT, SIZE.page, INK)
  mast:SetPoint("TOP", p, "TOP", 0, -20)
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

-- Billigste nå: en prissjekk ved AH (sekunder gammel) går foran din egen siste skanning, som går foran Data.lua.
-- Data.lua er fra forrige opplasting og kan henge en skanning etter – f.eks. etter at du selv kjøpte kuppet.
-- nil = ingen ute nå (vi har en skanning, og varen er ikke i den).
local function cheapestNow(key, by, fallback)
  local f = fresh[key]
  if type(f) == "table" and f.listings then return f.listings[1] and f.listings[1][1] end
  if by then return by[key] and by[key][1] and by[key][1][1] end
  return fallback
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
  back:SetPoint("RIGHT", bors, "LEFT", -2, 0)
  if sp.SetClampRectInsets then sp:SetClampRectInsets(-BOOKMARK_SIZE - 2, 0, 0, 0) end   -- bokmerket skal aldri havne utenfor skjermen
  folio(bors, 2)
  local borsDate = pageHead(bors, "BØRSEN", "KURSER OG KUPP FRA TORGET · BILAG TIL SPARKMACK'S KURSTIDENDE")
  sectionHead(bors, "KUPP PÅ TORGET", -110, IN)
  local deals = {}
  for i = 1, BORS_DEALS do deals[i] = smallRow(bors, -138 - (i - 1) * 34, "SparkmackDealRow" .. i, IN) end
  local dealsEmpty = emptyText(bors, -142, IN)
  local topY = -138 - BORS_DEALS * 34 - 10
  sectionHead(bors, "MEST OMSATT", topY, IN)
  local top = {}
  for i = 1, BORS_TOP do top[i] = smallRow(bors, topY - 28 - (i - 1) * 34, "SparkmackTopRow" .. i, IN) end
  local topEmpty = emptyText(bors, topY - 32, IN)

  -- Hovedboken: regnskap, netto per dag og siste handler
  local close = CreateFrame("Button", "SparkmackSpreadClose", book, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", book, "TOPRIGHT", 2, 2)
  close:SetScript("OnClick", function() paperSound("close") sp:Hide() DB.ui = DB.ui or {} DB.ui.gazetteHidden = true updateOpenButton() end)
  local bookDate = pageHead(book, "HOVEDBOKEN", "SPARKMACKS HANDELSPROTOKOLL")
  folio(book, 3)
  sectionHead(book, "UKENS REGNSKAP", -110)
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
    font(v, BODY_FONT, 14, INK)
    v:SetPoint("TOPLEFT", l, "BOTTOMLEFT", 0, -3)
    stats[i] = v
  end
  sectionHead(book, "NETTO PER DAG", -186)
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
  sectionHead(book, "SISTE HANDLER", -330)
  local trades = {}
  for i = 1, BOOK_TRADES do trades[i] = smallRow(book, -358 - (i - 1) * 34, "SparkmackLedgerRow" .. i) end
  local tradesEmpty = emptyText(book, -362)

  makeGrip(book, "SparkmackSpreadGrip", GAZETTE_W * 2)
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
  local function signed(v) return (v > 0 and "+" or "") .. coins(v) end
  L.stats[1]:SetText(signed(todayNet))
  L.stats[2]:SetText(signed(weekNet))
  L.stats[3]:SetText(coins(soldWeek))
  L.stats[4]:SetText(coins(costWeek))
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
    b.val:SetText(v ~= 0 and coins(v) or "")
    b.day:SetText(SHORT_DAY[tonumber(date("%w", now - (7 - i) * 86400)) + 1])
  end
  for _, r in ipairs(L.trades) do r:Hide() end
  L.tradesEmpty:SetText(#list == 0 and "Hovedboken er tom. Åpne postkassen, så fører budet inn salg, kjøp og utløpte auksjoner." or "")
  for i = 1, math.min(BOOK_TRADES, #list) do
    local e, r = list[i], L.trades[i]
    local known = e.item_id and DB.items[e.item_id] or {}
    r.icon:SetTexture(itemIcon(e.item_id or 0))
    r.itemId, r.itemKey, r.itemName = e.item_id, e.item_id and (e.item_id .. ":0"), e.name
    local amount = e.kind == "sold" and ("+" .. coins(e.net)) or e.kind == "bought" and coins(e.net)
      or (e.deposit and ("−" .. coins(e.deposit) .. " deposit") or "deposit ukjent")
    r.line:SetText(("%s  %s  %d ×   %s"):format(LEDGER_TEXT[e.kind] or e.kind, inkName(e.name, known[2]), e.qty or 1, amount))
    local detail = e.kind == "sold" and ("Brutto %s · AH-cut %s · %s"):format(coins(e.gross), coins(e.cut), whenText(e.at))
      or e.kind == "bought" and ("Betalt %s · %s"):format(coins(e.gross), whenText(e.at))
      or ("Varen ligger i posten · %s"):format(whenText(e.at))
    r.reason:SetText(detail)
    r:Show()
  end

  -- Børsen: kupp på torget (flagg i Data.lua) og mest omsatt (solgt per døgn)
  local B = ui.bors
  for _, r in ipairs(B.deals) do r:Hide() end
  for _, r in ipairs(B.top) do r:Hide() end
  local found, busy = {}, {}
  local by = latestListings()
  for key, b in pairs(md and md.items or {}) do
    if b[6] == "billig" or b[6] == "dump" then
      -- Fortsatt et kupp med prisen fra nå? (samme grense som «billig»: høyst 80 % av 7-dagers median)
      local now = cheapestNow(key, by, b[7])
      if now and b[5] and b[5] > 0 and now <= b[5] * 0.8 then
        found[#found + 1] = { key = key, b = b, now = now, ratio = now / b[5] }
      end
    end
    if b[3] and b[4] and b[4] >= 2 and b[3] > 0 then
      busy[#busy + 1] = { key = key, b = b, now = cheapestNow(key, by, b[7]), perDay = b[3] / b[4] * 24 }
    end
  end
  table.sort(found, function(x, y) return x.ratio < y.ratio end)
  table.sort(busy, function(x, y) return x.perDay > y.perDay end)
  B.dealsEmpty:SetText(#found == 0 and "Ingen kupp ennå. Sparkmack trenger tre dagers kurser for å vite hva som er billig, kompis." or "")
  for i = 1, math.min(BORS_DEALS, #found) do
    local d, r = found[i], B.deals[i]
    local id = tonumber(d.key:match("^(%d+)"))
    local known = DB.items[id] or {}
    r.icon:SetTexture(itemIcon(id))
    r.itemId, r.itemKey, r.itemName = id, d.key, known[1]
    r.line:SetText(("%s  %s  %s"):format(d.b[6] == "dump" and "|cff8a2a1aDUMP|r" or "|cff1d5a1dBILLIG NÅ|r",
      inkName(known[1] or ("Vare #" .. id), known[2]), coins(d.now)))
    r.reason:SetText(("7-dagers median %s · %d %% under"):format(coins(d.b[5] or 0), math.floor((1 - d.ratio) * 100 + 0.5)))
    r:Show()
  end
  B.topEmpty:SetText(#busy == 0 and "Omsetningen måles når budet har vært ute minst to ganger samme døgn." or "")
  for i = 1, math.min(BORS_TOP, #busy) do
    local d, r = busy[i], B.top[i]
    local id = tonumber(d.key:match("^(%d+)"))
    local known = DB.items[id] or {}
    r.icon:SetTexture(itemIcon(id))
    r.itemId, r.itemKey, r.itemName = id, d.key, known[1]
    r.line:SetText(("%s  ca. %d stk per døgn"):format(inkName(known[1] or ("Vare #" .. id), known[2]), math.floor(d.perDay + 0.5)))
    r.reason:SetText(("%s · 7-dagers median %s"):format(d.now and ("Billigste nå " .. coins(d.now)) or "Ingen ute nå",
      coins(d.b[5] or 0)))
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
    ui.spreadRight = x < 30
    if ui.spreadRight then x = left end   -- ikke plass til Børsen og bokmerket til venstre: legg oppslaget mot høyre
    ui.spread:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, top)
  else
    ui.spread:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  end
  ui.todo:Hide()
  ui.spread:Show()
  refreshSpread()
end

local function closeSpread()
  -- Forsiden legges der Hovedboken lå (eller Børsen, hvis oppslaget lå mot høyre), med skaleringen du valgte der
  local page = ui.spread and ui.spread:IsShown() and (ui.spreadRight and ui.bors.page or ui.book.page)
  local left, top = page and page:GetLeft(), page and page:GetTop()
  if left and top and ui.todo then
    ui.todo:SetScale(DB.ui and DB.ui.scale or 1)
    ui.todo:ClearAllPoints()
    ui.todo:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    savePosition(ui.todo)
  end
  if ui.spread then ui.spread:Hide() end
  if ui.todo then
    ui.todo:Show()
    if refreshTodo then refreshTodo() end
  end
end

local function ensureTodoFrame()
  if not ui.todo then
    local W = GAZETTE_W
    local ROWS_END = TOP_ROWS + ROWS_PER_PAGE * ROW_H
    local t = CreateFrame("Frame", "SparkmackTodoFrame", UIParent)
    t:SetSize(W, ROWS_END + 58)
    if t.SetClampRectInsets then t:SetClampRectInsets(0, BOOKMARK_SIZE + 2, 0, 0) end   -- bokmerket til høyre skal være på skjermen
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
    turn:SetPoint("LEFT", t, "RIGHT", 2, 0)
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
    status:SetPoint("LEFT", t, "TOPLEFT", 16, -140)   -- midt på knappene (layoutStatus finjusterer)
    status:SetWidth(W - 168 - 118 - 16 - 8)
    status:SetJustifyH("LEFT")
    status:SetText("Klar til å sende ut budet.")
    local track = t:CreateTexture(nil, "ARTWORK")
    track:SetPoint("TOPLEFT", t, "TOPLEFT", 16, -151)
    track:SetSize(W - 168 - 118 - 16 - 8, 4)
    track:Hide()
    track:SetColorTexture(INK[1], INK[2], INK[3], 0.15)
    local bar = CreateFrame("StatusBar", "SparkmackProgressBar", t)
    bar:SetPoint("TOPLEFT", track, "TOPLEFT", 0, 0)
    bar:SetSize(W - 168 - 118 - 16 - 8, 4)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(OXBLOOD[1], OXBLOOD[2], OXBLOOD[3])
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    bar:Hide()
    local scanButton = inkButton(t, "SparkmackScanButton", 118, 30, "Send ut budet", 16)
    scanButton:SetPoint("TOPRIGHT", t, "TOPRIGHT", -168, -125)
    scanButton:SetScript("OnClick", function()
      local ok, err = pcall(startScan)
      if not ok then logError("Send ut budet", err) end
    end)
    local saveButton = inkButton(t, "SparkmackSaveButton", 146, 30, "Send til trykken!", 16)
    saveButton:SetPoint("TOPRIGHT", t, "TOPRIGHT", -16, -125)
    saveButton:SetScript("OnClick", saveAndReload)
    ui.status, ui.bar, ui.track, ui.scan, ui.save = status, bar, track, scanButton, saveButton
    rule(t, -163, 1)

    -- Faner med et lite tresnitt: aktiv i mørkt blekk, inaktiv dempet, oksblod på hover. Ingen strek under.
    local tabs = {}
    local tabDefs = { { id = "todo", text = "NYHETER", icon = "Interface\\Icons\\INV_Misc_Note_01" },
                      { id = "sale", text = "TIL AUKSJON", icon = "Interface\\Icons\\INV_Misc_Bag_10" } }
    for i, def in ipairs(tabDefs) do
      local b = CreateFrame("Button", i == 1 and "SparkmackTabTodo" or "SparkmackTabSale", t)
      b:SetSize(160, 26)
      b:SetPoint("TOPLEFT", t, "TOPLEFT", 16 + (i - 1) * 170, -167)
      b.icon = engraving(b, def.icon, 20, 0.85)
      b.icon:SetPoint("LEFT", b, "LEFT", 0, 0)
      b.label = b:CreateFontString(nil, "OVERLAY")
      font(b.label, TITLE_FONT, SIZE.rubric, INK)
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
    summary:SetPoint("TOP", t, "TOP", 0, -206)   -- sentrert på egen linje under fanene
    summary:SetJustifyH("CENTER")
    rule(t, -192, 2)   -- dobbel strek under fanene, som under rubrikkene på side 2–3
    rule(t, -197, 1)

    local empty = t:CreateFontString(nil, "OVERLAY")
    font(empty, BODY_FONT, 13, INK)
    empty:SetPoint("TOPLEFT", t, "TOPLEFT", 16, -TOP_ROWS - 10)
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
      r.icon:SetPoint("TOPLEFT", r, "TOPLEFT", 0, -ROW_PAD - CAP_GAP)
      -- «LEGG UT» / «OMPRIS» / «LA STÅ» i mindre skrift foran varenavnet
      r.tag = r:CreateFontString(nil, "OVERLAY")
      font(r.tag, TITLE_FONT, SIZE.tag, INK)
      r.line = r:CreateFontString(nil, "OVERLAY")
      font(r.line, TITLE_FONT, SIZE.headline, INK)
      r.line:SetPoint("TOPLEFT", r, "TOPLEFT", 44, -ROW_PAD)
      r.line:SetWidth(W - 32 - 44 - 112)
      r.line:SetJustifyH("LEFT")
      r.price = r:CreateFontString(nil, "OVERLAY")
      font(r.price, BODY_FONT, 13, INK)
      r.price:SetPoint("TOPLEFT", r.line, "BOTTOMLEFT", 0, -3)
      r.price:SetWidth(W - 32 - 44 - 112)
      r.price:SetJustifyH("LEFT")
      r.reason = r:CreateFontString(nil, "OVERLAY")
      font(r.reason, BODY_FONT, 11, INK_SOFT)
      r.reason:SetPoint("TOPLEFT", r.price, "BOTTOMLEFT", 0, -3)
      r.reason:SetWidth(W - 32 - 44 - 112)
      r.reason:SetJustifyH("LEFT")
      r.sep = r:CreateTexture(nil, "ARTWORK")
      r.sep:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 0, 0)
      r.sep:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", 0, 0)
      r.sep:SetHeight(1)
      r.sep:SetColorTexture(INK[1], INK[2], INK[3], 0.3)
      r.button = inkButton(r, "SparkmackTodoButton" .. i, BTN_W, BTN_H, nil, 15)
      r.button:SetPoint("TOPRIGHT", r, "TOPRIGHT", 0, -ROW_PAD)
      -- Velg antall: skriv det inn (f.eks. 30 av 100). Bare for varevarer; andre varer legges ut én og én.
      -- Mens du skriver tegnes ikke lista på nytt (da ville feltet miste fokus); bare prislinja oppdateres.
      r.qtyBox = CreateFrame("Frame", nil, r)
      r.qtyBox:SetSize(BTN_W, 20)
      r.qtyBox:SetPoint("TOP", r.button, "BOTTOM", 0, -4)
      local edit = CreateFrame("EditBox", "SparkmackQtyEdit" .. i, r.qtyBox)
      edit:SetSize(46, 20)
      edit:SetPoint("LEFT", r.qtyBox, "LEFT", 0, 0)
      if edit.SetAutoFocus then edit:SetAutoFocus(false) end
      if edit.SetNumeric then edit:SetNumeric(true) end
      if edit.SetMaxLetters then edit:SetMaxLetters(5) end
      if edit.SetJustifyH then edit:SetJustifyH("CENTER") end
      if edit.SetTextInsets then edit:SetTextInsets(2, 2, 0, 0) end
      font(edit, BODY_FONT, 13, INK)
      local bg = edit:CreateTexture(nil, "BACKGROUND")
      bg:SetAllPoints(edit)
      bg:SetColorTexture(1, 1, 1, 0.35)
      for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local e = edit:CreateTexture(nil, "BORDER")
        if side == "TOP" or side == "BOTTOM" then
          e:SetPoint(side .. "LEFT", edit, side .. "LEFT", 0, 0) e:SetPoint(side .. "RIGHT", edit, side .. "RIGHT", 0, 0) e:SetHeight(1)
        else
          e:SetPoint("TOP" .. side, edit, "TOP" .. side, 0, 0) e:SetPoint("BOTTOM" .. side, edit, "BOTTOM" .. side, 0, 0) e:SetWidth(1)
        end
        e:SetColorTexture(INK[1], INK[2], INK[3], 0.9)
      end
      r.qtyEdit = edit
      r.qtyOf = r.qtyBox:CreateFontString("SparkmackQtyOf" .. i, "OVERLAY")
      font(r.qtyOf, BODY_FONT, 12, INK_SOFT)
      r.qtyOf:SetPoint("LEFT", edit, "RIGHT", 5, 0)
      edit:SetScript("OnEditFocusGained", function() ui.typing = true end)
      edit:SetScript("OnEditFocusLost", function(self)
        ui.typing = false
        if r.qtyNow then self:SetText(tostring(r.qtyNow)) end
        if ui.refreshPending then ui.refreshPending = false refreshTodo() end
      end)
      edit:SetScript("OnTextChanged", function(self, userInput)
        if not userInput or not r.qtyKey then return end
        local n = tonumber(self:GetText() or "")
        if not n or n < 1 then return end
        n = math.min(r.qtyMax or 1, math.floor(n))
        ui.qty[r.qtyKey] = n
        if r.applyQty then r.applyQty(n) end
      end)
      edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
      edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
      r.qtyBox:Hide()
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
      r:SetScript("OnMouseUp", function(_, button) if button == "LeftButton" and r.itemId then searchOrCopy(r.itemId, r, r.itemName) end end)
      rows[i] = r
    end

    -- Blaing i lista (bare når den trengs) rett over bunnstreken; sidetall og kursgrunnlag under
    local function textButton(name, label)
      local b = CreateFrame("Button", name, t)
      b:SetSize(72, 16)
      local fs = b:CreateFontString(nil, "OVERLAY")
      font(fs, BODY_FONT, 11, INK)
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
    basis:SetPoint("LEFT", t, "BOTTOMLEFT", 16, FOOT_Y)
    ui.basis = basis

    makeGrip(t, "SparkmackTodoGrip", W)

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
local function fillRow(r, icon, line, reason, buttonText, onClick, itemId, itemKey, price, tag, name)
  r.itemId, r.itemKey, r.itemName = itemId, itemKey, name
  r.icon:SetTexture(icon)
  r.tag:SetText(tag or "")
  r.line:SetText(coinify(line))
  if r.price then r.price:SetText(coinify(price or "")) end
  if r.qtyBox then r.qtyBox:Hide() r.qtyKey = nil end
  if r.button then r.button.onHover = nil end
  r.reason:SetText(coinify(reason or ""))
  if buttonText then
    r.button:SetText(buttonText)
    r.button:SetIcon(buttonText == "Legg ut" and "Interface\\Icons\\INV_Misc_Bag_10" or nil)
    r.button:SetScript("OnClick", onClick)
    r.button:Enable()
    r.button:Show()
  else
    r.button:Hide()
  end
  r:Show()
end

local LINE_H = { line = 17, price = 15, reason = 13 }   -- linjehøyde for varenavn (15), pris (13) og grunn (11)

-- Notisene stables med samme luft (ROW_PAD) over og under hver strek. Innholdet i en notis er tekstspalten
-- (ikon + tre linjer) og knappespalten (knapp + antall); den laveste sentreres mot den høyeste.
local function layoutRows()
  if not (ui.todo and ui.todoRows) then return end
  local W = GAZETTE_W
  local y = TOP_ROWS
  for _, r in ipairs(ui.todoRows) do
    if r:IsShown() then
      local tagText = r.tag:GetText()
      local tagW = 0
      if tagText and tagText ~= "" then
        local sw = r.tag.GetStringWidth and r.tag:GetStringWidth()
        tagW = (type(sw) == "number" and sw > 0 and sw or 60) + 6
      end
      -- Med knapp slutter teksten 8 punkter før knappespalten; uten knapp går den helt ut til høyre
      local textW = W - 32 - 44 - tagW - (r.button:IsShown() and (BTN_W + 8) or 0)
      r.line:SetWidth(textW)
      r.price:SetWidth(textW)
      r.reason:SetWidth(textW)
      local lineH = math.max(1, textLines(r.line)) * LINE_H.line
      local priceH = textLines(r.price) * LINE_H.price
      local reasonH = textLines(r.reason) * LINE_H.reason
      local textH = lineH + 3 + priceH + 3 + reasonH
      local leftH = math.max(textH, CAP_GAP + 36)
      local colH = 0
      if r.button:IsShown() then colH = BTN_H end
      if r.qtyBox:IsShown() then colH = colH + 4 + 20 end
      local h = math.max(leftH, colH)
      local rowH = h + 2 * ROW_PAD
      local pad = (rowH - h) / 2
      local textTop = pad + (h - leftH) / 2
      r:SetHeight(rowH)
      r:ClearAllPoints()
      r:SetPoint("TOPLEFT", ui.todo, "TOPLEFT", 16, -y)
      r.line:ClearAllPoints()
      r.line:SetPoint("TOPLEFT", r, "TOPLEFT", 44 + tagW, -textTop)
      r.price:ClearAllPoints()
      r.price:SetPoint("TOPLEFT", r, "TOPLEFT", 44 + tagW, -(textTop + lineH + 3))
      r.reason:ClearAllPoints()
      r.reason:SetPoint("TOPLEFT", r, "TOPLEFT", 44 + tagW, -(textTop + lineH + 3 + priceH + 3))
      r.tag:ClearAllPoints()
      r.tag:SetPoint("TOPLEFT", r, "TOPLEFT", 44, -textTop - 2.5)   -- samme grunnlinje som varenavnet (15 mot 12 pt)
      r.icon:ClearAllPoints()
      r.icon:SetPoint("TOPLEFT", r, "TOPLEFT", 0, -textTop - CAP_GAP)
      r.button:ClearAllPoints()
      r.button:SetPoint("TOPRIGHT", r, "TOPRIGHT", 0, -(pad + (h - colH) / 2))
      y = y + rowH
    end
  end
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
        x.status = "|cff8a2a1aUnderbudt|r – billigste er " .. coins(cheapest)
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

-- Hvor gammel prisen bak et råd er
local function priceAge(key, scanRec)
  if not canLookup() then return "" end
  local f = fresh[key]
  if f and time() - f.at <= POST_SECONDS then return "  ·  |cff1d5a1dpris sjekket nå|r" end
  if f and time() - f.at <= FRESH_SECONDS then return "  ·  pris sjekket kl. " .. date("%H:%M:%S", f.at) .. ", sjekkes igjen" end
  local at = f and f.at or (scanRec and scanRec.started)
  return at and ("  ·  pris fra kl. " .. date("%H:%M", at) .. ", sjekkes før utlegging") or ""
end

local function drawTodo()
  if ui.typing then ui.refreshPending = true return end   -- vent til du er ferdig med å skrive antall
  ui.visibleRows = nil
  refreshSpread()
  if not ui.todo or not ui.todo:IsShown() then return end
  local input, md, scanRec = todoInput()
  local rows = ui.todoRows
  for _, r in ipairs(rows) do r:Hide() end
  ui.todoInfo:SetText(datelineText(md, scanRec))
  local basis = md or marketData()   -- Data.lua finnes også før første skanning
  if ui.basis then
    ui.basis:SetText(not basis and "Kursgrunnlag mangler"
      or basis.own and ("Kursgrunnlag: egne kurser, %d døgn"):format(basis.days)
      or ("Kursgrunnlag v" .. (basis.version or "–")))
  end
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
    ui.summary:SetText(("%d auksjoner ute · verdi %s"):format(#list, coins(total)))
    if #list == 0 then
      ui.todoEmpty:SetText("Ingenting på auksjon. Åpne fanen «Auctions» ved AH én gang, så noterer budet dine auksjoner.")
      pageOf(list)
      return
    end
    local first, last = pageOf(list)
    for i = first + 1, last do
      local x = list[i]
      fillRow(rows[i - first], itemIcon(x.item_id), inkName(x.name or ("Vare #" .. x.item_id), x.quality),
        x.status .. ("  ·  %s igjen"):format(timeLeft(x.time_left_s)),
        nil, nil, x.item_id, x.item_id .. ":" .. x.variant,
        ("%d stk à %s  ·  i alt %s"):format(x.qty, coins(x.price), coins(x.qty * x.price)), nil, x.name)
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
  ui.summary:SetText(("%d råd · forventet fortjeneste %s"):format(acts, coins(gain)))
  if #list == 0 then
    ui.todoEmpty:SetText(md and "Ingenting å gjøre akkurat nå. Du er billigst, og ingenting i bagen lønner seg. Hvil vingene, kompis."
      or "Ingen kurser ennå. Send ut budet, kompis – Sparkmack fører kursboka selv.")
    pageOf(list)
    return
  end
  local first, last = pageOf(list)
  ui.visibleRows = {}
  for i = first + 1, last do
    local x = list[i]
    if (x.action == "POST" or x.action == "REPOST") and not x.done then ui.visibleRows[#ui.visibleRows + 1] = x end
    local tag = ACTION_TEXT[x.action]
    local line = inkName(x.name or ("Vare #" .. x.item_id), x.quality)
    local unit = x.action == "REPOST" and ("%s, ny %s"):format(coins(x.old_price), coins(x.price)) or coins(x.price)
    local price = ("%d stk à %s"):format(x.qty, unit)
    price = price .. "  ·  i alt " .. coins(x.qty * x.price)
    local r = rows[i - first]
    if x.action == "POST" and not x.done then
      -- Du velger antallet; forslaget er det Sparkmack tror selges. Fortjenesten skaleres med antallet.
      local commodity = isCommodityInBags(x.item_id, x.variant)
      local maxQ = commodity and math.max(1, bagCount(x.item_id, x.variant)) or 1
      local post = {}
      for k2, v2 in pairs(x) do post[k2] = v2 end
      local function apply(q)
        post.qty = q
        post.gain = x.qty > 0 and math.floor(x.gain * q / x.qty + 0.5) or x.gain
        local p, why = price, x.reason
        if q ~= x.qty then
          p = ("%d stk à %s"):format(q, coins(x.price))
          p = p .. "  ·  i alt " .. coins(q * x.price)
          why = (commodity and ("Du har valgt %d (forslag %d). "):format(q, x.qty)
            or ("Legges ut én om gangen (forslag %d). "):format(x.qty)) .. why
        end
        return p, why .. priceAge(x.key, scanRec)
      end
      local q = math.max(1, math.min(maxQ, ui.qty[x.key] or x.qty))
      local p, why = apply(q)
      fillRow(r, itemIcon(x.item_id), line, why, "Legg ut", function()
        if ui.typing and r.qtyEdit then r.qtyEdit:ClearFocus() end
        if checkFirst(x, r.button, "Legg ut", POST_SECONDS) then return end
        local ok, sent = pcall(doPost, post, input.settings, r.button)
        if not ok then logError("Legg ut", sent) elseif sent then r.button:Disable() end
      end, x.item_id, x.key, p, tag, x.name)
      -- Siste prissjekk når musa kommer over «Legg ut», så klikket bruker prisen fra sekundene før
      r.button.onHover = function()
        if not isFresh(x.key, HOVER_SECONDS) and not checkPending(x.key) then requestPrice(x, true) end
      end
      if commodity and maxQ > 1 then
        r.qtyKey, r.qtyMax, r.qtyNow = x.key, maxQ, q
        r.applyQty = function(n)
          r.qtyNow = n
          local p2, why2 = apply(n)
          r.price:SetText(coinify(p2))
          r.reason:SetText(coinify(why2))
          layoutRows()
        end
        r.qtyEdit:SetText(tostring(q))
        r.qtyOf:SetText("av " .. maxQ)
        r.qtyBox:Show()
      end
    elseif x.action == "REPOST" and not x.done then
      fillRow(r, itemIcon(x.item_id), line, x.reason .. priceAge(x.key, scanRec), "Kanseller", function()
        if checkFirst(x, r.button, "Kanseller") then return end
        local ok, sent = pcall(doCancel, x, r.button)
        if not ok then logError("Kanseller", sent) elseif sent then r.button:Disable() end
      end, x.item_id, x.key, price, tag, x.name)
    else
      fillRow(r, itemIcon(x.item_id), line, x.reason, nil, nil, x.item_id, x.key, price, tag, x.name)
    end
  end
  freshenVisible()
end

refreshTodo = function()
  drawTodo()
  layoutRows()
end
ui.relayout = function()
  layoutRows()
  layoutStatus()
end

-- Hva statuslinja sier når budet ikke er ute og ingen handling venter på svar
idleStatus = function()
  if scan or pending or (priceCheck and priceCheck.urgent) or not ui.status then return end
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
    C_Timer.NewTicker(5, function() if ui.todo and ui.todo:IsShown() then idleStatus() freshenVisible() end end)
    return
  end
  C_Timer.After(5, function()   -- eldre klienter: egne tidtakere, stopper når avisen er lukket
    if ui.todo and ui.todo:IsShown() then idleStatus() freshenVisible() statusTicker() else ui.needTicker = true end
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
  "AUCTION_HOUSE_POST_ERROR", "AUCTION_CANCELED", "MAIL_INBOX_UPDATE", "COMMODITY_SEARCH_RESULTS_UPDATED",
  "ITEM_SEARCH_RESULTS_UPDATED", "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" }) do
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
  elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" or event == "ITEM_SEARCH_RESULTS_UPDATED" then
    onSearchResults(event, arg1)
  elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
    sendNextLookup()
  elseif event == "AUCTION_HOUSE_CLOSED" then
    if scan and scan.waiting then scan = nil end
    -- Prisene og valgt antall gjelder bare mens du står ved AH
    for k in pairs(fresh) do fresh[k] = nil end
    for k in pairs(ui.qty) do ui.qty[k] = nil end
    if ui.typing then
      for _, r in ipairs(ui.todoRows or {}) do if r.qtyEdit then r.qtyEdit:ClearFocus() end end
      ui.typing, ui.refreshPending = false, false
    end
    for k in pairs(tried) do tried[k] = nil end
    for i = #lookupQueue, 1, -1 do lookupQueue[i] = nil end
    if priceCheck then local job = priceCheck priceCheck = nil for _, cb in ipairs(job.done) do pcall(cb, false) end end
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
