-- ============================================================
-- GuildBankScanner.lua
-- Scans the guild bank and exports a CSV for use with
-- craftingplanner.com (recipe / crafting analysis).
-- ============================================================

local ADDON_NAME = "GuildBankScanner"

-- ── SavedVariables layout ────────────────────────────────────
-- GuildBankScannerDB = {
--   inventory = { [itemID] = { name, itemID, count, tabs } },
--   lastScan  = timestamp string,
--   guildName = string,
-- }

-- ── Constants ────────────────────────────────────────────────
local SLOTS_PER_TAB    = 98
local INTERACTION_TYPE = 10    -- Enum.PlayerInteractionType.GuildBanker
local SPINNER_FRAMES   = { "|", "/", "-", "\\" }

-- ── State ────────────────────────────────────────────────────
local scanInProgress  = false
local tabsToScan      = {}   -- ordered queue of tab indices still to read
local tabsTotal       = 0    -- total tabs we started with (for progress display)
local tabsDone        = 0    -- how many tabs have been fully read
local scanResults     = {}   -- [itemID] = { name, count, tabs={} }
local waitingForTab   = nil  -- the tab index we just queried, awaiting event

-- ── UI references (set during CreateGuildBankButton) ─────────
local scanButton      = nil
local statusLabel     = nil
local spinnerTimer    = nil
local spinnerIndex    = 1

-- ── Utility ──────────────────────────────────────────────────
local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[GuildBankScanner]|r " .. tostring(msg))
end

local function GetItemIDFromLink(link)
    if not link then return nil end
    local itemID = link:match("item:(%d+)")
    return itemID and tonumber(itemID) or nil
end

-- ── Progress UI helpers ───────────────────────────────────────
local function SetButtonScanning(tabName)
    if not scanButton then return end
    scanButton:SetText("Scanning...")
    scanButton:Disable()

    if statusLabel then
        statusLabel:SetText(string.format(
            "|cffffd700Scanning tab %d of %d:|r %s",
            tabsDone + 1, tabsTotal, tabName or "..."
        ))
        statusLabel:Show()
    end
end

local function SetButtonIdle()
    if not scanButton then return end
    scanButton:SetText("Scan Bank")
    scanButton:Enable()

    if statusLabel then
        statusLabel:Hide()
    end

    -- Stop spinner
    if spinnerTimer then
        spinnerTimer:Cancel()
        spinnerTimer = nil
    end
end

local function StartSpinner()
    if spinnerTimer then spinnerTimer:Cancel() end
    spinnerIndex = 1
    spinnerTimer = C_Timer.NewTicker(0.2, function()
        if not scanButton then return end
        spinnerIndex = (spinnerIndex % #SPINNER_FRAMES) + 1
        scanButton:SetText("Scanning " .. SPINNER_FRAMES[spinnerIndex])
    end)
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

    local title = exportFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("Guild Bank Scanner — Export CSV")

    local info = exportFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    info:SetPoint("TOP", 0, -40)
    info:SetTextColor(0.8, 0.8, 0.8)
    info:SetText("Select all (Ctrl-A) then copy (Ctrl-C), then paste into craftingplanner.com.")
    exportFrame.infoText = info

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

    local closeBtn = CreateFrame("Button", nil, exportFrame, "UIPanelButtonTemplate")
    closeBtn:SetSize(100, 26)
    closeBtn:SetPoint("BOTTOMRIGHT", -18, 18)
    closeBtn:SetText("Close")
    closeBtn:SetScript("OnClick", function() exportFrame:Hide() end)

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
        "Guild: %s  |  Scanned: %s  |  Select All → Copy → Paste into craftingplanner.com.",
        guildName or "Unknown", scanTime or "?"
    ))
    f:Show()
    f.editBox:SetFocus()
    f.editBox:HighlightText()
end

-- ── CSV Builder ──────────────────────────────────────────────
local function BuildCSV(inventory, guildName, scanTime)
    local lines = {
        "# GuildBankScanner Export",
        string.format("# Guild: %s", guildName or "Unknown"),
        string.format("# Scanned: %s", scanTime or "?"),
        "itemID,name,totalCount,tabs",
    }

    local sorted = {}
    for _, entry in pairs(inventory) do
        table.insert(sorted, entry)
    end
    table.sort(sorted, function(a, b) return a.name < b.name end)

    for _, entry in ipairs(sorted) do
        local tabList  = table.concat(entry.tabs, "|")
        local safeName = entry.name:gsub(",", ";")
        table.insert(lines, string.format("%d,%s,%d,%s",
            entry.itemID, safeName, entry.count, tabList))
    end

    return table.concat(lines, "\n")
end

-- ── Read one tab's slots into scanResults ────────────────────
local function ReadTab(tab)
    local tabName = GetGuildBankTabInfo(tab) or ("Tab " .. tab)

    for slot = 1, SLOTS_PER_TAB do
        local _, count = GetGuildBankItemInfo(tab, slot)
        if count and count > 0 then
            local link   = GetGuildBankItemLink(tab, slot)
            local itemID = GetItemIDFromLink(link)
            if itemID then
                local name = C_Item.GetItemNameByID(itemID)
                if not name or name == "" then
                    name = link:match("%[(.-)%]") or ("Item:" .. itemID)
                end

                if not scanResults[itemID] then
                    scanResults[itemID] = {
                        itemID = itemID,
                        name   = name,
                        count  = 0,
                        tabs   = {},
                    }
                end

                scanResults[itemID].count = scanResults[itemID].count + count

                local found = false
                for _, t in ipairs(scanResults[itemID].tabs) do
                    if t == tabName then found = true; break end
                end
                if not found then
                    table.insert(scanResults[itemID].tabs, tabName)
                end
            end
        end
    end

    -- Per-tab progress in chat
    tabsDone = tabsDone + 1
    Print(string.format(
        "Tab %d/%d scanned: |cffffd700%s|r",
        tabsDone, tabsTotal, tabName
    ))
