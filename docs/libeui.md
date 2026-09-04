# libeui, the toolkit

<!-- Generated from src/user/eui/ by `zig build eui-docs`.
     Do not edit: change the toolkit instead. -->

Every program that draws draws with this. It has no syscalls in it: a
control is given a surface and a rectangle and it paints, and the
program it belongs to is the one that talks to the window manager.
That is what makes the whole toolkit testable on a host with no
machine under it.

## The frame a program runs in

A windowed program does not own an event loop: it hands `proto.app`
a draw pass and only the interceptions it wants, and the frame owns
the connection, the window, resizing, theme changes and the commit.

```zig
const ctx = &proto.app.ctx;

export fn _start() callconv(.c) noreturn {
    proto.app.run("name", "Title", 460, 320, .{ .draw = draw });
}

fn draw() void {
    if (ctx.button(save_rect, "Save")) save();
}
```

The ground is painted before `draw` runs, and what the controls
damaged is committed after it; keys and text a program does not
intercept reach the controls on their own.

A control is a call that both draws and answers: `ctx.button` returns
whether it was pressed this pass, so there is no separate event
handler to keep in step with the drawing. State that must outlive a
pass lives in the caller, and the context keeps only what it needs to
know whether a control has to be repainted.

A program that paints by hand rather than through controls has to
say what it painted: `ctx.addDamage(rect)`. Controls do it for
themselves, and a window that draws its own pixels and reports
nothing is a window the manager never puts on the screen.

Nothing repaints unless it changed. `ctx.damaged` is true when the
whole window has to be redrawn; otherwise each control decides for
itself, and `ctx.damageList()` is the set of rectangles the manager is
asked to put on the screen. A program that filled its background every
pass would flicker on hardware, which is why the fill above is inside
the test.

## Where a control belongs

In the toolkit, if two programs could want it. An applet that draws
its own slider has made a second slider that will drift from this one.
Geometry is pure and tested on the host; painting is the part that
needs a screen, and it is kept thin enough to be checked by looking.

## Controls

Each takes the rectangle it occupies and returns what the person did
with it this pass.

| call | signature |
|---|---|
| `button` | `fn (*widget.Context, draw.Rect, []const u8) bool` |
| `buttonAs` | `fn (*widget.Context, draw.Rect, []const u8, widget.Emphasis) bool` |
| `choice` | `fn (*widget.Context, draw.Rect, anytype) anytype` |
| `choiceOf` | `fn (*widget.Context, draw.Rect, anytype, []const []const u8) anytype` |
| `choiceAmong` | `fn (*widget.Context, draw.Rect, anytype, anytype, []const []const u8) anytype` |
| `slider` | `fn (*widget.Context, draw.Rect, slider.Range, i32, Context.SliderStyle) i32` |
| `toggle` | `fn (*widget.Context, draw.Rect, []const u8, bool) bool` |
| `segment` | `fn (*widget.Context, draw.Rect, []const u8, bool, widget.Seat) bool` |
| `onOff` | `fn (*widget.Context, draw.Rect, bool) bool` |
| `checkbox` | `fn (*widget.Context, draw.Rect, []const u8, bool) bool` |
| `scrollbar` | `fn (*widget.Context, draw.Rect, *scroll.State, usize, usize, usize) usize` |
| `table` | `fn (*widget.Context, draw.Rect, *table.State, []const table.Column, []const table.Row) ?usize` |
| `sampleHeight` | `fn () i32` |
| `samplesWidth` | `fn (*const widget.Context, usize) i32` |
| `samples` | `fn (*widget.Context, draw.Rect, Context.Sample, usize) usize` |
| `swatches` | `fn (*widget.Context, draw.Rect, []const u32, usize) usize` |
| `rail` | `fn (*widget.Context, draw.Rect, []const rail.Item, usize, []const u8) usize` |
| `footer` | `fn (*widget.Context, draw.Rect, []const u8, []const []const u8, usize) ?usize` |
| `row` | `fn (*widget.Context, draw.Rect, rail.Item, bool) bool` |
| `fieldRow` | `fn (*widget.Context, draw.Rect, []const u8, anytype) bool` |
| `label` | `fn (*widget.Context, draw.Rect, []const u8) void` |
| `labelDim` | `fn (*widget.Context, draw.Rect, []const u8) void` |
| `labelIn` | `fn (*widget.Context, draw.Rect, []const u8, u32) void` |
| `rowText` | `fn (*widget.Context, draw.Rect, []const u8, u32) void` |
| `pips` | `fn (*widget.Context, draw.Rect, usize, usize) usize` |
| `stepper` | `fn (*widget.Context, draw.Rect, slider.Range, i32) i32` |
| `progress` | `fn (*widget.Context, draw.Rect, u8, Context.ProgressStyle) void` |

