MIX ?= mix
DATA_DIR ?= ./data-elixir
PEERS ?= 127.0.0.1:48333

.PHONY: test node-status sync-local clean

test:
	$(MIX) test

node-status:
	DATA_DIR=$(DATA_DIR) PEERS=$(PEERS) $(MIX) node.status

sync-local:
	DATA_DIR=$(DATA_DIR) PEERS=$(PEERS) HEADERS_MAX=$(or $(HEADERS_MAX),2000) \
	HEADER_BATCHES_MAX=$(or $(HEADER_BATCHES_MAX),50) \
	BLOCKS_MAX=$(or $(BLOCKS_MAX),128) SKIP_BLOCKS=$(SKIP_BLOCKS) \
	$(MIX) sync.local

clean:
	$(MIX) clean
	rm -rf _build deps data-elixir-smoke
