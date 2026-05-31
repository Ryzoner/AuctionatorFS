AuctionatorKeywordSearchProviderMixin = CreateFromMixins(AuctionatorMultiSearchMixin, AuctionatorSearchProviderMixin)

-- Firestorm patch: C_AuctionHouse.SendBrowseQuery() doesn't work and
-- SearchButton:Click() switches tabs. Use cached ReplicateItems data instead.

function AuctionatorKeywordSearchProviderMixin:CreateSearchTerm(term)
  Auctionator.Debug.Message("AuctionatorKeywordSearchProviderMixin:CreateSearchTerm()", term)
  return term
end

function AuctionatorKeywordSearchProviderMixin:GetSearchProvider()
  Auctionator.Debug.Message("AuctionatorKeywordSearchProviderMixin:GetSearchProvider()")

  return function(searchString)
    self.searchComplete = false
    self:FirestormLocalSearch(searchString)
  end
end

function AuctionatorKeywordSearchProviderMixin:FirestormLocalSearch(searchString)
  -- Try cached data first
  local cache = Auctionator.State.ReplicateCache
  if cache and #cache > 0 then
    Auctionator.Debug.Message("Firestorm Keyword: using cache (" .. #cache .. " items)")
    self:SearchData(cache, searchString, true)
    return
  end

  -- Fall back to live ReplicateItems
  local totalItems = C_AuctionHouse.GetNumReplicateItems()
  Auctionator.Debug.Message("Firestorm Keyword: no cache, replicate items = " .. totalItems)

  if totalItems == 0 then
    C_AuctionHouse.ReplicateItems()
    C_Timer.After(3, function()
      local count = C_AuctionHouse.GetNumReplicateItems()
      if count > 0 then
        self:SearchLive(count, searchString)
      else
        self.searchComplete = true
        self:AddResults({})
      end
    end)
  else
    self:SearchLive(totalItems, searchString)
  end
end

function AuctionatorKeywordSearchProviderMixin:SearchData(cache, searchString, isCache)
  local searchLower = string.lower(searchString or "")
  local browseResultsMap = {}

  for _, item in ipairs(cache) do
    if item.name and item.itemID and item.buyoutPrice > 0 then
      local nameLower = string.lower(item.name)
      local matches = (searchLower == "") or string.find(nameLower, searchLower, 1, true)

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

  local results = {}
  for _, result in pairs(browseResultsMap) do
    table.insert(results, result)
  end

  Auctionator.Debug.Message("Firestorm Keyword: " .. #results .. " results")
  self.searchComplete = true
  self:AddResults(results)
end

function AuctionatorKeywordSearchProviderMixin:SearchLive(totalItems, searchString)
  local searchLower = string.lower(searchString or "")
  local browseResultsMap = {}

  for i = 0, totalItems - 1 do
    local info = { C_AuctionHouse.GetReplicateItemInfo(i) }
    local name = info[1]
    local count = info[3] or 1
    local buyoutPrice = info[10] or 0
    local itemID = info[17]
    local owner = info[14]

    if name and itemID and buyoutPrice > 0 then
      local nameLower = string.lower(name)
      local matches = (searchLower == "") or string.find(nameLower, searchLower, 1, true)

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

  Auctionator.Debug.Message("Firestorm Keyword: " .. #results .. " results (live)")
  self.searchComplete = true
  self:AddResults(results)
end

function AuctionatorKeywordSearchProviderMixin:HasCompleteTermResults()
  Auctionator.Debug.Message("AuctionatorKeywordSearchProviderMixin:HasCompleteTermResults()")
  return self.searchComplete
end

function AuctionatorKeywordSearchProviderMixin:OnSearchEventReceived(eventName, ...)
end

function AuctionatorKeywordSearchProviderMixin:RegisterProviderEvents()
end

function AuctionatorKeywordSearchProviderMixin:UnregisterProviderEvents()
end
