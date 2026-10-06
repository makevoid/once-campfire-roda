# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:accounts) do
      primary_key :id
      String :name, null: false
      String :join_code, null: false
      String :custom_styles, text: true
      String :settings, text: true, default: "{}", null: false
      Integer :singleton_guard, default: 0, null: false, unique: true
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
    end
    create_table(:users) do
      primary_key :id
      String :name, null: false
      String :email_address, unique: true, collate: "NOCASE"
      String :password_digest
      String :bio, text: true
      String :bot_token, unique: true
      Integer :role, default: 0, null: false
      Integer :status, default: 0, null: false
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
    end
    create_table(:rooms) do
      primary_key :id
      foreign_key :creator_id, :users, null: false
      String :name
      String :type, null: false
      String :direct_key, unique: true
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
    end
    create_table(:memberships) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      foreign_key :room_id, :rooms, null: false, on_delete: :cascade
      String :involvement, null: false, default: "mentions"
      Integer :connections, default: 0, null: false
      DateTime :connected_at
      DateTime :unread_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index [:room_id, :user_id], unique: true
      index [:user_id, :room_id]
    end
    create_table(:messages) do
      primary_key :id
      foreign_key :room_id, :rooms, null: false, on_delete: :cascade
      foreign_key :creator_id, :users, null: false
      String :client_message_id, null: false
      String :body, text: true, null: false, default: ""
      String :plain_text, text: true, null: false, default: ""
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index [:room_id, :created_at, :id]
      index [:room_id, :updated_at, :id]
      index [:room_id, :creator_id, :client_message_id], unique: true
      index :creator_id
    end
    create_table(:boosts) do
      primary_key :id
      foreign_key :message_id, :messages, null: false, on_delete: :cascade
      foreign_key :booster_id, :users, null: false
      String :content, null: false
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index :message_id
    end
    create_table(:sessions) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      String :token, null: false, unique: true
      String :ip_address
      String :user_agent
      DateTime :last_active_at, null: false
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index :user_id
    end
    create_table(:searches) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      String :query, null: false
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index [:user_id, :query], unique: true
    end
    create_table(:bans) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      String :ip_address, null: false
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index :ip_address
    end
    create_table(:attachments) do
      primary_key :id
      foreign_key :message_id, :messages, null: false, on_delete: :cascade
      String :key, null: false, unique: true
      String :filename, null: false
      String :content_type, null: false
      Integer :byte_size, null: false
      DateTime :created_at, null: false
      index :message_id
    end
    # Durable change feed supports multiple Puma processes, edits and deletions.
    create_table(:events) do
      primary_key :id
      foreign_key :room_id, :rooms, null: false, on_delete: :cascade
      Integer :message_id
      String :kind, null: false
      DateTime :created_at, null: false
      index [:room_id, :id]
    end
    create_table(:login_attempts) do
      String :key, primary_key: true
      Integer :attempts, default: 0, null: false
      Integer :window, null: false
    end
    run "CREATE VIRTUAL TABLE message_search_index USING fts5(body, tokenize = 'porter')"
    run <<~SQL
      CREATE TRIGGER messages_search_insert AFTER INSERT ON messages BEGIN
        INSERT INTO message_search_index(rowid, body) VALUES (new.id, new.plain_text);
      END
    SQL
    run <<~SQL
      CREATE TRIGGER messages_search_update AFTER UPDATE OF plain_text ON messages BEGIN
        UPDATE message_search_index SET body = new.plain_text WHERE rowid = new.id;
      END
    SQL
    run <<~SQL
      CREATE TRIGGER messages_search_delete AFTER DELETE ON messages BEGIN
        DELETE FROM message_search_index WHERE rowid = old.id;
      END
    SQL
  end
end
