# Tasqer

## Build

You need the [Odin](https://github.com/odin-lang/Odin) compiler installed. [Nushell](https://github.com/nushell/nushell) is required to use the install scripts. [Neovim](https://github.com/neovim/neovim) is required at to run as a plugin.
To build an executable, use `nu build.nu` or just `odin build .`.
To install it into the system, run `nu build.nu install`. This will also create file associations for the `openfile` command.

## Neovim installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)
```lua
return {
  'qxuken/tasqer',
  config = function()
    local tasqer = require 'tasqer'
    tasqer.setup({
        log_level = 3, -- Just info and warns with errors
        host = "127.0.0.1", -- Keep it local, security model is not very robust, so it will be better to not bind it 0.0.0.0
        port = 48391, -- Do not change this unless you have to. You will need to change the standalone executable port too
        log = function(level, message) end -- in case your logger does some stupid sorting thing
    })
    tasqer.setup_wezterm_tasks()
    tasqer.start()
  end,
}
```

## What

A small tool to run a cluster of task runners on a single machine.

## Why

I wanted to open files inside Neovim from the outside world, even on a Windows+WSL combo.

## How

It uses a leader-follower communication algorithm, with an issuer as a special case of follower. The process binds to a predefined UDP port and listens for requests (e.g. `openfile`). The leader and then the followers check whether they can handle the request. The leader picks the first capable node, falling back to the next one on failure, and so on. If the entire cluster fails, the issuer executes its own logic -- for example, spawning a terminal tab with Neovim and passing it the file.

