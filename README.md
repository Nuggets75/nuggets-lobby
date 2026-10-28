# Nuggets lobby

Additions to the Forged Alliance Forever game lobby (the screen when you host or join a game), running on top of FAF's own lobby. Players on the normal lobby need nothing and notice nothing: the changes only affect what your lobby shows, and the game itself is identical for everyone.

- **Lobby options of inactive mods are hidden.** FAF lists the options of every installed mod; this shows only those of the sim mods the host enabled and your own UI mods.
- **Minigames window** (button left of Settings), standalone, no mod needed:
  - **Liar's Dice** for 2 to 8 players at tables anyone here can host, join or watch. The rules are the Traditional and Basic modes of Liar's Bar: stars (ones) are wild, Spot on, lives or dice, turn timer, and bots.
  - **Challenges:** Chess and Battleship against a player you pick.
  - **Solo games:** Snake, Sudoku, Minesweeper, Dragonsweeper, Lag Clicker, Battleship against the bot.

## Download

**[NuggetsLobby.zip](https://github.com/Nuggets75/nuggets-lobby/releases/latest/download/NuggetsLobby.zip)**: the latest release, ready to install with `wrapper.exe` included (see [Releases](https://github.com/Nuggets75/nuggets-lobby/releases)). `wrapper.exe` is built from [`nuggets-lobby/source`](nuggets-lobby/source); each release lists its SHA-256.

## How it works

FAF's files are never modified, so the client's file check still passes and nothing is overwritten by updates.

1. The client starts `wrapper.exe` instead of the game (the client's launch wrapper / executable decorator setting).
2. The wrapper finds the client's `/init <file>` argument and writes `bin\init_nuggets_launch.lua`. That file runs the client's init file first, then `init_nuggets.lua`. The wrapper then starts the game with it; every other argument is passed through unchanged.
3. `init_nuggets.lua` adds `nuggets-lobby\hook` to the engine's hook folders, the same mechanism mods use for their `hook/` folders, and mounts `nuggets-lobby\games` at `/nuggetslobby`.
4. When the engine loads `/lua/ui/lobby/lobby.lua`, it appends `hook/lua/ui/lobby/lobby.lua` to it in memory.

Every entry point is guarded and falls back to FAF's normal behaviour on error. The lobby is not part of the simulation, so these changes cannot desync a game.

Lobby players find each other with a `NuggetsLobbyHello` message. A player on the normal lobby drops it and logs at most two "Unknown message type" warnings per player who runs this lobby. Minigame and Liar's Dice messages only go to players who run it.

## Building wrapper.exe

The wrapper is in [`nuggets-lobby/source`](nuggets-lobby/source) (Go, standard library only). With Go installed:

```
cd nuggets-lobby\source
set GOOS=windows& go build -trimpath -ldflags "-s -w -H=windowsgui" -o ..\wrapper.exe .
```

`go test ./...` runs the tests for the argument handling.

## Installing

Download the zip above, then (details in [`nuggets-lobby/README.txt`](nuggets-lobby/README.txt)):

1. Copy `init_nuggets.lua` into `C:\ProgramData\FAForever\bin\`.
2. Copy the `nuggets-lobby` folder (with `wrapper.exe`) into `C:\ProgramData\FAForever\`.
3. Tell the client to start the game through the wrapper:
   - Rust client: `"launchWrapper": "C:\\ProgramData\\FAForever\\nuggets-lobby\\wrapper.exe"` in `%APPDATA%\FAForever\FAForever Client\config\settings.json`.
   - Java client: executable decorator `"C:\ProgramData\FAForever\nuggets-lobby\wrapper.exe" %s`.

To undo, clear that setting again.

## Layout

```
init_nuggets.lua                 goes into FAForever\bin
nuggets-lobby/
  README.txt                     install and usage
  source/                        wrapper.exe (Go)
  hook/lua/ui/lobby/lobby.lua    appended to FAF's lobby.lua
  hook/lua/ui/dialogs/mapselect.lua
  games/
    hub.lua                      the Minigames window
    ui.lua                       shared look of the windows; art/ has the icons
    liarsdice/                   rules, bots, tables and networking, the table window, art
    snake.lua, sudoku.lua, window.lua
    minigames.lua                runs the bundled games below
    minigames/                   copy of the Minigames mod's games (see its CREDITS.txt)
```
