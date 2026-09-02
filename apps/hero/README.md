# Hero

A character journal for Dungeons and Dragons on the 2024 rules: an optional
application, not part of the system. `make hero` builds it into `home/`, where
it is on the machine at the next image build; `make apps` builds it with the
rest. It opens a `.hero` file from the launcher, or from its own File menu.

Hero is versioned on its own, apart from the system's string, because it
ships when it ships: `hero --version` says which, and the rail says it when no
file is open.

The rest of this file is the design: what the file is, and what the window
makes of it.


Hero is an optional application, not part of the system: a tracker for a
Dungeons and Dragons character on the 2024 rules, in the toolkit's own
language. It opens a `.hero` file, shows the character the file adds up to,
and answers the moments of play with helpers: a roll, damage taken, a rest,
a spell cast, gold paid, a note. Everything it draws is `libeui`'s, and
nothing of the game is in the toolkit; the only pictures of its own are the
shield, heart, bolt, chevrons, skull, die, d20, moon and spark, drawn on the
toolkit's twelve pixel grid and kept in the program.

## 13.1 The file is the journal

A `.hero` file is text, one line per fact or event, in the order they were
written. The sheet is the fold of the lines from top to bottom: a fact sets
something, an event changes it, and the character at any moment is the
result of everything above. Nothing is overwritten. A mistake is corrected by
another line, and the history of the character is the file itself.

Text, because a journal that only one program can read is a journal in a
locked drawer: `cat` prints it, `grep` finds the session a name was written
in, Pad edits it, and `file` names it a character journal. The shell has
every capability the window has, because the file has them.

The first line names the format: `hero 1`. Every other line is a keyword,
a space, and the rest of the line; where the rest has parts they are
separated by ` | `. Blank lines and lines starting with `#` are kept and
ignored. Text is UTF-8. Unknown keywords are kept and shown as notes rather
than refused, so a file from a later version still opens in an earlier one.

## 13.2 Facts

| Line | Meaning |
|---|---|
| `name cinaed I` | What the character is called |
| `class Sorcerer`, `level 1` | Class and level; the level sets the proficiency bonus |
| `species Halfling`, `background Acolyte`, `alignment Chaotic Good`, `size Small` | Origin |
| `player cinaed666`, `advancement milestone` | Who plays, and whether experience is counted |
| `portrait <base64>` | The headshot, a square of sixty-four pixels kept as a small JPEG inside the journal; `portrait -` takes it away |
| `picture cinaed.png` | A picture file beside the journal, shown as the headshot when there is no portrait line |
| `str 14` and the other five | Ability scores; modifiers are derived |
| `saves con cha` | Saving throw proficiencies |
| `skills deception insight persuasion religion` | Skill proficiencies; `expertise` lists the doubled ones |
| `hp 8`, `hit-die d6` | Hit point maximum, and the die a level gives |
| `ac 12`, `speed 30` | Armour class and speed in feet |
| `spellcasting cha`, `slots 2 0 0 0 0 0 0 0 0` | The casting ability, and slots per level from first to ninth |
| `innate 2 \| Innate Sorcery` | Uses of the class's innate feature per long rest, and what it is called |
| `weapons Simple weapons`, `tools Calligrapher's supplies`, `languages Common`, `armour none` | Proficiencies and training |
| `feature Innate Sorcery \| 2 / long rest` | A feature and, optionally, how often |
| `attack Dagger \| +4 \| 1d4+2 piercing \| Finesse, light, thrown, nick, 20/60` | An attack: name, to hit, damage, notes |
| `spell Fire Bolt \| 0 \| 1 action \| 120 ft. \| V/S, +7 to hit` | A spell: name, level (0 for a cantrip), casting time, range, notes |
| `item Dagger \| 2 \| 1` | Gear: name, quantity, weight of one in pounds |
| `coins 0 0 0 36 0` | Copper, silver, electrum, gold, platinum |

Facts may appear anywhere, so a level gained mid-journal is `level 2` on the
day it happened, followed by the new `hp` and `slots`. An attack, spell,
item or feature written again under a name already there replaces the
earlier line, so a correction is the line again rather than a twin, and an
`item` with a quantity of none is the item gone.

## 13.3 Events

