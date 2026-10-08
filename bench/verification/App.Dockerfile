ARG APP_IMAGE=once-campfire-roda:app
FROM ${APP_IMAGE}
USER root
RUN mkdir -p /rails/storage/db /rails/storage/files /rails/storage/logs && chown -R campfire:campfire /rails
USER campfire
CMD ["bench/verification/boot"]