## The pass

What a program calls around its controls, once each way.

| call | signature |
|---|---|
| `init` | `fn (draw.Surface) widget.Context` |
| `initOn` | `fn (draw.Surface, Context.Ground) widget.Context` |
| `begin` | `fn (*widget.Context, i32, i32, syscalls.Buttons) void` |
| `bounds` | `fn (*const widget.Context) draw.Rect` |
| `postKey` | `fn (*widget.Context, u8, syscalls.Modifiers) void` |
| `postScroll` | `fn (*widget.Context, i8) void` |
| `postText` | `fn (*widget.Context, u32) void` |
| `damageList` | `fn (*const widget.Context) []const draw.Rect` |
| `end` | `fn (*widget.Context) void` |
| `damage` | `fn (*widget.Context) void` |
| `again` | `fn (*widget.Context) void` |
| `wantsPass` | `fn (*const widget.Context) bool` |
| `damageNow` | `fn (*widget.Context) void` |
| `pressedThisPass` | `fn (*const widget.Context) bool` |
| `releasedThisPass` | `fn (*const widget.Context) bool` |
| `rightPressedThisPass` | `fn (*const widget.Context) bool` |

## For control authors

What a new control is built out of: a slot that remembers what it
looked like last pass, the pointer's business with it, and whether
that means it has to be painted again.

| call | signature |
|---|---|
| `addDamage` | `fn (*widget.Context, draw.Rect) void` |
| `takeWheel` | `fn (*widget.Context) i8` |
| `takeTextFor` | `fn (*widget.Context, *const widget.Entry) ?u32` |
| `slotFor` | `fn (*widget.Context, draw.Rect) ?*widget.Entry` |
| `indexOf` | `fn (*const widget.Context, *const widget.Entry) usize` |
| `takeKeyFor` | `fn (*widget.Context, *const widget.Entry) ?u8` |
| `focusAt` | `fn (*widget.Context, draw.Rect) void` |
| `interact` | `fn (*widget.Context, *widget.Entry, draw.Rect) Context.Interaction` |
| `activatedByKey` | `fn (*widget.Context, *const widget.Entry) bool` |
| `needsPaint` | `fn (*const widget.Context, *const widget.Entry, widget.Visual) bool` |

### What a control paints with

Every control is handed a `draw.Surface` and a rectangle, and these
are all it may do to the one inside the other. Listed from the
surface itself, so a primitive added to the toolkit is a primitive
this guide offers rather than one an author has to find by reading
another control.

