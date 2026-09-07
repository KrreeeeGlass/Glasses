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
airship calibrate
airship zero
airship setup
airship goto X Y Z
airship hold
airship abort
airship status
```

`airship controller` performs a read-only probe of the Advanced Contraption Controller. It lists every exposed ComputerCraft method, safely reads its status and graph variables, and saves the complete report to `/airship_controller_probe.txt`.

`airship calibrate` rises toward 2.5 blocks above its starting point, but begins testing as soon as it has remained at least 1.5 blocks clear of the ground with low vertical speed. It adopts the actual achieved Y as its hold altitude instead of requiring an exact height and performs short X, Z, and yaw pulses. Throughout takeoff and testing, it continuously combines live Diagram mass, measured lift-thruster force, vertical position, and vertical velocity: mass times gravity supplies neutral 0G/hover force, with controlled acceleration added or removed to change altitude. It saves the real actuator-axis matrix, yaw polarity, yaw acceleration response, and the sign conversion between Diagram angular velocity and quaternion heading, then immediately releases all thrust and lets the ship drop. Run it once after building or rotating the thruster/computer layout, in a clear area with overhead room and the gyro enabled.

`airship zero` records the current quaternion direction as heading 0. Run it while the ship is pointed in the exact direction you want it to preserve. No navigation table, lodestone compass, CC GPS constellation, or gimbal sensor is required.

`airship setup` automatically maps the supported square layout: four lift thrusters below the corners plus paired horizontal thrusters on the four outer edges. It derives corner position and force direction from the stable relay/thruster names, so the twelve thrusters no longer require individual direction entry.

Lift is mass-aware: the center combines the Diagram's live mass with Sable gravity and the corner relays' measured Create Propulsion thrust. Because `setPowerNormalized` is internally quantized to fifteen redstone levels, fractional lift is distributed between already-spooled lift thrusters. Horizontal motion and heading corrections are force-limited and share an exact allocator, but use steady discrete power so horizontal thrusters can complete their startup envelope. Pure X and Z commands use the required pair. Fine yaw uses one balanced pair, stronger yaw uses four thrusters, and combined movement and turning uses at most three horizontal thrusters.

Before translating, the autopilot aligns to the configured heading and waits for both heading error and yaw rate to settle. Its predictive yaw controller calculates an explicit stopping distance from live angular velocity, measured yaw acceleration, and the thruster response delay. When that distance reaches the remaining safe angle, counter-thrust starts immediately instead of waiting for the sampled angle to overshoot. While inside the allowed heading band, a longer velocity projection triggers damping before slow angular drift can cross either boundary. For the installed Create Propulsion: Simulated 1.1.5 behavior, the projection and stopping calculation include the thruster's ten-tick response envelope plus command-transfer margin. Version 1.1.5 also floors normalized ComputerCraft input to 15 levels, so active horizontal thrusters are held continuously at stable discrete levels instead of using rapid PWM that would repeatedly reset their startup ramp. Every pure yaw correction uses all four force-balanced yaw thrusters at an equal power step; translation pauses during a heading correction so the two controls cannot conflict. Translation otherwise uses the appropriate pair. Horizontal speed and acceleration use conservative safety caps plus a stopping-distance limit to reduce overshoot.

Updates are automatic. The center refreshes its launcher and runtime at every boot and before every `airship` command. Corner relays also check GitHub while idle and install updates automatically; they never update or reboot while a center is actively commanding thrust.

Every published airship change increments the runtime version. The launcher prints the downloaded and running version on the center, and each corner prints its running version at startup so all five computers can be checked at a glance.

Runtime downloads use immutable `airship-vX.Y.Z` Git tags. This prevents a GitHub raw cache from mixing launcher and runtime revisions.
Launchers and corner updaters compare semantic versions and reject stale downloads, so a delayed `main` cache can never downgrade a computer that already has a newer release.
