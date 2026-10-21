# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
FROM ruby:4.0.7-bookworm@sha256:119a36c51c7893215202220eabfdcb561638735de4d45bacf2e8619be3de47f2 AS base
WORKDIR /opt/skvoz/server
RUN apt-get update && apt-get install -y --no-install-recommends libsodium23=1.0.18-1+deb12u1 \
    && rm -rf /var/lib/apt/lists/*
COPY Gemfile Gemfile.lock ./
RUN gem install bundler --version 4.0.22 --no-document \
    && bundle config set deployment true \
    && bundle config set without test \
    && bundle install \
    && bundle clean --force \
    && rm -rf /usr/local/bundle/cache
COPY lib lib
COPY bin/skvoz-server bin/skvoz-child bin/skvoz-tls-worker bin/

FROM base AS native
ARG NETWORK_LOCK=product-native-lock.json
ARG NETWORK_ARCHIVE=artifacts/native/skvoz-network-0.7.0-x86_64-unknown-linux-gnu-current-identity.tar.gz
COPY ${NETWORK_LOCK} /native/lock.json
COPY ${NETWORK_ARCHIVE} /native/bundle.tar.gz
COPY bin/install-native bin/
COPY bin/support/network_download.rb bin/support/
RUN bundle exec ruby bin/install-native /native/lock.json /opt/skvoz-native /native/bundle.tar.gz

FROM base AS broker
# The server image currently targets Linux amd64; use the exact official release.
ADD --checksum=sha256:bf5edc7b1ce98e885c368cb43a886eb148dc5d0551d99f3cf6141fb5e1954c70 https://github.com/nats-io/nats-server/releases/download/v2.15.1/nats-server-v2.15.1-linux-amd64.tar.gz /opt/broker-build/nats.tar.gz
RUN test "$(uname -m)" = x86_64 \
    && tar -xzf /opt/broker-build/nats.tar.gz -C /opt/broker-build \
    && install -m 0755 /opt/broker-build/nats-server-v2.15.1-linux-amd64/nats-server /usr/local/bin/nats-server \
    && test "$(nats-server --version)" = 'nats-server: v2.15.1' \
    && rm -rf /opt/broker-build
FROM ghcr.io/letsencrypt/pebble:2.10.1@sha256:ddf230642b1a584f519f32e347de1b05a6e4c1f6c35c1863b33effeab5f78199 AS acme-test

FROM base AS ruby-tests
RUN apt-get update && apt-get install -y --no-install-recommends util-linux \
    && rm -rf /var/lib/apt/lists/* \
    && bundle config unset without && bundle install \
    && groupadd --gid 10001 skvoz && useradd --uid 10001 --gid 10001 --no-create-home skvoz
COPY bin bin
COPY spec spec
COPY deployment deployment
COPY deploy deploy
ENV SKVOZ_INTEGRATION=0
USER 10001:10001
CMD ["bundle", "exec", "rspec", "spec"]

FROM ruby-tests AS tests
USER 0:0
COPY --from=native /opt/skvoz-native /opt/skvoz-native
COPY --from=broker /usr/local/bin/nats-server /usr/local/bin/nats-server
COPY --from=acme-test /app /usr/local/bin/pebble
RUN ln -s /opt/skvoz-native/bin/skvoz-network-runtime /usr/local/bin/skvoz-network-runtime \
    && ln -s /opt/skvoz-native/bin/skvoz-network-helper /usr/local/bin/skvoz-network-helper
ENV SKVOZ_INTEGRATION=1
USER 10001:10001
CMD ["bundle", "exec", "rspec", "spec"]

FROM ruby:4.0.7-slim-bookworm@sha256:b21bc6c2360f7b7b615ff8860f239b12b2c6634ec026712745743b0661ac14b9 AS deploy
ARG SOURCE_REVISION
LABEL org.opencontainers.image.source="https://github.com/skvoz-project/skvoz-server" \
    org.opencontainers.image.version="9.0.0" \
    org.opencontainers.image.revision="${SOURCE_REVISION}"
RUN apt-get update && apt-get install -y --no-install-recommends util-linux ca-certificates iproute2 nftables conntrack libsodium23=1.0.18-1+deb12u1 \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 skvoz && useradd --uid 10001 --gid 10001 --no-create-home skvoz \
    && install -d -o skvoz -g skvoz -m 0700 /var/lib/skvoz \
    && install -d -o root -g root -m 0700 /var/lib/skvoz-network
WORKDIR /opt/skvoz/server
COPY --from=base /usr/local/bundle /usr/local/bundle
COPY --from=base /opt/skvoz/server /opt/skvoz/server
COPY --from=native /opt/skvoz-native/bin/skvoz-network-runtime /opt/skvoz-native/bin/skvoz-network-helper /opt/skvoz-native/bin/
COPY --from=native /opt/skvoz-native/lib /opt/skvoz-native/lib
COPY --from=native /opt/skvoz-native/resources /opt/skvoz-native/resources
COPY --from=native /opt/skvoz-native/licenses /opt/skvoz-native/licenses
COPY --from=native /opt/skvoz-native/manifest.json /opt/skvoz-native/supplier-manifest.json
COPY --from=native /opt/skvoz-native/source-inputs.sha256 /opt/skvoz-native/source-inputs.sha256
RUN ln -s /opt/skvoz-native/bin/skvoz-network-runtime /usr/local/bin/skvoz-network-runtime \
    && ln -s /opt/skvoz-native/bin/skvoz-network-helper /usr/local/bin/skvoz-network-helper
COPY --from=broker /usr/local/bin/nats-server /usr/local/bin/nats-server
RUN ln -s /opt/skvoz/server/bin/skvoz-server /usr/local/bin/skvoz-server
ENV BUNDLE_GEMFILE=/opt/skvoz/server/Gemfile SKVOZ_STATE_DIR=/var/lib/skvoz
USER 0:0
EXPOSE 4222 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=3 CMD ["skvoz-server", "health", "--state", "/var/lib/skvoz"]
ENTRYPOINT ["skvoz-server"]
CMD ["serve"]
