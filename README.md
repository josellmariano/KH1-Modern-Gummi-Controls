# KH1 Modern Gummi Controls

Makes gummi ship flight control like a modern game. The left stick moves the
aiming reticle, and the reticle stays where you leave it instead of snapping
back to the center. Up and down are flipped from vanilla by default
(vanilla's are inverted). Reticle speed and the flip can both be changed in a
config file. Menus, the world map and Sora keep their normal controls.

## Requirements

- Kingdom Hearts Final Mix, Steam version
- LuaBackend, installed through OpenKH Mods Manager

## Settings

Start the game once with the mod and `KH1_Modern_Gummi_Controls_Config.lua`
appears in the game folder, next to `KINGDOM HEARTS FINAL MIX.exe`. Open it
in a text editor, change a value, save, and restart the game. Every setting
is explained in the file, and mod updates never overwrite it.

| Setting | Default | What it does |
| --- | --- | --- |
| `InvertY` | `true` | Flip up/down from vanilla. `false` keeps vanilla's direction. |
| `HoldReticle` | `true` | `false` brings back vanilla's snap-back to center. |
| `ReticleSpeed` | `4.0` | How fast the reticle moves. |

## License

MIT. See [LICENSE](LICENSE).
