include ../Shared/state_root.mk
.PHONY: config start stop
config:
	docker compose -f docker/docker-compose.yml config
start:
	docker compose -f docker/docker-compose.yml up -d
stop:
	docker compose -f docker/docker-compose.yml stop