| Line | Effect on the fold |
|---|---|
| `session 3 \| 2026-08-30` | A heading: everything after it belongs to this session, until the next |
| `damage 5 \| goblin arrow` | Temporary hit points absorb first, then current hit points, never below zero |
| `heal 4 \| potion` | Current hit points rise, never above the maximum; death saves reset |
| `temp 5` | Temporary hit points are set, not added |
| `hitdie 5` | One hit die spent and its roll applied as healing |
| `rest short` | A marker; what a short rest heals is written as `hitdie` lines |
| `rest long` | Hit points to maximum, every hit die and slot and innate use back, exhaustion down one, death saves reset |
| `cast 1 \| Burning Hands` | A slot of that level spent; level 0 spends nothing and is a record |
| `innate-use` | One innate use spent |
| `save success`, `save failure`, `save reset` | Death saves |
| `condition frightened \| on` | A condition set or cleared; bloodied is derived from hit points and never written |
| `exhaustion 1` | The exhaustion level, set |
| `inspiration on` | Heroic Inspiration held or spent |
| `gold -3 \| rations` | Gold paid or received, with why |
| `roll Persuasion \| 12 \| +7 \| advantage` | A d20 rolled: what for, the die kept, the modifier, and how |
| `dice Dagger damage \| 1d4+2 \| 3 \| 5` | A handful rolled: what for, the dice as named, as they fell, and the total |
| `drop item \| Rope, hempen` | An attack, spell, item or feature gone from the sheet, by name |
| `concentrate Bane`, `concentrate -` | Concentration on a spell, or on nothing; casting a spell whose notes say concentration starts it, and a rest ends it |
| `note The shrine keeper asked for the crystal back` | Anything at all |

An event before the first `session` line belongs to no session, which is
what a file made by hand looks like; the program writes a session heading
before the first event of a day it has not seen.

## 13.4 What the program derives

Ability modifier: half of the score less ten, rounded down. Proficiency
bonus: two, plus one per four levels past the first. A skill's bonus is the
ability's modifier plus the proficiency bonus where proficient, twice where
expert. A passive score is ten plus the skill's bonus. Bloodied is hit points
at or below half the maximum. Carrying capacity is fifteen times Strength in
pounds, and push, drag or lift twice that. Exhaustion subtracts twice its
level from every d20 test, which the roll helper applies and shows.

A d20 test rolls once, or twice keeping the higher for advantage and the
lower for disadvantage; the journal line records the die kept, so a total
can be checked by hand. A death save, from the Roll menu or the button by
the Combat pane's pips at no hit points, is marked from what fell: ten or
more a success, less a failure, a 1 two failures, a 20 a hit point back.
Three successes are stable, three failures the end, and the status line
says which. A handful of dice, an attack's damage or a free
roll, is summed, and every die that fell is recorded. Poisoned and
frightened put disadvantage on checks and attacks, and prone on attacks,
which the dice window sets before it opens and says why.

## 13.5 The window

The rail on the left holds the headshot and six sections: Sheet, Skills,
Combat, Spells, Gear and Journal. The status bar names the file and whether
it is saved, the session, and what the pane is about or what was just done:
the hit points on Combat, what is concentrated on in Spells, the count on
Journal. Helpers are the toolkit's
prompt sheet across the bottom of the body, so a question never covers what
it is about: a rest asks which, a cast asks whether to spend the slot, and
damage, healing, gold and a hit die ask how much on the sheet's own stepper.
Every answer is a line appended to the journal, and Save writes the file
whole under a new name, renames it over the old, and flushes, like every
document on this machine that matters.

A roll opens the dice: a second window floating over the sheet, filled in by
what asked for it. Enter on a skill, a tile's save, an attack, or the Roll
menu for anything at all. It shows the die, how many, the bonus and where it
comes from, and for one d20 the mode; Enter rolls, Escape leaves, and every
roll is written as it lands, with both dice shown and the kept one ringed
when a mode chose. An attack offers its damage dice next.

The Character menu builds and corrects the sheet a fact at a time: each item
asks for one line, with a field on the prompt sheet already holding what the
sheet says, in the parts the file takes, and showing the shape of the line
while it is empty. A number that is not one is refused rather than written.
Portrait takes in any picture the machine reads, up to half a megabyte: the
square from its middle is shrunk to the headshot's size and kept as JPEG on
one line of the journal, so the face travels with the file. New character starts a fresh
journal that is saved where the first Save says. Each pane adds its own rows
with an Add button: a feature on the Sheet, an attack on Combat, a spell on
Spells, an item on Gear, where gold is paid and received too. The Edit menu
holds the moments of play: damage, healing, a hit die, one of an item used
up, the selected row dropped, the innate feature used, concentration
stopped, a level gained with its new hit points, a session, a note, and the
last line since the save taken back. Each pane's table takes the keyboard as
the pane opens, so arrows and Enter reach a roll, a cast or an item without
the pointer.

The journal section lists the events newest first with their session, and a
note is typed into the strip below it. A session heading is written before
the first event of a day the journal has not seen. Closing with lines
unsaved asks, the way Pad asks.

From the shell, `hero --version` says which Hero this is, and `hero --roll
2d6+3` or `hero --roll d20 advantage` throws the same dice the window does
and prints what fell.

## 13.6 Budgets

One character per window. The file is held whole, sixty-four kilobytes,
which is years of play at a line per moment with the portrait's few
kilobytes among them. Up to sixty-four items, thirty-two spells, twelve
attacks, sixteen features and two thousand lines. A picture taken in for the
portrait is read whole, up to half a megabyte, and decoded through the same
library the picture viewer uses; what is kept is the sixty-four pixel
square.
