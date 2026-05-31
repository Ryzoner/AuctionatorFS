AuctionatorDirectSearchProviderMixin = CreateFromMixins(AuctionatorMultiSearchMixin, AuctionatorSearchProviderMixin)

-- Firestorm patch: C_AuctionHouse.SendBrowseQuery() doesn't work and
-- SearchButton:Click() switches tabs away from Shopping.
-- Instead we search locally through cached ReplicateItems data (from Full Scan)
-- or fall back to live ReplicateItems API if cache is available.

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
  -- Try cached data first (from Full Scan)
  local cache = Auctionator.State.ReplicateCache
  if cache and #cache > 0 then
    Auctionator.Debug.Message("Firestorm Shopping: using cache (" .. #cache .. " items)")
    self:SearchCache(cache)
    return
  end

  -- Fall back to live ReplicateItems
  local totalItems = C_AuctionHouse.GetNumReplicateItems()
  Auctionator.Debug.Message("Firestorm Shopping: no cache, replicate items = " .. totalItems)

  if totalItems == 0 then
    C_AuctionHouse.ReplicateItems()
    C_Timer.After(3, function()
      local count = C_AuctionHouse.GetNumReplicateItems()
      if count > 0 then
        self:SearchLiveReplicate(count)
      else
        Auctionator.Debug.Message("Firestorm Shopping: no data available")
        self.searchComplete = true
        self:AddResults({})
      end
    end)
  else
    self:SearchLiveReplicate(totalItems)
  end
end

-- Fast path: search through pre-built cache (instant)
function AuctionatorDirectSearchProviderMixin:SearchCache(cache)
  local searchString = self.currentQuery.searchString or ""
  local searchLower = string.lower(searchString)
  local filters = self.currentQuery.filters or {}
  local minLevel = self.currentQuery.minLevel
  local maxLevel = self.currentQuery.maxLevel

  local requiredQuality = nil
  for _, filter in ipairs(filters) do
    if FILTER_TO_QUALITY[filter] ~= nil then
      requiredQuality = FILTER_TO_QUALITY[filter]
      break
    end
  end

  local browseResultsMap = {}

  for _, item in ipairs(cache) do
    if item.name and item.itemID and item.buyoutPrice > 0 then
      local nameLower = string.lower(item.name)
      local matches = (searchLower == "") or string.find(nameLower, searchLower, 1, true)

      if matches and requiredQuality ~= nil then
        matches = (item.qualityID == requiredQuality)
      end
      if matches and minLevel and minLevel > 0 then
        matches = (item.level >= minLevel)
      end
      if matches and maxLevel and maxLevel > 0 then
        matches = (item.level <= maxLevel)
      end

      if matches then
        local count = item.count or 1
        local effectivePrice = math.floor(item.buyoutPrice / count)
        local itemLevel = 0
        if item.itemLink then
          itemLevel = C_Item.GetDetailedItemLevelInfo(item.itemLink) or 0
        end

        local itemKey = {
          itemID = item.itemID,
          itemLevel = itemLevel,
          itemSuffix = 0,
          battlePetSpeciesID = 0,
        }
        local keyString = tostring(item.itemID) .. ":" .. tostring(itemLevel)

        if not browseResultsMap[keyString] then
          browseResultsMap[keyString] = {
            itemKey = itemKey,
            minPrice = effectivePrice,
            totalQuantity = count,
            containsOwnerItem = (item.owner == UnitName("player")),
            name = item.name,
          }
        else
          local existing = browseResultsMap[keyString]
          existing.totalQuantity = existing.totalQuantity + count
          if effectivePrice < existing.minPrice then
            existing.minPrice = effectivePrice
          end
          if item.owner == UnitName("player") then
            existing.containsOwnerItem = true
          end
        end
      end
    end
  end

  -- Convert to array and process through filters
  local results = {}
  for _, result in pairs(browseResultsMap) do
    table.insert(results, result)
  end

  Auctionator.Debug.Message("Firestorm Shopping: " .. #results .. " unique items matched")
  self:ProcessFilteredResults(results)
end

-- Slow path: scan live ReplicateItems data
function AuctionatorDirectSearchProviderMixin:SearchLiveReplicate(totalItems)
  local searchString = self.currentQuery.searchString or ""
  local searchLower = string.lower(searchString)
  local filters = self.currentQuery.filters or {}
  local minLevel = self.currentQuery.minLevel
  local maxLevel = self.currentQuery.maxLevel

  local requiredQuality = nil
  for _, filter in ipairs(filters) do
    if FILTER_TO_QUALITY[filter] ~= nil then
      requiredQuality = FILTER_TO_QUALITY[filter]
      break
    end
  end

  local browseResultsMap = {}

  for i = 0, totalItems - 1 do
    local info = { C_AuctionHouse.GetReplicateItemInfo(i) }
    local name = info[1]
    local count = info[3] or 1
    local qualityID = info[4]
    local level = info[6] or 0
    local buyoutPrice = info[10] or 0
    local itemID = info[17]
    local owner = info[14]

    if name and itemID and buyoutPrice > 0 then
      local nameLower = string.lower(name)
      local matches = (searchLower == "") or string.find(nameLower, searchLower, 1, true)

      if matches and requiredQuality ~= nil then
        matches = (qualityID == requiredQuality)
      end
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

        local itemKey = {
          itemID = itemID,
          itemLevel = itemLevel,
          itemSuffix = 0,
          battlePetSpeciesID = 0,
        }
        local keyString = tostring(itemID) .. ":" .. tostring(itemLevel)

        if not browseResultsMap[keyString] then
          browseResultsMap[keyString] = {
            itemKey = itemKey,
            minPrice = effectivePrice,
            totalQuantity = count,
            containsOwnerItem = (owner == UnitName("player")),
            name = name,
          }
        else
          local existing = browseResultsMap[keyString]
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

  local results = {}
  for _, result in pairs(browseResultsMap) do
    table.insert(results, result)
  end

  Auctionator.Debug.Message("Firestorm Shopping: " .. #results .. " unique items matched (live)")
  self:ProcessFilteredResults(results)
end

function AuctionatorDirectSearchProviderMixin:ProcessFilteredResults(results)
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
  if not self.registeredForEvents then
    self.registeredForEvents = true
    Auctionator.EventBus:Register(self, { Auctionator.Search.Events.SearchResultsReady })
  end
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
