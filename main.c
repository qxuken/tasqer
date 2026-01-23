#include <stdio.h>

#include "include/luajit/lua.h"
#include "include/luajit/lualib.h"
#include "include/luajit/lauxlib.h"

int luaopen_luv(lua_State *L);

static void preload(lua_State *L, const char *name, lua_CFunction openf) {
  // package.preload[name] = openf
  lua_getglobal(L, "package");          // stack: package
  lua_getfield(L, -1, "preload");       // stack: package, package.preload
  lua_pushcfunction(L, openf);          // stack: package, preload, openf
  lua_setfield(L, -2, name);            // preload[name] = openf; stack: package, preload
  lua_pop(L, 2);                        // pop preload, package
}

int main(void) {
  lua_State *L = luaL_newstate();
  if (!L) return 1;

  luaL_openlibs(L);

  preload(L, "luv", luaopen_luv);

  if (luaL_dofile(L, "main.lua") != 0) {
    fprintf(stderr, "%s\n", lua_tostring(L, -1));
    lua_pop(L, 1);
    lua_close(L);
    return 1;
  }

  lua_close(L);
  return 0;
}
