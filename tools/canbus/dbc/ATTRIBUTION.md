# subaru_global.dbc

Broadcast CAN frame definitions for the Subaru Global Platform, vendored from
[commaai/opendbc](https://github.com/commaai/opendbc) (MIT License),
`opendbc/dbc/generator/subaru/_subaru_global.dbc`.

**Community reverse engineering, not an official Subaru document.** It covers
what openpilot needs, which is why `Engine_RPM` is present but coolant
temperature, fuel trims and oil temperature are not.

The frames this project cares about:

- `0x3AC BodyInfo` — `DOOR_OPEN_FL/FR/RL/RR` and **`DOOR_OPEN_TRUNK`**
- `0x390 Dashlights` — `SEATBELT_FL`, blinkers, units
- `0x040 Throttle` — `Engine_RPM`, `Throttle_Pedal`

`DOOR_OPEN_TRUNK` is the broadcast counterpart of the `22 104E` we measured
on module `0x75A`. Cross-checking the two validates both — one is someone
else's claim, the other is our measurement, and they should agree.
