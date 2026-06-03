ERL_ROOT := $(shell erl -noshell -eval 'io:format("~s", [code:root_dir()]), halt().')
ERL_INCLUDE := $(ERL_ROOT)/usr/include
PRIV_DIR := ../priv
ROCKSDB_CFLAGS := $(shell pkg-config --cflags rocksdb 2>/dev/null)
ROCKSDB_LIBS := $(shell pkg-config --libs rocksdb 2>/dev/null)
SECP_CFLAGS := $(shell pkg-config --cflags libsecp256k1 2>/dev/null)
SECP_LIBS := $(shell pkg-config --libs libsecp256k1 2>/dev/null)

ifeq ($(shell uname -s),Darwin)
  SO_EXT := so
  SHARED_FLAGS := -dynamiclib -undefined dynamic_lookup
else
  SO_EXT := so
  SHARED_FLAGS := -shared -fPIC
endif

CFLAGS ?= -O2 -Wall -Wextra -fPIC
CXXFLAGS ?= -O2 -Wall -Wextra -fPIC

.PHONY: all clean

all: $(PRIV_DIR)/exbitnode_native_rocksdb.$(SO_EXT) $(PRIV_DIR)/exbitnode_native_secp256k1.$(SO_EXT)

$(PRIV_DIR):
	mkdir -p $(PRIV_DIR)

$(PRIV_DIR)/exbitnode_native_rocksdb.$(SO_EXT): native_rocksdb.cc | $(PRIV_DIR)
	$(CXX) $(CXXFLAGS) $(SHARED_FLAGS) -I$(ERL_INCLUDE) $(ROCKSDB_CFLAGS) $< -o $@ $(ROCKSDB_LIBS)

$(PRIV_DIR)/exbitnode_native_secp256k1.$(SO_EXT): native_secp256k1.c | $(PRIV_DIR)
	$(CC) $(CFLAGS) $(SHARED_FLAGS) -I$(ERL_INCLUDE) $(SECP_CFLAGS) $< -o $@ $(SECP_LIBS)

clean:
	rm -f $(PRIV_DIR)/exbitnode_native_rocksdb.so $(PRIV_DIR)/exbitnode_native_rocksdb.dylib
	rm -f $(PRIV_DIR)/exbitnode_native_secp256k1.so $(PRIV_DIR)/exbitnode_native_secp256k1.dylib
