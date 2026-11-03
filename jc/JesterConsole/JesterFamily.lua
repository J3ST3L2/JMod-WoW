-- JesterConsole family travel and beginner quest guide (WoW 3.3.5a).
-- The travel buttons require the server-side mod-jmod-family module.
-- This addon never grants privileges or executes privileged GM commands.
local function Message(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cffb56cffJesterConsole:|r " .. text)
end

local function Trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function Button(parent, label, x, y, w, callback)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetWidth(w)
    b:SetHeight(25)
    b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    b:SetText(label)
    b:SetScript("OnClick", callback)
    return b
end

local function Panel(name, title, width, height)
    local f = CreateFrame("Frame", name, UIParent)
    f:SetWidth(width)
    f:SetHeight(height)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.03, 0.03, 0.03, 0.97)
    local heading = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    heading:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -14)
    heading:SetText(title)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -3, -3)
    f:Hide()
    return f
end

local family = Panel("JesterFamilyPanel", "Jester Family Travel", 460, 438)
local selectedName = nil
local target = CreateFrame("EditBox", "JesterFamilyTarget", family, "InputBoxTemplate")
target:SetAutoFocus(false)
target:SetWidth(244)
target:SetHeight(26)
target:SetPoint("TOPLEFT", family, "TOPLEFT", 24, -56)
target:SetMaxLetters(32)

local targetLabel = family:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
targetLabel:SetPoint("BOTTOMLEFT", target, "TOPLEFT", -2, 2)
targetLabel:SetText("Player name (or click a group member)")

local function SendFamily(action, value)
    local allowed = { go = true, summon = true, accept = true, decline = true, hub = true }
    if not allowed[action] then return end
    if action == "go" or action == "summon" then
        value = Trim(value)
        -- Only character names are sent. Never forward raw chat or GM commands.
        if not value:match("^[%a]+$") then
            Message("|cffff5555Select or enter a valid player name.|r")
            return
        end
    elseif action == "hub" then
        if value ~= "dalaran" and value ~= "shattrath" and
           value ~= "stormwind" and value ~= "orgrimmar" then
            return
        end
    else
        value = nil
    end
    local command = ".jmodfamily " .. action .. (value and (" " .. value) or "")
    SendChatMessage(command, "SAY")
end

Button(family, "Go to Player", 22, -91, 132, function()
    SendFamily("go", target:GetText())
end)
Button(family, "Request Summon", 160, -91, 150, function()
    SendFamily("summon", target:GetText())
end)
Button(family, "Accept", 316, -91, 122, function()
    SendFamily("accept")
end)

local hint = family:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
hint:SetPoint("TOPLEFT", family, "TOPLEFT", 22, -131)
hint:SetText("Summons require acceptance. Travel is blocked during combat/instances.")

local rosterHeading = family:CreateFontString(nil, "OVERLAY", "GameFontNormal")
rosterHeading:SetPoint("TOPLEFT", family, "TOPLEFT", 22, -158)
rosterHeading:SetText("Your group (click to select):")

local rosterButtons = {}
for i = 1, 8 do
    local b = Button(family, "-", 22 + ((i-1)%2)*207, -180 - math.floor((i-1)/2)*27, 200, function(self)
        selectedName = self.playerName
        if selectedName then target:SetText(selectedName) end
    end)
    rosterButtons[i] = b
end

local function RefreshRoster()
    local names, seen = {}, {}
    local function AddName(name)
        if name and name ~= "" and name ~= UnitName("player") and not seen[name] then
            seen[name] = true
            table.insert(names, name)
        end
    end
    local raidCount = GetNumRaidMembers and GetNumRaidMembers() or 0
    if raidCount > 0 then
        for i = 1, raidCount do
            local name = GetRaidRosterInfo(i)
            AddName(name)
        end
    else
        local partyCount = GetNumPartyMembers and GetNumPartyMembers() or 0
        for i = 1, partyCount do AddName(UnitName("party" .. i)) end
    end
    table.sort(names)
    for i, b in ipairs(rosterButtons) do
        b.playerName = names[i]
        b:SetText(names[i] or "-")
        if names[i] then b:Enable() else b:Disable() end
    end
end

local hubs = family:CreateFontString(nil, "OVERLAY", "GameFontNormal")
hubs:SetPoint("TOPLEFT", family, "TOPLEFT", 22, -298)
hubs:SetText("Fast travel to a city:")

Button(family, "Dalaran", 22, -322, 96, function() SendFamily("hub", "dalaran") end)
Button(family, "Shattrath", 128, -322, 96, function() SendFamily("hub", "shattrath") end)
Button(family, "Stormwind", 234, -322, 96, function() SendFamily("hub", "stormwind") end)
Button(family, "Orgrimmar", 340, -322, 96, function() SendFamily("hub", "orgrimmar") end)
Button(family, "Refresh Group", 22, -365, 190, RefreshRoster)
Button(family, "Decline Summon", 226, -365, 210, function() SendFamily("decline") end)