| call | signature |
|---|---|
| `init` | `fn ([*]u32, i32, i32, i32) draw.Surface` |
| `clipped` | `fn (draw.Surface, draw.Rect) draw.Surface` |
| `set` | `fn (draw.Surface, i32, i32, u32) void` |
| `get` | `fn (draw.Surface, i32, i32) u32` |
| `fillRounded` | `fn (draw.Surface, draw.Rect, i32, draw.Corners, u32) void` |
| `frameRounded` | `fn (draw.Surface, draw.Rect, i32, draw.Corners, u32) void` |
| `fillAround` | `fn (draw.Surface, draw.Rect, draw.Rect, u32) void` |
| `fill` | `fn (draw.Surface, draw.Rect, u32) void` |
| `copyFrom` | `fn (draw.Surface, draw.Surface, i32, i32, draw.Rect) void` |
| `frame` | `fn (draw.Surface, draw.Rect, u32) void` |
| `borderInset` | `fn (draw.Surface, draw.Rect, i32, u32) void` |
| `glyph` | `fn (draw.Surface, i32, i32, u21, u32) void` |
| `glyphIn` | `fn (draw.Surface, *const font.Font, i32, i32, u21, u32) void` |
| `picture` | `fn (draw.Surface, i32, i32, *const [24]u8, u32) void` |
| `icon` | `fn (draw.Surface, i32, i32, icon.Icon, u32) void` |
| `iconLarge` | `fn (draw.Surface, i32, i32, icon.Icon, u32, i32) void` |
| `iconLargeSize` | `fn (i32) i32` |
| `iconTopFor` | `fn (i32) i32` |
| `iconSize` | `fn () i32` |
| `bitmap` | `fn (draw.Surface, i32, i32, []const u8, usize, usize, usize, u32) void` |
| `bitmapAt` | `fn (draw.Surface, i32, i32, []const u8, usize, usize, usize, u32, i32) void` |
| `text` | `fn (draw.Surface, i32, i32, []const u8, u32) void` |
| `textIn` | `fn (draw.Surface, *const font.Font, i32, i32, []const u8, u32) void` |
| `title` | `fn (draw.Surface, i32, i32, []const u8, u32) void` |
| `titleWidth` | `fn ([]const u8) i32` |
| `titleHeight` | `fn () i32` |
| `besideTitle` | `fn (i32) i32` |
| `textFitted` | `fn (draw.Surface, i32, i32, i32, []const u8, u32) void` |
| `textWidth` | `fn ([]const u8) i32` |
| `textHeight` | `fn () i32` |
| `textCentred` | `fn (draw.Surface, draw.Rect, []const u8, u32) void` |

## Parts

Geometry lives apart from painting, so where a thing goes can be
tested without drawing it.

### `eui.chooser`

Choosing a file: the panel, not the window.

| call | signature |
|---|---|
| `run` | `fn (*widget.Context, draw.Rect, *chooser.Chooser, []const u8, []const chooser.Entry) chooser.Outcome` |

### `eui.context_menu`

The menu the other mouse button opens.

| call | signature |
|---|---|
| `isOpen` | `fn () bool` |
| `openedBy` | `fn (usize) bool` |
| `open` | `fn (*widget.Context, usize, []const widget.MenuItem) void` |
| `openAt` | `fn (i32, i32, usize, []const widget.MenuItem) void` |
| `close` | `fn () void` |
| `area` | `fn (draw.Surface) draw.Rect` |
| `run` | `fn (*widget.Context) ?usize` |

### `eui.menubar`

A menu bar: named menus along a strip, each dropping a list of commands.

| call | signature |
|---|---|
| `run` | `fn (*widget.Context, draw.Rect, *menubar.State, []const menubar.Menu) ?u16` |
| `key` | `fn (*menubar.State, syscalls.KeyCode, syscalls.Modifiers, []const menubar.Menu) menubar.KeyResult` |
| `altKey` | `fn (*menubar.State, u21, []const menubar.Menu) bool` |
| `focus` | `fn (*menubar.State, []const menubar.Menu) void` |
| `isOpen` | `fn (*const menubar.State) bool` |

### `eui.scroll`

Scrollbars.

| call | signature |
|---|---|
| `vertical` | `fn (*widget.Context, draw.Rect, *scroll.State, usize, usize, usize) usize` |

Numbers it owns:

- `WIDTH` = 9

### `eui.scrollpane`

A pane that scrolls when what is in it does not fit.

| call | signature |
|---|---|
| `begin` | `fn (*widget.Context, draw.Rect, *scrollpane.State) scrollpane.View` |
| `end` | `fn (*widget.Context, *scrollpane.State, scrollpane.View, i32) void` |

### `eui.statusbar`

The strip along the bottom of a window.

| call | signature |
|---|---|
| `height` | `fn () i32` |
| `run` | `fn (*widget.Context, draw.Rect, []const statusbar.Panel) void` |

### `eui.table`

A scrolling table of rows.

