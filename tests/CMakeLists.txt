cmake_minimum_required(VERSION 3.20)
project(umbriel_shaders_tests LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(LUAU_SOURCE_DIR "" CACHE PATH "Luau source checkout (for example Noctalia's third_party/luau)")
if(NOT EXISTS "${LUAU_SOURCE_DIR}/VM/include/lua.h")
  message(FATAL_ERROR "Set LUAU_SOURCE_DIR or use an existing Luau CLI with tests/run.py")
endif()
file(GLOB LUAU_TEST_SOURCES CONFIGURE_DEPENDS
  "${LUAU_SOURCE_DIR}/VM/src/*.cpp" "${LUAU_SOURCE_DIR}/Ast/src/*.cpp"
  "${LUAU_SOURCE_DIR}/Compiler/src/*.cpp" "${LUAU_SOURCE_DIR}/Common/src/*.cpp"
  "${LUAU_SOURCE_DIR}/Bytecode/src/*.cpp")
add_library(luau-test-runtime STATIC ${LUAU_TEST_SOURCES})
target_include_directories(luau-test-runtime PUBLIC
  "${LUAU_SOURCE_DIR}/VM/include" "${LUAU_SOURCE_DIR}/Ast/include"
  "${LUAU_SOURCE_DIR}/Compiler/include" "${LUAU_SOURCE_DIR}/Common/include"
  "${LUAU_SOURCE_DIR}/Bytecode/include")
add_executable(luau-test-runner luau_runner.cpp)
target_link_libraries(luau-test-runner PRIVATE luau-test-runtime)
find_package(Python3 REQUIRED COMPONENTS Interpreter)
enable_testing()
add_test(NAME backend COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/run.py" $<TARGET_FILE:luau-test-runner>)
add_test(NAME ui COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/ui_workflows.py" $<TARGET_FILE:luau-test-runner>)
