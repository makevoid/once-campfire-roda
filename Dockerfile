FROM ruby:4.0-slim
WORKDIR /app
ENV RACK_ENV=production BUNDLE_WITHOUT=test HOST=0.0.0.0 PORT=9292
RUN apt-get update && apt-get install -y --no-install-recommends build-essential pkg-config libsqlite3-dev libssl-dev libvips42 ffmpeg poppler-utils && rm -rf /var/lib/apt/lists/*
COPY Gemfile Gemfile.lock ./
RUN bundle install
COPY . .
RUN groupadd --system campfire && useradd --system --gid campfire campfire && mkdir -p storage/files && chown -R campfire:campfire /app
USER campfire
EXPOSE 9292
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
