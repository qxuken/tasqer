# Tasqer dependencies

## Why

The dependencies match the Neovim stack, since the project is designed so that its Lua logic is compatible with the Neovim runtime.

## How I build them

Clone the [luv](https://github.com/luvit/luv) library and build it using the CMake recipe. Then fetch the build artifacts for libluajit, libuv, and libluv.

