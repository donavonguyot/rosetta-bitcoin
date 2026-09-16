FROM ubuntu:24.04@sha256:db6914f1ac0c566f57857641e2214e3f3e453cb340cc2c890ed6c2b7b81b8a00
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends clang-18 llvm-18 libclang-rt-18-dev libssl-dev python3 python3-reportlab poppler-utils make ca-certificates && rm -rf /var/lib/apt/lists/*
ENV PATH=/usr/lib/llvm-18/bin:$PATH
WORKDIR /work
