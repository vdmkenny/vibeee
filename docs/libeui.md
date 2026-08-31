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
| `choice` | `fn (*widget.Context, draw.Rect, anytype) anytype` |
| `choiceOf` | `fn (*widget.Context, draw.Rect, anytype, []const []const u8) anytype` |
| `slider` | `fn (*widget.Context, draw.Rect, slider.Range, i32, Context.SliderStyle) i32` |
| `toggle` | `fn (*widget.Context, draw.Rect, []const u8, bool) bool` |
| `checkbox` | `fn (*widget.Context, draw.Rect, []const u8, bool) bool` |
| `scrollbar` | `fn (*widget.Context, draw.Rect, *scroll.State, usize, usize, usize) usize` |
| `table` | `fn (*widget.Context, draw.Rect, *table.State, []const table.Column, []const table.Row) ?usize` |
| `sampleHeight` | `fn () i32` |
| `samples` | `fn (*widget.Context, draw.Rect, Context.Sample, usize) usize` |
| `swatches` | `fn (*widget.Context, draw.Rect, []const u32, usize) usize` |
| `rail` | `fn (*widget.Context, draw.Rect, []const rail.Item, usize, []const u8) usize` |
| `footer` | `fn (*widget.Context, draw.Rect, []const u8, []const []const u8, usize) ?usize` |
| `label` | `fn (*widget.Context, draw.Rect, []const u8) void` |
| `labelDim` | `fn (*widget.Context, draw.Rect, []const u8) void` |
| `labelIn` | `fn (*widget.Context, draw.Rect, []const u8, u32) void` |
| `progress` | `fn (*widget.Context, draw.Rect, u8) void` |

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
| `damageNow` | `fn (*widget.Context) void` |
| `pressedThisPass` | `fn (*const widget.Context) bool` |
| `releasedThisPass` | `fn (*const widget.Context) bool` |

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

## Parts

Geometry lives apart from painting, so where a thing goes can be
tested without drawing it.

### `eui.rail`

The column of sections down the side of a window.

| call | signature |
|---|---|
| `marked` | `fn ([]const rail.Item) bool` |
| `width` | `fn () i32` |
| `rowHeight` | `fn () i32` |
| `column` | `fn (draw.Rect, i32) draw.Rect` |
| `beside` | `fn (draw.Rect, draw.Rect) draw.Rect` |
| `rowRect` | `fn (draw.Rect, usize) draw.Rect` |
| `rowAt` | `fn (draw.Rect, usize, i32, i32) ?usize` |
| `footer` | `fn (draw.Rect) draw.Rect` |

Numbers it owns:

- `WIDTH` = 124
- `ROW_HEIGHT` = 26

### `eui.footer`

The strip along its bottom: a message and the buttons.

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

### `eui.row`

Fixed cells packed against one end, dropping what will not fit.

| call | signature |
|---|---|
| `place` | `fn (draw.Rect, row.Side, []const i32, []draw.Rect) []draw.Rect` |
| `at` | `fn ([]const draw.Rect, i32, i32) ?usize` |
| `extent` | `fn ([]const draw.Rect) draw.Rect` |

### `eui.slider`

A value you drag, and where its parts land.

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

### `eui.meter`

A level you read, with a peak that trails it.

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

### `eui.popover`

A panel beside the thing that opened it, kept on screen.

| call | signature |
|---|---|
| `place` | `fn (draw.Rect, i32, i32, draw.Rect, popover.Side) draw.Rect` |

Numbers it owns:

- `INSET` = 6

### `eui.region`

What is left of a rectangle once others cover it.

### `eui.scroll`

How far down a list is, and the bar that says so.

| call | signature |
|---|---|
| `vertical` | `fn (*widget.Context, draw.Rect, *scroll.State, usize, usize, usize) usize` |

Numbers it owns:

- `WIDTH` = 9

### `eui.table`

Columns, and which one a press landed in.

| call | signature |
|---|---|
| `rowHeight` | `fn () i32` |
| `run` | `fn (*widget.Context, draw.Rect, *table.State, []const table.Column, []const table.Row) ?usize` |

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
| `terminal_ground` | `#14140F` | `#14140F` | `#14140F` | `#14140F` |
| `terminal_ink` | `#D8D8D0` | `#D8D8D0` | `#D8D8D0` | `#D8D8D0` |
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

