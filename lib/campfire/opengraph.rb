# frozen_string_literal: true

module Campfire
  class OpenGraph
    MAX_BYTES = 5 * 1024 * 1024
    IMAGE_TYPES = %w[image/jpeg image/png image/gif image/webp].freeze
    SKIP = /\.(?:zip|tar|gz|bz2|rar|7z|dmg|exe|msi|pkg|deb|iso|jpe?g|png|gif|bmp|mp4|mov|avi|mkv|wmv|flv|heic|heif|mp3|wav|ogg|aac|wma|webm|ogv|mpe?g)(?:\z|[?#])/i

    def initialize(resolver: Resolv.method(:getaddresses), transport: nil)
      @resolver = resolver
      @transport = transport || method(:request)
    end

    def from_url(url)
      uri, = public_location(url)
      return if SKIP.match?(uri.to_s)
      if %w[twitter.com www.twitter.com x.com www.x.com].include?(uri.host) && !["", "/"].include?(uri.path)
        uri.host = "fxtwitter.com"
      end
      response = fetch(uri.to_s, :get)
      return unless response && response[:code] == 200 && response[:type] == "text/html"
      doc = Nokogiri::HTML(response[:body], nil, "UTF-8")
      attrs = doc.css("meta[property],meta[name]").each_with_object({}) do |node, values|
        name = (node["property"] || node["name"]).to_s.delete_prefix("og:")
        values[name] = node["content"] if %w[title url image description].include?(name) && (node["property"] || node["name"]).start_with?("og:")
      end
      %w[title description].each { |key| attrs[key] = Nokogiri::HTML5.fragment(attrs[key].to_s).text.strip }
      return if attrs["title"].empty? || attrs["description"].empty?
      attrs["url"] = public_url?(attrs["url"]) ? attrs["url"] : url
      image = begin
        attrs["image"] && fetch(attrs["image"], :head)
      rescue Error, URI::InvalidURIError, SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError
        nil
      end
      attrs["image"] = nil unless image && image[:code] == 200 && IMAGE_TYPES.include?(image[:type])
      attrs.slice("title", "url", "image", "description")
    rescue Error, URI::InvalidURIError, SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError
      nil
    end

    private

    def public_location(url)
      uri = URI.parse(url.to_s)
      raise Error, "Invalid link" unless uri.is_a?(URI::HTTP) && uri.host && !uri.userinfo && uri.to_s.bytesize <= 4096
      addresses = @resolver.call(uri.hostname)
      raise Error, "Link is not public" unless !addresses.empty? && addresses.all? { |ip| OutboundHTTP.public_address?(ip) }
      [uri, addresses.first]
    end

    def public_url?(url)
      public_location(url)
      true
    rescue Error, URI::InvalidURIError, SocketError
      false
    end

    def fetch(url, method)
      10.times do
        uri, ip = public_location(url)
        response = @transport.call(uri, ip, method)
        if (300..399).cover?(response[:code]) && response[:location]
          url = URI.join(uri.to_s, response[:location]).to_s
        else
          return response
        end
      end
      nil
    end

    def request(uri, ip, method)
      http = Net::HTTP.new(uri.hostname, uri.port, nil)
      http.ipaddr = ip
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = http.read_timeout = http.write_timeout = 7
      result = nil
      Timeout.timeout(10) do
        http.start do |connection|
          request = (method == :head ? Net::HTTP::Head : Net::HTTP::Get).new(uri.request_uri)
          connection.request(request) do |response|
            body = +""
            if method == :get && response.code == "200" && response.content_type == "text/html"
              raise Error, "Link response is too large" if response.content_length.to_i > MAX_BYTES
              response.read_body do |chunk|
                raise Error, "Link response is too large" if body.bytesize + chunk.bytesize > MAX_BYTES
                body << chunk
              end
            end
            result = {code: response.code.to_i, type: response.content_type, location: response["location"], body: body}
          end
        end
      end
      result
    end
  end
end
