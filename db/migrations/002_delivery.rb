# frozen_string_literal: true
Sequel.migration do
  change do
    create_table(:push_subscriptions) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      String :endpoint, null: false, unique: true
      String :p256dh_key, null: false
      String :auth_key, null: false
      String :user_agent
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index :user_id
    end
    create_table(:webhooks) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade, unique: true
      String :url, null: false
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
    end
    create_table(:jobs) do
      primary_key :id
      String :kind, null: false
      String :payload, null: false, text: true
      String :dedup_key, unique: true
      Integer :attempts, default: 0, null: false
      DateTime :available_at, null: false
      DateTime :locked_at
      String :lock_token
      String :last_error
      DateTime :created_at, null: false
      index [:available_at, :id]
    end
  end
end
