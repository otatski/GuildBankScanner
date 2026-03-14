-- ============================================================
-- GuildBankScanner.lua
-- Scans the guild bank and exports a CSV for use in the
-- companion web app (recipe / crafting analysis).
-- ============================================================

local ADDON_NAME = "GuildBankScanner"
local GBS = {}

-- ── SavedVariables layout ────────────────────────────────────
-- GuildBankScannerDB = {
--   inventory = { [itemID] = { name, itemID, count, tabs } },
--   lastScan  = timestamp string,
--   guildName = string,
-- }

-- ── Constants ────────────────────────────────────────────────
local SLOTS_PER_TAB      = 98
local SCAN_DELAY         = 0.3   -- seconds between tab queries
local INTERACTION_TYPE   = 10    -- Enum.PlayerInteractionType.GuildBanker

-- ── State ────────────────────────────────────────────────────
local scanInProgress  = false
local tabsToScan      = {}       -- queue of tab indices
local scanResults     = {}       -- [itemID] = { name, count, tabs={} }
local currentTabIndex = 0
local totalTabs       = 0

-- ── Utility ──────────────────────────────────────────────────
local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[GuildBankScanner]|r " .. tostring(msg))
end

local function GetItemIDFromLink(link)
    if not link then return nil end
    local itemID = link:match("item:(%d+)")
    return itemID and tonumber(itemID) or nil
end

-- ── Export Window ────────────────────────────────────────────
local exportFrame

local function BuildExportFrame()
    if exportFrame then return exportFrame end

    exportFrame = CreateFrame("Frame", "GBSExportFrame", UIParent, "BackdropTemplate")
    exportFrame:SetSize(520, 440)
    exportFrame:SetPoint("CENTER")
    exportFrame:SetFrameStrata("DIALOG")
    exportFrame:SetMovable(true)
    exportFrame:EnableMouse(true)
    exportFrame:RegisterForDrag("LeftButton")
    exportFrame:SetScript("OnDragStart", exportFrame.StartMoving)
    exportFrame:SetScript("OnDragStop",  exportFrame.StopMovingOrSizing)
    exportFrame:SetBackdrop({
        bgFile   = "Interface/DialogFrame/UI-DialogBox-Background",
        edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 32,
        insets   = { left=11, right=12, top=12, bottom=11 },
    })
    exportFrame:Hide()

    -- Title
    local title = exportFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("Guild Bank Scanner — Export CSV")

    -- Info line
    local info = exportFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    info:SetPoint("TOP", 0, -40)
    info:SetTextColor(0.8, 0.8, 0.8)
    info:SetText("Select all (Ctrl-A) then copy (Ctrl-C), then paste into the web app.")
    exportFrame.infoText = info

    -- Scroll area
    local scrollFrame = CreateFrame("ScrollFrame", nil, exportFrame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 18, -65)
    scrollFrame:SetPoint("BOTTOMRIGHT", -36, 50)

    local editBox = CreateFrame("EditBox", nil, scrollFrame)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetWidth(450)
    editBox:SetText("")
    scrollFrame:SetScrollChild(editBox)
    exportFrame.editBox = editBox

    -- Close button
    local closeBtn = CreateFrame("Button", nil, exportFrame, "UIPanelButtonTemplate")
    closeBtn:SetSize(100, 26)
    closeBtn:SetPoint("BOTTOMRIGHT", -18, 18)
    closeBtn:SetText("Close")
    closeBtn:SetScript("OnClick", function() exportFrame:Hide() end)

    -- Copy-all helper button
    local copyBtn = CreateFrame("Button", nil, exportFrame, "UIPanelButtonTemplate")
    copyBtn:SetSize(100, 26)
    copyBtn:SetPoint("BOTTOMLEFT", 18, 18)
    copyBtn:SetText("Select All")
    copyBtn:SetScript("OnClick", function()
        editBox:SetFocus()
        editBox:HighlightText()
    end)

    return exportFrame
end

local function ShowExportWindow(csvText, scanTime, guildName)
    local f = BuildExportFrame()
    f.editBox:SetText(csvText)
    f.infoText:SetText(string.format(
        "Guild: %s  |  Scanned: %s  |  Select All → Copy → Paste into web app.",
        guildName or "Unknown", scanTime or "?"
    ))
    f:Show()
    f.editBox:SetFocus()
    f.editBox:HighlightText()
end

-- ── CSV Builder ──────────────────────────────────────────────
local function BuildCSV(inventory, guildName, scanTime)
    local lines = {
        string.format("# GuildBankScanner Export"),
        string.format("# Guild: %s", guildName or "Unknown"),
        string.format("# Scanned: %s", scanTime or "?"),
        "itemID,name,totalCount,tabs",
    }
    -- Sort by name for readability
    local sorted = {}
    for _, entry in pairs(inventory) do
        table.insert(sorted, entry)
    end
    table.sort(sorted, function(a, b) return a.name < b.name end)

    for _, entry in ipairs(sorted) do
        local tabList = table.concat(entry.tabs, "|")
        -- Escape any commas in item names
        local safeName = entry.name:gsub(",", ";")
        table.insert(lines, string.format("%d,%s,%d,%s",
            entry.itemID, safeName, entry.count, tabList))
    end
    return table.concat(lines, "\n")
end

-- ── Scan Logic ───────────────────────────────────────────────
local scanTimer

