# Meltwater

A survival colony sim set inside a glacier after a new Ice Age. The ice is the warmest shelter left, and every bit of warmth you make melts it.

This is an early prototype. It uses plain shapes instead of art and tests whether managing heat against melting ice is fun, with an expedition journal that leads you down through the camps of earlier expeditions.

## How to run it

1. Install [Godot 4](https://godotengine.org/download) (the standard version, not .NET).
2. Open Godot, click **Import**, and pick the `project.godot` file in this folder.
3. Press **F5** (or the play button at the top right) to start.

## Goal

Follow the expedition journal (the gold line at the top) to its last entry while keeping at least one of your three survivors alive. One day lasts one minute at normal speed.

The journal leads you through three camps frozen in the ice, each deeper than the last. You can see them faintly through the ice, marked with a "?". Digging into one gives you its supplies, a page of its story, and sometimes a blueprint for a new building:

| Camp | Where | What you find |
| --- | --- | --- |
| The survey hut | South-west, a short dig down | Rations and the lichen bed blueprint |
| The drill camp | East and deeper | Rations, fuel and the peat stove blueprint |
| The last shelter | Near bedrock | The end of the journal |

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
| 7 | Lichen bed: grows food when kept above 4°C and dry (costs 2 snow, needs its blueprint) |
| 8 | Peat stove: heats like a fire on under half the fuel (needs its blueprint) |
| Scroll wheel | Zoom in and out, toward the mouse pointer |
| W A S D or arrow keys | Move the view when zoomed in |
| Space | Pause |
| + / - | Change speed (1x to 3x) |
| H | Heat view |
| R | Restart with a new glacier |

## What to watch for

- Colonists lose warmth below 0°C and freeze when it runs out. Being wet makes it much worse.
- Each colonist eats one ration a day. When the food runs out, hunger makes the cold hit harder. Crates sometimes hold rations, and lichen beds grow more.
- Fires warm the cave, but warm air rises and melts the ceiling. Meltwater drips, pools and can drown a fire. Ice that falls on a burning fire melts into it.
- Weakened ice cracks, and if nothing holds it from the sides it falls, hurting anyone underneath.
- Water refreezes in cold spots into new, weaker ice.
- Fuel runs out in about four days with one fire. Dig out the orange crates left by earlier expeditions for more.
- Colonists can walk up and down diagonal stairs, so dig paths as steps. For straight shafts, place ladders.
- Felt and snow walls slow the heat that escapes into the ice around them.

## Project layout

- `scripts/world.gd`: the simulation (heat, melting, water, collapse, colonists, food, camps and the journal). No drawing.
- `scripts/main.gd`: drawing, mouse and keyboard tools, and the on-screen text.
- `tests/sim_test.gd`: automated checks for the simulation rules.

To run the checks from a terminal:

```
godot --headless --path . --script res://tests/sim_test.gd
```
