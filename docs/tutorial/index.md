## Getting Persistore

Persistore is supposed to be a ModuleScript which you should place inside your Roblox game's *ServerScriptService* or wherever else is preferred.
Since DataStores are server-side only, Persistore is also a module that should only run on the server-side.

### Get Persistore from GitHub

* [Persistore repository](https://github.com/CheckPickerUpper/Persistore)
* Use `ProfileStore.luau` as the `ProfileStore` ModuleScript under `ServerScriptService`.

For roblox-ts, install a pinned commit from GitHub (the package is not published to npm):

```sh
pnpm add "@rbxts/persistore@git+https://github.com/CheckPickerUpper/Persistore.git#<commit>"
```

Replace `<commit>` with the full commit SHA you want to use, then import from `@rbxts/persistore`.

The Wally package `checkpickerupper/persistore` is not published. Copy `ProfileStore.luau` into your project as described above.

### Upstream ProfileStore Roblox library

The [upstream ProfileStore library model](https://create.roblox.com/store/asset/109379033046155/ProfileStore) is the original project's release and does not include Persistore's changes.
These screenshots show the upstream model; Persistore keeps the same `ProfileStore` ModuleScript name:

![Open toolbox menu for the upstream model](../images/Step1.jpg)

![Find the upstream ProfileStore model](../images/Step2.jpg)

![Move the upstream ProfileStore model to ServerScriptService](../images/Step3.jpg)

## Basic Usage

To start using Persistore, you need a piece of code that starts a profile session when a player joins. When a profile session is started,
changes to the `Profile.Data` table will be auto-saved periodically and saved for the last time after `Profile:EndSession()` is called.
You can find explanations for every method and property of `ProfileStore` and `Profile` objects in the [Persistore API](../api).

`StartSessionAsync` returns `nil` when a session does not start. To receive the specific reason, use
[`StartSessionResultAsync`](/Persistore/api/#startsessionresultasync): its `SessionNotStarted` result reports
`Because` as `ServerClosing`, `Cancelled`, `SupersededOnThisServer`, `ClaimedByAnotherServer`, or `TimedOut`.

This code is a standard implementation of Persistore:

``` luau
local ProfileStore = require(game.ServerScriptService.ProfileStore)

-- The PROFILE_TEMPLATE table is what new profile "Profile.Data" will default to:
local PROFILE_TEMPLATE = {
   Cash = 0,
   Items = {},
}

local Players = game:GetService("Players")

local PlayerStore = ProfileStore.New("PlayerStore", PROFILE_TEMPLATE)
local Profiles: {[Player]: typeof(PlayerStore:StartSessionAsync())} = {}

local function PlayerAdded(player)

   -- Start a profile session for this player's data:

   local profile = PlayerStore:StartSessionAsync(`{player.UserId}`, {
      Cancel = function()
         return player.Parent ~= Players
      end,
   })

   -- Handling new profile session or failure to start it:

   if profile ~= nil then

      profile:AddUserId(player.UserId) -- GDPR compliance
      profile:Reconcile() -- Fill in missing variables from PROFILE_TEMPLATE (optional)

      profile.OnSessionEnd:Connect(function()
         Profiles[player] = nil
         player:Kick(`Profile session end - Please rejoin`)
      end)

      if player.Parent == Players then
         Profiles[player] = profile
         print(`Profile loaded for {player.DisplayName}!`)
         -- EXAMPLE: Grant the player 100 coins for joining:
         profile.Data.Cash += 100
         -- You should set "Cash" in PROFILE_TEMPLATE and use "Profile:Reconcile()",
         -- otherwise you'll have to check whether "Data.Cash" is not nil
      else
         -- The player has left before the profile session started
         profile:EndSession()
      end

   else
      -- The session did not start; StartSessionResultAsync reports why (see above)
      player:Kick(`Profile load fail - Please rejoin`)
   end

end

-- In case Players have joined the server earlier than this script ran:
for _, player in Players:GetPlayers() do
   task.spawn(PlayerAdded, player)
end

Players.PlayerAdded:Connect(PlayerAdded)

Players.PlayerRemoving:Connect(function(player)
   local profile = Profiles[player]
   if profile ~= nil then
      profile:EndSession()
   end
end)

```
