# Focus

Windower 4 addon for a private server. Party tab picks a main. Engage tab closes on a nearby enemy and attacks. Engage is off when the addon loads.

## Install

1. Copy the `Focus` folder into `Windower/addons`.
2. In game: `//lua l Focus`

## Party

Shows all six party slots (`p0`–`p5`), including empty ones: name, HP%, distance in yalms, and status. Choose one member as the main. The name is saved and restored on reload.

On every other character running Focus, with Engage off, that character sets its target to the main's current target. This tab does not attack.

## Engage

Checkbox, default off. The slider is the approach radius, 0–100 yalms.

While on, this character runs to the nearest valid enemy inside the radius, targets it, and engages once it is in melee range. A valid enemy is a hostile mob that is alive and is not a party member, alliance member, or pet. Unclaimed mobs and mobs claimed by the party are taken before mobs claimed by anyone else.

If position barely changes for about two seconds while running, Focus strafes, backs up, then tries a new heading, and waits before doing that again. It stops running in melee range, when Engage is turned off, and when the addon is unloaded.

`mob.distance` from the client is squared yalms. The list, the radius, and melee range all use real yalms (`sqrt`).
