cmake_minimum_required(VERSION 3.20)
project(umbriel_shaders_native VERSION 0.2.0 LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
include(CTest)
option(ENABLE_SANITIZERS "Enable address and undefined-behaviour sanitizers" OFF)
if(ENABLE_SANITIZERS)
  add_compile_options(-fsanitize=address,undefined -fno-omit-frame-pointer)
  add_link_options(-fsanitize=address,undefined)
endif()
find_package(nlohmann_json 3.11 REQUIRED)
find_package(tomlplusplus 3.4 REQUIRED)
find_package(OpenSSL REQUIRED COMPONENTS Crypto)
find_package(CURL 7.85 REQUIRED)
add_library(shader_core
  src/storage.cpp src/catalogue.cpp
  src/peer.cpp src/controller.cpp src/runtime.cpp src/selection.cpp
  src/source.cpp src/registry.cpp src/local.cpp src/diagnostics.cpp)
target_include_directories(shader_core PUBLIC src)
target_compile_definitions(shader_core PRIVATE _GNU_SOURCE)
target_compile_options(shader_core PRIVATE -Wall -Wextra -Wpedantic -Werror)
target_link_libraries(shader_core PUBLIC
  nlohmann_json::nlohmann_json tomlplusplus::tomlplusplus OpenSSL::Crypto CURL::libcurl)
add_executable(umbriel-shaders-native src/main.cpp)
target_link_libraries(umbriel-shaders-native PRIVATE shader_core)
set_target_properties(umbriel-shaders-native PROPERTIES INSTALL_RPATH_USE_LINK_PATH TRUE)
install(TARGETS umbriel-shaders-native RUNTIME DESTINATION bin)
install(DIRECTORY umbriel-shaders-native/
  DESTINATION share/noctalia/plugins/umbriel-shaders-native
  PATTERN "bin" EXCLUDE)
install(FILES catalog.toml DESTINATION share/noctalia/plugins)
if(BUILD_TESTING)
  find_package(Python3 COMPONENTS Interpreter REQUIRED)
  add_executable(native-tests tests/test.cpp)
  target_link_libraries(native-tests PRIVATE shader_core)
  add_test(NAME native-transactions COMMAND native-tests)
  add_executable(native-catalogue-review EXCLUDE_FROM_ALL tests/catalogue_review.cpp)
  target_link_libraries(native-catalogue-review PRIVATE shader_core)
  add_executable(fake-umbriel tests/fake_server.cpp)
  target_link_libraries(fake-umbriel PRIVATE shader_core)
  set_target_properties(fake-umbriel PROPERTIES OUTPUT_NAME umbriel
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/fixture")
  add_test(NAME native-cli-ipc COMMAND ${Python3_EXECUTABLE} -B
    ${CMAKE_SOURCE_DIR}/tests/integration.py
    $<TARGET_FILE:umbriel-shaders-native> $<TARGET_FILE:fake-umbriel>)
  set_tests_properties(native-cli-ipc PROPERTIES TIMEOUT 60 SKIP_RETURN_CODE 77)
  add_test(NAME native-cli-offline COMMAND ${Python3_EXECUTABLE} -B
    ${CMAKE_SOURCE_DIR}/tests/cli_smoke.py $<TARGET_FILE:umbriel-shaders-native>)
  set(LUAU_SOURCE_DIR "" CACHE PATH "Optional Noctalia vendored Luau source for UI workflow tests")
  if(LUAU_SOURCE_DIR)
    file(GLOB LUAU_TEST_SOURCES CONFIGURE_DEPENDS
      "${LUAU_SOURCE_DIR}/VM/src/*.cpp" "${LUAU_SOURCE_DIR}/Ast/src/*.cpp"
      "${LUAU_SOURCE_DIR}/Compiler/src/*.cpp" "${LUAU_SOURCE_DIR}/Common/src/*.cpp"
      "${LUAU_SOURCE_DIR}/Bytecode/src/*.cpp")
    add_library(luau-test-runtime STATIC ${LUAU_TEST_SOURCES})
    target_include_directories(luau-test-runtime PUBLIC
      "${LUAU_SOURCE_DIR}/VM/include" "${LUAU_SOURCE_DIR}/Ast/include"
      "${LUAU_SOURCE_DIR}/Compiler/include" "${LUAU_SOURCE_DIR}/Common/include"
      "${LUAU_SOURCE_DIR}/Bytecode/include")
    add_executable(luau-test-runner tests/luau_runner.cpp)
    target_link_libraries(luau-test-runner PRIVATE luau-test-runtime)
    add_test(NAME native-ui-workflows COMMAND ${Python3_EXECUTABLE} -B
      ${CMAKE_SOURCE_DIR}/tests/ui_workflows.py $<TARGET_FILE:luau-test-runner>)
  endif()
endif()
