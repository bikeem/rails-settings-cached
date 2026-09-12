module RailsSettings
  # What `record.settings` returns: a small handle bound to one record.
  #
  # It deliberately is NOT RailsSettings::ScopedSettings. Every call re-establishes the binding for
  # its own duration and restores whatever was there before, so a handle held across another
  # record's `settings` call still reads its own record -- which a shared binding cannot do.
  # Operations are delegated to the ScopedSettings class methods, so behaviour, and any stub placed
  # on that class, are unchanged.
  class Scope
    # Protocol methods Ruby and ActiveSupport consult via respond_to? to decide how to treat an
    # object -- implicit conversion, and `blank?` checking for `empty?`. The settings class answers
    # false to all of them today, so this changes nothing now; it is here so that a method added to
    # that class later cannot silently change what a handle *is*.
    NOT_DELEGATED = %i[empty? to_hash to_ary to_str to_a].freeze

    # No method undefining: across the consumer's 572 setting keys none collides with an Object
    # method, and undefining would break `==` and friends for callers and test matchers. A setting
    # whose name does collide is still reachable as `settings[:name]`.

    def initialize(object, settings_scope, settings_class = RailsSettings::ScopedSettings)
      @object = object
      @settings_scope = settings_scope
      @settings_class = settings_class
    end

    # Double-underscored so it cannot shadow a setting of the same name.
    def __scope_object__
      @object
    end

    def [](key, object = nil)
      with_scope { @settings_class[key, object] }
    end

    # `handle[key, value] = object` arrives here as ([key, value], object).
    def []=(*args)
      value = args.pop
      with_scope { @settings_class.send(:[]=, *args, value) }
    end

    def method_missing(name, *args, **kwargs, &block)
      with_scope { @settings_class.public_send(name, *args, **kwargs, &block) }
    end

    # Answers for the delegated API exactly as the class did, so `settings.respond_to?(:get_all)`
    # and `settings.try(:get_all)` keep working. Plain setting keys still answer false -- the class
    # defines no respond_to_missing? either -- so `try(:some_key)` stays a no-op rather than a query.
    def respond_to_missing?(name, include_private = false)
      return false if NOT_DELEGATED.include?(name)
      @settings_class.respond_to?(name, include_private) || super
    end

    def inspect
      "#<#{self.class.name} #{@object.class}##{@object.id} scope=#{@settings_scope.inspect}>"
    end

    # Object#as_json falls through to instance_values, which would serialise the bound record --
    # into logs, Sentry breadcrumbs and anything that renders a handle by accident.
    def as_json(_options = nil)
      inspect
    end

    def to_s
      inspect
    end

    private

    def with_scope
      state  = RailsSettings::ExecutionState
      prev_o = state[state::OBJECT_KEY]
      prev_s = state[state::SCOPE_KEY]
      state[state::OBJECT_KEY] = @object
      state[state::SCOPE_KEY]  = @settings_scope
      yield
    ensure
      state[state::OBJECT_KEY] = prev_o
      state[state::SCOPE_KEY]  = prev_s
    end
  end
end
