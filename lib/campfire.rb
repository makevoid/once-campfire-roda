# frozen_string_literal: true

require_relative "campfire/database"
require_relative "campfire/domain"
require_relative "campfire/repository"
require_relative "campfire/response_cache"
require_relative "campfire/fragment_cache"
require_relative "campfire/authentication"
require_relative "campfire/uploads"
require_relative "campfire/media"
require_relative "campfire/tokens"
require_relative "campfire/service"
require_relative "campfire/file_body"
require_relative "campfire/delivery"
require_relative "campfire/push_policy"
require_relative "campfire/opengraph"
require_relative "campfire/sound"
require_relative "campfire/ui/view"
require_relative "campfire/api"
require_relative "campfire/realtime/hub"
require_relative "campfire/realtime/protocol"
require_relative "campfire/realtime/socket"

module Campfire
  class Container
    attr_reader :db, :repo, :auth, :uploads, :media, :tokens, :service, :hub, :response_cache, :fragment_cache
    def initialize(db:, upload_root: ENV.fetch("UPLOAD_ROOT", File.expand_path("../storage/files", __dir__)), push_resolver: Resolv.method(:getaddresses))
      @db = db
      @response_cache = ResponseCache.new(db)
      @fragment_cache = FragmentCache.new
      @repo = Repository.new(db)
      @auth = Authentication.new(db)
      @uploads = Uploads.new(upload_root)
      @media = Media.new(db, @uploads)
      @tokens = Tokens.new(Authentication.session_secret)
      @service = Service.new(repo, uploads, tokens: tokens, media: media, push_resolver: push_resolver)
      @hub = Realtime::Hub.new(db)
      freeze
    end
  end
end
