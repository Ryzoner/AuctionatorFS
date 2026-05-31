AuctionatorIncrementalScanFrameMixin = {}

-- Firestorm patch: standard C_AuctionHouse.SendBrowseQuery() and events
-- (AUCTION_HOUSE_BROWSE_RESULTS_UPDATED/ADDED) do not work.
-- Instead we use the AuctionHouseFrame internal UI: trigger search via
-- SearchButton:Click(), read results from BrowseResultsFrame.browseResults,
-- and poll with RequestMoreBrowseResults() until HasFullBrowseResults().

local POLL_INTERVAL = 2  -- seconds between pagination requests

function AuctionatorIncrementalScanFrameMixin:OnLoad()
  Auctionator.Debug.Message("AuctionatorIncrementalScanFrameMixin:OnLoad (Firestorm)")
  Auctionator.EventBus:RegisterSource(self, "AuctionatorIncrementalScanFrameMixin")

  self.doingFullScan = false
  self.state = Auctionator.SavedState
  self.lastResultCount = 0

  -- Still register AUCTION_HOUSE_CLOSED to detect AH closing mid-scan
  self:RegisterEvent("AUCTION_HOUSE_CLOSED")
  self:SetScript("OnEvent", function(_, event)
    if event == "AUCTION_HOUSE_CLOSED" and self.doingFullScan then
      self:AbortScan()
      Auctionator.Utilities.Message(AUCTIONATOR_L_FULL_SCAN_FAILED_SUMMARY)
      Auctionator.EventBus:Fire(self, Auctionator.IncrementalScan.Events.ScanFailed)
    end
  end)
end

function AuctionatorIncrementalScanFrameMixin:IsAutoscanReady()
  local timeSinceLastScan = time() - (self.state.TimeOfLastBrowseScan or 0)

  return timeSinceLastScan >= (Auctionator.Config.Get(Auctionator.Config.Options.AUTOSCAN_INTERVAL) * 60)
end

function AuctionatorIncrementalScanFrameMixin:InitiateScan()
  if self.doingFullScan then
    -- Safety: if stuck from a previous failed scan, reset after 60s
    if self.scanStartTime and (time() - self.scanStartTime > 60) then
      Auctionator.Debug.Message("Firestorm: resetting stuck scan state")
      self:AbortScan()
    else
      Auctionator.Utilities.Message(AUCTIONATOR_L_FULL_SCAN_IN_PROGRESS)
      return
    end
  end

  if not AuctionHouseFrame or not AuctionHouseFrame:IsShown() then
    Auctionator.Utilities.Message("Auction House is not open")
    return
  end

  Auctionator.Utilities.Message(AUCTIONATOR_L_STARTING_FULL_SCAN_SUMMARY)
  self.state.TimeOfLastBrowseScan = time()
  self.scanStartTime = time()
  self.previousDatabaseCount = Auctionator.Database:GetItemCount()
  self.doingFullScan = true
  self.lastResultCount = 0
  self.info = {}
  self.rawScan = {}

  Auctionator.EventBus:Fire(self, Auctionator.IncrementalScan.Events.ScanStart)
  self:FireProgressEvent()

  -- Trigger browse with empty search string via UI button
  local searchBar = AuctionHouseFrame.SearchBar
  if searchBar and searchBar.SearchBox then
    searchBar.SearchBox:SetText("")
  else
    Auctionator.Debug.Message("Firestorm: SearchBar.SearchBox not found")
  end
  if searchBar and searchBar.SearchButton then
    searchBar.SearchButton:Click()
  else
    Auctionator.Debug.Message("Firestorm: SearchBar.SearchButton not found")
  end

  -- Start polling for results after a short delay to let the query fire
  C_Timer.After(POLL_INTERVAL + 1, function() self:PollResults() end)
end

function AuctionatorIncrementalScanFrameMixin:PollResults()
  if not self.doingFullScan then
    return
  end

  -- Check if AH was closed
  if not AuctionHouseFrame or not AuctionHouseFrame:IsShown() then
    self:AbortScan()
    Auctionator.Utilities.Message(AUCTIONATOR_L_FULL_SCAN_FAILED_SUMMARY)
    Auctionator.EventBus:Fire(self, Auctionator.IncrementalScan.Events.ScanFailed)
    return
  end

  local browseResultsFrame = AuctionHouseFrame.BrowseResultsFrame
  local browseResults = browseResultsFrame and browseResultsFrame.browseResults or {}
  local currentCount = #browseResults
  local hasFull = C_AuctionHouse.HasFullBrowseResults()

  -- Update progress
  self:FireProgressEvent()

  if hasFull then
    -- All results received, process them
    self:ProcessFirestormResults(browseResults)
  else
    -- Request more and poll again
    self.lastResultCount = currentCount
    C_AuctionHouse.RequestMoreBrowseResults()
    C_Timer.After(POLL_INTERVAL, function() self:PollResults() end)
  end
end

function AuctionatorIncrementalScanFrameMixin:ProcessFirestormResults(browseResults)
  self.info = {}
  self.rawScan = {}

  for _, resultInfo in ipairs(browseResults) do
    if resultInfo.totalQuantity and resultInfo.totalQuantity ~= 0 then
      local success, allDBKeys = pcall(Auctionator.Utilities.DBKeyFromBrowseResult, resultInfo)

      if success and allDBKeys then
        for _, dbKey in ipairs(allDBKeys) do
          if self.info[dbKey] == nil then
            self.info[dbKey] = {}
          end

          table.insert(self.info[dbKey],
            { price = resultInfo.minPrice, available = resultInfo.totalQuantity }
          )
        end
        table.insert(self.rawScan, resultInfo)
      end
    end
  end

  -- Process into database
  local count = Auctionator.Database:ProcessScan(self.info)
  local rawScan = self.rawScan

  self.info = {}
  self.rawScan = {}
  self.doingFullScan = false

  Auctionator.Utilities.Message(AUCTIONATOR_L_FINISHED_PROCESSING:format(count))

  Auctionator.EventBus:Fire(self, Auctionator.IncrementalScan.Events.ScanComplete, rawScan)
  Auctionator.EventBus:Fire(self, Auctionator.IncrementalScan.Events.PricesProcessed)
end

function AuctionatorIncrementalScanFrameMixin:AbortScan()
  self.doingFullScan = false
  self.info = {}
  self.rawScan = {}
  self.lastResultCount = 0
end

function AuctionatorIncrementalScanFrameMixin:FireProgressEvent()
  local browseResults = AuctionHouseFrame
    and AuctionHouseFrame.BrowseResultsFrame
    and AuctionHouseFrame.BrowseResultsFrame.browseResults
    or {}

  local currentCount = #browseResults
  local dbCount = Auctionator.Database:GetItemCount()

  -- 10% complete after making the browse request
  local progress = 0.1

  if dbCount == 0 then
    progress = 0.1 + 0.8 * (currentCount / 10000)  -- estimate ~10k items
  elseif dbCount > currentCount then
    progress = 0.1 + 0.8 * currentCount / dbCount
  else
    progress = 0.9
  end

  progress = math.min(progress, 0.95)

  Auctionator.EventBus:Fire(self, Auctionator.IncrementalScan.Events.ScanProgress, progress)
end
