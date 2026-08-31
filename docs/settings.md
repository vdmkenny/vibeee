# vibeee settings

<!-- Generated from src/user/proto/schema.zig by `zig build settings-docs`.
     Do not edit: change the schema instead. -->

Every key the system has, what it accepts, and what it is when nobody has
said otherwise. Keys are declared by the system, so a name it does not know
is an error rather than a new setting.

    cfg                       every domain and key
    cfg net                   one domain
    cfg set net.hostname pi   change one
    cfg reset net.hostname    put it back

Values are read from `/etc/<domain>.cfg` first and then from `/cfg` on top,
so an image ships with the first and a machine remembers the second.

## input

| key | accepts | default |
|---|---|---|
| `input.keymap` | us_intl \| be_azerty | `us_intl` |

## wm

| key | accepts | default |
|---|---|---|
| `wm.theme` | slate \| classic \| paper \| dusk | `slate` |
| `wm.bar` | top \| bottom | `top` |
| `wm.wallpaper` | #rrggbb; unset takes the theme's own | unset |
| `wm.master` | a number | `58` |

## net

| key | accepts | default |
|---|---|---|
| `net.hostname` | letters, digits and hyphens; unset takes vibeee-<address> | unset |
| `net.if0_match` | a class (ether, wifi), a driver name, a bus location, or unset | `ether` |
| `net.if0_enabled` | true \| false | `true` |
| `net.if0_address` | an address and prefix, a.b.c.d/nn; unset asks DHCP | unset |
| `net.if0_gateway` | an address, a.b.c.d; unset takes what the lease offers | unset |
| `net.if0_dns` | up to two addresses, comma separated | unset |
| `net.if0_ssid` | a network name, up to 32 characters | unset |
| `net.if0_psk` | a passphrase of 8 to 63 characters, or 64 hex digits | unset |
| `net.if0_regdomain` | conservative \| fcc \| etsi \| mkk \| unrestricted | `conservative` |
| `net.if0_txpower` | regulatory \| max \| a number of dBm | `regulatory` |
| `net.if1_match` | a class (ether, wifi), a driver name, a bus location, or unset | `wifi` |
| `net.if1_enabled` | true \| false | `false` |
| `net.if1_address` | an address and prefix, a.b.c.d/nn; unset asks DHCP | unset |
| `net.if1_gateway` | an address, a.b.c.d; unset takes what the lease offers | unset |
| `net.if1_dns` | up to two addresses, comma separated | unset |
| `net.if1_ssid` | a network name, up to 32 characters | unset |
| `net.if1_psk` | a passphrase of 8 to 63 characters, or 64 hex digits | unset |
| `net.if1_regdomain` | conservative \| fcc \| etsi \| mkk \| unrestricted | `conservative` |
| `net.if1_txpower` | regulatory \| max \| a number of dBm | `regulatory` |
| `net.if2_match` | a class (ether, wifi), a driver name, a bus location, or unset | unset |
| `net.if2_enabled` | true \| false | `false` |
| `net.if2_address` | an address and prefix, a.b.c.d/nn; unset asks DHCP | unset |
| `net.if2_gateway` | an address, a.b.c.d; unset takes what the lease offers | unset |
| `net.if2_dns` | up to two addresses, comma separated | unset |
| `net.if2_ssid` | a network name, up to 32 characters | unset |
| `net.if2_psk` | a passphrase of 8 to 63 characters, or 64 hex digits | unset |
| `net.if2_regdomain` | conservative \| fcc \| etsi \| mkk \| unrestricted | `conservative` |
| `net.if2_txpower` | regulatory \| max \| a number of dBm | `regulatory` |
| `net.if3_match` | a class (ether, wifi), a driver name, a bus location, or unset | unset |
| `net.if3_enabled` | true \| false | `false` |
| `net.if3_address` | an address and prefix, a.b.c.d/nn; unset asks DHCP | unset |
| `net.if3_gateway` | an address, a.b.c.d; unset takes what the lease offers | unset |
| `net.if3_dns` | up to two addresses, comma separated | unset |
| `net.if3_ssid` | a network name, up to 32 characters | unset |
| `net.if3_psk` | a passphrase of 8 to 63 characters, or 64 hex digits | unset |
| `net.if3_regdomain` | conservative \| fcc \| etsi \| mkk \| unrestricted | `conservative` |
| `net.if3_txpower` | regulatory \| max \| a number of dBm | `regulatory` |

