# Smart Glasses HUD

ComputerCraft/CC:Tweaked Smart Glasses HUD for Advanced Peripherals 0.8 on Minecraft 1.21.1.

## Install on the glasses

Enable HTTP in the server's CC:Tweaked configuration, then run:

```lua
wget run https://raw.githubusercontent.com/KrreeeeGlass/Glasses/main/install.lua
```

The installer downloads `player_tracker.lua` and `startup.lua`, then reboots. On every subsequent login, death, or reboot, `startup.lua` downloads the newest tracker before launching it. If GitHub is unavailable, the installed copy is kept and launched.

## Files

- `player_tracker.lua` — main HUD and controls
- `startup.lua` — updater and automatic launcher
- `install.lua` — first-time one-command installer
- `sable_hud_sender.lua` — example telemetry sender for a Sable ship computer

The Sable sender belongs on the ship computer, not in the glasses.
