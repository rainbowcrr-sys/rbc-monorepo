cmake_minimum_required(VERSION 3.16)
project(gc_primitives_cpp VERSION 0.1.1 LANGUAGES CXX)

# header-only INTERFACE 库，C++17
add_library(gc_primitives INTERFACE)
add_library(rbc::gc_primitives ALIAS gc_primitives)

target_include_directories(gc_primitives INTERFACE
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>)
target_compile_features(gc_primitives INTERFACE cxx_std_17)

option(GC_PRIMITIVES_BUILD_TESTS "编译契约测试" ON)
option(GC_PRIMITIVES_BUILD_BENCH "编译 Google Benchmark 基准（需安装 benchmark）" ON)

if(GC_PRIMITIVES_BUILD_TESTS)
    enable_testing()
    add_executable(contract_test tests/contract_test.cpp)
    target_link_libraries(contract_test PRIVATE gc_primitives)
    target_compile_options(contract_test PRIVATE -Wall -Wextra -Wpedantic)
    add_test(NAME contract_test COMMAND contract_test)
endif()

if(GC_PRIMITIVES_BUILD_BENCH)
    find_package(benchmark QUIET)
    if(benchmark_FOUND)
        add_executable(allocation_bench bench/allocation_bench.cpp)
        target_link_libraries(allocation_bench PRIVATE gc_primitives benchmark::benchmark)
    else()
        message(STATUS "未找到 Google Benchmark，跳过 allocation_bench（不影响库本体与测试）")
    endif()
endif()

install(DIRECTORY include/ DESTINATION include)
install(TARGETS gc_primitives EXPORT gc_primitivesTargets)
install(EXPORT gc_primitivesTargets
    FILE gc_primitivesTargets.cmake
    NAMESPACE rbc::
    DESTINATION lib/cmake/gc_primitives)
