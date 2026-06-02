cmake_minimum_required(VERSION 3.20)
project(cpbitnode VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# System SQLite (no vendored amalgamation in Gate 0). See third_party/sqlite/README.md.
find_package(SQLite3 REQUIRED)

option(CPBITNODE_USE_ROCKSDB "Build with RocksDB native chainstate support" OFF)
option(CPBITNODE_USE_NATIVE_SECP256K1 "Build with native libsecp256k1 support" OFF)
option(ENABLE_COVERAGE "Build with gcov/lcov coverage flags" OFF)
if(ENABLE_COVERAGE)
    add_compile_options(--coverage -fprofile-arcs -ftest-coverage)
    add_link_options(--coverage)
endif()

if(CPBITNODE_USE_ROCKSDB)
    find_path(ROCKSDB_INCLUDE_DIR rocksdb/db.h
        HINTS /opt/homebrew/include /opt/homebrew/opt/rocksdb/include /usr/local/include /usr/include)
    find_library(ROCKSDB_LIBRARY rocksdb
        HINTS /opt/homebrew/lib /opt/homebrew/opt/rocksdb/lib /usr/local/lib /usr/lib)
    if(NOT ROCKSDB_INCLUDE_DIR OR NOT ROCKSDB_LIBRARY)
        message(FATAL_ERROR "CPBITNODE_USE_ROCKSDB=ON requires RocksDB headers and library")
    endif()
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
    src/db/schema.cpp
    src/db/tracker.cpp
    src/db/chainstate.cpp
    src/db/rocksdb_node_state.cpp
    src/storage/blocks.cpp
    src/metrics.cpp
    src/config/settings.cpp
    src/endpoint_parse.cpp
    src/util/json.cpp
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
if(TARGET SQLite3::SQLite3)
    target_link_libraries(cpbitnode_lib PUBLIC SQLite3::SQLite3)
else()
    target_include_directories(cpbitnode_lib PUBLIC ${SQLite3_INCLUDE_DIRS})
    target_link_libraries(cpbitnode_lib PUBLIC ${SQLite3_LIBRARIES})
endif()
if(CPBITNODE_USE_ROCKSDB)
    target_include_directories(cpbitnode_lib PUBLIC ${ROCKSDB_INCLUDE_DIR})
    target_link_libraries(cpbitnode_lib PUBLIC ${ROCKSDB_LIBRARY})
    target_compile_definitions(cpbitnode_lib PUBLIC CPBITNODE_USE_ROCKSDB=1)
endif()
if(CPBITNODE_USE_NATIVE_SECP256K1)
    target_include_directories(cpbitnode_lib PUBLIC ${SECP256K1_INCLUDE_DIR})
    target_link_libraries(cpbitnode_lib PUBLIC ${SECP256K1_LIBRARY})
    target_compile_definitions(cpbitnode_lib PUBLIC CPBITNODE_USE_NATIVE_SECP256K1=1)
endif()

if(CPBITNODE_USE_ROCKSDB)
    set(CPBITNODE_NATIVE_LIB_SOURCES ${CPBITNODE_LIB_SOURCES})
    list(REMOVE_ITEM CPBITNODE_NATIVE_LIB_SOURCES src/db/schema.cpp src/db/tracker.cpp)
    add_library(cpbitnode_native_lib ${CPBITNODE_NATIVE_LIB_SOURCES})
    target_include_directories(cpbitnode_native_lib PUBLIC include ${ROCKSDB_INCLUDE_DIR})
    target_link_libraries(cpbitnode_native_lib PUBLIC ${ROCKSDB_LIBRARY})
    target_compile_definitions(cpbitnode_native_lib PUBLIC CPBITNODE_USE_ROCKSDB=1)
    if(CPBITNODE_USE_NATIVE_SECP256K1)
        target_include_directories(cpbitnode_native_lib PUBLIC ${SECP256K1_INCLUDE_DIR})
        target_link_libraries(cpbitnode_native_lib PUBLIC ${SECP256K1_LIBRARY})
        target_compile_definitions(cpbitnode_native_lib PUBLIC CPBITNODE_USE_NATIVE_SECP256K1=1)
    endif()
endif()

add_executable(cpbitnode cli/cpbitnode.cpp)
add_executable(cpbitnode-db cli/cpbitnode_db.cpp)
add_executable(cpbitnode-healthcheck cli/cpbitnode_healthcheck.cpp)
add_executable(cpbitnode-export-snapshots cli/cpbitnode_export_snapshots.cpp)
add_executable(cpbitnode-sync cli/cpbitnode_sync.cpp)
add_executable(cpbitnode-storage-proof cli/cpbitnode_storage_proof.cpp)
add_executable(cpbitnode-blocker-inspect cli/cpbitnode_blocker_inspect.cpp)
foreach(_exe cpbitnode cpbitnode-db cpbitnode-healthcheck cpbitnode-export-snapshots cpbitnode-sync cpbitnode-storage-proof cpbitnode-blocker-inspect)
    set(_use_native_lib OFF)
    if(CPBITNODE_USE_ROCKSDB AND (_exe STREQUAL "cpbitnode-db" OR _exe STREQUAL "cpbitnode-sync" OR _exe STREQUAL "cpbitnode-storage-proof"))
        set(_use_native_lib ON)
    endif()
    if(_use_native_lib)
        target_link_libraries(${_exe} PRIVATE cpbitnode_native_lib)
    else()
        target_link_libraries(${_exe} PRIVATE cpbitnode_lib)
    endif()
endforeach()

enable_testing()
add_executable(cpbitnode_tests
    tests/test_main.cpp
    tests/test_wire.cpp
    tests/test_wire_capabilities.cpp
    tests/test_messages.cpp
    tests/test_consensus.cpp
    tests/test_db.cpp
    tests/test_chain.cpp
    tests/test_storage.cpp
    tests/test_healthcheck.cpp
    tests/test_script.cpp
    tests/test_compact_block.cpp
    tests/test_connect.cpp
    tests/test_p2p.cpp
    tests/test_discovery.cpp
    tests/test_peer_manager.cpp
    tests/test_header_serving.cpp
    tests/test_sync.cpp
    tests/test_mempool.cpp
    tests/test_inbound_serve.cpp
    tests/test_peer_tx_relay.cpp
    tests/test_sync_integration_smoke.cpp
    tests/test_transport.cpp
    tests/test_metrics_http.cpp
    tests/test_endpoint_settings.cpp
    tests/test_metrics.cpp
    tests/test_json.cpp
    tests/test_header_refresh.cpp
    tests/test_server_discovery.cpp
    tests/test_node.cpp
    tests/test_cli_smoke.cpp
    tests/test_native_crypto.cpp
    tests/script_helpers.cpp
)
target_link_libraries(cpbitnode_tests PRIVATE cpbitnode_lib)
target_compile_definitions(cpbitnode_tests PRIVATE CPBITNODE_BUILD_DIR="${CMAKE_BINARY_DIR}")
add_test(NAME cpbitnode_tests COMMAND cpbitnode_tests WORKING_DIRECTORY ${CMAKE_SOURCE_DIR})
