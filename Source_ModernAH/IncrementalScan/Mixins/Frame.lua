AuctionatorIncrementalScanFrameMixin = {}

-- Firestorm patch: C_AuctionHouse.ReplicateItems() works and returns data
-- immediately without firing REPLICATE_ITEM_LIST_UPDATE event.
-- Data persists across tab switches and doesn't affect UI.
-- This allows fully background scanning while user interacts with AH.

local BATCH_SIZE = 200      -- items to process per frame tick
local BATCH_DELAY = 0.01    -- seconds between batches (minimal, non-blocking)

function AuctionatorIncrementalScanFrameMixin:OnLoad()
  Auctionator.Debug.Message("AuctionatorIncrementalScanFrameMixin:OnLoad (Firestorm Background Replicate)")
  Auctionator.EventBus:RegisterSource(self, "AuctionatorIncrementalScanFrameMixin")

  self.scanState = "idle" -- idle | scanning | processing
  self.state = Auctionator.SavedState
  self.scanData = {}
  self.dbKeysMapping = {}
  self.totalItems = 0
  self.processedItems = 0
  self.waitingForData = 0

  -- Register AH close — scan can continue even after close since data is cached,
  -- but we stop processing to avoid errors with item links
  self:RegisterEvent("AUCTION_HOUSE_CLOSED")
  self:SetScript("OnEvent", function(_, event)
    if event == "AUCTION_HOUSE_CLOSED" and self.scanState == "scanning" then
      -- Data is still in memory, finalize what we have
      self:EndProcessing()
    end
  end)
end

function AuctionatorIncrementalScanFrameMixin:IsAutoscanReady()
  local timeSinceLastScan = time() - (self.state.TimeOfLastBrowseScan or 0)
  return timeSinceLastScan >= (Auctionator.Config.Get(Auctionator.Config.Options.AUTOSCAN_INTERVAL) * 60)
end

function AuctionatorIncrementalScanFrameMixin:IsScanning()
  return self.scanState ~= "idle"
end

function AuctionatorIncrementalScanFrameMixin:InitiateScan()
  if self.scanState ~= "idle" then
    Auctionator.Utilities.Message(AUCTIONATOR_L_FULL_SCAN_IN_PROGRESS)
    return
  end

  if not AuctionHouseFrame or not AuctionHouseFrame:IsShown() then
    Auctionator.Utilities.Message("Auction House is not open")
    return
  end

  Auctionator.Debug.Message("Firestorm BG: InitiateScan called")
  self.scanState = "waiting" -- prevent double-calls while waiting for data

  -- Call ReplicateItems to request data from server
  C_AuctionHouse.ReplicateItems()

  Auctionator.Utilities.Message("Requesting auction data...")

  -- Wait for data to fully load (server needs time to populate)
  self:WaitForData(0, 0, 0)
end

function AuctionatorIncrementalScanFrameMixin:WaitForData(attempt, lastCount, stableCount)
  C_Timer.After(1, function()
    if self.scanState ~= "waiting" then return end

    local totalItems = C_AuctionHouse.GetNumReplicateItems()
    Auctionator.Debug.Message("Firestorm BG: wait " .. attempt .. " = " .. tostring(totalItems) .. " items (last=" .. lastCount .. ", stable=" .. stableCount .. ")")

    if totalItems == 0 and attempt < 10 then
      -- Still no data, keep waiting
      if attempt == 3 then
        -- Try calling ReplicateItems again
        C_AuctionHouse.ReplicateItems()
        Auctionator.Debug.Message("Firestorm BG: re-calling ReplicateItems")
      end
      self:WaitForData(attempt + 1, 0, 0)
    elseif totalItems == 0 then
      -- Give up — server cooldown (typically 15 min)
      self.scanState = "idle"
      Auctionator.Utilities.Message("Scan on cooldown. Try again in ~15 minutes.")
    elseif totalItems == lastCount then
      -- Count is stable
      if stableCount >= 2 then
        -- Stable for 3 consecutive checks — data is fully loaded
        self:StartProcessing(totalItems)
      else
        self:WaitForData(attempt + 1, totalItems, stableCount + 1)
      end
    else
      -- Count is still growing, wait more
      self:WaitForData(attempt + 1, totalItems, 0)
    end
  end)
end

function AuctionatorIncrementalScanFrameMixin:StartProcessing(totalItems)
  Auctionator.Debug.Message("Firestorm BG: StartProcessing with " .. totalItems .. " items")
  Auctionator.Utilities.Message(AUCTIONATOR_L_STARTING_FULL_SCAN_SUMMARY ..
    " (" .. totalItems .. " auctions)")
  self.state.TimeOfLastBrowseScan = time()
  self.scanStartTime = time()
  self.previousDatabaseCount = Auctionator.Database:GetItemCount()
  self.scanState = "scanning"
  self.scanData = {}
  self.dbKeysMapping = {}
  self.totalItems = totalItems
  self.processedItems = 0
  self.waitingForData = totalItems

  Auctionator.EventBus:Fire(self, Auctionator.IncrementalScan.Events.ScanStart)
  self:FireProgressEvent()

  -- Process in batches to avoid freezing the UI
  self:ProcessBatch(0)
end

-- LoadItemData: request item data from server if not cached
local pendingItems = {}
local itemFrame = CreateFrame("Frame")
itemFrame.elapsed = 0
itemFrame:SetScript("OnEvent", function(_, _, itemID)
  if pendingItems[itemID] ~= nil then
    local forItemID = pendingItems[itemID]
    pendingItems[itemID] = nil
    for _, callback in ipairs(forItemID) do
      callback()
    end
  end
end)
itemFrame.OnUpdate = function(self, elapsed)
  itemFrame.elapsed = itemFrame.elapsed + elapsed
  if itemFrame.elapsed > 0.4 then
    for itemID in pairs(pendingItems) do
      C_Item.RequestLoadItemDataByID(itemID)
    end
    itemFrame.elapsed = 0
  end

  if next(pendingItems) == nil then
    itemFrame.elapsed = 0
    self:SetScript("OnUpdate", nil)
    self:UnregisterEvent("ITEM_DATA_LOAD_RESULT")
  end