| call | signature |
|---|---|
| `rowHeight` | `fn () i32` |
| `run` | `fn (*widget.Context, draw.Rect, *table.State, []const table.Column, []const table.Row) ?usize` |
| `rowRect` | `fn (draw.Rect, *const table.State, usize, usize) ?draw.Rect` |

### `eui.text`

Editable text: a buffer, the lines it breaks into, and a control that edits it.

| call | signature |
|---|---|
| `sequenceLength` | `fn (u8) usize` |
| `lines` | `fn ([]const u8, *const font.Font, i32) text.Lines` |
| `count` | `fn ([]const u8, *const font.Font, i32) usize` |
| `positionOf` | `fn ([]const u8, *const font.Font, i32, usize) text.Position` |
| `lineAt` | `fn ([]const u8, *const font.Font, i32, usize) text.Line` |
| `offsetAt` | `fn ([]const u8, *const font.Font, text.Line, i32) usize` |
| `placeOf` | `fn ([]const u8, usize) text.Place` |
| `lineCount` | `fn ([]const u8) usize` |
| `inner` | `fn (draw.Rect) draw.Rect` |
| `rowsIn` | `fn (draw.Rect) usize` |
| `shown` | `fn (*const text.Editor, *const text.Buffer, *[128]u8) []const u8` |
| `edit` | `fn (*widget.Context, draw.Rect, *text.Editor, *text.Buffer) void` |
| `run` | `fn (*text.Editor, *text.Buffer, text.Command, widget.Clipboard) bool` |
| `paragraph` | `fn (draw.Surface, draw.Rect, []const u8, u32) i32` |
| `Field` | `fn (usize) type` |
| `field` | `fn (*widget.Context, draw.Rect, *text.Editor, *text.Buffer) bool` |

### `eui.keys`

The keys, named, along the bottom of a window.

| call | signature |
|---|---|
| `width` | `fn (keys.Key, keys.Style) i32` |
| `place` | `fn (draw.Rect, i32, []const keys.Key, keys.Style, []keys.Placed) []keys.Placed` |
| `placeRight` | `fn (draw.Rect, []const keys.Key, keys.Style, []keys.Placed) []keys.Placed` |
| `bar` | `fn (draw.Surface, draw.Rect, []const keys.Key, []const u8) void` |
| `paint` | `fn (draw.Surface, draw.Rect, []const keys.Key, i32, keys.Style) i32` |
| `drawPlaced` | `fn (draw.Surface, []const keys.Placed, draw.Rect, keys.Style, u32) void` |

### `eui.meter`

A level that is read rather than set.

| call | signature |
|---|---|
| `clamp` | `fn (u8) u8` |
| `fill` | `fn (draw.Rect, u8) draw.Rect` |
| `peak` | `fn (draw.Rect, u8) draw.Rect` |
| `limit` | `fn (draw.Rect) draw.Rect` |
| `over` | `fn (u8) bool` |

Numbers it owns:

- `HEIGHT` = 7
- `LIMIT` = 90
- `PEAK_WIDTH` = 2
- `LIMIT_OVERHANG` = 2

### `eui.footer`

The strip along the bottom of a window: what just happened on the left, what to do about it on the right.

| call | signature |
|---|---|
| `height` | `fn () i32` |
| `strip` | `fn (draw.Rect) draw.Rect` |
| `above` | `fn (draw.Rect) draw.Rect` |
| `buttonWidth` | `fn ([]const u8) i32` |
| `place` | `fn (draw.Rect, []const []const u8, []draw.Rect) []draw.Rect` |
| `messageRect` | `fn (draw.Rect, []const draw.Rect) draw.Rect` |

Numbers it owns:

- `BUTTON_PADDING` = 14

### `eui.gauge`

A reading with a proportion to it: what it is, what it says, how full it is, and what that means.

| call | signature |
|---|---|
| `alarming` | `fn (u8, gauge.Alarm) bool` |
| `inkFor` | `fn (u8, gauge.Alarm) u32` |
| `height` | `fn () i32` |
| `cellRect` | `fn (draw.Rect, usize, usize) draw.Rect` |
| `barRect` | `fn (draw.Rect) draw.Rect` |
| `paint` | `fn (draw.Surface, draw.Rect, []const gauge.Reading) void` |

