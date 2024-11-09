-- DkpBids.lua
-- Version: 0.1
-- Created by: Nils

addon.name      = 'DkpBids';
addon.author    = 'Nils';
addon.version   = '0.1';
addon.desc      = 'Handles item bidding in Linkshell chat';
addon.link      = '';

require('common')
local imgui = require('imgui')

-- Bidding Variables
local bids = {
    items = T{},
    is_open = { true, },
    messages = T{},
    message_ids = {},
    timer_duration = 180, -- Set timer to 180 seconds
    start_time = 0, -- To capture the start time
    winners = T{}, -- Table to hold winners for each item
    is_bidding_active = false,
    notified_30_seconds = false, -- Flag to check if the 30 seconds message has been sent
    itemInactiveTimers = {}, -- Table to track inactivity timers for each item
    loggingFolder = "", -- Logging folder path
};

local whitelist = T{} -- Table to hold whitelisted items
local dkp_data = T{} -- Table to hold player DKP values for DKP
local edkp_data = T{} -- Table to hold player DKP values for EDKP

------------------------------
-- Load DKP Data from CSV --
------------------------------
local function LoadDkpData(folder, dataTable)
    local filePath = addon.path:append(folder .. '\\dkp.txt')
    print("Attempting to load DKP data from:", filePath)

    local file = io.open(filePath, 'r')
    if not file then
        print("Error: Unable to open DKP file at", filePath)
        return
    end

    print("File opened successfully. Reading content:")
    dataTable:clear() -- Clear previous data

    local line_count = 0
    for line in file:lines() do
        line_count = line_count + 1
        print("Line " .. line_count .. ": " .. line) -- Print each line for verification

        local parts = {}
        for part in line:gmatch("([^,]+)") do
            table.insert(parts, part:trim()) -- Trim whitespace
        end
        
        if #parts == 2 then
            local name = parts[1]:gsub("^%s*(.-)%s*$", "%1") -- Trim whitespace around name
            local dkp,_ = (parts[2]:gsub("^%s*(.-)%s*$", "%1"))
            dkp = tonumber(dkp)
            
            if name and dkp then
                dataTable[name] = dkp
                print("Loaded entry into dataTable:", name, dkp)
            else
                print("Parsing error: Could not convert name or DKP value on line " .. line_count)
            end
        else
            print("Formatting error on line " .. line_count .. ": Line does not have exactly 2 parts.")
        end
    end

    file:close()
    print("Total entries loaded into dataTable:", #dataTable)
end

------------------------------
-- Load Whitelist Items --
------------------------------
local function LoadWhitelist()
    local filePath = addon.path:append('\\whitelist.txt') -- Adjust the path as necessary
    local file = io.open(filePath, 'r')

    if file then
        for line in file:lines() do
            line = line:trim() -- Remove leading/trailing whitespace
            if line ~= '' then
                whitelist:append(line) -- Add item to the whitelist
            end
        end
        file:close()
        print("Whitelist loaded with " .. #whitelist .. " items.")
    else
        print("Warning: Whitelist file not found.")
    end
end

------------------------------
-- Load Treasure Pool Items --
------------------------------
local function GetTreasurePoolItems()
    bids.items:clear() -- Clear previous items
    bids.winners:clear() -- Clear previous winners
    bids.itemInactiveTimers = {} -- Clear previous inactivity timers

    local inv = AshitaCore:GetMemoryManager():GetInventory()
    if not inv then
        print("Error: Unable to access inventory.")
        return
    end

    for i = 0, 9 do
        local treasureItem = inv:GetTreasurePoolItem(i)
        if treasureItem and treasureItem.ItemId > 0 then
            local itemInfo = AshitaCore:GetResourceManager():GetItemById(treasureItem.ItemId)
            if itemInfo then
                -- Check if the item is in the whitelist
                if whitelist:contains(itemInfo.Name[1]) then
                    bids.items:append(itemInfo.Name[1]) -- Append the item name to the items list
                    bids.winners:append({name = nil, amount = 0}) -- Initialize winners for each item
                    bids.itemInactiveTimers[#bids.items] = os.time() -- Initialize inactivity timer for each item
                end
            else
                print("Error: Unable to get item info for ItemId: " .. treasureItem.ItemId)
            end
        end
    end

    if #bids.items == 0 then
        print("No items found in the treasure pool.")
    end
end

-----------------------------
-- Post Items to Linkshell Chat --
-----------------------------
local function PostItemsToLinkshellChat()
    local startMessage = "Bidding has started! Use \"!bid # dkp\" : Items up for bid:"
    
    local chatManager = AshitaCore:GetChatManager()
    if chatManager then
        print("Chat Manager is available.")

        chatManager:QueueCommand(1, '/l ' .. startMessage)
        coroutine.sleep(1.5)

        for index, item in ipairs(bids.items) do
            local itemMessage = string.format("%d. [%s]", index, item)
            chatManager:QueueCommand(1, '/l ' .. itemMessage)
            print("Sent message: " .. itemMessage)
            coroutine.sleep(1.5)
        end
    else
        print("Error: Chat Manager is not available.")
    end
end

---------------------------
-- Start Bidding Timer --
---------------------------
local function StartBiddingTimer()
    bids.start_time = os.time() -- Capture the current system time
    bids.is_bidding_active = true
    bids.notified_30_seconds = false
    print("Bidding timer started.")
end

------------------------
-- Handle Incoming Bids --
------------------------
local function HandleBid(itemId, bidAmount, playerName)
    local maxDkp = dkp_data[playerName:trim()] or edkp_data[playerName:trim()]

    if not maxDkp then
        print("Bid rejected: " .. playerName .. " does not have a registered DKP value.")
        return
    elseif bidAmount > maxDkp then
        print("Bid rejected: " .. playerName .. " attempted to bid " .. bidAmount .. " DKP, exceeding their maximum of " .. maxDkp)
        return
    elseif bidAmount < 1 or bidAmount % 1 ~= 0 then
        print("Bid rejected: " .. playerName .. " attempted to bid " .. bidAmount .. " DKP (must be a whole number)")
        return
    end

    -- Update winner if new bid is higher
    if bids.winners[itemId] == nil or bidAmount > bids.winners[itemId].amount then
        bids.winners[itemId] = {name = playerName, amount = bidAmount}
    end
    
    bids.messages:append(playerName .. " bids " .. bidAmount .. " DKP on item " .. itemId)
    bids.message_ids[playerName .. itemId] = true

    -- Reset inactivity timer for this specific item
    bids.itemInactiveTimers[itemId] = os.time()
    print("Inactivity timer for item " .. itemId .. " reset.")
end

-----------------------
-- Write Winners to CSV --
-----------------------
local function WriteWinnersToCSV(folder)
    local folderPath = folder or '\\DKPLogs' -- Default to DKPLogs if no folder specified
    local filePath = addon.path:append(folderPath .. '\\bidding_results_' .. os.date('%Y%m%d_%H%M%S') .. '.csv')
    local file = io.open(filePath, 'w')

    if file then
        local timestamp = os.date('%Y-%m-%d %H:%M:%S')

        for index, item in ipairs(bids.items) do
            local winner = bids.winners[index]
            if winner and winner.name then
                file:write(string.format("%s,%s,%d,%s\n", item, winner.name, winner.amount, timestamp))
            else
                file:write(string.format("%s,No bids placed,0,%s\n", item, timestamp))
            end
        end

        file:close()
        print("Bidding results saved to " .. filePath)
    else
        print("Error: Unable to create CSV file.")
    end
end

-----------------------
-- End Bidding --
-----------------------
local function EndBidding(command)
    local chatManager = AshitaCore:GetChatManager()
    if chatManager then
        chatManager:QueueCommand(1, '/l Bidding has ended.');
        bids.is_bidding_active = false

        coroutine.sleep(1.5)

        local itemsToPost = {}
        for i = 1, #bids.items do
            if bids.items[i] then
                local winner = bids.winners[i]
                local itemMessage = winner and string.format("%s : %s : %d DKP", bids.items[i], winner.name, winner.amount) 
                                      or string.format("%s : No bids placed", bids.items[i])
                table.insert(itemsToPost, itemMessage)
            end
        end

        for _, line in ipairs(itemsToPost) do
            chatManager:QueueCommand(1, '/l ' .. line)
            print("Sent message: " .. line)
            coroutine.sleep(1.5)
        end

        WriteWinnersToCSV(bids.loggingFolder) -- Use the set logging folder
    else
        print("Error: Chat Manager is not available when ending bidding.")
    end
end

------------------------
-- Respond to Tells --
------------------------
local function RespondToTell(playerName, dataTable)
    local dkp = dataTable[playerName:trim()]
    if dkp then
        local chatManager = AshitaCore:GetChatManager()
        if chatManager then
            chatManager:QueueCommand(1, '/t ' .. playerName .. ' Your current DKP is ' .. dkp)
        end
    else
        print("No DKP data found for " .. playerName)
    end
end

------------------------
-- Reset Functionality --
------------------------
local function ResetAddon()
    bids.items:clear()
    bids.messages:clear()
    bids.start_time = 0
    bids.winners:clear()
    bids.is_bidding_active = false
    bids.itemInactiveTimers = {} -- Reset inactivity timers
    print("DkpBids addon has been reset.")
end

------------------------
-- On Command Received --
------------------------
ashita.events.register('command', 'command_cb', function(e)
    local args = e.command:args();
    if (#args == 0 or not (args[1]:any('/dkpbids') or args[1]:any('/db') or args[1]:any('/dbe'))) then
        return;
    end
    e.blocked = true;

    -- Handle commands for /db and /dkpbids
    if args[1]:any('/dkpbids') or args[1]:any('/db') then
        if args[2] == "start" and not bids.is_bidding_active then
            ResetAddon() -- Reset the addon
            LoadDkpData('\\DKP', dkp_data) -- Load DKP data
            LoadWhitelist()
            GetTreasurePoolItems()
            PostItemsToLinkshellChat()
            StartBiddingTimer()
            bids.loggingFolder = '\\DKPLogs' -- Set logging folder for DKP
            bids.is_open[1] = true
        elseif args[2] == "stop" then
            bids.is_bidding_active = false
        elseif args[2] == "reset" then
            ResetAddon()
        elseif args[2] == "show" then
            bids.is_open[1] = true
        elseif args[2] == "hide" then
            bids.is_open[1] = false
        elseif args[2] == "end" then
            EndBidding("/db") -- Call end bidding with appropriate command
        end
    end

    -- Handle commands for /dbe
    if args[1]:any('/dbe') and args[2] == "start" and not bids.is_bidding_active then
        ResetAddon() -- Reset the addon
        LoadDkpData('\\EDKP', edkp_data) -- Load EDKP data
        LoadWhitelist()
        GetTreasurePoolItems()
        PostItemsToLinkshellChat()
        StartBiddingTimer()
        bids.loggingFolder = '\\EDKPLogs' -- Set logging folder for EDKP
        bids.is_open[1] = true
    elseif args[1]:any('/dbe') and args[2] == "end" then
        EndBidding("/dbe") -- Call end bidding for EDKP
    end
end)

----------------------------
-- Read Incoming Packets --
----------------------------
ashita.events.register('packet_in', 'packet_in_cb', function(e)
    if e.id == 0x017 or e.id == 0x015 then -- Check for tell and Linkshell message packets
        local msgType = struct.unpack('B', e.data, 0x04 + 1)

        local character = struct.unpack('c15', e.data_modified, 0x08 + 1):trimend('\x00');
        local msg = struct.unpack('s', e.data_modified, 0x17 + 0x01);

        -- Clean up the message
        msg = string.gsub(msg, "%%", "%%%%");

        if msgType == 3 then -- Tells are message type 3
            print("Received tell from " .. character .. ": " .. msg)

            -- Handle tell command for checking DKP
            if msg:match("!dkp") then
                RespondToTell(character, dkp_data)
            elseif msg:match("!edkp") then
                RespondToTell(character, edkp_data)
            end

            -- Handle bid commands from tells
            local bidPattern = "!bid (%d+%.?%d*) (%d+%.?%d*)"; -- Match bids
            local itemId, bidAmount = msg:match(bidPattern);
            if itemId and bidAmount and bids.is_bidding_active then
                print("Bid recognized from Tell: Item ID = " .. itemId .. ", Bid Amount = " .. bidAmount)
                HandleBid(tonumber(itemId), tonumber(bidAmount), character);
            else
                print("No valid bid found in tell message.")
            end

        elseif msgType == 5 then -- Linkshell messages are message type 5
            print("Received Linkshell message from " .. character .. ": " .. msg)

            -- Handle bid commands from Linkshell messages
            local bidPattern = "!bid (%d+%.?%d*) (%d+%.?%d*)"; -- Match bids
            local itemId, bidAmount = msg:match(bidPattern);
            if itemId and bidAmount and bids.is_bidding_active then
                print("Linkshell bid recognized: Item ID = " .. itemId .. ", Bid Amount = " .. bidAmount)
                HandleBid(tonumber(itemId), tonumber(bidAmount), character);
            else
                print("No valid bid found in Linkshell message.")
            end
        end
    end
end)

---------------------------
-- Outgoing Messages --
---------------------------
ashita.events.register('packet_out', 'packet_out_cb', function(e)
    if (e.id == 0x0B5) then -- Outgoing chat message packet
        local msgType = struct.unpack('B', e.data, 0x04 + 1);
        local msg = struct.unpack('s', e.data_modified, 0x06 + 0x01); 

        print("Sent message: " .. msg)

        local playerName = AshitaCore:GetMemoryManager():GetParty():GetMemberName(0); -- Get the first member's name

        local bidPattern = "!bid (%d+%.?%d*) (%d+%.?%d*)"; -- Match bids
        local itemId, bidAmount = msg:match(bidPattern);
        
        if itemId and bidAmount and bids.is_bidding_active and playerName then
            print("Outgoing bid recognized: Item ID = " .. itemId .. ", Bid Amount = " .. bidAmount)
            HandleBid(tonumber(itemId), tonumber(bidAmount), playerName);
        end
        
        if msgType == 5 then
            print("Outgoing Linkshell chat message detected: " .. msg)
        end
    end
end)

---------------------------
-- Bidding Timer Check --
---------------------------
ashita.events.register('timer', 'timer_cb', function()
    if bids.is_bidding_active then
        -- Check each item for inactivity
        for i = 1, #bids.items do
            if bids.itemInactiveTimers[i] then
                local timeSinceLastBid = os.time() - bids.itemInactiveTimers[i]
                
                if timeSinceLastBid >= 30 and (bids.winners[i].amount > 0) then
                    print("No new bids for item " .. i .. ". Ending bidding for this item.")
                    bids.messages:append(string.format("Bidding for %s has ended. Winner: %s with %d DKP", bids.items[i], bids.winners[i].name, bids.winners[i].amount))
                    bids.winners[i].amount = -1 -- Mark the item as closed for bidding
                    bids.itemInactiveTimers[i] = nil -- Clear the timer as the item is now closed
                end
            end
        end
    end
end)

-----------------------
-- Item Timer Display --
-----------------------
local function GetTimeSinceLastBid(itemIndex)
    if bids.itemInactiveTimers[itemIndex] then
        return os.time() - bids.itemInactiveTimers[itemIndex]
    end
    return 0
end

--------------------
-- Form Design --
--------------------
ashita.events.register('d3d_present', 'present_cb', function ()
    if (bids.is_open[1]) then
        imgui.SetNextWindowSize({ 400, 400, }, ImGuiCond_FirstUseEver);
        if (imgui.Begin('DkpBids Window', bids.is_open)) then
            imgui.Text("Current Bids:");

            -- Show only the most recent 5 bids
            local recentBids = {}
            for i = math.max(1, #bids.messages - 4), #bids.messages do
                table.insert(recentBids, bids.messages[i]) -- Collect recent bids
            end
            
            for _, msg in ipairs(recentBids) do
                imgui.Text(msg); -- Display recent bids
            end
            
            if bids.is_bidding_active then
                local elapsed_time = os.time() - bids.start_time
                local remaining_time = bids.timer_duration - elapsed_time 
                local countdown = math.max(remaining_time, 0)

                local minutes = math.floor(countdown / 60)
                local seconds = countdown % 60
                imgui.Text("Time Remaining: " .. string.format("%02d:%02d", minutes, seconds))

                if countdown <= 0 then
                    print("Timer finished. Ending bidding.")
                    EndBidding("/db") -- Specify command when calling EndBidding
                elseif countdown == 30 and not bids.notified_30_seconds then
                    local chatManager = AshitaCore:GetChatManager()
                    if chatManager then
                        chatManager:QueueCommand(1, '/l 30 Seconds left for bids')
                    end
                    bids.notified_30_seconds = true
                end
            else
                imgui.Text("Bidding has ended.")
            end
            
            imgui.Text("Items in Loot Pool:");
            for index, item in ipairs(bids.items) do
                local winner = bids.winners[index]
                local timeSinceLastBid = GetTimeSinceLastBid(index)
                local timerDisplay = string.format("(%d sec)", timeSinceLastBid)

                if winner and winner.name then
                    imgui.Text(string.format("%d. [%s] : %s - %d %s", index, item, winner.name, winner.amount, timerDisplay))
                else
                    imgui.Text(string.format("%d. [%s] : No bids placed %s", index, item, timerDisplay))
                end
            end
            
            imgui.End();
        end
    end
end);

-- Load DKP data when the addon loads
LoadDkpData('\\DKP', dkp_data)  -- Load DKP data
LoadDkpData('\\EDKP', edkp_data) -- Load EDKP data
LoadWhitelist()