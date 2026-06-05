FROM ocaml/opam:debian-12-ocaml-5.2

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      git \
      libgmp-dev \
      librocksdb-dev \
      libsecp256k1-dev \
      pkg-config \
    && rm -rf /var/lib/apt/lists/*

USER opam
WORKDIR /workspace/OCaml

COPY --chown=opam:opam dune-project ocbitnode.opam ./
RUN opam update && opam install -y . --deps-only --with-test

COPY --chown=opam:opam . .
RUN opam exec -- dune build @install

USER root
RUN chmod +x docker/entrypoint.sh
ENTRYPOINT ["/workspace/OCaml/docker/entrypoint.sh"]
