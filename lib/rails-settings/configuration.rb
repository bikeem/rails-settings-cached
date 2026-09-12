require 'yaml'

module RailsSettings
  class Configuration
    DEFAULT_CACHE_EXPIRES_IN = 12 * 60 * 60 # seconds

    attr_writer :yaml_permitted_classes, :yaml_aliases, :yaml_unsafe_load, :cache_expires_in

    # ActiveRecord's own allow-list plus what settings rows have always contained. Memoised so
    # that `config.yaml_permitted_classes << MyClass` actually sticks -- rebuilding the array on
    # every read would make that append a silent no-op.
    def yaml_permitted_classes
      @yaml_permitted_classes ||= default_permitted_classes
    end

    # A reader that is descheduled between its database read and its cache write can publish a
    # stale value after a writer has invalidated the key. No invalidation scheme closes that race,
    # so entries expire. Set to nil to keep them forever (the pre-0.8 behaviour).
    def cache_expires_in
      defined?(@cache_expires_in) ? @cache_expires_in : DEFAULT_CACHE_EXPIRES_IN
    end

    def yaml_aliases
      @yaml_aliases.nil? ? true : @yaml_aliases
    end

    def yaml_unsafe_load
      return @yaml_unsafe_load unless @yaml_unsafe_load.nil?
      active_record_config(:use_yaml_unsafe_load) { false }
    end

    private

    # `defined?` rather than a bare constant reference: ActiveRecord may not be loaded at all when
    # the configuration is read, and a bare `ActiveRecord` would raise NameError there.
    def active_record_config(name)
      return yield unless defined?(::ActiveRecord) && ::ActiveRecord.respond_to?(name)
      ::ActiveRecord.public_send(name)
    end

    def default_permitted_classes
      base = active_record_config(:yaml_column_permitted_classes) { [] }
      (base + [Symbol, Time, Date, ActiveSupport::HashWithIndifferentAccess]).uniq
    end
  end

  # Built at load time: `||=` on first access can race between threads, and the loser's
  # `configure` block would be written to a Configuration nobody reads.
  @config = Configuration.new

  class << self
    attr_reader :config

    def configure
      yield config
    end
  end

  # Single decode path for settings rows and the defaults file.
  module YAMLCoder
    def self.load(string)
      return nil if string.nil?
      cfg = RailsSettings.config
      if cfg.yaml_unsafe_load
        YAML.unsafe_load(string)
      else
        YAML.safe_load(string, permitted_classes: cfg.yaml_permitted_classes, aliases: cfg.yaml_aliases)
      end
    end
  end
end
