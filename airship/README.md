# Create Propulsion Airship Autopilot

## Universal installer (recommended)

Run this exact same command on the center and all four corner computers:

```lua
wget run https://raw.githubusercontent.com/KrreeeeGlass/Glasses/main/airship/unified_v3/install.lua
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

The center must directly touch, or share a wired-modem network with, the **Advanced Contraption Controller** whose shared graph is linked to the ship's Contraption Diagram. The autopilot now relies only on that graph for physics; the old navigation-table, lodestone, gimbal, and position-difference methods are not used.

Expose these graph variables with these exact names:

```text
available
mass
position_x position_y position_z
orientation_x orientation_y orientation_z orientation_w
linear_velocity_x linear_velocity_y linear_velocity_z
angular_velocity_x angular_velocity_y angular_velocity_z
```

Commands:

```lua
airship list
airship controller
airship zero
airship setup
airship goto X Y Z
airship hold
airship abort
airship status
```

`airship controller` performs a read-only probe of the Advanced Contraption Controller. It lists every exposed ComputerCraft method, safely reads its status and graph variables, and saves the complete report to `/airship_controller_probe.txt`.

`airship zero` records the current quaternion direction as heading 0. Run it while the ship is pointed in the exact direction you want it to preserve. No navigation table, lodestone compass, CC GPS constellation, or gimbal sensor is required.

`airship setup` automatically maps the supported square layout: four lift thrusters below the corners plus paired horizontal thrusters on the four outer edges. It derives corner position and force direction from the stable relay/thruster names, so the twelve thrusters no longer require individual direction entry.

Updates are automatic. The center refreshes its launcher and runtime at every boot and before every `airship` command. Corner relays also check GitHub while idle and install updates automatically; they never update or reboot while a center is actively commanding thrust.

Every published airship change increments the runtime version. The launcher prints the downloaded and running version on the center, and each corner prints its running version at startup so all five computers can be checked at a glance.

Runtime downloads use immutable `airship-vX.Y.Z` Git tags. This prevents a GitHub raw cache from mixing launcher and runtime revisions.
Launchers and corner updaters compare semantic versions and reject stale downloads, so a delayed `main` cache can never downgrade a computer that already has a newer release.
