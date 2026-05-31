AuctionatorDirectSearchProviderMixin = CreateFromMixins(AuctionatorMultiSearchMixin, AuctionatorSearchProviderMixin)

-- Firestorm patch: C_AuctionHouse.SendBrowseQuery() doesn't work.
-- Instead we use SearchButton:Click() + poll browseResults + RequestMoreBrowseResults()
-- This replaces event-based flow with polling-based flow.

local POLL_INTERVAL = 0.5  -- seconds between polls
local POLL_TIMEOUT = 30    -- max seconds to wait for results

local QUALITY_TO_FILTER = {
  [0] = Enum.AuctionHouseFilter.PoorQuality,
  [1] = Enum.AuctionHouseFilter.CommonQuality,
  [2] = Enum.AuctionHouseFilter.UncommonQuality,
  [3] = Enum.AuctionHouseFilter.RareQuality,
  [4] = Enum.AuctionHouseFilter.EpicQuality,
  [5] = Enum.AuctionHouseFilter.LegendaryQuality,
  [6] = Enum.AuctionHouseFilter.ArtifactQuality,
}

local function GetQualityFilters(quality)
  if QUALITY_TO_FILTER[quality] ~= nil then
    return { QUALITY_TO_FILTER[quality] }
  else
    return {}
  end
end

function AuctionatorDirectSearchProviderMixin:CreateSearchTerm(term)
  Auctionator.Debug.Message("AuctionatorDirectSearchProviderMixin:CreateSearchTerm()", term)

  local parsed = Auctionator.Search.SplitAdvancedSearch(term)

  return {
    query = {
      searchString = parsed.searchString,
      minLevel = parsed.minLevel,
      maxLevel = parsed.maxLevel,
      filters = GetQualityFilters(parsed.quality),
      itemClassFilters = Auctionator.Search.GetItemClassCategories(parsed.categoryKey),
      sorts = Auctionator.Constants.ShoppingSorts,
    },
    extraFilters = {
      itemLevel = {
        min = parsed.minItemLevel,
        max = parsed.maxItemLevel,
      },
      craftedLevel = {
        min = parsed.minCraftedLevel,
        max = parsed.maxCraftedLevel,
      },
      price = {
        min = parsed.minPrice,
        max = parsed.maxPrice,
      },
      exactSearch = (parsed.isExact and parsed.searchString) or nil,
      expansion = parsed.expansion,
      tier = parsed.tier,
    },
    resultMetadata = {
      quantity = parsed.quantity,
    }
  }
end

function AuctionatorDirectSearchProviderMixin:GetSearchProvider()
  Auctionator.Debug.Message("AuctionatorDirectSearchProviderMixin:GetSearchProvider()")

  return function(searchTerm)
    self.currentFilter = searchTerm.extraFilters
    self.resultMetadata = searchTerm.resultMetadata
    self.waiting = 0
    self.pollStartTime = time()
    self.lastPollCount = 0
    self.searchComplete = false

    -- Use SearchButton:Click() with the search string
    local searchString = searchTerm.query.searchString or ""
    self:FirestormBrowseSearch(searchString)
  end
end

function AuctionatorDirectSearchProviderMixin:FirestormBrowseSearch(searchString)
  Auctionator.Debug.Message("Firestorm Shopping: searching for '" .. searchString .. "'")

  if not AuctionHouseFrame or not AuctionHouseFrame:IsShown() then
    Auctionator.Debug.Message("Firestorm Shopping: AH not open")
    self:AddResults({})
    return
  end

  local searchBar = AuctionHouseFrame.SearchBar
  if searchBar and searchBar.SearchBox then
    searchBar.SearchBox:SetText(searchString)
  end
  if searchBar and searchBar.SearchButton then
    searchBar.SearchButton:Click()
  end

  -- Start polling for results
  C_Timer.After(POLL_INTERVAL + 0.5, function() self:PollSearchResults() end)
end

