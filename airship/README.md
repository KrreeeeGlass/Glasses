# Create Propulsion Airship Autopilot

## Universal installer (recommended)

Run this exact same command on the center and all four corner computers:

```lua
wget run https://raw.githubusercontent.com/KrreeeeGlass/Glasses/main/airship/unified/install.lua
```

The identical startup detects the role from local hardware: zero touching thrusters is the center controller; three touching thrusters is a corner relay.

Install on the dedicated ship computer:

```lua
wget run https://raw.githubusercontent.com/KrreeeeGlass/Glasses/main/airship/center/install.lua
```

The installer places `/airship.lua` and `/startup.lua`, then reboots. Startup downloads the newest controller, rejects invalid Lua, preserves the last working copy if GitHub is unavailable, forces all visible thrusters to zero, and leaves the computer ready for a command.

The normal layout uses one center controller and four corner relay computers. Each corner computer directly touches its three Create Propulsion thrusters and has a wireless/Ender modem. Install the corner relay on all four corner computers:

```lua
wget run https://raw.githubusercontent.com/KrreeeeGlass/Glasses/main/airship/corner/install.lua
```

No ID or pairing step is required. Each relay reboots, finds the center automatically, and releases the temporary binding if that center disappears.

The center computer uses the main installer shown above. Its wireless/Ender modem handles corner commands and SABLE Smart Glasses telemetry.

The center must directly touch, or share a wired-modem network with, the **Advanced Navigation Table from Create Aeronautics: Gadgets & Gizmos**. Put a valid permanent reference target in the table and select it. The controller reads live world X/Y/Z from the table and derives yaw from the reference target and pointer angle. Keep that reference more than two blocks away.

Commands:

```lua
airship list
airship zero
airship setup
airship goto X Y Z
airship hold
airship abort
airship status
```

`airship zero` records the ship's current direction as heading 0. Run it while the ship is pointed in the exact direction you want it to preserve. No CC GPS constellation, Gimbal Sensor, or Create: Avionics is required.

Updates are automatic. The center refreshes its launcher and runtime at every boot and before every `airship` command. Corner relays also check GitHub while idle and install updates automatically; they never update or reboot while a center is actively commanding thrust.
