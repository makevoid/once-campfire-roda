# frozen_string_literal: true

ENV["RACK_ENV"] = "test"
require "bundler/setup"
require "minitest/autorun"
require "rack/test"
require "tmpdir"
require_relative "../app"

class CampfireTest < Minitest::Test
  include Rack::Test::Methods
  PASSWORD = "a secure test password"
  DIGEST = BCrypt::Password.create(PASSWORD, cost: 4).to_s
  attr_reader :db, :container, :service, :repo, :admin, :member, :outsider, :room

  def setup
    @directory = Dir.mktmpdir("campfire-test-")
    @db = Campfire::Database.connect(path: database_path)
    Campfire::Database.migrate(db)
    @container = Campfire::Container.new(db: db, upload_root: File.join(@directory, "files"), push_resolver: ->(*) { ["8.8.8.8"] })
    @service, @repo = container.service, container.repo
    now = Time.now.utc
    db[:accounts].insert(name: "Test Campfire", join_code: "invite", settings: "{}", created_at: now, updated_at: now)
    @admin = make_user("Admin", role: 1)
    @member = make_user("Member")
    @outsider = make_user("Outsider")
    @room = service.create_room(admin, {"name" => "Watercooler"}, type: "Rooms::Open")
    @app = Campfire::App.build(container)
  end

  def app = @app
  def database_path = ":memory:"
  def teardown
    container.response_cache.clear
    db.disconnect
    FileUtils.remove_entry(@directory)
  end

  def make_user(name, role: 0)
    service.create_user({"name" => name, "email_address" => "#{name.downcase}@example.com"}, role: role, digest: DIGEST)
  end

  def sign_in(user = admin)
    get "/session/new"
    @csrf = csrf_from_response
    post "/session", {email_address: user[:email_address], password: PASSWORD, authenticity_token: @csrf}
    assert_equal 302, last_response.status, last_response.body
    get "/rooms/#{room.id}"
    assert_equal 200, last_response.status, last_response.body
    @csrf = csrf_from_response
  end

  def csrf_from_response
    CGI.unescapeHTML(last_response.body[/<meta name="csrf-token" content="([^"]+)"/, 1] || "")
  end

  def mutate(method, path, values = {}, csrf: true)
    header "Sec-Fetch-Site", csrf ? "same-origin" : "cross-site"
    public_send(method, path, values)
    header "Sec-Fetch-Site", nil
  end

  def post_message(user = admin, target = room, text = "Coffee is ready", **extra)
    service.post_message(user, target.id, {"body" => text}.merge(extra.transform_keys(&:to_s)))
  end

  def mention(user)
    token = container.tokens.generate(user.id, purpose: :mention)
    %(<action-text-attachment sgid="#{token}" content-type="application/vnd.campfire.mention"></action-text-attachment>)
  end
end
