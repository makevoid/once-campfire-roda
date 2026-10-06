# frozen_string_literal: true

require_relative "campfire/database"
require_relative "campfire/domain"
require_relative "campfire/repository"
require_relative "campfire/authentication"
require_relative "campfire/uploads"
require_relative "campfire/service"
require_relative "campfire/renderer"
require_relative "campfire/delivery"

module Campfire
  class Container
    attr_reader :db, :repo, :auth, :uploads, :service, :renderer
    def initialize(db:, upload_root: ENV.fetch("UPLOAD_ROOT", File.expand_path("../storage/files", __dir__)))
      @db = db
      @repo = Repository.new(db)
      @auth = Authentication.new(db)
      @uploads = Uploads.new(upload_root)
      @service = Service.new(repo, uploads)
      @renderer = Renderer.new
      freeze
    end
  end
end
