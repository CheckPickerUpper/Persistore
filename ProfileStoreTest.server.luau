--[[
MAD STUDIO

-[ProfileStoreTest]---------------------------------------

	Automatic testing of the PofileStore module
	
--]]

local TEST_MOCK = false
local PREFIX = "[PS_TEST]: "

----- Dependencies -----

local ProfileStore

do
	local yielded = true
	task.spawn(function()
		ProfileStore = require(game.ServerScriptService.ProfileStore)
		yielded = false
	end)
	if yielded == true then
		error(PREFIX .. `Module shouldn't yield when required`)
	end
end

local AUTO_SAVE_PERIOD = 10
ProfileStore.SetConstant("AUTO_SAVE_PERIOD", AUTO_SAVE_PERIOD) -- Faster auto-save lets tests proceed faster

----------

local ServerScriptService = game:GetService("ServerScriptService")
local HttpService = game:GetService("HttpService")
local DataStoreService = game:GetService("DataStoreService")

local function DeepCopyTable(t)
	local copy = {}
	for key, value in pairs(t) do
		if type(value) == "table" then
			copy[key] = DeepCopyTable(value)
		else
			copy[key] = value
		end
	end
	return copy
end

local function KeyToString(key)
	if type(key) == "string" then
		return "\"" .. key .. "\""
	else
		return tostring(key)
	end
end

local function TableToString(t: {})
	local output = "{"
	local entries = 0
	for key, value in pairs(t) do
		entries = entries + 1
		if type(value) == "string" then
			output = output .. (entries > 1 and ", " or "") .. "[" .. KeyToString(key) .. "] = \"" .. value .. "\""
		elseif type(value) == "number" then
			output = output .. (entries > 1 and ", " or "") .. "[" .. KeyToString(key) .. "] = " .. value
		elseif type(value) == "table" then
			output = output .. (entries > 1 and ", " or "") .. "[" .. KeyToString(key) .. "] = " .. TableToString(value)
		elseif type(value) == "userdata" then
			if typeof(value) == "Instance" then
				output = output .. (entries > 1 and ", " or "") .. "[" .. KeyToString(key) .. "] = Instance:" .. tostring(value)
			else
				output = output .. (entries > 1 and ", " or "") .. "[" .. KeyToString(key) .. "] = userdata:" .. typeof(value)
			end
		else
			output = output .. (entries > 1 and ", " or "") .. "[" .. KeyToString(key) .. "] = " .. tostring(value)
		end
	end
	output = output .. "}"
	return output
end

local FailCount = 0
local PassCount = 0

local function TestPass(test_txt: string, is_pass: boolean)
	print(PREFIX .. test_txt .. ": " .. (if is_pass == true then "PASS ✅" else "FAIL ❌"))
	if is_pass == true then
		PassCount += 1
	else
		FailCount += 1
	end
end

local function MockUpdateAsync(mock_data_store: {}, store_name: string, profile_key: string, transform_fn: () -> ())
	
	local profile_store = mock_data_store[store_name]
	
	if profile_store == nil then
		profile_store = {}
		mock_data_store[store_name] = profile_store
	end
	
	local mock_entry = profile_store[profile_key]
	local transform = transform_fn(if mock_entry ~= nil then DeepCopyTable(mock_entry.Data) else nil)
	
	if transform == nil then
		return nil
	else
		
		local epoch_time = math.floor(os.time() * 1000)
		local mock_entry = profile_store[profile_key]
		
		if mock_entry == nil then
			mock_entry = {
				Data = nil,
				CreatedTime = epoch_time,
				UpdatedTime = epoch_time,
				VersionId = 0,
				UserIds = {},
				MetaData = {},
			}
			profile_store[profile_key] = mock_entry
		end
		
		mock_entry.UpdatedTime = epoch_time
		mock_entry.VersionId += 1
		mock_entry.Data = DeepCopyTable(transform)
		
		return DeepCopyTable(mock_entry.Data)
		
	end
	
end

local function UpdateAsync(store_name: string, profile_key: string, transform_fn: () -> (), is_mock: boolean?)
	if ProfileStore.DataStoreState ~= "Access" or is_mock == true then
		return MockUpdateAsync(
			if is_mock == true then ProfileStore.Test().UserMockStore else ProfileStore.Test().MockStore,
			store_name,
			profile_key,
			transform_fn
		)
	else
		local data_store = DataStoreService:GetDataStore(store_name)
		return data_store:UpdateAsync(profile_key, transform_fn)
	end
end

local function UniqueKey(identifier: any?)
	local guid = tostring(HttpService:GenerateGUID(false))
	guid = string.gsub(guid, "-", "")
	return (if identifier ~= nil then tostring(identifier) .. "_" else "") .. guid
end

local Store1Live
local Store1 = ProfileStore.New(UniqueKey("Store1"), {Counter = 0, Array = {}})

if TEST_MOCK == true then
	
	Store1Live = Store1
	Store1 = Store1.Mock
	
	print(PREFIX .. `Testing ProfileStore in MOCK mode`)
	
end

