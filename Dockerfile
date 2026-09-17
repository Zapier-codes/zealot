FROM --platform=$BUILDPLATFORM ruby:3.4.7-alpine AS builder

ARG BUILD_PACKAGES="build-base libxml2 libxslt git curl bzip2-dev"
ARG DEV_PACKAGES="ruby-dev libffi-dev libxml2-dev libxslt-dev yaml-dev postgresql-dev nodejs npm pnpm zlib-dev imagemagick-dev libwebp-dev libpng-dev tiff-dev gcompat"
ARG RUBY_PACKAGES="tzdata"

ARG REPLACE_CHINA_MIRROR="true"
ARG ORIGINAL_REPO_URL="dl-cdn.alpinelinux.org"
ARG MIRROR_REPO_URL="mirrors.ustc.edu.cn"
ARG RUBYGEMS_SOURCE="https://gems.ruby-china.com"
ARG NPM_REGISTRY="https://registry.npmmirror.com"
ARG RUBY_GEMS="bundler"
ARG APP_ROOT="/app"

ENV BUNDLE_APP_CONFIG="$APP_ROOT/.bundle" \
    RAILS_ENV="production" \
    RUBY_YJIT_ENABLE="true"

# System dependencies
RUN set -ex && \
    if [[ "$REPLACE_CHINA_MIRROR" == "true" ]]; then \
      sed -i "s/$ORIGINAL_REPO_URL/$MIRROR_REPO_URL/g" /etc/apk/repositories && \
      gem sources --add $RUBYGEMS_SOURCE --remove https://rubygems.org/ && \
      bundle config mirror.https://rubygems.org $RUBYGEMS_SOURCE; \
    fi && \
    apk --update --no-cache add $BUILD_PACKAGES $DEV_PACKAGES $RUBY_PACKAGES && \
    if [[ "$REPLACE_CHINA_MIRROR" == "true" ]]; then \
      pnpm config set registry $NPM_REGISTRY; \
    fi && \
    gem install $RUBY_GEMS

# Compile bsdiff from source for state-of-the-art delta patching (musl compatible)
RUN set -ex && \
    curl -fL -o /tmp/bsdiff.tar.gz "https://github.com/aburgh/bsdiff/archive/refs/heads/master.tar.gz" && \
    mkdir -p /tmp/bsdiff && tar -xzf /tmp/bsdiff.tar.gz -C /tmp/bsdiff --strip-components=1 && \
    cd /tmp/bsdiff && \
    sed -i '/#include <sys\/cdefs.h>/d' bsdiff/bsdiff.c bspatch/bspatch.c && \
    gcc -O2 -o /usr/local/bin/bsdiff bsdiff/bsdiff.c -lbz2 && \
    gcc -O2 -o /usr/local/bin/bspatch bspatch/bspatch.c -lbz2 && \
    cd / && rm -rf /tmp/bsdiff /tmp/bsdiff.tar.gz

WORKDIR $APP_ROOT

# Node dependencies
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

# Ruby dependencies
COPY Gemfile Gemfile.lock ./
RUN bundle config --global frozen 1 && \
    bundle config set deployment 'true' && \
    bundle config set without 'development test' && \
    bundle config set path 'vendor/bundle' && \
    bundle lock --add-platform ruby && \
    bundle config set force_ruby_platform true && \
    bundle install --jobs `expr $(cat /proc/cpuinfo | grep -c "cpu cores") - 1` --retry 3

COPY . $APP_ROOT
RUN SECRET_KEY_BASE=precompile_placeholder bin/rails assets:precompile

