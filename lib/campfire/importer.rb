# frozen_string_literal: true
require_relative "../campfire"

module Campfire
  # Import into a NEW Roda database. The Rails database is opened read-only and
  # never migrated in place; old signed cookies intentionally do not carry over.
  class Importer
    TABLES = %i[accounts users rooms memberships boosts searches bans].freeze
    def initialize(source:, target:, rails_storage: nil)
      @source = Sequel.sqlite(File.expand_path(source), readonly: true)
      @target = target
      @db = target.db
      @rails_storage = rails_storage && File.expand_path(rails_storage)
      @files = []
      @counts = {}
    end

    def run
      raise "Destination must be empty" if @db[:accounts].any? || @db[:users].any?
      @db.transaction(mode: :immediate) do
        %i[accounts users rooms memberships].each { |table| copy_table(table) }
        @source[:messages].order(:id).each do |row|
          text = @source[:action_text_rich_texts].where(record_type: "Message", record_id: row[:id], name: "body").get(:body)
          content = Content.new(text)
          @db[:messages].insert(row.merge(body: content.html, plain_text: content.text).slice(*columns(:messages)))
        end
        @counts[:messages] = @db[:messages].count
        %i[boosts searches bans webhooks push_subscriptions].each { |table| copy_table(table) }
        @db[:rooms].where(type: "Rooms::Direct").each do |room|
          ids = @db[:memberships].where(room_id: room[:id]).order(:user_id).select_map(:user_id)
          @db[:rooms].where(id: room[:id]).update(direct_key: ids.join(","))
        end
        import_attachments if @rails_storage
      end
      @db.run("ANALYZE")
      @counts
    rescue StandardError
      @files.each { |path| FileUtils.rm_f(path) }
      raise
    ensure
      @source.disconnect
    end

    private

    def columns(table) = @db.schema(table).map(&:first)

    def copy_table(table)
      return unless @source.table_exists?(table)
      selected = columns(table)
      @source[table].order(:id).each do |row|
        row = row.slice(*selected)
        row[:settings] ||= "{}" if table == :accounts
        row[:email_address] = row[:email_address]&.downcase if table == :users
        @db[table].insert(row)
      end
      @counts[table] = @db[table].count
    end

    def import_attachments
      return unless @source.table_exists?(:active_storage_attachments)
      @source[:active_storage_attachments].where(record_type: "Message", name: "attachment").each do |attachment|
        blob = @source[:active_storage_blobs][id: attachment[:blob_id]]
        next unless blob && @db[:messages][id: attachment[:record_id]]
        key = blob[:key]
        raise "Invalid Rails blob key" unless /\A[A-Za-z0-9_-]+\z/.match?(key)
        source = File.join(@rails_storage, key[0, 2], key[2, 2], key)
        raise "Missing attachment: #{blob[:filename]} (#{key})" unless File.file?(source)
        # Reject symlinks that escape the explicitly selected storage directory.
        raise "Attachment outside source storage" unless File.realpath(source).start_with?(File.realpath(@rails_storage) + "/")
        new_key = SecureRandom.hex(32)
        destination = @target.uploads.path(new_key)
        FileUtils.cp(source, destination)
        @files << destination
        @db[:attachments].insert(message_id: attachment[:record_id], key: new_key, filename: blob[:filename],
          content_type: blob[:content_type] || "application/octet-stream", byte_size: File.size(source), created_at: attachment[:created_at])
        message = @db[:messages][id: attachment[:record_id]]
        @db[:messages].where(id: message[:id]).update(plain_text: blob[:filename]) if message[:plain_text].empty?
      end
      @counts[:attachments] = @db[:attachments].count
    end
  end
end
