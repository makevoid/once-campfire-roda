# frozen_string_literal: true

module Campfire
  class API
    def initialize(view) = @view = view

    def messages(page)
      page.messages.map { |row| message(@view.context.message(row[:id])) }
    end

    def message(record)
      {id: record.id, created_at: record.created_at.utc.iso8601(3),
        body: {plain_text: record.plain_text_body, html: @view.tag.div(UI::RichText.new(@view).render(record.body.to_s, presentation: false), class: "lexxy-content")},
        creator: user(record.creator), room: {id: record[:room_id]}, url: message_url(record)}
    end

    def user(record)
      {id: record.id, name: record.name, role: record.role, avatar_url: "#{@view.request.base_url}#{@view.avatar_url(record)}"}
    end

    def boost(record)
      {id: record.id, content: record.content, created_at: record.created_at.utc.iso8601(3), booster: user(record.booster),
        message: {id: record[:message_id], url: message_url(record.message)}}
    end

    def message_url(record) = "#{@view.request.base_url}/rooms/#{record[:room_id]}/messages/#{record.id}"
  end
end
