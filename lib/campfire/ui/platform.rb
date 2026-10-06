# frozen_string_literal: true
module Campfire
  module UI
    class Platform
      def initialize(agent) = @agent = agent.to_s
      def ios? = @agent.match?(/iPhone|iPad/)
      def android? = @agent.include?("Android")
      def mac? = @agent.include?("Macintosh")
      def windows? = @agent.include?("Windows")
      def desktop? = !ios? && !android?
      def edge? = @agent.match?(/Edg(?:e|A|iOS)?\//)
      def firefox? = @agent.match?(/Firefox|FxiOS/)
      def chrome? = !edge? && @agent.match?(/Chrome|CriOS/)
      def safari? = !edge? && !firefox? && !chrome? && @agent.include?("Safari")
      def apple_messages? = @agent.match?(/facebookexternalhit/i) && @agent.match?(/Twitterbot/i)
      def browser = edge? ? "edge" : firefox? ? "firefox" : chrome? ? "chrome" : safari? ? "safari" : "browser"
      def operating_system
        return "iPhone" if @agent.include?("iPhone")
        return "iPad" if @agent.include?("iPad")
        return "Android" if android?
        return "macOS" if mac?
        return "Windows" if windows?
        return "ChromeOS" if @agent.include?("CrOS")
        @agent.include?("Linux") ? "Linux" : "operating system"
      end
    end
  end
end