local function ProcessNextTab()
    if #tabsToScan == 0 then
        -- Done scanning all tabs
        scanInProgress = false

        local guildName = GetGuildInfo("player") or "Unknown"
        local scanTime  = date("%Y-%m-%d %H:%M")

        -- Persist to SavedVariables
        GuildBankScannerDB = GuildBankScannerDB or {}
        GuildBankScannerDB.inventory = scanResults
        GuildBankScannerDB.lastScan  = scanTime
        GuildBankScannerDB.guildName = guildName

        local csv = BuildCSV(scanResults, guildName, scanTime)
        Print(string.format("Scan complete! %d unique items found. Opening export window...",
            (function() local n=0; for _ in pairs(scanResults) do n=n+1 end; return n end)()))
        ShowExportWindow(csv, scanTime, guildName)
        return
    end

    local tab = table.remove(tabsToScan, 1)
    currentTabIndex = tab
    QueryGuildBankTab(tab)

    -- Wait for data to arrive before reading slots
    scanTimer = C_Timer.After(SCAN_DELAY, function()
        local tabName = GetGuildBankTabInfo(tab) or ("Tab " .. tab)

        for slot = 1, SLOTS_PER_TAB do
            local _, count = GetGuildBankItemInfo(tab, slot)
            if count and count > 0 then
                local link = GetGuildBankItemLink(tab, slot)
                local itemID = GetItemIDFromLink(link)
                if itemID then
                    local name = C_Item.GetItemNameByID(itemID) or link or ("Item:" .. itemID)
                    if not scanResults[itemID] then
                        scanResults[itemID] = {
                            itemID = itemID,
                            name   = name,
                            count  = 0,
                            tabs   = {},
                        }
                    end
                    scanResults[itemID].count = scanResults[itemID].count + count
                    -- Track which tabs hold this item (avoid duplicates)
                    local tabAlreadyAdded = false
                    for _, t in ipairs(scanResults[itemID].tabs) do
                        if t == tabName then tabAlreadyAdded = true; break end
                    end
                    if not tabAlreadyAdded then
                        table.insert(scanResults[itemID].tabs, tabName)
                    end
                end
            end
        end

        -- Move to next tab
        ProcessNextTab()
    end)
end

local function StartScan()
    if scanInProgress then
        Print("Scan already in progress, please wait...")
        return
    end

    -- Must be at the guild bank
    if not C_PlayerInteractionManager.IsInteractingWithNpcOfType(INTERACTION_TYPE) then
        Print("|cffff4444You must be standing at the Guild Bank to scan.|r")
        return
    end

    Print("Starting guild bank scan...")
    scanInProgress = true
    scanResults    = {}
    tabsToScan     = {}

    totalTabs = GetNumGuildBankTabs()
    if totalTabs == 0 then
        Print("No accessible guild bank tabs found.")
        scanInProgress = false
        return
    end

    for i = 1, totalTabs do
        local _, _, isViewable = GetGuildBankTabPermissions(i)
        if isViewable then
            table.insert(tabsToScan, i)
        end
    end

    Print(string.format("Scanning %d accessible tab(s)...", #tabsToScan))
    ProcessNextTab()
end

-- ── Guild Bank Button ─────────────────────────────────────────
local scanButton

local function CreateGuildBankButton()
    if scanButton then return end

    scanButton = CreateFrame("Button", "GBSScanButton", GuildBankFrame, "UIPanelButtonTemplate")
    scanButton:SetSize(110, 22)
    -- Anchor just above the bottom-left of the guild bank frame
    scanButton:SetPoint("BOTTOMLEFT", GuildBankFrame, "BOTTOMLEFT", 8, 8)
    scanButton:SetText("Scan Bank")
    scanButton:SetScript("OnClick", StartScan)

    -- Tooltip
    scanButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Guild Bank Scanner", 1, 1, 1)
        GameTooltip:AddLine("Click to scan all accessible tabs\nand export inventory as CSV.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    scanButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

-- ── Event Handler ─────────────────────────────────────────────
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
eventFrame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == ADDON_NAME then
            GuildBankScannerDB = GuildBankScannerDB or {}
            Print("Loaded. Use |cffffd700/gbscan|r or open the Guild Bank for the scan button.")
        end

    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        local interactionType = ...
        if interactionType == INTERACTION_TYPE then
            -- Guild bank just opened — attach our button
            C_Timer.After(0.1, function()
                if GuildBankFrame and GuildBankFrame:IsShown() then
                    CreateGuildBankButton()
                    if scanButton then scanButton:Show() end
                end
            end)
        end

    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        local interactionType = ...
        if interactionType == INTERACTION_TYPE then
            if scanButton then scanButton:Hide() end
        end
    end
end)

-- ── Slash Commands ────────────────────────────────────────────
SLASH_GBSCAN1 = "/gbscan"
SLASH_GBSCAN2 = "/guildbankscanner"

SlashCmdList["GBSCAN"] = function(msg)
    local cmd = strtrim(msg):lower()

    if cmd == "" or cmd == "scan" then
        StartScan()

    elseif cmd == "export" then
        -- Re-open export window with last saved scan
        if GuildBankScannerDB and GuildBankScannerDB.inventory then
            local csv = BuildCSV(
                GuildBankScannerDB.inventory,
                GuildBankScannerDB.guildName,
                GuildBankScannerDB.lastScan
            )
            ShowExportWindow(csv, GuildBankScannerDB.lastScan, GuildBankScannerDB.guildName)
        else
            Print("No saved scan found. Run |cffffd700/gbscan|r at the guild bank first.")
        end

    elseif cmd == "help" then
        Print("|cffffd700/gbscan|r          — scan the guild bank (must be at bank)")
        Print("|cffffd700/gbscan export|r   — re-open the CSV export window")
        Print("|cffffd700/gbscan help|r     — show this help")

    else
        Print("Unknown command. Try |cffffd700/gbscan help|r")
    end
end