family:SetScript("OnShow", RefreshRoster)

function JesterFamily_Show()
    if family:IsShown() then family:Hide() else family:Show() end
end

-- The 3.3.5a client has quest titles and objectives, but no full world quest
-- coordinate database. Questie-335 provides the missing map pins and TomTom
-- can supply an arrow; do not invent waypoints from quest titles.
local guide = Panel("JesterQuestGuidePanel", "Quest Guide - What Do I Do Next?", 500, 450)
local guideStatus = guide:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
guideStatus:SetPoint("TOPLEFT", guide, "TOPLEFT", 18, -45)
guideStatus:SetWidth(465)
guideStatus:SetJustifyH("LEFT")

local questRows = {}
local quests = {}
local page = 1
local selectedQuest = nil
local objectives = guide:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
objectives:SetPoint("TOPLEFT", guide, "TOPLEFT", 20, -283)
objectives:SetWidth(460)
objectives:SetJustifyH("LEFT")
objectives:SetJustifyV("TOP")
objectives:SetHeight(72)
objectives:SetText("Choose a quest to see what still needs to be done.")

local function QuestStatus()
    local questie = (IsAddOnLoaded and (IsAddOnLoaded("Questie") or
        IsAddOnLoaded("Questie-335"))) or type(Questie) == "table"
    if questie then
        guideStatus:SetText("|cff80ff80Questie installed:|r quest locations are on your world map.")
    else
        guideStatus:SetText("|cffffff55Install Questie-335 for exact quest locations on the map.|r")
    end
end

local function SelectQuest(index)
    selectedQuest = index
    if not index then return end
    local title = GetQuestLogTitle(index)
    local lines = { "|cffffd100" .. (title or "Quest") .. "|r" }
    local n = GetNumQuestLeaderBoards(index) or 0
    for i = 1, n do
        local description, _, done = GetQuestLogLeaderBoard(i, index)
        table.insert(lines, (done and "|cff80ff80[Done] |r" or "|cffffdd77[To do] |r") .. (description or ""))
    end
    if n == 0 then table.insert(lines, "Open the quest log to read the quest instructions.") end
    objectives:SetText(table.concat(lines, "\n"))
end

local function RefreshGuide()
    QuestStatus()
    quests = {}
    local entries = GetNumQuestLogEntries() or 0
    for i = 1, entries do
        local title, level, _, _, isHeader = GetQuestLogTitle(i)
        if title and not isHeader then
            table.insert(quests, { index = i, title = title, level = level })
        end
    end
    local pages = math.max(1, math.ceil(#quests / 8))
    page = math.max(1, math.min(page, pages))
    for row, b in ipairs(questRows) do
        local q = quests[(page - 1)*8 + row]
        b.questIndex = q and q.index or nil
        b:SetText(q and ("[" .. tostring(q.level or "?") .. "] " .. q.title) or "")
        if q then b:Enable() else b:Disable() end
    end
    if selectedQuest then SelectQuest(selectedQuest) end
end

for i = 1, 8 do
    local b = Button(guide, "", 18, -78 - (i - 1)*25, 464, function(self)
        if self.questIndex then SelectQuest(self.questIndex) end
    end)
    questRows[i] = b
end
Button(guide, "Previous", 18, -365, 92, function()
    page = math.max(1, page - 1)
    RefreshGuide()
end)
Button(guide, "Next", 116, -365, 92, function()
    page = page + 1
    RefreshGuide()
end)
Button(guide, "Track Quest", 213, -365, 115, function()
    if selectedQuest then
        AddQuestWatch(selectedQuest)
        Message("Tracking quest. Use the map for Questie pins.")
    else
        Message("Select a quest first.")
    end
end)
Button(guide, "Open Map", 334, -365, 148, function()
    if ToggleWorldMap then ToggleWorldMap() end
end)
Button(guide, "Refresh", 18, -400, 120, RefreshGuide)
Button(guide, "Quest Log", 146, -400, 120, function()
    if ToggleQuestLog then ToggleQuestLog() end
end)
guide:SetScript("OnShow", RefreshGuide)

function JesterFamily_QuestGuide()
    if guide:IsShown() then guide:Hide() else guide:Show() end
end

SLASH_JESTERFAMILY1 = "/family"
SlashCmdList["JESTERFAMILY"] = JesterFamily_Show
SLASH_JESTERGUIDE1 = "/guide"
SlashCmdList["JESTERGUIDE"] = JesterFamily_QuestGuide

local events = CreateFrame("Frame")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("PARTY_MEMBERS_CHANGED")
events:RegisterEvent("RAID_ROSTER_UPDATE")
events:RegisterEvent("QUEST_LOG_UPDATE")
events:SetScript("OnEvent", function(self, event)
    if event == "QUEST_LOG_UPDATE" then
        if guide:IsShown() then RefreshGuide() end
    elseif family:IsShown() then
        RefreshRoster()
    end
end)
