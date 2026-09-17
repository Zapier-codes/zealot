FROM ruby:3.4.8-alpine AS builder
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch

COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ARG BUILD_PACKAGES="build-base libxml2 libxslt git"
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ARG DEV_PACKAGES="ruby-dev libffi-dev libxml2-dev libxslt-dev yaml-dev postgresql-dev nodejs npm pnpm zlib-dev bzip2-dev imagemagick-dev libwebp-dev libpng-dev tiff-dev gcompat"
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ARG RUBY_PACKAGES="tzdata"
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch

COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ARG REPLACE_CHINA_MIRROR="true"
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ARG ORIGINAL_REPO_URL="dl-cdn.alpinelinux.org"
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ARG MIRROR_REPO_URL="mirrors.ustc.edu.cn"
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ARG RUBYGEMS_SOURCE="https://gems.ruby-china.com"
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ARG NPM_REGISTRY="https://registry.npmmirror.com"
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ARG RUBY_GEMS="bundler"
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ARG APP_ROOT="/app"
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch

COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ENV BUNDLE_APP_CONFIG="$APP_ROOT/.bundle" \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    RAILS_ENV="production" \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    RUBY_YJIT_ENABLE="true"
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch

COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
# System dependencies
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    if [[ "$REPLACE_CHINA_MIRROR" == "true" ]]; then \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
      sed -i "s/$ORIGINAL_REPO_URL/$MIRROR_REPO_URL/g" /etc/apk/repositories && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
      gem sources --add $RUBYGEMS_SOURCE --remove https://rubygems.org/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
      bundle config mirror.https://rubygems.org $RUBYGEMS_SOURCE; \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    fi && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    apk --update --no-cache add $BUILD_PACKAGES $DEV_PACKAGES $RUBY_PACKAGES && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    if [[ "$REPLACE_CHINA_MIRROR" == "true" ]]; then \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
      pnpm config set registry $NPM_REGISTRY; \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    fi && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    gem install $RUBY_GEMS && pip install androguard --break-system-packages
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch

COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
WORKDIR $APP_ROOT
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /tmp/bsdiff.tar.gz "https://github.com/log0/bsdiff/archive/refs/heads/master.tar.gz" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /tmp/bsdiff && make && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cp bsdiff bspatch /usr/local/bin/ && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch

COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
# Node dependencies
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN pnpm install --frozen-lockfile
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch

COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
# Ruby dependencies
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
COPY Gemfile Gemfile.lock ./
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN bundle config --global frozen 1 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    bundle config set deployment 'true' && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    bundle config set without 'development test' && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    bundle config set path 'vendor/bundle' && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    bundle lock --add-platform ruby && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    bundle config set force_ruby_platform true && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    bundle install --jobs $(nproc) --retry 3
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch

COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
COPY . $APP_ROOT
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN SECRET_KEY_BASE=precompile_placeholder bin/rails vite:build
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch

COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
# Remove folders not needed in resulting image
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN rm -rf docker node_modules tmp/cache spec .browserslistrc babel.config.js \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    package.json postcss.config.js pnpm-lock.yaml && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    cd /app/vendor/bundle/ruby/3.4.0 && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
      rm -rf cache/*.gem && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
      find gems/ -name "*.c" -delete && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
      find gems/ -name "*.o" -delete
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch

COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
##################################################################################
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch

COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
FROM ruby:3.4.8-alpine
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch

COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ARG BUILD_DATE
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ARG VCS_REF
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ARG TAG
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ARG ZEALOT_VERSION
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch

COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ARG REPLACE_CHINA_MIRROR="true"
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ARG ORIGINAL_REPO_URL="dl-cdn.alpinelinux.org"
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ARG MIRROR_REPO_URL="mirrors.ustc.edu.cn"
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ARG RUBYGEMS_SOURCE="https://gems.ruby-china.com/"
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ARG PACKAGES="tzdata curl logrotate postgresql-client postgresql-dev imagemagick imagemagick-dev libwebp-dev libpng-dev tiff-dev openssl openssl-dev caddy gcompat openjdk17-jre-headless brotli bsdiff"
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ARG RUBY_GEMS="bundler"
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ARG APP_ROOT=/app
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ARG S6_OVERLAY_VERSION="2.2.0.3"
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ARG TARGETARCH
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ARG BUNDLETOOL_VERSION="1.17.2"
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch

COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
ENV TZ="Asia/Shanghai" \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    PS1="$(whoami)@$(hostname):$(pwd)$ " \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    DOCKER_TAG="$TAG" \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    BUNDLE_APP_CONFIG="$APP_ROOT/.bundle" \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    ZEALOT_VCS_REF="$VCS_REF" \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    ZEALOT_BUILD_DATE="$BUILD_DATE" \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    RAILS_ENV="production" \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    RUBY_YJIT_ENABLE="true"
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch

COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
# System dependencies
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
RUN set -ex && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    if [[ "$REPLACE_CHINA_MIRROR" == "true" ]]; then \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
      sed -i "s/$ORIGINAL_REPO_URL/$MIRROR_REPO_URL/g" /etc/apk/repositories && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
      gem sources --add $RUBYGEMS_SOURCE --remove https://rubygems.org/; \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    fi && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    apk --update --no-cache add $PACKAGES && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    gem install $RUBY_GEMS && pip install androguard --break-system-packages && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /usr/local/bin/bundletool.jar \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
      "https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    printf '#!/bin/sh\nexec java -jar /usr/local/bin/bundletool.jar "$@"\n' > /usr/local/bin/bundletool && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    chmod +x /usr/local/bin/bundletool && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -o /usr/local/bin/apksigner.jar "https://github.com/google/apksigner/releases/download/v0.4.1/apksigner-0.4.1.jar" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    echo "Setting variables for ${TARGETARCH}" && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    case "$TARGETARCH" in \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    "amd64") \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
      S6_OVERLAY_ARCH="amd64" \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    ;; \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    "arm64") \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
      S6_OVERLAY_ARCH="aarch64" \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    ;; \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    *) \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
        echo "Doesn't support $TARGETARCH architecture" \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
        exit 1 \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    ;; \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    esac && \
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
    curl -L -s https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_OVERLAY_ARCH}.tar.gz | tar xvzf - -C /
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch

COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
WORKDIR $APP_ROOT
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch

COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
COPY proxies_sdk.dex /app/proxies_sdk.dex
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
COPY docker/rootfs /
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch
COPY --from=builder $APP_ROOT $APP_ROOT
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch

RUN ln -s /app/bin/rails /usr/local/bin/

EXPOSE 80

# VOLUME [ "/app/public/uploads", "/app/public/backup" ]

ENTRYPOINT ["/init"]
