# frozen_string_literal: true
require_relative "test_helper"
require_relative "../lib/campfire/importer"

class ImporterTest < CampfireTest
  def test_import_preserves_ids_passwords_permissions_and_search_without_changing_source
    source_path = File.join(@directory, "rails.sqlite3")
    source = Sequel.sqlite(source_path)
    %i[accounts users rooms memberships messages boosts searches bans webhooks push_subscriptions].each do |table|
      schema = db.schema(table).reject { |name, _| (table == :messages && %i[body plain_text].include?(name)) || name == :direct_key }
      source.create_table(table) do
        schema.each do |name, options|
          if options[:primary_key]
            primary_key name
          else
            column name, options[:type]
          end
        end
      end
      db[table].each { |row| source[table].insert(row.slice(*schema.map(&:first))) }
    end
    source.create_table(:action_text_rich_texts) do
      primary_key :id
      String :record_type
      Integer :record_id
      String :name
      String :body, text: true
    end
    now = Time.now.utc
    source[:messages].insert(id: 777, room_id: room.id, creator_id: member.id, client_message_id: "rails-message", created_at: now, updated_at: now)
    signed_id = Base64.urlsafe_encode64(JSON.generate(_rails: {data: "gid://campfire/User/#{member.id}"})) + "--old-signature"
    source[:action_text_rich_texts].insert(record_type: "Message", record_id: 777, name: "body", body: %(<p>Imported coffee</p><script>bad()</script> <action-text-attachment sgid="#{signed_id}"></action-text-attachment>))
    source.create_table(:active_storage_blobs) do
      primary_key :id
      String :key
      String :filename
      String :content_type
      String :metadata
    end
    source.create_table(:active_storage_attachments) do
      primary_key :id
      String :record_type
      Integer :record_id
      String :name
      Integer :blob_id
      DateTime :created_at
    end
    storage = File.join(@directory, "rails-storage")
    [["Message", 777, "attachment"], ["User", member.id, "avatar"], ["Account", 1, "logo"]].each_with_index do |(type, id, name), index|
      key = "ab12file#{index}"
      path = File.join(storage, "ab", "12", key)
      FileUtils.mkdir_p(File.dirname(path))
      Vips::Image.black(20, 10).write_to_file("#{path}.png")
      File.rename("#{path}.png", path)
      blob = source[:active_storage_blobs].insert(key: key, filename: "#{name}.png", content_type: "image/png", metadata: '{"width":20,"height":10}')
      source[:active_storage_attachments].insert(record_type: type, record_id: id, name: name, blob_id: blob, created_at: now)
    end
    source.disconnect
    before = Digest::SHA256.file(source_path).hexdigest
    target_db = Campfire::Database.connect(path: File.join(@directory, "imported.sqlite3"))
    Campfire::Database.migrate(target_db)
    target = Campfire::Container.new(db: target_db, upload_root: File.join(@directory, "imported-files"))
    counts = Campfire::Importer.new(source: source_path, target: target, rails_storage: storage).run
    assert_equal 1, counts[:messages]
    assert_equal before, Digest::SHA256.file(source_path).hexdigest
    imported = target_db[:messages][id: 777]
    assert_equal "Imported coffee\n @Member", imported[:plain_text]
    refute_includes imported[:body], "bad()"
    assert_equal [member.id], target.service.mentioned_user_ids(imported[:body])
    assert_equal 1, counts[:attachments]
    assert_equal 2, counts[:media]
    assert_equal "avatar.png", target.media.find("User", member.id, "avatar")[:filename]
    assert_equal "image/png", target.media.variant(target.media.find("Account", 1, "logo"), :logo).last
    assert_equal DIGEST, target_db[:users][id: member.id][:password_digest]
    assert_equal [777], target.repo.search(target.repo.user(member.id), "coffee").messages.map { |m| m[:id] }
    assert_equal room.id, target.repo.room(target.repo.user(member.id), room.id).id
    assert_equal 0, target_db[:sessions].count
    assert_raises(RuntimeError) { Campfire::Importer.new(source: source_path, target: target).run }
  ensure
    source&.disconnect
    target_db&.disconnect
  end

  def test_snapshot_includes_committed_wal_data
    path = File.join(@directory, "source.sqlite3")
    source = Campfire::Database.connect(path: path)
    source.create_table(:values) { Integer :value }
    source[:values].insert(value: 123)
    copy = File.join(@directory, "copy.sqlite3")
    Campfire::Database.snapshot(path, copy)
    target = Sequel.sqlite(copy)
    assert_equal 123, target[:values].get(:value)
    assert_raises(RuntimeError) { Campfire::Database.snapshot(path, copy) }
  ensure
    source&.disconnect
    target&.disconnect
  end
end
