FROM postgres:16

RUN apt-get update && \
    apt-get install -y --no-install-recommends python3-pip python3-dev libpq-dev build-essential curl netcat-openbsd && \
    pip3 install --break-system-packages "patroni[consul]" psycopg2-binary && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /data/patroni && chown -R postgres:postgres /data/patroni
RUN echo "{}" > /patroni.yml && chown postgres:postgres /patroni.yml

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER postgres
WORKDIR /home/postgres

EXPOSE 5432 8008

ENTRYPOINT ["/entrypoint.sh"]
