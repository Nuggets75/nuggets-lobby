Nuggets custom lobby
====================

Your own lobby changes, running on top of FAF's lobby. Standalone: no mod is
needed. Other players need nothing: the changes only affect what your lobby
shows, and the game itself is identical for everyone.

Features
--------
- Lobby options of mods that are not active are hidden, both in the option
  summary on the lobby screen and in the host's Options dialog. "Active" means
  the sim mods the host enabled, plus your own UI mods. FAF's own options are
  always shown. Hidden options keep their values; nothing about the game
  settings changes.

- Minigames button (top bar, left of Settings) opens the Minigames window:

  Liar's Dice tab
    The tables in this lobby. HOST A TABLE opens yours; everyone here who runs
    this lobby gets a chat line about it. JOIN takes a seat (2 to 8 players),
    WATCH lets you look on. Joining a game that already started, or a full
    table, makes you a watcher until the next game.

  Challenges tab
    Chess and Battleship against a player you pick from the list. Only that
    player gets the challenge. The list shows only players here who run this
    lobby. If they do not answer in time, Battleship starts against the bot.
    The tick boxes turn incoming challenges off.

  Solo games tab
    Snake, Sudoku, Minesweeper, Dragonsweeper, Lag Clicker, Battleship against
    the bot. Minesweeper size and hard mode are set below the games.
    Snake: arrow keys or WASD, Space pauses (or tick "Steer with the mouse").
    Sudoku: click a cell, then a number below the board; right-click clears.
    Lag Clicker scores are shared with the players here who run this lobby.

  Games close when the lobby closes or the game launches.

Liar's Dice
-----------
Everyone rolls their dice in secret. In turn, players bid how many dice on the
WHOLE table show a face ("7 fours"). Each bid must be higher: more dice, or as
many dice with a higher face. Instead of bidding you can call:
  LIAR!     everyone shows their dice. If the bid was too high, the bidder
            loses; if it holds, you lose.
  SPOT ON!  (Traditional rules) you say the bid is exactly right. If it is,
            everyone else loses; if not, you lose.
Traditional rules: the one is a gold STAR and is wild: it counts as every
face, except in a bid on stars. Basic rules: plain ones, nothing wild, no
Spot on.
A loss costs a life (default 3 lives) or a die, as the host sets. Out of lives
or dice and you are out; the last player in wins. Whoever lost starts the next
round.

The host sets, before the game: rules (Traditional / Basic), what a loss costs
(a life / a die), lives (1-5), dice (3-6), turn time (15-90 s), and can add
bots (up to 8 seats) or take seats off the table. START GAME needs 2 seats.
After a game, NEW GAME takes everyone back to the table.

At the table: your dice are at the bottom. Pick a face, set the number with
- and +, then BID. Faces you cannot bid are greyed out. When the timer runs
out, a move is made for you.
After a call everyone's dice are shown: gold-ringed dice show the bid's face,
blue-ringed stars are wild dice that count for it, grey dice do not count. Bids of this round and what happened at the table
are listed on the right.
Hide keeps your seat and closes the window; it comes back when it is your
turn. The X leaves the table (it asks first during a game; for the host it
closes the table for everyone).
A player who leaves the lobby is taken off the table after a few seconds; if
that happens during the bidding, everyone rolls again. If the host leaves,
the table closes.
The host's lobby rolls the dice and runs the table; every player's window only
receives their own dice until a call reveals them all.

Compatibility
-------------
Players on the normal lobby are unaffected: their game log shows at most two
"Unknown message type: NuggetsLobbyHello" lines per player here who runs this
lobby. Minigame and Liar's Dice messages only go to players who run it.

Check the game log for "NuggetsLobby" lines to see what loaded.

Install
-------
1. Copy init_nuggets.lua into  C:\ProgramData\FAForever\bin\
2. Copy this nuggets-lobby folder into  C:\ProgramData\FAForever\
   (so it sits next to bin)
3. Right-click nuggets-lobby\wrapper.exe > Properties > tick "Unblock" if shown.
4. Tell the client to start the game through wrapper.exe:

   FAF Rust client (the field is hidden on Windows, so edit the file):
   a. Quit the client completely, including from the tray.
   b. Open in Notepad:
      %APPDATA%\FAForever\FAForever Client\config\settings.json
   c. Find      "launchWrapper": ""
      Change to "launchWrapper": "C:\\ProgramData\\FAForever\\nuggets-lobby\\wrapper.exe"
      (double backslashes are required in this file)
      If "launchWrapper" is not in the file, add that line inside the "game": { } block.
   d. Save and start the client.

   FAF Java client:
   Settings > Forged Alliance > executable decorator. Replace  "%s"  with:
   "C:\ProgramData\FAForever\nuggets-lobby\wrapper.exe" %s

5. Host a custom game.

Updating
--------
Copy the new files over the old ones (init_nuggets.lua into bin when an
update includes it). Changes take effect the next time the game starts.
Everyone who should play Liar's Dice together needs the same version.

If something does not work
--------------------------
Send these two files:
- C:\ProgramData\FAForever\nuggets-lobby\wrapper.log   (what the wrapper did)
- the game log of that launch. Search it for "NuggetsLobby".

Undo
----
Rust client: quit it, set "launchWrapper" back to "" in settings.json.
Java client: set the executable decorator back to "%s".
The game then starts exactly as before. Nothing of FAF's was modified.

Known limitation
----------------
The Rust client's "Borderless window" option does not apply while the wrapper
is in use: the client looks for the window of the process it started, which
is now wrapper.exe rather than the game.

What is in here
---------------
wrapper.exe   Started by the client instead of the game. If init_nuggets.lua
              sits next to the game, it writes init_nuggets_launch.lua there
              (the client's own init file first, then init_nuggets.lua) and
              starts the game with it. Every other argument is passed through
              unchanged. Waits for the game, passes its exit code back to the
              client, and closes the game if the client kills it. Replays pass
              through unchanged. Writes wrapper.log next to itself each launch.
hook\         Lobby code the game appends to its own files of the same path
              (mounted at /nuggetshook):
              lua\ui\lobby\lobby.lua         the lobby screen
              lua\ui\dialogs\mapselect.lua   the host's map and Options dialog
games\        The lobby's games (mounted at /nuggetslobby):
              hub.lua         the Minigames window
              ui.lua          the look shared by the Minigames and Liar's Dice
                              windows; art\ has their icons
              minigames.lua   runs the bundled games below, challenges
              liarsdice\      Liar's Dice: rules.lua (the rules), bot.lua (the
                              bots, and moves for players whose time ran out),
                              table.lua (tables, joining, the host's game),
                              view.lua (the table window), art\
              snake.lua, sudoku.lua, window.lua
              minigames\      a copy of the Minigames mod's game files (Chess,
                              Battleship, Minesweeper, Dragonsweeper, Lag
                              Clicker) with their paths pointed here. Changes
                              to the mod do not reach this copy by themselves.
                              CREDITS.txt lists the music licences.
              minigames\sounds is mounted at /sounds for Lag Clicker, unless an
              installed mod already has sound banks with the same names.
source\       Go source of wrapper.exe. Build it yourself with:
              set GOOS=windows& go build -ldflags "-H=windowsgui" -o ..\wrapper.exe .
