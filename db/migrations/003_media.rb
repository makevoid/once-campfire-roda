# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:media) do
      primary_key :id
      String :owner_type, null: false
      Integer :owner_id, null: false
      String :purpose, null: false
      String :key, null: false, unique: true
      String :filename, null: false
      String :content_type, null: false
      Integer :byte_size, null: false
      String :metadata, text: true, default: "{}", null: false
      DateTime :created_at, null: false
      index [:owner_type, :owner_id, :purpose], unique: true
    end
    alter_table(:attachments) do
      add_column :metadata, String, text: true, default: "{}", null: false
    end
  end
end