task.spawn(function()
	
	if ProfileStore.DataStoreState == "NotReady" then
		print(PREFIX .. `Waiting for DataStore API access check`)
		repeat task.wait() until ProfileStore.DataStoreState ~= "NotReady"
	end
	
	local is_api_access = ProfileStore.DataStoreState == "Access"
	
	print(PREFIX .. `Begin...`)

	for _, missing_record in ipairs({false, true}) do
		local store = ProfileStore.New(UniqueKey("Takeover"), {Counter = 0})
		local key = UniqueKey("Queued")
		local profile = store:StartSessionAsync(key)
		profile:EndSession()
		if missing_record == true then
			UpdateAsync(store.Name, key, function() return {GlobalUpdates = {0, {}}} end, false)
		end
		local is_cancel = false
		local first_profile
		local second_profile
		local completed = 0
		task.spawn(function()
			first_profile = store:StartSessionAsync(key, {Cancel = function() return is_cancel end})
			completed += 1
		end)
		task.spawn(function()
			second_profile = store:StartSessionAsync(key)
			completed += 1
		end)
		is_cancel = true
		local deadline = os.clock() + 10
		repeat task.wait() until completed == 2 or os.clock() > deadline
		local expected_load_count = if missing_record == true then 1 else 2
		TestPass(`A takeover ignores the previous request's cancellation ({if missing_record then "missing" else "existing"} record)`,
			completed == 2 and first_profile == nil and second_profile ~= nil and second_profile:IsActive()
			and second_profile.SessionLoadCount == expected_load_count)
		for _, loaded_profile in pairs({first_profile, second_profile}) do
			loaded_profile:EndSession()
			loaded_profile.OnAfterSave:Wait()
		end
		store:RemoveAsync(key)
	end

	do
		local store = ProfileStore.New(UniqueKey("TakeoverSteal"), {Counter = 0})
		local key = UniqueKey("Held")
		local profile = store:StartSessionAsync(key)
		profile:EndSession()
		UpdateAsync(store.Name, key, function(data)
			data.MetaData.ActiveSession = {-1, "ForeignServer"}
			return data
		end, false)
		local first_profile
		local second_profile
		local completed = 0
		task.spawn(function()
			first_profile = store:StartSessionAsync(key, {Steal = true})
			completed += 1
		end)
		local checks = 0
		task.spawn(function()
			second_profile = store:StartSessionAsync(key, {Cancel = function()
				checks += 1
				return checks >= 4
			end})
			completed += 1
		end)
		local deadline = os.clock() + 10
		repeat task.wait() until completed == 2 or os.clock() > deadline
		local record = UpdateAsync(store.Name, key, function(data) return data end, false)
		TestPass(`A takeover without Steal preserves the foreign session`, completed == 2 and first_profile == nil
			and second_profile == nil and record.MetaData.ActiveSession[2] == "ForeignServer")
		for _, loaded_profile in pairs({first_profile, second_profile}) do
			loaded_profile:EndSession()
			loaded_profile.OnAfterSave:Wait()
		end
		store:RemoveAsync(key)
	end

	do
		local store = ProfileStore.New(UniqueKey("LateTakeover"), {Counter = 0})
		local key = UniqueKey("Unclaimed")
		local first_profile
		local second_profile
		local completed = 0
		local checks = 0
		task.spawn(function()
			first_profile = store:StartSessionAsync(key, {Cancel = function()
				checks += 1
				return checks >= 2
			end})
			completed += 1
		end)
		local record = UpdateAsync(store.Name, key, function(data) return data end, false)
		local was_unclaimed = completed == 0 and checks == 2 and record.MetaData.ActiveSession == nil
		task.spawn(function()
			second_profile = store:StartSessionAsync(key)
			completed += 1
		end)
		local deadline = os.clock() + 10
		repeat task.wait() until completed == 2 or os.clock() > deadline
		TestPass(`A takeover retries a record left unclaimed before it took over`, was_unclaimed and completed == 2
			and first_profile == nil and second_profile ~= nil and second_profile:IsActive()
			and second_profile.SessionLoadCount == 1)
		for _, loaded_profile in pairs({first_profile, second_profile}) do
			loaded_profile:EndSession()
			loaded_profile.OnAfterSave:Wait()
		end
		store:RemoveAsync(key)
	end

	do
		local store = ProfileStore.New(UniqueKey("AbortedUpdate"), {})
		local key = UniqueKey("Copy")
		local profile = store.Mock:StartSessionAsync(key)
		local saw_session = false
		UpdateAsync(store.Name, key, function(data)
			if type(data.MetaData.ActiveSession) == "table" then
				saw_session = true
				data.MetaData.ActiveSession[2] = "AbortedSession"
			end
			return nil
		end, true)
		local saved_profile = store.Mock:GetAsync(key)
		TestPass(`An aborted mock update preserves the stored session`, saw_session == true and saved_profile.Session.JobId == profile.Session.JobId)
		profile:EndSession()
		profile.OnAfterSave:Wait()
		store.Mock:RemoveAsync(key)
	end

	-- Session start results:

	do
		local key = UniqueKey("Started")
		local result = Store1:StartSessionResultAsync(key)
		TestPass(`An available session starts`, result.Kind == "SessionStarted" and result.Profile:IsActive())
		if result.Kind == "SessionStarted" then
			result.Profile:EndSession()
			result.Profile.OnAfterSave:Wait()
		end
		Store1:RemoveAsync(key)
	end

	do
		local store = ProfileStore.New(UniqueKey("MockCancel"), {})
		local key = UniqueKey("Cancelled")
		local profile = store.Mock:StartSessionAsync(key, {Cancel = function() return true end})
		TestPass(`Mock forwards Cancel to the upstream start method`, profile == nil)
		if profile ~= nil then
			profile:EndSession()
			profile.OnAfterSave:Wait()
		end
		local result = store.Mock:StartSessionResultAsync(key, {Cancel = function() return true end})
		TestPass(`Mock returns the cancellation reason before loading`, result.Kind == "SessionNotStarted" and result.Because == "Cancelled")
		if result.Kind == "SessionStarted" then
			result.Profile:EndSession()
			result.Profile.OnAfterSave:Wait()
		end
		store.Mock:RemoveAsync(key)
	end

	do
		local key = UniqueKey("BeforeLoad")
		local result = Store1:StartSessionResultAsync(key, {Cancel = function() return true end})
		TestPass(`Cancel stops a session before loading`, result.Kind == "SessionNotStarted" and result.Because == "Cancelled")
		if result.Kind == "SessionStarted" then
			result.Profile:EndSession()
			result.Profile.OnAfterSave:Wait()
		end
		Store1:RemoveAsync(key)
	end

	do
		local key = UniqueKey("DuringLoad")
		local checks = 0
		local result = Store1:StartSessionResultAsync(key, {Cancel = function()
			checks += 1
			return checks >= 2
		end})
		TestPass(`Cancel during loading leaves no active session`, result.Kind == "SessionNotStarted" and result.Because == "Cancelled"
			and UpdateAsync(Store1.Name, key, function(data) return data end, TEST_MOCK).MetaData.ActiveSession == nil)
		if result.Kind == "SessionStarted" then
			result.Profile:EndSession()
			result.Profile.OnAfterSave:Wait()
		end
		Store1:RemoveAsync(key)
	end

	do
		local key = UniqueKey("AfterLoad")
		local checks = 0
		local result = Store1:StartSessionResultAsync(key, {Cancel = function()
			checks += 1
			return checks >= 4
		end})
		local record = UpdateAsync(Store1.Name, key, function(data) return data end, TEST_MOCK)
		TestPass(`Cancel after loading releases the session`, result.Kind == "SessionNotStarted" and result.Because == "Cancelled"
			and record.MetaData.SessionLoadCount == 1 and record.MetaData.ActiveSession == nil)
		if result.Kind == "SessionStarted" then
			result.Profile:EndSession()
			result.Profile.OnAfterSave:Wait()
		end
		Store1:RemoveAsync(key)
	end

	do
		local key = UniqueKey("HeldCancel")
		UpdateAsync(Store1.Name, key, function()
			return {Data = {}, MetaData = {ActiveSession = {-1, "OtherServer"}, LastUpdate = os.time(), SessionLoadCount = 0}, GlobalUpdates = {0, {}}}
		end, TEST_MOCK)
		local checks = 0
		local result = Store1:StartSessionResultAsync(key, {Cancel = function()
			checks += 1
			return checks >= 4
		end})
		TestPass(`Cancel stops a claim held by another server`, result.Kind == "SessionNotStarted" and result.Because == "Cancelled")
		Store1:RemoveAsync(key)
	end

	for claim_count = 2, 3 do
		local key = UniqueKey("Concurrent")
		local results = {}
		local completed = 0
		for index = 1, claim_count do
			task.spawn(function()
				results[index] = Store1:StartSessionResultAsync(key)
				completed += 1
			end)
		end
		local deadline = os.clock() + 10
		repeat task.wait() until completed == claim_count or os.clock() > deadline
		local is_pass = completed == claim_count
		for index = 1, claim_count - 1 do
			is_pass = is_pass and results[index].Kind == "SessionNotStarted" and results[index].Because == "SupersededOnThisServer"
		end
		is_pass = is_pass and results[claim_count].Kind == "SessionStarted" and results[claim_count].Profile:IsActive()
		TestPass(`The last of {claim_count} concurrent claims starts; earlier claims are superseded`, is_pass)
		for _, result in pairs(results) do
			if result.Kind == "SessionStarted" then
				result.Profile:EndSession()
				result.Profile.OnAfterSave:Wait()
			end
		end
		Store1:RemoveAsync(key)
	end

	do
		local key = UniqueKey("OtherClaim")
		UpdateAsync(Store1.Name, key, function()
			return {Data = {}, MetaData = {ActiveSession = {-1, "OtherServer"}, LastUpdate = os.time(), SessionLoadCount = 0}, GlobalUpdates = {0, {}}}
		end, TEST_MOCK)
		local checks = 0
		local result = Store1:StartSessionResultAsync(key, {Cancel = function()
			checks += 1
			if checks == 5 then
				UpdateAsync(Store1.Name, key, function(data)
					data.MetaData.ForceLoadSession = {-1, "NewClaim"}
					return data
				end, TEST_MOCK)
			end
			return checks > 12
		end})
		TestPass(`Another server replacing the force-load claim interrupts loading`, result.Kind == "SessionNotStarted" and result.Because == "ClaimedByAnotherServer")
		Store1:RemoveAsync(key)
	end

	do
		local was_closing = ProfileStore.IsClosing
		ProfileStore.IsClosing = true
		local result = Store1:StartSessionResultAsync(UniqueKey("Closing"))
		ProfileStore.IsClosing = was_closing
		TestPass(`A closing server refuses a new session`, result.Kind == "SessionNotStarted" and result.Because == "ServerClosing")
	end

	do
		local store = ProfileStore.New(UniqueKey("MockSteal"), {})
		local key = UniqueKey("Steal")
		UpdateAsync(store.Name, key, function()
			return {Data = {}, MetaData = {ActiveSession = {-1, "OtherServer"}, LastUpdate = os.time(), SessionLoadCount = 0}, GlobalUpdates = {0, {}}}
		end, true)
		local checks = 0
		local profile = store.Mock:StartSessionAsync(key, {Steal = true, Cancel = function()
			checks += 1
			return checks > 4
		end})
		TestPass(`Mock forwards Steal to take an existing lock`, profile ~= nil and profile:IsActive())
		if profile ~= nil then
			profile:EndSession()
			profile.OnAfterSave:Wait()
		end
		store.Mock:RemoveAsync(key)
	end

	-- Session end reasons and synchronous saves:

	do
		local key = UniqueKey("SaveAsync")
		local profile = Store1:StartSessionAsync(key)
		local attempts = {}
		local connection = Store1.OnSaveAttempt:Connect(function(profile_key, outcome)
			if profile_key == key then table.insert(attempts, outcome) end
		end)
		profile.Data.Counter = 57
		local outcome = profile:SaveAsync()
		TestPass(`SaveAsync waits for Written and updates LastSavedData`, outcome == "Written" and profile.LastSavedData.Counter == 57
			and attempts[1] == outcome and #attempts == 1)
		local payload = Store1:GetAsync(key)
		local success = pcall(function() payload:SaveAsync() end)
		TestPass(`SaveAsync rejects a profile loaded in view mode`, success == false)
		local reason
		local upstream_listener = false
		profile.OnSessionEnd:Connect(function(ended) reason = ended end)
		profile.OnSessionEnd:Connect(function() upstream_listener = true end)
		profile:EndSession()
		profile.OnAfterSave:Wait()
		TestPass(`EndSession reports Manual and calls listeners with no arguments`, reason == "Manual" and upstream_listener)
		local attempt_count = #attempts
		TestPass(`SaveAsync on an ended session makes no request`, profile:SaveAsync() == "SessionEnded" and #attempts == attempt_count)
		connection:Disconnect()
		Store1:RemoveAsync(key)
	end

	do
		local key = UniqueKey("Refused")
		local profile = Store1:StartSessionAsync(key)
		local reason
		local attempt
		local connection = Store1.OnSaveAttempt:Connect(function(profile_key, outcome)
			if profile_key == key then attempt = outcome end
		end)
		profile.OnSessionEnd:Connect(function(ended) reason = ended end)
		UpdateAsync(Store1.Name, key, function(data)
			data.MetaData.ActiveSession = {-1, "OtherServer"}
			return data
		end, TEST_MOCK)
		profile.Data.Counter = 99
		local outcome = profile:SaveAsync()
		TestPass(`SaveAsync refuses a stolen lock and reports Stolen`, outcome == "OwnershipRefused" and attempt == outcome
			and reason == "Stolen" and profile:IsActive() == false and Store1:GetAsync(key).Data.Counter == 0)
		connection:Disconnect()
		Store1:RemoveAsync(key)
	end

	do
		local key = UniqueKey("External")
		local profile = Store1:StartSessionAsync(key)
		local reason
		profile.OnSessionEnd:Connect(function(ended) reason = ended end)
		profile.Data.Counter = 34
		UpdateAsync(Store1.Name, key, function(data)
			data.MetaData.ForceLoadSession = {-1, "OtherClaim"}
			return data
		end, TEST_MOCK)
		local outcome = profile:SaveAsync()
		local saved_profile = Store1:GetAsync(key)
		TestPass(`A foreign force-load request ends the session with External`, reason == "External" and outcome == "Written"
			and profile:IsActive() == false and saved_profile.Data.Counter == 34 and saved_profile.Session == nil)
		Store1:RemoveAsync(key)
	end

	do
		local key = UniqueKey("Overwritten")
		local profile = Store1:StartSessionAsync(key)
		local reason
		profile.OnSessionEnd:Connect(function(ended) reason = ended end)
		local payload = Store1:GetAsync(key)
		payload.Data.Counter = 75
		payload:SetAsync()
		profile.Data.Counter = 76
		local outcome = profile:SaveAsync()
		TestPass(`SetAsync replacement ends the live session with Overwritten`, reason == "Overwritten"
			and outcome == "OwnershipRefused" and profile:IsActive() == false and Store1:GetAsync(key).Data.Counter == 75)
		Store1:RemoveAsync(key)
	end

	do
		local key = UniqueKey("TimedOut")
		UpdateAsync(Store1.Name, key, function()
			return {Data = {}, MetaData = {SessionLoadCount = {}}, GlobalUpdates = {0, {}}}
		end, TEST_MOCK)
		local errors = 0
		local connection = ProfileStore.OnError:Connect(function(_, store_name, profile_key)
			if store_name == Store1.Name and profile_key == key then errors += 1 end
		end)
		ProfileStore.SetConstant("START_SESSION_TIMEOUT", 0)
		local result = Store1:StartSessionResultAsync(key)
		ProfileStore.SetConstant("START_SESSION_TIMEOUT", 120)
		connection:Disconnect()
		TestPass(`Failed session requests time out without Cancel`, errors == 1
			and result.Kind == "SessionNotStarted" and result.Because == "TimedOut")
		Store1:RemoveAsync(key)
	end

	do
		local key = UniqueKey("FailedCancel")
		UpdateAsync(Store1.Name, key, function()
			return {Data = {}, MetaData = {SessionLoadCount = {}}, GlobalUpdates = {0, {}}}
		end, TEST_MOCK)
		local errors = 0
		local connection = ProfileStore.OnError:Connect(function(_, store_name, profile_key)
			if store_name == Store1.Name and profile_key == key then errors += 1 end
		end)
		local checks = 0
		local result = Store1:StartSessionResultAsync(key, {Cancel = function()
			checks += 1
			return checks >= 4
		end})
		connection:Disconnect()
		TestPass(`Cancel stops failed session requests`, errors == 1 and checks == 4
			and result.Kind == "SessionNotStarted" and result.Because == "Cancelled")
		Store1:RemoveAsync(key)
	end

	do
		local key = UniqueKey("RequestFailed")
		local profile = Store1:StartSessionAsync(key)
		local original_record
		UpdateAsync(Store1.Name, key, function(data)
			original_record = DeepCopyTable(data)
			data.Data = "corrupt"
			return data
		end, TEST_MOCK)
		local attempts = {}
		local connection = Store1.OnSaveAttempt:Connect(function(profile_key, outcome)
			if profile_key == key then table.insert(attempts, outcome) end
		end)
		local outcome = profile:SaveAsync()
		connection:Disconnect()
		TestPass(`SaveAsync reports a failed request consistently`, outcome == "RequestFailed"
			and #attempts == 1 and attempts[1] == outcome)
		UpdateAsync(Store1.Name, key, function() return original_record end, TEST_MOCK)
		profile:EndSession()
		profile.OnAfterSave:Wait()
		Store1:RemoveAsync(key)
	end

	print(PREFIX .. `Skipping Shutdown session-end test (requires server shutdown)`)

	-- Save attempt results:

	do

		local key = UniqueKey("SaveAttempt")
		local attempts = {}
		local connection = Store1.OnSaveAttempt:Connect(function(profile_key, outcome, purpose)
			if profile_key == key then
				table.insert(attempts, {outcome, purpose})
			end
		end)

		local profile = Store1:StartSessionAsync(key)
		profile.Data.Counter = 1
		profile:Save()
		profile.OnAfterSave:Wait()
		local saved = Store1:GetAsync(key)
		profile:EndSession()
		profile.OnAfterSave:Wait()
		local payload = Store1:GetAsync(key)
		payload.Data.Counter = 2
		payload:SetAsync()
		local overwritten = Store1:GetAsync(key)

		connection:Disconnect()
		Store1:RemoveAsync(key)

		TestPass(`Manual, final and overwrite save attempts`, saved.Data.Counter == 1 and overwritten.Data.Counter == 2
			and #attempts == 3
			and attempts[1][1] == "Written" and attempts[1][2] == "SessionSave"
			and attempts[2][1] == "Written" and attempts[2][2] == "FinalSave"
			and attempts[3][1] == "Written" and attempts[3][2] == "Overwrite")

	end

	do

		local store = ProfileStore.New(UniqueKey("MockSaveAttempt"), {})
		local key = UniqueKey("Mock")
		local attempts = {}
		local connection = store.OnSaveAttempt:Connect(function(profile_key, outcome, purpose)
			table.insert(attempts, {profile_key, outcome, purpose})
		end)

		local profile = store.Mock:StartSessionAsync(key)
		profile.Data.Counter = 1
		profile:EndSession()
		profile.OnAfterSave:Wait()
		local saved = store.Mock:GetAsync(key)

		connection:Disconnect()
		store.Mock:RemoveAsync(key)

		TestPass(`Mock saves reach the store signal`, saved.Data.Counter == 1 and #attempts == 1
			and attempts[1][1] == key and attempts[1][2] == "Written" and attempts[1][3] == "FinalSave")

	end

	-- Versioning test:

	if is_api_access == true and TEST_MOCK == false then
		
		-- Due to a change to DataStore versioning on July 2024, this test can only retreive one version
		-- and thus doesn't truly test the feature. ProfileStore versioning was directly ported from ProfileService
		-- versioning which was tested properly before.
		-- SOURCE: https://devforum.roblox.com/t/data-stores-versioning-changes-are-going-live/3093227

		-- Creating several versions for the same key:
		
		local key = "Versioning"

		local profile = Store1:StartSessionAsync(key)
		profile.Data.Gold = 10
		profile:EndSession()

		local payload = Store1:GetAsync(key)
		payload.Data.Gold += 10
		payload:SetAsync()

		local query = Store1:VersionQuery(
			key,
			Enum.SortDirection.Descending,
			nil,
			DateTime.fromUnixTimestamp(os.time() + 10000) -- Future time
		)
		
		local result = query:NextAsync()
		
		local is_pass = result and result.Data.Gold == 20 or false
		
		Store1:RemoveAsync(key)
		
		TestPass(`Versioning test`, is_pass)

	elseif TEST_MOCK == false then
		
		print(PREFIX .. `Skipping versioning test due to no API access`)
		
	end
	
	-- Test profile payloads:
	
	do

		print(PREFIX .. `Payload test ⏳... (Will take around {AUTO_SAVE_PERIOD} seconds)`)

		-- Create profile with some data and a message:
		
		local key = "PayloadTest"

		local profile = Store1:StartSessionAsync(key)
		profile.Data = {
			Coins = 68,
		}
		profile:AddUserId(2312310)
		profile.RobloxMetaData = {Playtime = 123456}
		
		Store1:MessageAsync(key, {GiftType = "SpecialGift"})

		-- We need the profile to be active, and ensure all above data is saved in the DataStore:
		
		profile.OnAfterSave:Wait()

		if #profile.global_updates == 0 then
			error(PREFIX .. `Message was not received`)
		end

		-- Create a profile payload:

		profile.Data.Coins = 1000000 -- The player JUST received tons of cash!!! Payloads can lose up to
		-- several minutes of in-game progress when overwriting. You should use :StartSessionAsync()
		-- even in manual editing if you want to protect live in-game progress.

		local payload = Store1:GetAsync(key)
		payload.Data.Coins += 1
		payload:AddUserId(50)

		local message_received = false
		
		payload:MessageHandler(function(message, is_processed_callback)
			if message.GiftType == "SpecialGift" then
				message_received = true
			end
		end)

		if message_received ~= true then
			error(PREFIX .. `Message was not received in GET profile`)
		end
		
		-- Message clear test:
		
		local a_message_was_cleared = false
		
		payload:MessageHandler(function(message, is_processed_callback) -- A function like this will clear all unprocessed messages
			a_message_was_cleared = true
			is_processed_callback()
		end)
		
		local messages_empty = true
		
		payload:MessageHandler(function()
			messages_empty = false
		end)

		if messages_empty == false or a_message_was_cleared == false then
			error(PREFIX .. `Message clear test fail`)
		end

		payload:SetAsync()

		-- The profile should lose its session lock:

		local start = os.clock()
		local wait_for_profile = true
		
		profile.OnSessionEnd:Connect(function()
			wait_for_profile = false
		end)
		
		while wait_for_profile == true do
			if os.clock() - start > 120 then
				error(PREFIX .. `Session steal by payload timeout`)
			end
			task.wait()
		end

		if profile:IsActive() == true then
			error(PREFIX .. `Faulty :IsActive()`)
		end

		-- Load and check new data:

		profile = Store1:GetAsync(key)

		local key_info = profile.KeyInfo
		local metadata = key_info:GetMetadata()
		local user_ids = key_info:GetUserIds()
		
		local active_messages = 0
		
		profile:MessageHandler(function()
			active_messages += 1
		end)

		local is_passed = profile.Data.Coins == 69
			and metadata.Playtime == 123456 and table.find(user_ids, 2312310) ~= nil
			and table.find(user_ids, 50) ~= nil and active_messages == 0
		
		Store1:RemoveAsync(key)
		
		TestPass(`Payload test`, is_passed)

	end
	
	-- Test KeyInfo:

	do
		
		local key = "KeyInfoTest"

		local profile = Store1:StartSessionAsync(key)
		
		profile.RobloxMetaData = {Color = {0.955, 0, 0}, Dedication = "Veteran"}
		profile:AddUserId(2312310)
		profile:AddUserId(50)
		profile:AddUserId(420)
		profile:RemoveUserId(50)

		profile:EndSession()
		
		profile.OnAfterSave:Wait()

		local key_info = profile.KeyInfo
		local metadata = key_info:GetMetadata()
		local user_ids = key_info:GetUserIds()

		local is_color_good = type(metadata.Color) == "table"
			and metadata.Color[1] == 0.955
			and metadata.Color[2] == 0
			and metadata.Color[3] == 0

		local is_passed = is_color_good == true
			and metadata.Dedication == "Veteran" and table.find(user_ids, 2312310) ~= nil
			and table.find(user_ids, 420) ~= nil and table.find(user_ids, 50) == nil

		if is_api_access == true and profile.is_mock ~= true and type(key_info) == "table" then
			error(PREFIX .. `Mock KeyInfo leak`)
		end
		
		Store1:RemoveAsync(key)

		TestPass(`DataStore KeyInfo (Roblox Metadata) test`, is_passed)

	end
	
	-- Test MOCK:
	
	if TEST_MOCK == true then
		
		local key = UniqueKey("Mock")
		
		local success_mock, error_message = pcall(function()
			local profile_live = Store1:StartSessionAsync(key)
			wait(1)
			local profile_mock = Store1Live:StartSessionAsync(key)
			profile_live:EndSession()
			profile_mock:EndSession()
			Store1:RemoveAsync(key)
			Store1Live:RemoveAsync(key)
		end)
		
		TestPass(`Mock test`, success_mock == true)
		
		if success_mock == false then
			print(`ERROR:`, error_message)
		end
		
	end
	
	-- Message test:

	do
		
		print(PREFIX .. `Message test ⏳... (Will take a few seconds)`)

		local key = UniqueKey(2)

		local profile = Store1:StartSessionAsync(key)

		local message_received_1 = false
		local message_received_2 = false
		local fell_through = false
		
		local processed_names = {}

		profile:MessageHandler(function(message, is_processed_callback)
			
			if message.UpdateTag == "Hello!" then
				message_received_1 = true
				is_processed_callback()
				Store1:MessageAsync(key, {UpdateTag = "Another!"})
			elseif message.UpdateTag == "Another!" then
				message_received_2 = true
				is_processed_callback()
			end
			
			if processed_names[message.UpdateTag] ~= nil then
				error(PREFIX .. `A message was processed too many times`)
			end
			
			processed_names[message.UpdateTag] = true
			
		end)
		
		profile:MessageHandler(function(message)
			if message.UpdateTag == "Hello!" then
				error(PREFIX .. `A message was passed to another handler after confirming processed status`)
			elseif message.UpdateTag == "No!" then
				fell_through = true
			end
		end)
		
		Store1:MessageAsync(key, {UpdateTag = "No!"})
		Store1:MessageAsync(key, {UpdateTag = "Yes!"})
		Store1:MessageAsync(key, {UpdateTag = "Hello!"})
		
		local start = os.clock()
		
		while message_received_1 == false or message_received_2 == false do
			if os.clock() - start > 120 then
				error(PREFIX .. `Message wait timeout`)
			end
			task.wait()
		end

		profile:EndSession()
		
		-- From this point on, checking a profile in any way immediately should result in active 2 messages
		
		local profile_get
		task.spawn(function()
			profile_get = Store1:GetAsync(key)
		end)
		
		profile = Store1:StartSessionAsync(key)
		
		repeat task.wait() until profile_get ~= nil
		
		local active_messages = 0
		local active_messages_get = 0

		profile:MessageHandler(function()
			active_messages += 1
		end)
		
		profile_get:MessageHandler(function()
			active_messages_get += 1
		end)
		
		profile:EndSession()
		
		-- Check message removal through payload:
		
		local payload = Store1:GetAsync(key)
		
		payload:MessageHandler(function(message, is_processed_callback)
			is_processed_callback()
		end)
		
		payload:SetAsync()
		
		profile = Store1:StartSessionAsync(key)
		
		local active_messages_after_clear = 0
		
		payload:MessageHandler(function(message, is_processed_callback)
			active_messages_after_clear += 1
		end)
		
		profile:EndSession()
		Store1:RemoveAsync(key)

		TestPass(`Message test`, active_messages == 2 and active_messages_get == 2 and fell_through == true and active_messages_after_clear == 0)

	end
	
	-- LastSavedData test: 

	do
		
		print(PREFIX .. `LastSavedData test ⏳... (Will take around {AUTO_SAVE_PERIOD} seconds)`)

		local key = UniqueKey("LastSaved")

		local profile = Store1:StartSessionAsync(key)
		profile.Data.LoadedFirstTime = true
		profile.Data.PurchaseIds = {}
		table.insert(profile.Data.PurchaseIds, "a")
		
		local initial_check = profile.LastSavedData ~= profile.Data

		local attempt
		local connection = Store1.OnSaveAttempt:Connect(function(profile_key, outcome, purpose)
			if profile_key == key then
				attempt = {outcome, purpose}
			end
		end)

		profile.OnAfterSave:Wait()
		connection:Disconnect()
		
		local is_pass = initial_check and profile.LastSavedData ~= profile.Data
			and profile.LastSavedData.LoadedFirstTime == true
			and profile.LastSavedData.PurchaseIds ~= nil
			and profile.LastSavedData.PurchaseIds[1] == "a"
		
		profile:EndSession()
		Store1:RemoveAsync(key)

		TestPass("LastSavedData test", is_pass)
		TestPass("Auto-save attempt result", attempt ~= nil and attempt[1] == "Written" and attempt[2] == "SessionSave")

	end
	
	-- .OnOverwrite test:

	do

		print(PREFIX .. `.OnOverwrite test ⏳... (Will take around {AUTO_SAVE_PERIOD} seconds)`)

		local key = UniqueKey("Overwrite")

		local signal_received = false

		ProfileStore.OnOverwrite:Connect(function(store_name, profile_key)
			if store_name == Store1.Name and profile_key == key then
				signal_received = true
			end
		end)

		UpdateAsync(Store1.Name, key, function() -- Injecting data that doesn't match the DataStore internal schema
			return {"ThisAintRight"}
		end, TEST_MOCK)

		local profile = Store1:StartSessionAsync(key)
		profile:EndSession()
		Store1:RemoveAsync(key)

		TestPass(`.OnOverwrite test`, signal_received == true)

	end
	
	-- Test #1: (Rapid consecutive session start-end and profile removal)
	
	do
		
		local key = UniqueKey(1)
	
		for i = 1, 2 do
			local profile = Store1:StartSessionAsync(key)
			profile.Data.Counter = profile.Data.Counter and profile.Data.Counter + 1 or 1
			profile:EndSession()
		end
		
		local profile_get1 = Store1:GetAsync(key)
		Store1:RemoveAsync(key)
		local profile_get2 = Store1:GetAsync(key)
		
		TestPass(`Test #1`, profile_get1.Data.Counter == 2 and profile_get2 == nil)
		
	end
	
	-- Test #2: (Other types of repeat session starts)
	
	do
		
		local key = UniqueKey(2)
	
		local profile

		local success = pcall(function() -- Should fail
			profile = Store1:StartSessionAsync(key) -- This should succeed
			profile = Store1:StartSessionAsync(key) -- This should error
		end)
		
		profile:EndSession()

		local success_2 = pcall(function()
			profile = Store1:StartSessionAsync(key)
			profile:EndSession()
			profile = Store1:StartSessionAsync(key)
		end)
		
		profile:EndSession()
		Store1:RemoveAsync(key)
		
		TestPass(`Test #2`, success == false and success_2 == true)
		
	end
	
	-- Test #3: (Session start grabbing)
	
	do
		
		local key = UniqueKey(3)
		
		local profiles = {}
		
		-- If :StartSessionAsync() is called several times quickly, only the last call should
		-- receive the profile reference and others should return nil without throwing an error.
		-- This is to prevent race conditions where a user might rejoin faster than the first
		-- session manages to start.
		
		for i = 1, 3 do
			task.spawn(function()
				profiles[i] = Store1:StartSessionAsync(key) or 0
			end)
		end

		while profiles[1] == nil or profiles[2] == nil or profiles[3] == nil do
			wait()
		end
		
		profiles[3]:EndSession()
		Store1:RemoveAsync(key)

		TestPass(`Test #3`, profiles[1] == 0 and profiles[2] == 0 and type(profiles[3]) == "table")
		
	end
	
	-- Test #4: (External session steal simulation)
	
	do
	
		print(PREFIX .. `Test #4 ⏳... (Will take around {AUTO_SAVE_PERIOD} seconds)`)
		
		local key = UniqueKey(4)
		
		local profile = Store1:StartSessionAsync(key)
		local attempt
		local connection = Store1.OnSaveAttempt:Connect(function(profile_key, outcome, purpose)
			if profile_key == key then
				attempt = {outcome, purpose}
			end
		end)
		
		UpdateAsync(Store1.Name, key, function() -- "Stealing" profile through injection
			return {
				Data = {},
				MetaData = {
					ProfileCreateTime = 0,
					SessionLoadCount = 0,
					ActiveSession = {123, 123},
					ForceLoadSession = nil,
					MetaTags = {},
				},
				GlobalUpdates = {0, {}},
			}
		end, TEST_MOCK)
		
		local start = os.clock()

		while profile:IsActive() == true do
			if os.clock() - start > 120 then
				error(PREFIX .. `Steal wait timeout`)
			end
			task.wait()
		end
		
		connection:Disconnect()
		Store1:RemoveAsync(key)
		
		TestPass(`Test #4`, true)
		TestPass(`Lost ownership save attempt`, attempt ~= nil and attempt[1] == "OwnershipRefused" and attempt[2] == "SessionSave")
		
	end
	
	-- Test #5: (Session swap between servers simulation)
	
	do
		
		print(PREFIX .. `Test #5 ⏳... (Will take around {AUTO_SAVE_PERIOD} seconds)`)
		
		local key = UniqueKey(5)
		
		local profile = Store1:StartSessionAsync(key)
		profile.Data.Counter = 75
		local last_save_reason
		profile.OnLastSave:Connect(function(reason)
			last_save_reason = reason
			profile.Data.Counter = 76
		end)
		
		local injected_data = UpdateAsync(Store1.Name, key, function(data) -- Injecting profile table with force load request
			if type(data.MetaData.ActiveSession) ~= "table" then
				return nil
			end
			data.MetaData.ForceLoadSession = {123, 123}
			return data
		end, TEST_MOCK)

		local active_session = injected_data and injected_data.MetaData.ActiveSession
		local is_injected = type(active_session) == "table"
			and active_session[1] == profile.Session.PlaceId and active_session[2] == profile.Session.JobId
			and injected_data.MetaData.SessionLoadCount == profile.SessionLoadCount
			and injected_data.MetaData.ForceLoadSession[1] == 123 and injected_data.MetaData.ForceLoadSession[2] == 123

		if is_injected == true then
			profile:Save()
		else
			profile:EndSession()
		end
		profile.OnAfterSave:Wait()
		local saved_profile = Store1:GetAsync(key)
		Store1:RemoveAsync(key)

		TestPass(`Test #5 force-load saves the payload and reports External`, is_injected == true and last_save_reason == "External"
			and profile:IsActive() == false and saved_profile.Data.Counter == 76 and saved_profile.Session == nil)
		
	end
	
	-- Test #6: (Templates and reconciliation)
	
	do
		
		local key = UniqueKey(6)
		
		local profile = Store1:StartSessionAsync(key)
		profile.Data = {Array = false}
		profile:Reconcile()
		
		local is_pass = profile.Data.Counter == 0 and profile.Data.Array == false
		
		profile:EndSession()
		Store1:RemoveAsync(key)
		
		TestPass(`Test #6`, is_pass)
		
	end
	
	-- Cache test:
	
	do
		
		task.wait(3)
		
		local test = ProfileStore.Test()
		
		local is_pass = next(test.ActiveSessionCheck) == nil
			and #test.AutoSaveList == 0
			and test.ActiveProfileLoadJobs == 0
			and test.ActiveProfileSaveJobs == 0
			and next(test.MockStore) == nil
			and next(test.UserMockStore) == nil
			and next(test.UpdateQueue) == nil
			
		TestPass(`Cache test`, is_pass)
		
		if is_pass == false then
			print(test)
		end
		
	end
	
	-- Summary:
	
	print(PREFIX .. `Test complete! PASS ✅ = {PassCount}; FAIL ❌ = {FailCount}`)
	
	if FailCount == 0 then
		print(PREFIX .. `Test PASSED ✅✅✅!`)
	else
		print(PREFIX .. `Test FAILED ❌❌❌!`)
	end

end)
