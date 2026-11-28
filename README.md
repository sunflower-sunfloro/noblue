# noblue

noblue takes the blue out of your screen, on Linux with X11.

White shows as bright yellow. Blue shows as black. Every other color
keeps its red and green.

It works underneath every program, at the graphics card. So nothing a
program draws can bring blue back.

Night lights and color filters only turn blue down, and they dim green
as well. noblue turns blue off and leaves green at full strength, so
text stays bright and sharp.

## How it works

Your graphics card has a color table for each screen. It is the card's
last step before the picture goes to the screen. noblue sets every
table so that red and green display as they are, and blue is always 0.

It does this in two steps.

1. It asks X, the window system, to set the tables.
2. It checks. X can say "done" when nothing was done. So noblue then
   asks Linux, which runs the card, what is really in each table.

The check passes only if every screen that is on has a table, with
blue 0 from top to bottom.

## Using it

    noblue          set the tables once, and check them
    noblue watch    keep going: set and check again every second, and
                    whenever a screen changes
    noblue off      put blue back

noblue prints what it found, like this:

    noblue: 1 screen, 0 with no color table, blue at most 0

That line is a pass: 1 screen or more, 0 with no color table, and blue
at most 0. Anything else is a fail, and the line says why.

For scripts: noblue answers 0 for a pass, and 1 for anything else.

`noblue watch` prints a line only when what it finds changes. It keeps
setting the tables even after a check fails, and ends only when X ends.

`noblue off` sets plain tables. If a color calibration was loaded
before noblue, it is not brought back: load it again.

## Starting it when you log in

Most desktops start the programs listed in the folder
`~/.config/autostart`. Put a file there named `noblue.desktop`, with
these lines, and the real path to noblue in the last one:

    [Desktop Entry]
    Type=Application
    Name=noblue
    Exec=/path/to/noblue watch

Write the path out in full, starting with `/`. The short forms `~` and
`$HOME` may not be filled in there, and then noblue does not start.

Use the start-up folder, and nothing else. Do not put noblue in a file
the desktop runs and waits for, like `~/.xprofile`, or in the login
screen's own settings, like LightDM's `display-setup-script`. noblue
watch never ends, so the desktop or the login screen would wait for it
forever. And plain noblue answers 1 when its check fails, which can
make the login screen stop and start again without end.

## Building

noblue is one file of fasmg source (fasmg is the flat assembler g). It
uses no libraries, so the built program runs on any 64-bit PC Linux
with X11.

    INCLUDE=/path/to/fasmg/packages/x86/include fasmg noblue.asm noblue
    chmod +x noblue

The first line builds it. INCLUDE tells fasmg where its x86 package
is: the add-on that knows the PC chip's instructions, and the shape of
a Linux program. The second line marks the built file as a program;
fasmg does not.

## Limits

noblue turns off the blue signal to the screen. Please read these
before you rely on it.

- The light itself. An LCD's backlight can still leak a little blue
  through closed pixels. noblue cannot change that. Polyimide tape
  over the screen can cut it down; no promise about how its removal
  will go.
- X11 only. Wayland is not covered.
- Your own session only. Run noblue inside your X session, on the
  computer itself, not over the network.
- Before you log in. The computer's start-up screens, the boot menu,
  the login screen and the text consoles (Ctrl+Alt+F3 and the like)
  are not covered.
- The mouse pointer and video, on some older cards. They can be drawn
  after the color table, and keep their blue. Look at a white pointer
  to check.
- HDMI. Some cards send black as level 16, not 0. A screen that
  expects 0 then shows a faint glow in every color, blue too. Set the
  card or the screen to full range. On Intel cards, this command sets
  the card. In place of HDMI-1, put your output's name, which plain
  `xrandr` lists. It lasts until you log out.

      xrandr --output HDMI-1 --set "Broadcast RGB" "Full"
- Some TVs. They are sent colors in another form (YCbCr), made after
  the color table. The TV turns them back, and its rounding can leave
  a trace of blue, a level or two out of 255.
- Night lights. A night light, or anything else that sets the same
  tables, can put blue back. Turn it off. `noblue watch` sets the
  tables again within a second, but a moment of blue can show first.
- Screenshots. A screenshot still shows blue, because it is taken
  before the color table. Look at the screen itself, or photograph it.

## Tests

`tests/noblue.py` plays the part of X and of the graphics cards, and
checks what noblue does with each: right answers, wrong ones, and
answers twisted on purpose. Run it from noblue's folder, with fasmg
and INCLUDE set as for building:

    python3 -I tests/noblue.py

A pass ends "81 checks, 0 failed". The stand-in cards need a Linux
feature named ptrace, which some containers forbid.

On real hardware, under X11: one screen, blue 0, Linux's check passed.

## License

Copyright (C) 2026 the noblue project. GPL version 3 only (LICENSE).
No warranty.