function AuctionatorDirectSearchProviderMixin:PollSearchResults()
  if self.searchComplete then
    return
  end

  -- Timeout check
  if time() - self.pollStartTime > POLL_TIMEOUT then
    Auctionator.Debug.Message("Firestorm Shopping: poll timeout")
    self.searchComplete = true
    self:ProcessFirestormResults()
    return
  end

  local hasFull = C_AuctionHouse.HasFullBrowseResults()
  local browseResultsFrame = AuctionHouseFrame and AuctionHouseFrame.BrowseResultsFrame
  local browseResults = browseResultsFrame and browseResultsFrame.browseResults or {}
  local currentCount = #browseResults

  Auctionator.Debug.Message("Firestorm Shopping: poll count=" .. currentCount .. " hasFull=" .. tostring(hasFull))

  if hasFull then
    self.searchComplete = true
    self:ProcessFirestormResults()
  else
    self.lastPollCount = currentCount
    C_AuctionHouse.RequestMoreBrowseResults()
    C_Timer.After(POLL_INTERVAL, function() self:PollSearchResults() end)
  end
end

function AuctionatorDirectSearchProviderMixin:ProcessFirestormResults()
  Auctionator.Debug.Message("Firestorm Shopping: processing results")

  local browseResultsFrame = AuctionHouseFrame and AuctionHouseFrame.BrowseResultsFrame
  local browseResults = browseResultsFrame and browseResultsFrame.browseResults or {}

  Auctionator.Debug.Message("Firestorm Shopping: " .. #browseResults .. " total results to filter")

  -- Process results through the filter system (same as original)
  self.waiting = self.waiting + #browseResults
  for index = 1, #browseResults do
    local resultInfo = browseResults[index]
    local filterTracker = CreateAndInitFromMixin(
      Auctionator.Search.Filters.FilterTrackerMixin,
      resultInfo
    )
    resultInfo.purchaseQuantity = self.resultMetadata.quantity
    local filters = Auctionator.Search.Filters.Create(resultInfo, self.currentFilter, filterTracker)
    filterTracker:SetWaiting(#filters)
  end

  if #browseResults == 0 then
    self:AddResults({})
  end
end

function AuctionatorDirectSearchProviderMixin:HasCompleteTermResults()
  Auctionator.Debug.Message("AuctionatorDirectSearchProviderMixin:HasCompleteTermResults()")
  return self.searchComplete and self.waiting == 0
end

function AuctionatorDirectSearchProviderMixin:GetCurrentEmptyResult()
  return Auctionator.Search.GetEmptyResult(self:GetCurrentSearchParameter(), self:GetCurrentSearchIndex())
end

function AuctionatorDirectSearchProviderMixin:OnSearchEventReceived(eventName, ...)
  -- Firestorm: we don't use events for browse results anymore
  -- But we still need to handle SearchResultsReady from filter system
  if eventName == "EXTRA_BROWSE_INFO_RECEIVED" or eventName == "GET_ITEM_INFO_RECEIVED" then
    Auctionator.EventBus
      :RegisterSource(self, "AuctionatorDirectSearchProviderMixin")
      :Fire(self, Auctionator.Search.Events.BlizzardInfo, eventName, ...)
      :UnregisterSource(self)
  end
end

function AuctionatorDirectSearchProviderMixin:ReceiveEvent(eventName, results)
  if eventName == Auctionator.Search.Events.SearchResultsReady then
    self.waiting = self.waiting - 1
    if self:HasCompleteTermResults() then
      self.registeredForEvents = false
      Auctionator.EventBus:Unregister(self, { Auctionator.Search.Events.SearchResultsReady })
    end
    self:AddResults(results)
  end
end

function AuctionatorDirectSearchProviderMixin:RegisterProviderEvents()
  -- Register for filter completion events
  if not self.registeredForEvents then
    self.registeredForEvents = true
    Auctionator.EventBus:Register(self, { Auctionator.Search.Events.SearchResultsReady })
  end
  -- Still register these for item info loading
  self:RegisterEvents({
    "GET_ITEM_INFO_RECEIVED",
    "EXTRA_BROWSE_INFO_RECEIVED",
  })
end

function AuctionatorDirectSearchProviderMixin:UnregisterProviderEvents()
  self:UnregisterEvents({
    "GET_ITEM_INFO_RECEIVED",
    "EXTRA_BROWSE_INFO_RECEIVED",
  })
  if self.registeredForEvents then
    self.registeredForEvents = false
    Auctionator.EventBus:Unregister(self, { Auctionator.Search.Events.SearchResultsReady })
  end
end
