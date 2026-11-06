# ffxi-addons/autofight  
Autofight:  
Windower addon that engages, uses job abilities and weaponskills, and casts cures, enhancing, enfeebles, and nukes from a clickable overlay. It starts off. Load it, then turn it on from the overlay or with a command.

Install:  
Copy the `windower` folder to `Windower/addons/autofight` so `autofight.lua` sits next to `gui.lua`, `healer.lua`, `levels.lua`, `roles.lua`, and `scan.lua`.

Commands:  
//af help  
//af on | off | status  
//af role tank | dd | healer | support | mage  
//af focus damage | grind  
//af mode priority | aggressive | manual  
//af distance <yalms|loaded>  
//af names <a, b, c>  
//af main <name|me>  
//af follow <yalms>  
//af ws add <name> [tp] [min hp%]  
//af ja add <Name> [me|t] [tp]  
//af for <JOB> <command>  

Roles:  
tank holds hate and faces the enemy. dd uses job abilities and skillchain weaponskills. healer cures and maintains buffs. support sings, rolls, or places geomancy bubbles. mage enfeebles and nukes, and magic bursts when a skillchain is up.

Target modes:  
priority fights typed names, earlier names first, inside the chase distance. aggressive fights the nearest monster inside that distance. manual fights only the monster you already have targeted.

Multiple characters:  
Set Main to a character name on the others. They follow that character and assist whatever it is fighting. Main set to me means this character picks its own targets.

Scan:  
The Scan tab reads the client's widescan, lists enemies, and puts a unique name first. Clicking an entry moves you toward that enemy.

Settings:  
Saved in `data/settings.lua`, including a per-character box and a per-job weaponskill and ability list. The included file is a working profile. The overlay position, role, and job lists are edited from the panel and written back to that file.