Numbers it owns:

- `FULL` = 90
- `EMPTY` = 10
- `BAR_HEIGHT` = 8

### `eui.chrome`

What a window is made of: a strip along the top, a strip along the bottom, and the work between them.

| call | signature |
|---|---|
| `split` | `fn (draw.Rect, chrome.Wants) chrome.Layout` |

### `eui.facts`

A label and what it says, in two columns.

| call | signature |
|---|---|
| `column` | `fn (draw.Rect) i32` |
| `height` | `fn () i32` |
| `heightIn` | `fn (draw.Rect) i32` |
| `one` | `fn (*widget.Context, draw.Rect, i32, []const u8, []const u8) i32` |
| `columnFor` | `fn (draw.Rect, []const facts.Fact) i32` |
| `oneWith` | `fn (*widget.Context, draw.Rect, i32, []const u8, []const u8, i32) i32` |
| `all` | `fn (*widget.Context, draw.Rect, i32, []const facts.Fact) i32` |

### `eui.figure`

A figure with its name: one number, large, on a tile with a dim label above it.

| call | signature |
|---|---|
| `height` | `fn () i32` |
| `figureRect` | `fn (draw.Rect) draw.Rect` |
| `paint` | `fn (draw.Surface, draw.Rect, []const u8, []const u8, ?*const [24]u8) void` |

### `eui.grid`

Equal cells in a rectangle.

### `eui.heading`

A section's title inside a pane.

| call | signature |
|---|---|
| `height` | `fn () i32` |
| `paint` | `fn (draw.Surface, draw.Rect, []const u8, ?*const [24]u8) void` |

### `eui.pips`

A tally: n of m, as a row of pips.

| call | signature |
|---|---|
| `size` | `fn () i32` |
| `gap` | `fn () i32` |
| `width` | `fn (usize) i32` |
| `cell` | `fn (draw.Rect, usize) draw.Rect` |
| `at` | `fn (draw.Rect, usize, i32, i32) ?usize` |
| `pressed` | `fn (usize, usize) usize` |

Numbers it owns:

- `SIZE` = 10
- `GAP` = 4

### `eui.popover`

Where a panel anchored to something goes.

| call | signature |
|---|---|
| `place` | `fn (draw.Rect, i32, i32, draw.Rect, popover.Side) draw.Rect` |

Numbers it owns:

- `INSET` = 6

### `eui.prompt`

A question across the bottom of a window, with the ways to answer it.

| call | signature |
|---|---|
| `sheet` | `fn (draw.Rect) draw.Rect` |
| `above` | `fn (draw.Rect) draw.Rect` |
| `run` | `fn (*widget.Context, draw.Rect, *prompt.Prompt) ?usize` |
| `key` | `fn (*prompt.Prompt, syscalls.KeyCode) ?usize` |
| `letter` | `fn (*const prompt.Prompt, u32) ?usize` |

### `eui.rail`

The column of sections down the side of a window.

| call | signature |
|---|---|
| `indentOf` | `fn (u2) i32` |
| `badge` | `fn (draw.Rect, u16) ?draw.Rect` |
| `spellCount` | `fn (u16, *[4]u8) []const u8` |
| `marked` | `fn ([]const rail.Item) bool` |
| `width` | `fn () i32` |
| `rowHeight` | `fn () i32` |
| `column` | `fn (draw.Rect, i32) draw.Rect` |
| `beside` | `fn (draw.Rect, draw.Rect) draw.Rect` |
| `rowRect` | `fn (draw.Rect, usize) draw.Rect` |
| `rowAt` | `fn (draw.Rect, usize, i32, i32) ?usize` |
| `footer` | `fn (draw.Rect) draw.Rect` |

Numbers it owns:

- `INDENT` = 10
- `WIDTH` = 124
- `ROW_HEIGHT` = 26

### `eui.region`

What is left of an area once other rectangles are taken out of it.

