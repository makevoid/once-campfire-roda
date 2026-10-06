# frozen_string_literal: true

require "erb"
require "time"

module Campfire
  class Renderer
    class Templates; end
    PARAMETERS = {
      "layout" => "title:, content:, csrf:, user:, sidebar:",
      "form" => "title:, action:, csrf:, fields:, method:, extras:, submit:",
      "room" => "room:, name:, page:, user:, csrf:, cursor:",
      "search" => "query:, page:, user:, csrf:, recent:"
    }.freeze

    PARAMETERS.each do |name, parameters|
      path = File.expand_path("../../views/#{name}.erb", __dir__)
      ERB.new(File.read(path), trim_mode: "-").def_method(Templates, "#{name}(view:, #{parameters})", path)
    end

    def initialize
      @templates = Templates.new.freeze
    end

    def template(name, **locals)
      @templates.public_send(name, view: self, **locals)
    end

    def h(value) = CGI.escapeHTML(value.to_s)

    def page(title:, content:, csrf:, user: nil, sidebar: nil)
      template("layout", title: title, content: content, csrf: csrf, user: user, sidebar: sidebar)
    end

    def sidebar(data)
      output = +'<nav aria-label="Rooms"><a class="brand" href="/">🔥 Campfire</a><a href="/searches">Search messages</a><h2>Rooms <a href="/rooms/opens/new" aria-label="New room">+</a></h2><div id="shared_rooms">'
      data[:shared].each { |room| room_link(output, room) }
      output << '</div><h2>Direct messages <a href="/rooms/directs/new" aria-label="New direct message">+</a></h2><div id="direct_rooms">'
      data[:direct].each { |room| room_link(output, room) }
      output << '</div><div class="people">'
      data[:people].each { |person| output << %(<a href="/rooms/directs/new?user_id=#{person[:id]}">#{h(person[:name])}</a>) }
      output << '</div></nav>'
    end

    def messages(page, user: nil, controls: true)
      output = +""
      page.messages.each do |message|
        id = message[:id]
        output << %(<article class="message" id="message_#{id}" data-message-id="#{id}" data-client-id="#{h(message[:client_message_id])}"><div class="avatar">#{h(message[:creator_name].to_s[0, 1])}</div><div class="message-main"><header><a href="/users/#{message[:creator_id]}">#{h(message[:creator_name])}</a><a class="time" href="/rooms/#{message[:room_id]}/@#{id}"><time datetime="#{message[:created_at].iso8601}">#{message[:created_at].strftime("%b %-d, %H:%M")}</time></a></header><div class="body">#{message[:body]}</div>)
        page.attachments.fetch(id, []).each do |attachment|
          if Uploads::IMAGE_TYPES.include?(attachment[:content_type])
            output << %(<a href="/attachments/#{attachment[:id]}"><img class="image-preview" loading="lazy" src="/attachments/#{attachment[:id]}?inline=1" alt="#{h(attachment[:filename])}"></a>)
          end
          output << %(<a class="attachment" href="/attachments/#{attachment[:id]}">📎 #{h(attachment[:filename])} (#{attachment[:byte_size]} bytes)</a>)
        end
        output << '<div class="boosts">'
        page.boosts.fetch(id, []).each do |boost|
          if user && boost[:booster_id] == user.id
            output << %(<button type="button" class="boost" title="#{h(boost[:booster_name])}" data-boost-id="#{boost[:id]}">#{h(boost[:content])}</button>)
          else
            output << %(<span class="boost" title="#{h(boost[:booster_name])}">#{h(boost[:content])}</span>)
          end
        end
        output << '</div>'
        if controls && user
          output << '<div class="message-actions"><button type="button" data-action="boost">Boost</button>'
          if user.can_administer?(message)
            output << %(<a href="/rooms/#{message[:room_id]}/messages/#{id}/edit">Edit</a><button type="button" data-action="delete">Delete</button>)
          end
          output << '</div>'
        end
        output << '</div></article>'
      end
      output
    end

    def json_messages(page)
      page.messages.map do |message|
        {id: message[:id], client_message_id: message[:client_message_id], created_at: message[:created_at].iso8601(6),
          body: {plain_text: message[:plain_text], html: message[:body]},
          creator: {id: message[:creator_id], name: message[:creator_name]}, room: {id: message[:room_id]},
          boosts: page.boosts.fetch(message[:id], []).map { |b| {id: b[:id], content: b[:content], booster: {id: b[:booster_id], name: b[:booster_name]}} },
          attachments: page.attachments.fetch(message[:id], []).map { |a| {id: a[:id], filename: a[:filename], byte_size: a[:byte_size], url: "/attachments/#{a[:id]}"} },
          url: "/rooms/#{message[:room_id]}/messages/#{message[:id]}"}
      end
    end

    def form(title:, action:, csrf:, fields:, method: "post", extras: "", submit: "Save")
      template("form", title: title, action: action, csrf: csrf, fields: fields, method: method, extras: extras, submit: submit)
    end

    private

    def room_link(output, room)
      output << %(<a id="room_#{room[:id]}_list" class="room-link#{room[:unread_at] ? ' unread' : ''}" href="/rooms/#{room[:id]}"><span>#{room[:type] == 'Rooms::Closed' ? '🔒' : '#'}</span> #{h(room[:name])}#{room[:unread_at] ? '<span class="unread-dot" aria-label="Unread">●</span>' : ''}</a>)
    end
  end
end
