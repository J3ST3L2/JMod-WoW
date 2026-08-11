--[[
JesterConsole 1.0.1
===================

WoW 3.3.5a / AzerothCore GM helper console.

v1.0.1:
- Removes unsupported EditBox OnArrowPressed handler from 3.3.5a.
- Uses OnKeyDown for Up/Down command history instead.
]]

JesterConsoleDB = JesterConsoleDB or {}

local JC = {}
JC.history = {}
JC.historyIndex = 1
JC.maxHistory = 50

local itemAliases = {
    ["bags"]                 = { id = 41600, count = 4, label = "4 Glacial Bags" },
    ["bag"]                  = { id = 41600, count = 1, label = "Glacial Bag" },
    ["glacial bag"]          = { id = 41600, count = 1, label = "Glacial Bag" },
    ["glacial bags"]         = { id = 41600, count = 4, label = "4 Glacial Bags" },

    ["shadowmourne"]         = { id = 49623, count = 1, label = "Shadowmourne" },
    ["benediction"]          = { id = 18608, count = 1, label = "Benediction" },

    ["halo"]                 = { id = 16921, count = 1, label = "Halo of Transcendence" },
    ["neck"]                 = { id = 18723, count = 1, label = "Animated Chain Necklace" },
    ["shoulders"]            = { id = 16924, count = 1, label = "Pauldrons of Transcendence" },
    ["cloak"]                = { id = 19870, count = 1, label = "Hakkari Loa Cloak" },
    ["chest"]                = { id = 16923, count = 1, label = "Robes of Transcendence" },
    ["wrists"]               = { id = 16926, count = 1, label = "Bindings of Transcendence" },
    ["hands"]                = { id = 16920, count = 1, label = "Handguards of Transcendence" },
    ["belt"]                 = { id = 16925, count = 1, label = "Belt of Transcendence" },
    ["legs"]                 = { id = 16922, count = 1, label = "Leggings of Transcendence" },
    ["boots"]                = { id = 16919, count = 1, label = "Boots of Transcendence" },
    ["ring1"]                = { id = 19382, count = 1, label = "Pure Elementium Band" },
    ["ring2"]                = { id = 19140, count = 1, label = "Cauterizing Band" },
    ["trinket1"]             = { id = 19395, count = 1, label = "Rejuvenating Gem" },
    ["trinket2"]             = { id = 17064, count = 1, label = "Shard of the Scale" },
    ["wand"]                 = { id = 19435, count = 1, label = "Essence Gatherer" },
}

local function trim(text)
    if not text then return "" end
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function lower(text)
    return string.lower(trim(text or ""))
end

local function Print(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cffb56cffJesterConsole:|r " .. tostring(message))
end

local function AddHistory(text)
    text = trim(text)
    if text == "" then return end

    if JC.history[#JC.history] ~= text then
        table.insert(JC.history, text)
    end

    while #JC.history > JC.maxHistory do
        table.remove(JC.history, 1)
    end

    JC.historyIndex = #JC.history + 1
    JesterConsoleDB.history = JC.history
end

local function SendGMCommand(command)
    command = trim(command)
    if command == "" then return end

    AddHistory(command)
    Print("Running |cffffffff" .. command .. "|r")
    SendChatMessage(command, "SAY")
end

local function AddItem(itemID, count)
    itemID = tonumber(itemID)
    count = tonumber(count) or 1

    if not itemID or itemID < 1 then
        Print("|cffff5555Invalid item ID.|r")
        return
    end

    if count < 1 then count = 1 end
    if count > 1000 then count = 1000 end

    SendGMCommand(string.format(".additem %d %d", itemID, count))
end

local function ShowHelp()
    Print("Commands:")
    Print("  |cffffffffitem <id> [count]|r   Example: item 41600 4")
    Print("  |cffffffffadd <id> [count]|r    Same as item")
    Print("  |cffffffffbags|r                 Adds 4 Glacial Bags")
    Print("  |cffffffffshadowmourne|r         Adds Shadowmourne")
    Print("  |cffffffffbenediction|r          Adds Benediction")
    Print("  |cffffffff.raw <command>|r       Sends an exact GM dot-command")
    Print("  Direct dot-commands work too, e.g. |cffffffff.additem 41600 4|r")
end

local function ResolveInput(text)
    text = trim(text)
    if text == "" then return end

    local normalized = lower(text)

    if normalized == "help" or normalized == "?" then
        ShowHelp()
        return
    end

    local alias = itemAliases[normalized]
    if alias then
        Print("Adding " .. alias.label)
        AddItem(alias.id, alias.count)
        return
    end

    local verb, id, count = normalized:match("^(item)%s+(%d+)%s*(%d*)$")
    if not verb then
        verb, id, count = normalized:match("^(add)%s+(%d+)%s*(%d*)$")
    end

    if verb and id then
        AddItem(id, count ~= "" and count or 1)
        return
    end

    local raw = text:match("^%.raw%s+(.+)$")
    if raw then
        if raw:sub(1, 1) ~= "." and raw:sub(1, 1) ~= "!" then
            Print("|cffff5555Raw GM commands must start with . or !|r")
            return
        end
        SendGMCommand(raw)
        return
    end

    if text:sub(1, 1) == "." or text:sub(1, 1) == "!" then
        SendGMCommand(text)
        return
    end

    Print("|cffff5555Unknown command:|r " .. text)
    Print("Type |cffffffffhelp|r for examples.")
end

local frame = CreateFrame("Frame", "JesterConsoleFrame", UIParent)
frame:SetWidth(640)
frame:SetHeight(190)
frame:SetPoint("TOP", UIParent, "TOP", 0, -60)
frame:SetFrameStrata("DIALOG")
frame:SetClampedToScreen(true)
frame:EnableMouse(true)
frame:SetMovable(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:Hide()

frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
frame:SetBackdropColor(0.03, 0.03, 0.03, 0.96)

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -13)
title:SetText("|cffb56cffJester Console|r")

local subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
subtitle:SetPoint("LEFT", title, "RIGHT", 10, 0)
subtitle:SetText("AzerothCore GM helper")

local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)

local prompt = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
prompt:SetPoint("TOPLEFT", frame, "TOPLEFT", 17, -47)
prompt:SetText(">")

local input = CreateFrame("EditBox", "JesterConsoleInput", frame, "InputBoxTemplate")
input:SetAutoFocus(false)
input:SetWidth(545)
input:SetHeight(30)
input:SetPoint("LEFT", prompt, "RIGHT", 10, 0)
input:SetFontObject(ChatFontNormal)
input:SetMaxLetters(255)

local runButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
runButton:SetWidth(60)
runButton:SetHeight(24)
runButton:SetPoint("LEFT", input, "RIGHT", 7, 0)
runButton:SetText("Run")

local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
hint:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -78)
hint:SetText("Enter runs  |  Up/Down history  |  Esc closes  |  Try: bags, shadowmourne, item 41600 4")