end

-- ── Request the next tab ──────────────────────────────────────
local function RequestNextTab()
    if #tabsToScan == 0 then
        -- All tabs done — finalise
        scanInProgress = false
        waitingForTab  = nil
        SetButtonIdle()

        local guildName = GetGuildInfo("player") or "Unknown"
        local scanTime  = date("%Y-%m-%d %H:%M")

        GuildBankScannerDB           = GuildBankScannerDB or {}
        GuildBankScannerDB.inventory = scanResults
        GuildBankScannerDB.lastScan  = scanTime
        GuildBankScannerDB.guildName = guildName

        local count = 0
        for _ in pairs(scanResults) do count = count + 1 end
        Print(string.format(
            "|cff00ff00Scan complete!|r %d unique items found across %d tab(s). Opening export window...",
            count, tabsDone
        ))

        local csv = BuildCSV(scanResults, guildName, scanTime)
        ShowExportWindow(csv, scanTime, guildName)
        return
    end

    -- Peek at the next tab name for the status label
    local nextTab     = tabsToScan[1]
    local nextTabName = GetGuildBankTabInfo(nextTab) or ("Tab " .. nextTab)
    SetButtonScanning(nextTabName)

    local tab = table.remove(tabsToScan, 1)
    waitingForTab = tab
    QueryGuildBankTab(tab)

    -- Safety fallback: if GUILDBANKBAGSLOTS_CHANGED never fires for this tab
    -- (e.g. a locked or empty tab), advance after 3 seconds so the scan doesn't stall.
    C_Timer.After(3, function()
        if scanInProgress and waitingForTab == tab then
            local tabName = GetGuildBankTabInfo(tab) or ("Tab " .. tab)
            Print(string.format("|cffff8800Warning:|r Tab %d (%s) timed out — skipping.", tab, tabName))
            waitingForTab = nil
            RequestNextTab()
        end
    end)
end

-- ── Start scan ───────────────────────────────────────────────
local function StartScan()
    if scanInProgress then
        Print("Scan already in progress, please wait...")
        return
    end

    if not C_PlayerInteractionManager.IsInteractingWithNpcOfType(INTERACTION_TYPE) then
        Print("|cffff4444You must be standing at the Guild Bank to scan.|r")
        return
    end

    local totalTabs = GetNumGuildBankTabs()
    if totalTabs == 0 then
        Print("No accessible guild bank tabs found.")
        return
    end

    tabsToScan = {}
    for i = 1, totalTabs do
        -- GetGuildBankTabInfo returns: name, icon, isViewable, canDeposit, ...
        -- This is the authoritative source for whether the player can see a tab.
        local _, _, isViewable = GetGuildBankTabInfo(i)
        if isViewable then
            table.insert(tabsToScan, i)
        end
    end

    if #tabsToScan == 0 then
        Print("No tabs are accessible with your current permissions.")
        return
    end

    tabsTotal      = #tabsToScan
    tabsDone       = 0
    scanInProgress = true
    scanResults    = {}
    waitingForTab  = nil

    Print(string.format("Starting scan of %d accessible tab(s)...", tabsTotal))
    StartSpinner()
    RequestNextTab()
end

-- ── Guild Bank Button & Status Label ─────────────────────────
local function CreateGuildBankButton()
    if scanButton then return end

    -- Scan button
    scanButton = CreateFrame("Button", "GBSScanButton", GuildBankFrame, "UIPanelButtonTemplate")
    scanButton:SetSize(110, 22)
    scanButton:SetPoint("BOTTOMLEFT", GuildBankFrame, "BOTTOMLEFT", 8, 8)
    scanButton:SetText("Scan Bank")
    scanButton:SetScript("OnClick", StartScan)

    scanButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Guild Bank Scanner", 1, 1, 1)
        GameTooltip:AddLine("Click to scan all accessible tabs\nand export inventory as CSV.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    scanButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Status label — sits just above the button, hidden when idle
    statusLabel = GuildBankFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusLabel:SetPoint("BOTTOMLEFT", GuildBankFrame, "BOTTOMLEFT", 8, 34)
    statusLabel:SetPoint("BOTTOMRIGHT", GuildBankFrame, "BOTTOMRIGHT", -8, 34)
    statusLabel:SetJustifyH("LEFT")
    statusLabel:SetTextColor(0.8, 0.8, 0.8)
    statusLabel:Hide()
end

-- ── Event Handler ─────────────────────────────────────────────
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
eventFrame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
eventFrame:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")

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
            if statusLabel then statusLabel:Hide() end
            if scanInProgress then
                Print("|cffff4444Scan aborted — guild bank was closed.|r")
                scanInProgress = false
                waitingForTab  = nil
                tabsToScan     = {}
                SetButtonIdle()
            end
        end

    elseif event == "GUILDBANKBAGSLOTS_CHANGED" then
        if scanInProgress and waitingForTab then
            local tab = waitingForTab
            waitingForTab = nil
            ReadTab(tab)
            RequestNextTab()
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