### `eui.row`

A row of fixed-width cells, laid out from one end.

| call | signature |
|---|---|
| `place` | `fn (draw.Rect, row.Side, []const i32, []draw.Rect) []draw.Rect` |
| `at` | `fn ([]const draw.Rect, i32, i32) ?usize` |
| `extent` | `fn ([]const draw.Rect) draw.Rect` |

### `eui.slider`

Where a slider's parts are, and what a position along it means.

| call | signature |
|---|---|
| `track` | `fn (draw.Rect) draw.Rect` |
| `knob` | `fn (draw.Rect, slider.Range, i32) draw.Rect` |
| `filled` | `fn (draw.Rect, slider.Range, i32) draw.Rect` |
| `valueAt` | `fn (draw.Rect, slider.Range, i32) i32` |
| `step` | `fn (slider.Range) i32` |

Numbers it owns:

- `TRACK_HEIGHT` = 6
- `KNOB_WIDTH` = 9

### `eui.stepper`

An exact number with a step down and a step up.

| call | signature |
|---|---|
| `parts` | `fn (draw.Rect) stepper.Parts` |
| `width` | `fn (i32) i32` |

Numbers it owns:

- `VALUE_WIDTH` = 40

### `eui.strip`

A control strip: a picture you can press, a slider, and the number it is at.

| call | signature |
|---|---|
| `height` | `fn () i32` |
| `of` | `fn (draw.Rect) draw.Rect` |
| `below` | `fn (draw.Rect) draw.Rect` |
| `button` | `fn (draw.Rect) draw.Rect` |
| `track` | `fn (draw.Rect, []const u8) draw.Rect` |
| `reading` | `fn (draw.Rect, []const u8) draw.Rect` |

### `eui.thumb`

A picture, shrunk to fit and stood the right way up.

| call | signature |
|---|---|
| `uprightSize` | `fn (u16, u16, exif.Orientation) thumb.Size` |
| `fitAs` | `fn (draw.Rect, u16, u16, thumb.Scale) draw.Rect` |
| `fit` | `fn (draw.Rect, u16, u16) draw.Rect` |
| `paint` | `fn (draw.Surface, draw.Rect, thumb.Source, exif.Orientation) void` |
| `sampleAt` | `fn (u32, u32, u16, u16, exif.Orientation) thumb.Point` |

## Pictures

Twelve by twelve, one bit deep, drawn through the same blitter as a
letter and in the ink the caller passes. Drawn here as they are drawn
on the screen.

