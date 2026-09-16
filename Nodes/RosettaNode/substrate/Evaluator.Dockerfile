FROM rosettanode-substrate:instrument
COPY tools /evaluator/tools
COPY evaluator /evaluator/evaluator
COPY native /evaluator/native
COPY evidence /evaluator/evidence
COPY binaries /evaluator/.local
RUN chmod 711 /evaluator /evaluator/.local && chmod -R go-rwx /evaluator/tools /evaluator/evaluator /evaluator/native /evaluator/evidence && chmod 700 /evaluator/.local/* && chmod 444 /evaluator/.local/*.so && mkdir -p /work && ln -s /evaluator/.local /work/.local
WORKDIR /evaluator
ENV PYTHONDONTWRITEBYTECODE=1