local function MakeButton(label, x, width, callback)
    local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    button:SetWidth(width or 100)
    button:SetHeight(25)
    button:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", x, 18)
    button:SetText(label)
    button:SetScript("OnClick", callback)
    return button
end

MakeButton("4 Bags", 18, 84, function() AddItem(41600, 4) end)
MakeButton("Shadowmourne", 108, 112, function() AddItem(49623, 1) end)
MakeButton("Benediction", 226, 105, function() AddItem(18608, 1) end)

MakeButton("Priest T2 Set", 337, 105, function()
    local ids = {16921, 16924, 16923, 16926, 16920, 16925, 16922, 16919}
    for _, itemID in ipairs(ids) do
        AddItem(itemID, 1)
    end
end)

MakeButton("Help", 448, 72, ShowHelp)
MakeButton("Clear", 526, 72, function()
    input:SetText("")
    input:SetFocus()
end)

local function ExecuteInput()
    local text = input:GetText()
    if trim(text) == "" then return end

    ResolveInput(text)
    input:SetText("")
    input:SetFocus()
end

runButton:SetScript("OnClick", ExecuteInput)
input:SetScript("OnEnterPressed", ExecuteInput)

input:SetScript("OnEscapePressed", function()
    frame:Hide()
    input:ClearFocus()
end)

-- WoW 3.3.5a EditBox does not support OnArrowPressed.
-- OnKeyDown is available on the underlying frame and is used instead.
input:EnableKeyboard(true)
input:SetScript("OnKeyDown", function(self, key)
    if #JC.history == 0 then return end

    if key == "UP" then
        JC.historyIndex = JC.historyIndex - 1
        if JC.historyIndex < 1 then
            JC.historyIndex = 1
        end

        self:SetText(JC.history[JC.historyIndex] or "")
        self:SetCursorPosition(string.len(self:GetText()))

    elseif key == "DOWN" then
        JC.historyIndex = JC.historyIndex + 1

        if JC.historyIndex > #JC.history + 1 then
            JC.historyIndex = #JC.history + 1
        end

        if JC.historyIndex == #JC.history + 1 then
            self:SetText("")
        else
            self:SetText(JC.history[JC.historyIndex] or "")
            self:SetCursorPosition(string.len(self:GetText()))
        end
    end
end)

function JesterConsole_Toggle()
    if frame:IsShown() then
        frame:Hide()
        input:ClearFocus()
    else
        frame:Show()
        input:SetFocus()
    end
end

SLASH_JESTERCONSOLE1 = "/jc"
SLASH_JESTERCONSOLE2 = "/jester"

SlashCmdList["JESTERCONSOLE"] = function(msg)
    msg = trim(msg)

    if msg == "" then
        JesterConsole_Toggle()
    else
        ResolveInput(msg)
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function()
    if type(JesterConsoleDB.history) == "table" then
        JC.history = JesterConsoleDB.history
        JC.historyIndex = #JC.history + 1
    end

    Print("Loaded. Type |cffffffff/jc|r to open JesterConsole.")

    -- Do not force a tilde binding here.
    -- 3.3.5 key naming varies by client/locale, so binding is safer via
    -- Esc -> Key Bindings -> JesterConsole Toggle.
end)
