module RailsSettings
  class Settings < ActiveRecord::Base
    self.table_name = table_name_prefix + 'settings'

    class SettingNotFound < RuntimeError; end

    belongs_to :thing, polymorphic: true, optional: true

    # get the value field, YAML decoded
    def value
      RailsSettings::YAMLCoder.load(self[:value]) if self[:value].present?
    end

    # set the value field, YAML encoded
    def value=(new_value)
      encoded = new_value.to_yaml
      # Fail here rather than on every future read: an un-decodable row breaks get_all for
      # everyone, permanently, and gives no clue which call site wrote it.
      RailsSettings::YAMLCoder.load(encoded)
      self[:value] = encoded
    rescue Psych::DisallowedClass => e
      raise ArgumentError,
            "#{self.class} cannot store a value of type #{new_value.class}: it would not decode again " \
            "(#{e.message}). " \
            'Add the class to RailsSettings.config.yaml_permitted_classes if this is intended.'
    end

    class << self
      # get or set a variable with the variable as the called method
      def method_missing(method, *args, **kwargs, &block)
        method_name = method.to_s
        super(method, *args, **kwargs, &block)
      rescue NoMethodError
        scope_object = args[0] if args[0].is_a?(ActiveRecord::Base)

        # set a value for a variable
        if method_name[-1] == '='
          var_name = method_name.sub('=', '')
          value = args.first
          if scope_object
            self[var_name, value] = scope_object
          else
            self[var_name] = value
          end
        else
          # retrieve a value
          scope_object ? self[method_name, scope_object] : self[method_name]
        end
      end

      # destroy the specified settings record
      def destroy(var_name)
        # Apply the scope the same way reads and writes do, or a scoped row can never be found.
        var_name = respond_to?(:scoped_key) ? scoped_key(var_name.to_s) : var_name.to_s
        obj = object(var_name)
        raise SettingNotFound, "Setting variable \"#{var_name}\" not found" if obj.nil?

        obj.destroy
        true
      end

      # retrieve all settings as a hash (optionally starting with a given namespace)
      def get_all(starting_with = nil)
        vars = thing_scoped.select('var, value')
        # '!' rather than the default backslash: MySQL treats backslashes inside string literals
        # as escapes, which makes ESCAPE '\' a syntax error there.
        vars = vars.where("var LIKE ? ESCAPE '!'", "#{sanitize_sql_like(starting_with.to_s, '!')}%") if starting_with

        result = {}
        vars.each do |record|
          result[record.var] = record.value
        end

        defaults = {}
        if Default.enabled?
          defaults = starting_with.nil? ? Default.instance : Default.instance.select { |key, _| key.to_s.start_with?(starting_with.to_s) }
        end

        result.reverse_merge! defaults

        result.with_indifferent_access
      end

      def where(sql = nil)
        vars = thing_scoped.where(sql) if sql
        vars
      end

      # get a setting value by [] notation
      def [](var_name, object)
        if var = object(var_name, object)
          val = var.value
        elsif Default.enabled?
          val = Default[var_name]
        else
          val = nil
        end
        val
      end

      # set a setting value by [] notation
      def []=(var_name, value, object)
        var_name = var_name.to_s

        record = object(var_name, object)
        # An explicit object binds the new row to it; without one keep the receiver's own scope
        # (never `new_thing_scoped(nil)`, which is `unscoped` and would create a global row).
        record ||= object ? new_thing_scoped(object).new(var: var_name) : thing_scoped.new(var: var_name)
        record.value = value
        record.save!

        value
      end

      def merge!(var_name, hash_value)
        raise ArgumentError unless hash_value.is_a?(Hash)

        old_value = self[var_name] || {}
        raise TypeError, "Existing value is not a hash, can't merge!" unless old_value.is_a?(Hash)

        new_value = old_value.merge(hash_value)
        self[var_name] = new_value if new_value != old_value

        new_value
      end

      def object(var_name, obj = nil)
        return nil unless rails_initialized?
        return nil unless table_exists?

        scoped =
          if obj
            new_thing_scoped(obj)
          else
            thing_scoped
          end

        scoped.where(var: var_name.to_s).first
      end

      def thing_scoped
        unscoped.where('thing_type is NULL and thing_id is NULL')
      end

      private

      def new_thing_scoped(object)
        object ? unscoped.where(thing_type: object.class.base_class.to_s, thing_id: object.id) : unscoped
      end

      public

      def source(filename)
        Default.source(filename)
      end

      def rails_initialized?
        Rails.application && Rails.application.initialized?
      end
    end
  end
end
