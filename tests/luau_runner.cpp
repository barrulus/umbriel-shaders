// SPDX-License-Identifier: MIT
// Development-only runner for the plugin's scripts against a mocked host API.
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <iterator>
#include <lua.h>
#include <luacode.h>
#include <lualib.h>
int main(int argc, char **argv) {
    if (argc != 2)
        return 2;
    std::ifstream input(argv[1]);
    if (!input)
        return 2;
    const std::string source{std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
    auto *state = luaL_newstate();
    luaL_openlibs(state);
    size_t size = 0;
    char *bytecode = luau_compile(source.data(), source.size(), nullptr, &size);
    int result = luau_load(state, argv[1], bytecode, size, 0);
    std::free(bytecode);
    if (!result)
        result = lua_pcall(state, 0, 0, 0);
    if (result)
        std::cerr << lua_tostring(state, -1) << '\n';
    lua_close(state);
    return result ? 1 : 0;
}