# Remove folders not needed in resulting image
RUN rm -rf docker node_modules tmp/cache spec .browserslistrc babel.config.js \
    package.json postcss.config.js pnpm-lock.yaml && \
    cd /app/vendor/bundle/ruby/3.4.0 && \
      rm -rf cache/*.gem && \
      find gems/ -name "*.c" -delete && \
      find gems/ -name "*.o" -delete

##################################################################################

FROM --platform=$BUILDPLATFORM ruby:3.4.7-alpine

ARG BUILD_DATE
ARG VCS_REF
ARG TAG
ARG ZEALOT_VERSION

ARG REPLACE_CHINA_MIRROR="true"
ARG ORIGINAL_REPO_URL="dl-cdn.alpinelinux.org"
ARG MIRROR_REPO_URL="mirrors.ustc.edu.cn"
ARG RUBYGEMS_SOURCE="https://gems.ruby-china.com/"
ARG PACKAGES="tzdata curl logrotate postgresql-client postgresql-dev imagemagick imagemagick-dev libwebp-dev libpng-dev tiff-dev openssl openssl-dev caddy gcompat openjdk17-jre-headless brotli bzip2 python3 py3-pip build-base python3-dev"
ARG RUBY_GEMS="bundler"
ARG APP_ROOT=/app
ARG S6_OVERLAY_VERSION="2.2.0.3"
ARG TARGETARCH
ARG BUNDLETOOL_VERSION="1.17.2"
ARG APKTOOL_VERSION="2.9.3"

ENV TZ="Asia/Shanghai" \
    PS1="$(whoami)@$(hostname):$(pwd)$ " \
    DOCKER_TAG="$TAG" \
    BUNDLE_APP_CONFIG="$APP_ROOT/.bundle" \
    ZEALOT_VCS_REF="$VCS_REF" \
    ZEALOT_BUILD_DATE="$BUILD_DATE" \
    RAILS_ENV="production" \
    RUBY_YJIT_ENABLE="true"

# System dependencies
RUN set -ex && \
    if [[ "$REPLACE_CHINA_MIRROR" == "true" ]]; then \
      sed -i "s/$ORIGINAL_REPO_URL/$MIRROR_REPO_URL/g" /etc/apk/repositories && \
      gem sources --add $RUBYGEMS_SOURCE --remove https://rubygems.org/; \
    fi && \
    apk --update --no-cache add $PACKAGES && \
    gem install $RUBY_GEMS && pip install androguard --break-system-packages && \
    curl -fL -o /usr/local/bin/bundletool.jar \
      "https://github.com/google/bundletool/releases/download/${BUNDLETOOL_VERSION}/bundletool-all-${BUNDLETOOL_VERSION}.jar" && \
    printf '#!/bin/sh\nexec java -jar /usr/local/bin/bundletool.jar "$@"\n' > /usr/local/bin/bundletool && \
    chmod +x /usr/local/bin/bundletool && \
    curl -fL -o /usr/local/bin/apksigner.jar "https://github.com/google/apksigner/releases/download/v0.4.1/apksigner-0.4.1.jar" && \
    curl -fL -o /usr/local/bin/apktool.jar "https://github.com/iBotPeaches/Apktool/releases/download/v${APKTOOL_VERSION}/apktool_${APKTOOL_VERSION}.jar" && \
    printf '#!/bin/sh\nexec java -jar /usr/local/bin/apktool.jar "$@"\n' > /usr/local/bin/apktool && \
    chmod +x /usr/local/bin/apktool && \
    echo "Setting variables for ${TARGETARCH}" && \
    case "$TARGETARCH" in \
    "amd64") \
      S6_OVERLAY_ARCH="amd64" \
    ;; \
    "arm64") \
      S6_OVERLAY_ARCH="aarch64" \
    ;; \
    *) \
        echo "Doesn't support $TARGETARCH architecture" \
        exit 1 \
    ;; \
    esac && \
    curl -fL -s https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_OVERLAY_ARCH}.tar.gz | tar xvzf - -C /

WORKDIR $APP_ROOT

COPY docker/rootfs /
COPY --from=builder $APP_ROOT $APP_ROOT

# Copy compiled bsdiff binaries from builder stage
COPY --from=builder /usr/local/bin/bsdiff /usr/local/bin/bsdiff
COPY --from=builder /usr/local/bin/bspatch /usr/local/bin/bspatch

RUN ln -s /app/bin/rails /usr/local/bin/

EXPOSE 80

# VOLUME [ "/app/public/uploads", "/app/public/backup" ]

ENTRYPOINT ["/init"]
