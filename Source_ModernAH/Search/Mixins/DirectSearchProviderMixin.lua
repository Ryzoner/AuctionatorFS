AuctionatorDirectSearchProviderMixin = CreateFromMixins(AuctionatorMultiSearchMixin, AuctionatorSearchProviderMixin)

-- Firestorm patch: C_AuctionHouse.SendBrowseQuery() doesn't work and
-- SearchButton:Click() switches tabs away from Shopping.
-- Instead we search locally through ReplicateItems data.

local BATCH_SIZE = 500
local BATCH_DELAY = 0.01

local QUALITY_TO_FILTER = {
  [0] = Enum.AuctionHouseFilter.PoorQuality,
  [1] = Enum.AuctionHouseFilter.CommonQuality,
  [2] = Enum.AuctionHouseFilter.UncommonQuality,
  [3] = Enum.AuctionHouseFilter.RareQuality,
  [4] = Enum.AuctionHouseFilter.EpicQuality,
  [5] = Enum.AuctionHouseFilter.LegendaryQuality,
  [6] = Enum.AuctionHouseFilter.ArtifactQuality,
}

local FILTER_TO_QUALITY = {}
for quality, filter in pairs(QUALITY_TO_FILTER) do
  FILTER_TO_QUALITY[filter] = quality
end

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
    self.currentQuery = searchTerm.query
    self.waiting = 0
    self.searchComplete = false

    self:FirestormLocalSearch()
  end
end

function AuctionatorDirectSearchProviderMixin:FirestormLocalSearch()
  local totalItems = C_AuctionHouse.GetNumReplicateItems()
  Auctionator.Debug.Message("Firestorm Shopping: local search, replicate items = " .. totalItems)

  if totalItems == 0 then
    -- No replicate data available, try to request it
    C_AuctionHouse.ReplicateItems()
    -- Wait and retry
    C_Timer.After(3, function()
      local count = C_AuctionHouse.GetNumReplicateItems()
      Auctionator.Debug.Message("Firestorm Shopping: after wait, replicate items = " .. count)
      if count > 0 then
        self:ScanReplicateData(count)
      else
        -- No data available, return empty
        Auctionator.Debug.Message("Firestorm Shopping: no replicate data, returning empty")
        self.searchComplete = true
        self:AddResults({})
      end
    end)
  else
    self:ScanReplicateData(totalItems)
  end
end

function AuctionatorDirectSearchProviderMixin:ScanReplicateData(totalItems)
  local searchString = self.currentQuery.searchString or ""
  local searchLower = string.lower(searchString)
  local filters = self.currentQuery.filters or {}
  local minLevel = self.currentQuery.minLevel
  local maxLevel = self.currentQuery.maxLevel

  -- Determine required quality from filters
  local requiredQuality = nil
  for _, filter in ipairs(filters) do
    if FILTER_TO_QUALITY[filter] ~= nil then
      requiredQuality = FILTER_TO_QUALITY[filter]
      break
    end
  end

  self.browseResultsMap = {}  -- itemKey string -> aggregated browse result
  self.replicateTotal = totalItems
  self.replicateProcessed = 0

  Auctionator.Debug.Message("Firestorm Shopping: scanning " .. totalItems .. " items for '" .. searchString .. "'")

  self:ScanBatch(0, searchLower, requiredQuality, minLevel, maxLevel)
end

function AuctionatorDirectSearchProviderMixin:ScanBatch(startIndex, searchLower, requiredQuality, minLevel, maxLevel)
  local limit = self.replicateTotal
  local endIndex = math.min(startIndex + BATCH_SIZE, limit)

  for i = startIndex, endIndex - 1 do
    local info = { C_AuctionHouse.GetReplicateItemInfo(i) }
    -- info fields:
    -- [1]=name, [2]=texture, [3]=count, [4]=qualityID, [5]=usable,
    -- [6]=level, [7]=levelType, [8]=minBid, [9]=minIncrement,
    -- [10]=buyoutPrice, [11]=bidAmount, [12]=highBidder, [13]=bidderFullName,
    -- [14]=owner, [15]=ownerFullName, [16]=saleStatus, [17]=itemID, [18]=hasAllInfo

    local name = info[1]
    local count = info[3] or 1
    local qualityID = info[4]
    local level = info[6] or 0
    local buyoutPrice = info[10] or 0
    local itemID = info[17]
    local owner = info[14]

    if name and itemID and buyoutPrice > 0 then
      local nameLower = string.lower(name)

      -- Match search string
      local matches = (searchLower == "") or string.find(nameLower, searchLower, 1, true)

      -- Match quality filter
      if matches and requiredQuality ~= nil then
        matches = (qualityID == requiredQuality)
      end

      -- Match level filter
      if matches and minLevel and minLevel > 0 then
        matches = (level >= minLevel)
      end
      if matches and maxLevel and maxLevel > 0 then
        matches = (level <= maxLevel)
      end

      if matches then
        local effectivePrice = math.floor(buyoutPrice / count)
        local link = C_AuctionHouse.GetReplicateItemLink(i)
        local itemLevel = 0
        if link then
          itemLevel = C_Item.GetDetailedItemLevelInfo(link) or 0
        end

        -- Build itemKey
        local itemKey = {
          itemID = itemID,
          itemLevel = itemLevel,
          itemSuffix = 0,
          battlePetSpeciesID = 0,
        }
        local keyString = tostring(itemID) .. ":" .. tostring(itemLevel)

        -- Aggregate into browse-like results
        if not self.browseResultsMap[keyString] then
          self.browseResultsMap[keyString] = {
            itemKey = itemKey,
            minPrice = effectivePrice,
            totalQuantity = count,
            containsOwnerItem = (owner == UnitName("player")),
            name = name,
          }
        else
          local existing = self.browseResultsMap[keyString]
          existing.totalQuantity = existing.totalQuantity + count
          if effectivePrice < existing.minPrice then
            existing.minPrice = effectivePrice
          end
          if owner == UnitName("player") then
            existing.containsOwnerItem = true
          end
        end
      end
    end
  end

  self.replicateProcessed = endIndex

  if endIndex >= limit then
    -- Done scanning, process results through filters
    self:ProcessLocalResults()
  else
    C_Timer.After(BATCH_DELAY, function()
      self:ScanBatch(endIndex, searchLower, requiredQuality, minLevel, maxLevel)
    end)
  end
end

function AuctionatorDirectSearchProviderMixin:ProcessLocalResults()
  -- Convert map to array
  local results = {}
  for _, result in pairs(self.browseResultsMap) do
    table.insert(results, result)
  end
  self.browseResultsMap = nil

  Auctionator.Debug.Message("Firestorm Shopping: " .. #results .. " unique items matched")

  self.searchComplete = true

  -- Process results through the filter system
  if not self.registeredForEvents then
    self.registeredForEvents = true
    Auctionator.EventBus:Register(self, { Auctionator.Search.Events.SearchResultsReady })
  end

  self.waiting = self.waiting + #results
  for index = 1, #results do
    local resultInfo = results[index]
    local filterTracker = CreateAndInitFromMixin(
      Auctionator.Search.Filters.FilterTrackerMixin,
      resultInfo
    )
    resultInfo.purchaseQuantity = self.resultMetadata.quantity
    local filters = Auctionator.Search.Filters.Create(resultInfo, self.currentFilter, filterTracker)
    filterTracker:SetWaiting(#filters)
  end

  if #results == 0 then
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
  -- Handle item info events for filters that need them
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
  -- Register for item info loading (needed by some filters)
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
