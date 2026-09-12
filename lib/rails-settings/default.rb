require 'digest/md5'

module RailsSettings
  class Default < ::Hash
    class MissingKey < StandardError; end

    class << self
      def enabled?
        source_path && File.exist?(source_path)
      end

      def source(value = nil)
        @source ||= value
      end

      def source_path
        @source || Rails.root.join('config/app.yml')
      end

      def [](key)
        # foo.bar.dar Nested fetch value
        return instance[key] if instance.has_key?(key)
        keys = key.to_s.split('.')
        val = instance
        keys.each do |k|
          val = val.fetch(k.to_s, nil)
          break if val.nil?
        end
        val
      end

      def instance
        return @instance if defined? @instance
        @instance = new
        @instance
      end
    end

    def initialize
      content = File.read(self.class.source_path)
      hash = content.empty? ? {} : RailsSettings::YAMLCoder.load(ERB.new(content).result).to_hash
      hash = hash[Rails.env] || {}
      self.replace hash
    end
  end
end
