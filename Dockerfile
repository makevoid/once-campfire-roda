ARG RUBY_VERSION=4.0.7
FROM ruby:${RUBY_VERSION}-slim
WORKDIR /app
ENV RACK_ENV=production BUNDLE_WITHOUT=test HOST=0.0.0.0 PORT=9292 RUBY_YJIT_ENABLE=1
RUN apt-get update && apt-get install -y --no-install-recommends build-essential pkg-config libsqlite3-dev libssl-dev libvips42 ffmpeg poppler-utils && rm -rf /var/lib/apt/lists/*
COPY Gemfile Gemfile.lock ./
RUN bundle install
COPY . .
RUN groupadd --system campfire && useradd --system --gid campfire campfire && mkdir -p storage/files && chown -R campfire:campfire /app
USER campfire
ARG SOURCE_REVISION=unknown
ARG SOURCE_SHA256=unknown
LABEL org.opencontainers.image.revision=$SOURCE_REVISION io.campfire.source.sha256=$SOURCE_SHA256
EXPOSE 9292
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
