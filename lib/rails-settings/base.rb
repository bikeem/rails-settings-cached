module RailsSettings
  class Base < Settings
    def rewrite_cache
      Rails.cache.write(cache_key, value)
    end

    def expire_cache
      Rails.cache.delete(cache_key)
    end

    def cache_key
      self.class.cache_key(var, thing)
    end

    class << self
      def cache_prefix_by_startup
        return @cache_prefix_by_startup if defined? @cache_prefix_by_startup
        return '' unless Default.enabled?
        @cache_prefix_by_startup = Digest::MD5.hexdigest(Default.instance.to_s)
      end

      def cache_prefix(&block)
        @cache_prefix = block
      end

      def cache_key(var_name, scope_object)
        scope = ['rails_settings_cached', cache_prefix_by_startup]
        scope << @cache_prefix.call if @cache_prefix
        scope << "#{scope_object.class.base_class.to_s}-#{scope_object.id}" if scope_object
        scope << var_name.to_s
        scope.join('/')
      end

      def [](key, object = nil)
        settings_key = scoped_key(key, object)
        object ||= @object
        return super(settings_key, object) unless rails_initialized?
        val = Rails.cache.fetch(cache_key(settings_key, object)) do
          super(settings_key, object)
        end
        val
      end

      # set a setting value by [] notation
      def []=(var_name, value, object = nil)
        settings_key = scoped_key(var_name, object)
        object ||= @object
        super(settings_key, value, object)
        Rails.cache.write(cache_key(settings_key, object), value)
        value
      end

      ##
      # Gets the key with the settings scope applied (if it was specified)
      #
      # @param [String] key setting key before scope is applied
      #
      # @return [String] key with the model's scope applied to it
      #
      def scoped_key(key, object = nil)
        output = key
        output = "#{@settings_scope.to_s}.#{key}" if @settings_scope.present?
        output = "#{object.class.base_class.to_s.downcase}.#{key}" if object.present?

        output
      end

      def save_default(key, value)
        Kernel.warn 'DEPRECATION WARNING: RailsSettings save_default is deprecated and it will removed in 0.7.0. ' <<
                    'Please use YAML file for default setting.'
        return false unless self[key].nil?
        self[key] = value
      end
    end
  end
end

