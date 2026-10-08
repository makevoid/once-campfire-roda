# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:rooms) { add_column :messages_count, Integer, null: false, default: 0 }
    run "UPDATE rooms SET messages_count = (SELECT COUNT(*) FROM messages WHERE room_id = rooms.id)"
    run <<~SQL
      CREATE TRIGGER messages_count_insert AFTER INSERT ON messages BEGIN
        UPDATE rooms SET messages_count = messages_count + 1 WHERE id = new.room_id;
      END
    SQL
    run <<~SQL
      CREATE TRIGGER messages_count_delete AFTER DELETE ON messages BEGIN
        UPDATE rooms SET messages_count = messages_count - 1 WHERE id = old.room_id;
      END
    SQL
    run <<~SQL
      CREATE TRIGGER messages_count_move AFTER UPDATE OF room_id ON messages
      WHEN old.room_id IS NOT new.room_id BEGIN
        UPDATE rooms SET messages_count = messages_count - 1 WHERE id = old.room_id;
        UPDATE rooms SET messages_count = messages_count + 1 WHERE id = new.room_id;
      END
    SQL
    run "DROP TRIGGER messages_search_update"
    run <<~SQL
      CREATE TRIGGER messages_search_update AFTER UPDATE OF plain_text, id ON messages
      WHEN old.plain_text IS NOT new.plain_text OR old.id IS NOT new.id BEGIN
        DELETE FROM message_search_index WHERE rowid = old.id;
        INSERT INTO message_search_index(rowid, body) VALUES (new.id, new.plain_text);
      END
    SQL
  end

  down do
    %w[messages_count_insert messages_count_delete messages_count_move messages_search_update].each { |name| run "DROP TRIGGER #{name}" }
    alter_table(:rooms) { drop_column :messages_count }
    run <<~SQL
      CREATE TRIGGER messages_search_update AFTER UPDATE OF plain_text ON messages BEGIN
        UPDATE message_search_index SET body = new.plain_text WHERE rowid = new.id;
      END
    SQL
  end
end
