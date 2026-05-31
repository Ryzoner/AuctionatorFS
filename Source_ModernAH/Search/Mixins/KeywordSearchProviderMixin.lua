AuctionatorKeywordSearchProviderMixin = CreateFromMixins(AuctionatorMultiSearchMixin, AuctionatorSearchProviderMixin)

-- Firestorm patch: C_AuctionHouse.SendBrowseQuery() doesn't work and
-- SearchButton:Click() switches tabs. Use local ReplicateItems search instead.

local BATCH_SIZE = 500
local BATCH_DELAY = 0.01

function AuctionatorKeywordSearchProviderMixin:CreateSearchTerm(term)
  Auctionator.Debug.Message("AuctionatorKeywordSearchProviderMixin:CreateSearchTerm()", term)
  return term  -- just the search string
end

function AuctionatorKeywordSearchProviderMixin:GetSearchProvider()
  Auctionator.Debug.Message("AuctionatorKeywordSearchProviderMixin:GetSearchProvider()")

  return function(searchString)
    self.searchComplete = false
    self:FirestormLocalSearch(searchString)
  end
end

function AuctionatorKeywordSearchProviderMixin:FirestormLocalSearch(searchString)
  local totalItems = C_AuctionHouse.GetNumReplicateItems()
  Auctionator.Debug.Message("Firestorm Keyword: local search, replicate items = " .. totalItems)

  if totalItems == 0 then
    C_AuctionHouse.ReplicateItems()
    C_Timer.After(3, function()
      local count = C_AuctionHouse.GetNumReplicateItems()
      if count > 0 then
        self:ScanReplicateData(count, searchString)
      else
        self.searchComplete = true
        self:AddResults({})
      end
    end)
  else
    self:ScanReplicateData(totalItems, searchString)
  end
end

function AuctionatorKeywordSearchProviderMixin:ScanReplicateData(totalItems, searchString)
  local searchLower = string.lower(searchString or "")
  self.browseResultsMap = {}
  self.replicateTotal = totalItems

  self:ScanBatch(0, searchLower)
end

function AuctionatorKeywordSearchProviderMixin:ScanBatch(startIndex, searchLower)
  local limit = self.replicateTotal
  local endIndex = math.min(startIndex + BATCH_SIZE, limit)

  for i = startIndex, endIndex - 1 do
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

  if endIndex >= limit then
    self:ProcessLocalResults()
  else
    C_Timer.After(BATCH_DELAY, function()
      self:ScanBatch(endIndex, searchLower)
    end)
  end
end

function AuctionatorKeywordSearchProviderMixin:ProcessLocalResults()
  local results = {}
  for _, result in pairs(self.browseResultsMap) do
    table.insert(results, result)
  end
  self.browseResultsMap = nil

  Auctionator.Debug.Message("Firestorm Keyword: " .. #results .. " results")

  self.searchComplete = true
  self:AddResults(results)
end

function AuctionatorKeywordSearchProviderMixin:HasCompleteTermResults()
  Auctionator.Debug.Message("AuctionatorKeywordSearchProviderMixin:HasCompleteTermResults()")
  return self.searchComplete
end

function AuctionatorKeywordSearchProviderMixin:OnSearchEventReceived(eventName, ...)
  -- No-op, we use local search
end

function AuctionatorKeywordSearchProviderMixin:RegisterProviderEvents()
  -- No events needed
end

function AuctionatorKeywordSearchProviderMixin:UnregisterProviderEvents()
  -- No events to unregister
end