```
wifi
                          
                          
                    ####  
                    ####  
              ####  ####  
              ####  ####  
              ####  ####  
        ####  ####  ####  
        ####  ####  ####  
  ####  ####  ####  ####  
  ####  ####  ####  ####  
                          

wifi_good
                          
                          
                          
                          
              ####  ####  
              ####  ####  
              ####  ####  
        ####  ####  ####  
        ####  ####  ####  
  ####  ####  ####  ####  
  ####  ####  ####  ####  
                          

wifi_fair
                          
                          
                          
                          
                          
                          
                          
        ####  ####        
        ####  ####        
  ####  ####  ####        
  ####  ####  ####        
                          

wifi_weak
                          
                          
                          
                          
                          
                          
                          
                          
                          
  ####                    
  ####                    
                          

ethernet
                          
        ############      
        ##        ##      
        ############      
              ##          
      ##########          
      ##      ##          
      ##      ##          
    ######  ######        
    ##  ##  ##  ##        
    ######  ######        
                          

speaker
                          
                          
            ####          
          ######    ##    
      ##########  ##  ##  
      ##########  ##  ##  
      ##########  ##  ##  
      ##########  ##  ##  
          ######    ##    
            ####          
                          
                          

speaker_low
                          
                          
            ####          
          ######          
      ##########    ##    
      ##########  ##      
      ##########  ##      
      ##########    ##    
          ######          
            ####          
                          
                          

muted
                          
                          
            ####          
          ######          
      ##########  ##    ##
      ##########    ####  
      ##########    ####  
      ##########  ##    ##
          ######          
            ####          
                          
                          

battery
                          
                          
                          
    ##################    
    ##              ##    
    ##              ######
    ##              ######
    ##              ##    
    ##################    
                          
                          
                          

terminal
                          
  ####################    
  ##                ##    
  ##  ####          ##    
  ##      ####      ##    
  ##  ####          ##    
  ##                ##    
  ##    ########    ##    
  ##                ##    
  ####################    
                          
                          

document
                          
      ############        
      ##        ####      
      ##        ######    
      ##            ##    
      ##  ########  ##    
      ##            ##    
      ##  ########  ##    
      ##            ##    
      ################    
                          
                          

picture
                          
                          
      ################    
      ##            ##    
      ##  ####      ##    
      ##            ##    
      ##            ##    
      ##      ####  ##    
      ##    ##########    
      ################    
                          
                          

folder
                          
                          
      ######              
      ##    ##            
      ##################  
      ##              ##  
      ##              ##  
      ##              ##  
      ##################  
                          
                          
                          

chart
                          
                          
                          
    ####            ####  
    ####            ####  
    ####    ####    ####  
    ####    ####    ####  
    ####    ####    ####  
    ####    ####    ####  
                          
                          
                          

calculator
                          
                          
    ####################  
    ##                ##  
    ##  ############  ##  
    ##                ##  
    ##  ####    ####  ##  
    ##                ##  
    ##  ####    ####  ##  
    ##                ##  
    ####################  
                          

sliders
                          
          ####            
    ####################  
          ####            
                          
                  ####    
    ####################  
                  ####    
                          
      ####                
    ####################  
      ####                

power
                          
                          
            ####          
      ##    ####    ##    
    ##      ####      ##  
  ##        ####        ##
  ##                    ##
  ##                    ##
    ##                ##  
      ################    
                          
                          

check
                          
                          
                      ##  
                    ####  
  ##              ####    
  ####          ####      
    ####      ####        
      ####  ####          
        ######            
          ##              
                          
                          

maximised
                          
                          
    ####################  
    ##                ##  
    ##  ############  ##  
    ##  ############  ##  
    ##  ############  ##  
    ##  ############  ##  
    ##                ##  
    ####################  
                          
                          

display
                          
  ########################
  ##                    ##
  ##                    ##
  ##                    ##
  ##                    ##
  ##                    ##
  ########################
          ########        
          ########        
      ################    
                          

keyboard
                          
                          
  ########################
  ##  ##  ##  ##  ##    ##
  ##                    ##
  ##  ##  ##  ##  ##    ##
  ##                    ##
  ##    ############    ##
  ##                    ##
  ########################
                          
                          

about
                          
      ################    
    ####            ####  
  ####      ####      ####
  ####      ####      ####
  ####                ####
  ####      ####      ####
  ####      ####      ####
  ####      ####      ####
    ####            ####  
      ################    
                          

help
                          
        ############      
      ####        ####    
    ####            ####  
                    ####  
                  ####    
            ########      
            ####          
            ####          
                          
            ####          
            ####          

search
      ##########          
    ####      ####        
  ####          ####      
  ##              ##      
  ##              ##      
  ##              ##      
  ####          ####      
    ####      ####        
      ##########  ####    
                ####  ####
                      ####
                        ##

exit
                          
  ########                
  ##                      
  ##              ##      
  ##                ##    
  ##        ############  
  ##        ############  
  ##                ##    
  ##              ##      
  ##                      
  ########                
                          

apps
                          
    ########    ########  
    ########    ########  
    ########    ########  
    ########    ########  
                          
    ########    ########  
    ########    ########  
    ########    ########  
    ########    ########  
                          
                          

logo
                          
                          
              ########    
            ####    ####  
          ####        ####
        ################  
        ####              
      ####                
      ####          ####  
      ####        ####    
        ##########        
                          

battery_charging
                          
                          
                          
    ##################    
    ##        ####  ##    
    ##      ######  ######
    ##    ######    ######
    ##      ####    ##    
    ##################    
                          
                          
                          

battery_critical
                          
                          
                          
    ##################    
    ##      ####    ##    
    ##      ####    ######
    ##              ######
    ##      ####    ##    
    ##################    
                          
                          
                          

clock
                          
        ############      
      ####        ####    
    ####    ####    ####  
  ####      ####      ####
  ####      ####      ####
  ####      ##########  ##
  ####                ####
  ####                ####
    ####            ####  
      ####        ####    
        ############      

cut
    ####              ####
    ####              ####
      ####          ####  
        ####      ####    
          ####  ####      
            ######        
          ####  ####      
        ####      ####    
      ######      ######  
      ##  ##      ##  ##  
      ######      ######  
                          

copy
                          
    ############          
    ##        ##          
    ##    ############    
    ##    ##        ##    
    ########        ##    
          ##        ##    
          ##        ##    
          ##        ##    
          ############    
                          
                          

paste
          ########        
        ##        ##      
    ####################  
    ##                ##  
    ##                ##  
    ##                ##  
    ##                ##  
    ##                ##  
    ##                ##  
    ##                ##  
    ####################  
                          

select_all
                          
    ####################  
    ##                ##  
    ##  ############  ##  
    ##  ############  ##  
    ##  ############  ##  
    ##  ############  ##  
    ##  ############  ##  
    ##                ##  
    ####################  
                          
                          

sort_up
                          
                          
                          
            ####          
          ########        
        ####    ####      
      ####        ####    
    ####            ####  
                          
                          
                          
                          

sort_down
                          
                          
                          
    ####            ####  
      ####        ####    
        ####    ####      
          ########        
            ####          
                          
                          
                          
                          

```

