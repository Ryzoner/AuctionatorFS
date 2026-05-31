AuctionatorKeywordSearchProviderMixin = CreateFromMixins(AuctionatorMultiSearchMixin, AuctionatorSearchProviderMixin)

-- Firestorm patch: C_AuctionHouse.SendBrowseQuery() doesn't work.
-- Use SearchButton:Click() + poll browseResults instead.

local POLL_INTERVAL = 0.5
local POLL_TIMEOUT = 30

function AuctionatorKeywordSearchProviderMixin:CreateSearchTerm(term)
  Auctionator.Debug.Message("AuctionatorKeywordSearchProviderMixin:CreateSearchTerm()", term)

  return term  -- just the search string
end

function AuctionatorKeywordSearchProviderMixin:GetSearchProvider()
  Auctionator.Debug.Message("AuctionatorKeywordSearchProviderMixin:GetSearchProvider()")

  return function(searchString)
    self.pollStartTime = time()
    self.searchComplete = false

    self:FirestormBrowseSearch(searchString)
  end
end

function AuctionatorKeywordSearchProviderMixin:FirestormBrowseSearch(searchString)
  Auctionator.Debug.Message("Firestorm Keyword: searching for '" .. tostring(searchString) .. "'")

  if not AuctionHouseFrame or not AuctionHouseFrame:IsShown() then
    self:AddResults({})
    return
  end

  local searchBar = AuctionHouseFrame.SearchBar
  if searchBar and searchBar.SearchBox then
    searchBar.SearchBox:SetText(searchString or "")
  end
  if searchBar and searchBar.SearchButton then
    searchBar.SearchButton:Click()
  end

  C_Timer.After(POLL_INTERVAL + 0.5, function() self:PollSearchResults() end)
end

function AuctionatorKeywordSearchProviderMixin:PollSearchResults()
  if self.searchComplete then
    return
  end

  if time() - self.pollStartTime > POLL_TIMEOUT then
    Auctionator.Debug.Message("Firestorm Keyword: poll timeout")
    self.searchComplete = true
    self:ProcessFirestormResults()
    return
  end

  local hasFull = C_AuctionHouse.HasFullBrowseResults()

  if hasFull then
    self.searchComplete = true
    self:ProcessFirestormResults()
  else
    C_AuctionHouse.RequestMoreBrowseResults()
    C_Timer.After(POLL_INTERVAL, function() self:PollSearchResults() end)
  end
end

function AuctionatorKeywordSearchProviderMixin:ProcessFirestormResults()
  local browseResultsFrame = AuctionHouseFrame and AuctionHouseFrame.BrowseResultsFrame
  local browseResults = browseResultsFrame and browseResultsFrame.browseResults or {}

  Auctionator.Debug.Message("Firestorm Keyword: " .. #browseResults .. " results")

  self:AddResults(browseResults)
end

function AuctionatorKeywordSearchProviderMixin:HasCompleteTermResults()
  Auctionator.Debug.Message("AuctionatorKeywordSearchProviderMixin:HasCompleteTermResults()")
  return self.searchComplete
end

function AuctionatorKeywordSearchProviderMixin:OnSearchEventReceived(eventName, ...)
  -- No-op on Firestorm, we use polling
end

function AuctionatorKeywordSearchProviderMixin:RegisterProviderEvents()
  -- No events needed for polling approach
end

function AuctionatorKeywordSearchProviderMixin:UnregisterProviderEvents()
  -- No events to unregister
end
