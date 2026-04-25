# tn3270.nvim

A TN3270 terminal emulator for Neovim. Talk to mainframes (TSO/ISPF/REVEDIT)
from inside vim, with vim ergonomics.

## Features

- TN3270 over plain TCP, IBM-3278-3-E
- Color and highlighting (field-default + extended attributes)
- Mode-aware screen detection: TSO logon, password, READY, ISPF primary, REVEDIT
- Autologin (USERID + password)
- Mode-aware logoff: `:q` exits ISPF / REVEDIT, then LOGOFF, then closes
- REVEDIT ergonomics: `o`/`O` insert line, `dd` delete, `yy`/`pp` copy/paste,
  `gg`/`G` top/bottom, `:LINE N` jump, `A` append-end-of-content
- Password fields masked as `*`, captured chars sent on Enter
- IND$FILE transfer (`:TN3270Save` / `:TN3270Load`) ; structured-field path
  implemented; some hosts still pick legacy mode

## Install

```lua
vim.opt.runtimepath:prepend('~/path/to/tn3270.nvim')
```

## Setup

```lua
require('tn3270').setup({
    debug    = true,                                 -- log to log_file
    log_file = '/tmp/tn3270nvim.log',
    autologin = { userid = 'HERC01', password = '...' },
})
```

All options are optional. Defaults: `host=127.0.0.1`, `port=3270`,
`debug=false`, no autologin.

## Connecting

```
:TN3270                       " uses configured defaults
:TN3270 127.0.0.1 3271        " override host and port
```

If a connection is already open, `:TN3270` runs the mode-aware logoff first
and then connects to the new target.

## Keybindings

| Key            | Action                                       |
| -------------- | -------------------------------------------- |
| `<CR>`         | Send Enter (AID)                             |
| `<Tab>`        | Next unprotected field                       |
| `<S-Tab>`      | Previous unprotected field                   |
| `<leader>h`    | Home (first unprotected field)               |
| `<leader>pfN`  | Send PF1..PF24                               |
| `<PageUp>`     | PF7                                          |
| `<PageDown>`   | PF8                                          |
| `<leader>paN`  | Send PA1, PA2 (short read, bypass lock)      |
| `<leader>pcl`  | Send Clear                                   |
| `i` / `I`      | Enter Replace mode (3270 overtype)           |

## REVEDIT keys (active only on EDIT/VIEW/REVEDIT panels)

| Key         | Action                                |
| ----------- | ------------------------------------- |
| `o`         | Insert line below (`I` line command)  |
| `O`         | Insert line above                     |
| `dd`        | Delete line (`D`)                     |
| `yy` / `pp` | Copy/paste line (`C` + `A`, or `R`)   |
| `gg` / `G`  | Top / Bottom                          |
| `:LINE N`   | Jump to line N                        |
| `A`         | Append at end of trimmed line         |

## File transfer

From TSO READY:

```
:TN3270Save <dsname> <local-file>    " GET, mainframe -> local
:TN3270Load <local-file> <dsname>    " PUT, local -> mainframe
```

## Tests

```sh
brew install luarocks
luarocks install busted
busted
```