end

local function LoadItemData(itemID, callback)
  pendingItems[itemID] = pendingItems[itemID] or {}
  table.insert(pendingItems[itemID], callback)
  itemFrame:RegisterEvent("ITEM_DATA_LOAD_RESULT")
  itemFrame:SetScript("OnUpdate", itemFrame.OnUpdate)
  C_Item.RequestLoadItemDataByID(itemID)
end

function AuctionatorIncrementalScanFrameMixin:ProcessBatch(startIndex)
  if self.scanState ~= "scanning" then
    return
  end

  local limit = self.totalItems
  if startIndex >= limit then
    -- All items queued for processing, wait for async item data loads
    C_Timer.After(2, function()
      if self.waitingForData > 0 then
        -- Some items never loaded, finalize anyway
        self.waitingForData = 0
        self:EndProcessing()
      end
    end)
    return
  end

  local endIndex = math.min(startIndex + BATCH_SIZE, limit)

  for i = startIndex, endIndex - 1 do
    local info = { C_AuctionHouse.GetReplicateItemInfo(i) }
    local index = i

    -- info[17] = itemID, info[18] = itemDataLoaded
    local itemID = info[17]

    if not itemID or not C_Item.DoesItemExistByID(itemID) then
      -- Item doesn't exist, skip
      self.waitingForData = self.waitingForData - 1
      if self.waitingForData == 0 then
        self:EndProcessing()
      end
    elseif not info[18] then
      -- Item data not loaded yet, request it
      LoadItemData(itemID, function()
        local link = C_AuctionHouse.GetReplicateItemLink(index)
        if link then
          Auctionator.Utilities.DBKeyFromLink(link, function(dbKeys)
            self.waitingForData = self.waitingForData - 1
            self.scanData[index + 1] = {
              replicateInfo = { C_AuctionHouse.GetReplicateItemInfo(index) },
              itemLink = link,
              timeLeft = C_AuctionHouse.GetReplicateItemTimeLeft(index),
            }
            self.dbKeysMapping[index + 1] = dbKeys
            if self.waitingForData == 0 then
              self:EndProcessing()
            end
          end)
        else
          self.waitingForData = self.waitingForData - 1
          if self.waitingForData == 0 then
            self:EndProcessing()
          end
        end
      end)
    else
      -- Item data already loaded
      local link = C_AuctionHouse.GetReplicateItemLink(index)
      if link then
        Auctionator.Utilities.DBKeyFromLink(link, function(dbKeys)
          self.waitingForData = self.waitingForData - 1
          self.scanData[index + 1] = {
            replicateInfo = info,
            itemLink = link,
            timeLeft = C_AuctionHouse.GetReplicateItemTimeLeft(index),
          }
          self.dbKeysMapping[index + 1] = dbKeys
          if self.waitingForData == 0 then
            self:EndProcessing()
          end
        end)
      else
        self.waitingForData = self.waitingForData - 1
        if self.waitingForData == 0 then
          self:EndProcessing()
        end
      end
    end
  end

  self.processedItems = endIndex

  -- Update progress
  self:FireProgressEvent()

  -- Schedule next batch
  C_Timer.After(BATCH_DELAY, function()
    self:ProcessBatch(endIndex)
  end)
end

function AuctionatorIncrementalScanFrameMixin:EndProcessing()
  if self.scanState == "idle" then return end
  self.scanState = "processing"

  local fixedScanData = {}
  local fixedDbKeysMapping = {}

  -- Remove nil holes
  for i = 1, #self.scanData do
    if self.scanData[i] ~= nil then
      table.insert(fixedScanData, self.scanData[i])
      table.insert(fixedDbKeysMapping, self.dbKeysMapping[i])
    end
  end

  -- Merge into price info
  local allInfo = {}
  for index = 1, #fixedScanData do
    local replicateInfo = fixedScanData[index].replicateInfo
    local count = replicateInfo[3] or 1
    local buyoutPrice = replicateInfo[10] or 0

    if count > 0 and buyoutPrice > 0 then
      local effectivePrice = math.floor(buyoutPrice / count)
      local available = count

      for _, dbKey in ipairs(fixedDbKeysMapping[index]) do
        if allInfo[dbKey] == nil then
          allInfo[dbKey] = {}
        end
        table.insert(allInfo[dbKey],
          { price = effectivePrice, available = available }
        )
      end
    end
  end

  -- Process into database
  local dbCount = Auctionator.Database:ProcessScan(allInfo)

  self.scanState = "idle"
  self.scanData = {}
  self.dbKeysMapping = {}

  Auctionator.Utilities.Message(AUCTIONATOR_L_FINISHED_PROCESSING:format(dbCount))

  Auctionator.EventBus:Fire(self, Auctionator.IncrementalScan.Events.ScanComplete, fixedScanData)
  Auctionator.EventBus:Fire(self, Auctionator.IncrementalScan.Events.PricesProcessed)
end

function AuctionatorIncrementalScanFrameMixin:FireProgressEvent()
  local progress = 0.1

  if self.totalItems > 0 then
    progress = 0.1 + 0.85 * (self.processedItems / self.totalItems)
  end

  progress = math.min(progress, 0.95)
  Auctionator.EventBus:Fire(self, Auctionator.IncrementalScan.Events.ScanProgress, progress)
end
