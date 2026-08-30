# Create Propulsion Airship Autopilot

Install on the dedicated ship computer:

```lua
wget run https://raw.githubusercontent.com/KrreeeeGlass/Glasses/main/airship/install.lua
```

The installer places `/airship.lua` and `/startup.lua`, then reboots. Startup downloads the newest controller, rejects invalid Lua, preserves the last working copy if GitHub is unavailable, forces all visible thrusters to zero, and leaves the computer ready for a command.

The computer needs a CC wired-modem network to expose every Create Propulsion thruster. Wireless or Ender modems carry messages but do not expose remote peripherals. Keep a wireless/Ender modem on the computer for GPS and SABLE Smart Glasses telemetry.

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