## Themes

One value holds every colour and every measurement, so a control that
reads the theme is a control that follows the interface's size without
knowing that it does. Metrics are given at a hundred per cent; the
interface scale multiplies them.
| element | slate | classic | paper | dusk |
|---|---|---|---|---|
| `desktop` | `#2B3138` | `#5C6670` | `#707070` | `#1B1F24` |
| `surface` | `#E9EAEC` | `#D6D3CE` | `#F0F0EC` | `#2A2E35` |
| `surface_hot` | `#F5F6F7` | `#E4E2DE` | `#FFFFFC` | `#363B44` |
| `surface_pressed` | `#D8DADD` | `#B8B5B0` | `#D0D0CC` | `#1F2229` |
| `text` | `#1A1D21` | `#14140F` | `#000000` | `#D8DBE0` |
| `text_dim` | `#5C636B` | `#5A5A54` | `#4A4A44` | `#8A9099` |
| `text_inverted` | `#F7F8F9` | `#F4F4F0` | `#FFFFFF` | `#14171B` |
| `accent` | `#2F6FE0` | `#2864A4` | `#1A4E8C` | `#3A78BE` |
| `accent_text` | `#FFFFFF` | `#FFFFFF` | `#FFFFFF` | `#F4F8FC` |
| `line` | `#C6C9CD` | `#A8A498` | `#808078` | `#424852` |
| `border` | `#C6C9CD` | `#A8A498` | `#808078` | `#424852` |
| `border_focused` | `#2F6FE0` | `#2864A4` | `#1A4E8C` | `#3A78BE` |
| `bar` | `#1F242A` | `#C8C5C0` | `#E0E0DC` | `#14171B` |
| `bar_text` | `#D6D9DD` | `#14140F` | `#000000` | `#C8CCD2` |
| `bar_line` | `#10141A` | `#8C8880` | `#707068` | `#2A2E35` |
| `terminal_ground` | `#141414` | `#141414` | `#141414` | `#141414` |
| `terminal_ink` | `#D8D8D8` | `#D8D8D8` | `#D8D8D8` | `#D8D8D8` |
| `warning` | `#B33A2B` | `#A02820` | `#901810` | `#C05050` |

| metric | value |
|---|---|
| `bar_height` | 22 |
| `control_height` | 24 |
| `padding` | 6 |
| `menu_row_height` | 22 |
| `menu_padding` | 10 |
| `gap` | 8 |
| `border_width` | 1 |
| `border_width_focused` | 2 |
| `corner_radius` | 4 |

