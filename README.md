# Meltwater

A survival colony sim set inside a glacier after a new Ice Age. The ice is the warmest shelter left, and every bit of warmth you make melts it.

This is the first prototype. It uses plain shapes instead of art and only tests one question: is managing heat against melting ice fun on its own?

## How to run it

1. Install [Godot 4](https://godotengine.org/download) (the standard version, not .NET).
2. Open Godot, click **Import**, and pick the `project.godot` file in this folder.
3. Press **F5** (or the play button at the top right) to start.

## Goal

Keep at least one of your three survivors alive until day 10. One day lasts one minute at normal speed.

## Controls

| Key or mouse | What it does |
| --- | --- |
| Left click or drag | Use the selected tool |
| Right click or drag | Clear dig marks, fires and ladders |
| 1 | Dig: mark ice, snow or crates for colonists to dig out |
| 2 | Fire: build a fire on a stone hearth (burns fuel) |
| 3 | Felt wall: strong insulation (limited felt) |
| 4 | Snow block: weak insulation made from dug ice |
| 5 | Ladder: lets colonists climb up and down shafts |
| 6 | Clear |
| Space | Pause |
| + / - | Change speed (1x to 3x) |
| H | Heat view |
| R | Restart with a new glacier |

## What to watch for

- Colonists lose warmth below 0°C and freeze when it runs out. Being wet makes it much worse.
- Fires warm the cave, but warm air rises and melts the ceiling. Meltwater drips, pools and can drown a fire.
- Weakened ice cracks, and if nothing holds it from the sides it falls, hurting anyone underneath.
- Water refreezes in cold spots into new, weaker ice.
- Fuel runs out in about four days with one fire. Dig out the orange crates left by earlier expeditions for more.
- Felt and snow walls slow the heat that escapes into the ice around them.

## Project layout

- `scripts/world.gd`: the simulation (heat, melting, water, collapse, colonists). No drawing.
- `scripts/main.gd`: drawing, mouse and keyboard tools, and the on-screen text.
- `tests/sim_test.gd`: automated checks for the simulation rules.

To run the checks from a terminal:

```
godot --headless --path . --script res://tests/sim_test.gd
```
