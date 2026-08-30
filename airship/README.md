# Create Propulsion Airship Autopilot

Install on the dedicated ship computer:

```lua
wget run https://raw.githubusercontent.com/KrreeeeGlass/Glasses/main/airship/install.lua
```

The installer places `/airship.lua` and `/startup.lua`, then reboots. Startup downloads the newest controller, rejects invalid Lua, preserves the last working copy if GitHub is unavailable, forces all visible thrusters to zero, and leaves the computer ready for a command.

The normal layout uses one center controller and four corner relay computers. Each corner computer directly touches its three Create Propulsion thrusters and has a wireless/Ender modem. Install the corner relay on all four corner computers:

```lua
wget run https://raw.githubusercontent.com/KrreeeeGlass/Glasses/main/airship/corner-install.lua
```

No ID or pairing step is required. Each relay reboots, finds the center automatically, and releases the temporary binding if that center disappears.

The center computer uses the main installer shown above. Its wireless/Ender modem handles corner commands, GPS, and SABLE Smart Glasses telemetry.

Commands:

```lua
airship list
airship setup
airship goto X Y Z
airship hold
airship abort
airship status
```

The autopilot also requires a four-host CC GPS constellation and a `navigation_table` peripheral from Create: Avionics. A `gimbal_sensor` is recommended.
