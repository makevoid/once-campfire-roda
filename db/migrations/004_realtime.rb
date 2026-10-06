# frozen_string_literal: true
Sequel.migration do
  change do
    alter_table(:events) { add_column :payload, String, text: true, null: false, default: "{}" }
    create_table(:broadcasts) do
      primary_key :id
      String :stream, null: false
      String :payload, text: true, null: false
      DateTime :created_at, null: false
    end
  end
end
