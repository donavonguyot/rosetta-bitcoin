REFERENCE_TOPOLOGY_DIR ?= $(abspath ../Shared/docker)
include $(REFERENCE_TOPOLOGY_DIR)/reference_topology.env

DOCKER_P2P_PEER ?= $(REFERENCE_P2P_PEER)
REFERENCE_P2P_CHECK_PEER ?= $(DOCKER_P2P_PEER)
REFERENCE_P2P_CHECK = docker run --rm --network $(REFERENCE_DOCKER_NETWORK) -v $(REFERENCE_TOPOLOGY_DIR):/shared/docker:ro python:3.12-alpine python3 /shared/docker/check_reference_p2p.py --peer $(REFERENCE_P2P_CHECK_PEER)
