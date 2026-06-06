cmake_minimum_required(VERSION 3.20)
project(cpbitnode VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(CPBITNODE_USE_ROCKSDB "Build with RocksDB native chainstate support" ON)
option(CPBITNODE_USE_NATIVE_SECP256K1 "Build with native libsecp256k1 support" OFF)
option(ENABLE_COVERAGE "Build with gcov/lcov coverage flags" OFF)
if(ENABLE_COVERAGE)
    add_compile_options(--coverage -fprofile-arcs -ftest-coverage)
    add_link_options(--coverage)
endif()

if(NOT CPBITNODE_USE_ROCKSDB)
    message(FATAL_ERROR "Cpp Core-native builds require CPBITNODE_USE_ROCKSDB=ON")
endif()

find_path(ROCKSDB_INCLUDE_DIR rocksdb/db.h
    HINTS /opt/homebrew/include /opt/homebrew/opt/rocksdb/include /usr/local/include /usr/include)
find_library(ROCKSDB_LIBRARY rocksdb
    HINTS /opt/homebrew/lib /opt/homebrew/opt/rocksdb/lib /usr/local/lib /usr/lib)
if(NOT ROCKSDB_INCLUDE_DIR OR NOT ROCKSDB_LIBRARY)
    message(FATAL_ERROR "Cpp Core-native builds require RocksDB headers and library")
endif()

if(CPBITNODE_USE_NATIVE_SECP256K1)
    find_path(SECP256K1_INCLUDE_DIR secp256k1.h
        HINTS /opt/homebrew/include /opt/homebrew/opt/secp256k1/include /usr/local/include /usr/include)
    find_library(SECP256K1_LIBRARY secp256k1
        HINTS /opt/homebrew/lib /opt/homebrew/opt/secp256k1/lib /usr/local/lib /usr/lib)
    if(NOT SECP256K1_INCLUDE_DIR OR NOT SECP256K1_LIBRARY)
        message(FATAL_ERROR "CPBITNODE_USE_NATIVE_SECP256K1=ON requires libsecp256k1 headers and library")
    endif()
endif()

set(CPBITNODE_LIB_SOURCES
    src/consensus/sha256.cpp
    src/consensus/hash.cpp
    src/consensus/ripemd160.cpp
    src/consensus/sha1.cpp
    src/consensus/secp256k1.cpp
    src/consensus/script/sighash.cpp
    src/consensus/script/interpreter.cpp
    src/consensus/script/verify.cpp
    src/consensus/merkle.cpp
    src/consensus/subsidy.cpp
    src/consensus/coinbase.cpp
    src/consensus/witness.cpp
    src/consensus/block.cpp
    src/consensus/connect.cpp
    src/sync/validate.cpp
    src/sync/headers.cpp
    src/sync/headerRefresh.cpp
    src/sync/blocks.cpp
    src/sync/syncDatadirLock.cpp
    src/wire/serialize.cpp
    src/wire/frame.cpp
    src/wire/capabilities.cpp
    src/wire/capabilities_data.cpp
    src/messages/address.cpp
    src/messages/block_header.cpp
    src/messages/block.cpp
    src/messages/transaction.cpp
    src/messages/inventory.cpp
    src/messages/headers.cpp
    src/messages/handshake.cpp
    src/messages/reject.cpp
    src/messages/fee_filter.cpp
    src/messages/mempool_query.cpp
    src/messages/bip152_short_txid.cpp
    src/messages/sendcmpct.cpp
    src/messages/compact_block.cpp
    src/chain/params.cpp
    src/chain/genesis.cpp
    src/db/codec_v2.cpp
    src/db/chainstate.cpp
    src/db/rocksdb_node_state.cpp
    src/storage/blocks.cpp
    src/metrics.cpp
    src/config/settings.cpp
    src/endpoint_parse.cpp
    src/util/json.cpp
    src/conformance/script_corpus.cpp
    src/healthcheck.cpp
    src/p2p/transport.cpp
    src/p2p/peer.cpp
    src/p2p/discovery.cpp
    src/p2p/headerServing.cpp
    src/p2p/manager.cpp
    src/p2p/server.cpp
    src/mempool/prevout.cpp
    src/mempool/orphan_pool.cpp
    src/mempool/mempool.cpp
    src/mempool/relay.cpp
    src/node.cpp
    src/metrics_http.cpp
)

add_library(cpbitnode_lib ${CPBITNODE_LIB_SOURCES})
target_include_directories(cpbitnode_lib PUBLIC include)
target_include_directories(cpbitnode_lib PUBLIC ${ROCKSDB_INCLUDE_DIR})
target_link_libraries(cpbitnode_lib PUBLIC ${ROCKSDB_LIBRARY})
target_compile_definitions(cpbitnode_lib PUBLIC CPBITNODE_USE_ROCKSDB=1)
if(CPBITNODE_USE_NATIVE_SECP256K1)
    target_include_directories(cpbitnode_lib PUBLIC ${SECP256K1_INCLUDE_DIR})
    target_link_libraries(cpbitnode_lib PUBLIC ${SECP256K1_LIBRARY})
    target_compile_definitions(cpbitnode_lib PUBLIC CPBITNODE_USE_NATIVE_SECP256K1=1)
endif()

add_executable(cpbitnode cli/cpbitnode.cpp)
add_executable(cpbitnode-db cli/cpbitnode_db.cpp)
add_executable(cpbitnode-healthcheck cli/cpbitnode_healthcheck.cpp)
add_executable(cpbitnode-sync cli/cpbitnode_sync.cpp)
add_executable(cpbitnode-storage-proof cli/cpbitnode_storage_proof.cpp)
add_executable(cpbitnode-blocker-inspect cli/cpbitnode_blocker_inspect.cpp)
if(CPBITNODE_USE_NATIVE_SECP256K1)
    add_executable(cpbitnode-script-corpus cli/cpbitnode_script_corpus.cpp)
    target_link_libraries(cpbitnode-script-corpus PRIVATE cpbitnode_lib)
    target_compile_definitions(cpbitnode-script-corpus PRIVATE CPBITNODE_REPO_ROOT="${CMAKE_CURRENT_SOURCE_DIR}/../..")
    add_test(
        NAME shared_script_corpus
        COMMAND cpbitnode-script-corpus
            --result-path ${CMAKE_BINARY_DIR}/cpp_script_corpus_ctest.json
        WORKING_DIRECTORY ${CMAKE_SOURCE_DIR})
    set_tests_properties(shared_script_corpus PROPERTIES LABELS "core-regression;script-corpus")
endif()
foreach(_exe cpbitnode cpbitnode-db cpbitnode-healthcheck cpbitnode-sync cpbitnode-storage-proof cpbitnode-blocker-inspect)
    target_link_libraries(${_exe} PRIVATE cpbitnode_lib)
endforeach()

enable_testing()
add_executable(cpbitnode_tests
    tests/test_main.cpp
    tests/test_wire.cpp
    tests/test_messages.cpp
    tests/test_consensus.cpp
    tests/test_chain.cpp
    tests/test_storage.cpp
    tests/test_codec_v2.cpp
    tests/test_native_store.cpp
    tests/test_connect_timing.cpp
    tests/test_sync_hot_path.cpp
    tests/test_script.cpp
    tests/test_compact_block.cpp
    tests/test_transport.cpp
    tests/test_endpoint_settings.cpp
    tests/test_json.cpp
    tests/test_cli_smoke.cpp
    tests/test_native_crypto.cpp
    tests/test_shared_script_corpus.cpp
    tests/script_helpers.cpp
)
if(CPBITNODE_USE_NATIVE_SECP256K1)
    target_link_libraries(cpbitnode_tests PRIVATE cpbitnode_lib)
    target_compile_definitions(cpbitnode_tests PRIVATE
        CPBITNODE_USE_NATIVE_SECP256K1=1
        CPBITNODE_BUILD_DIR="${CMAKE_BINARY_DIR}"
        CPBITNODE_REPO_ROOT="${CMAKE_CURRENT_SOURCE_DIR}/../..")
else()
    target_link_libraries(cpbitnode_tests PRIVATE cpbitnode_lib)
    target_compile_definitions(cpbitnode_tests PRIVATE CPBITNODE_BUILD_DIR="${CMAKE_BINARY_DIR}")
endif()
add_test(NAME cpp_core_regression COMMAND cpbitnode_tests --suite core WORKING_DIRECTORY ${CMAKE_SOURCE_DIR})
set_tests_properties(cpp_core_regression PROPERTIES LABELS "core-regression")
add_test(NAME cpp_wire_codec COMMAND cpbitnode_tests --suite wire WORKING_DIRECTORY ${CMAKE_SOURCE_DIR})
set_tests_properties(cpp_wire_codec PROPERTIES LABELS "wire-codec")
add_test(NAME cpp_runtime_smoke COMMAND cpbitnode_tests --suite runtime WORKING_DIRECTORY ${CMAKE_SOURCE_DIR})
set_tests_properties(cpp_runtime_smoke PROPERTIES LABELS "runtime-smoke")
