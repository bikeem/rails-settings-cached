module RailsSettings
  class ScopedSettings < Base
    # Raised when ScopedSettings is used on a thread/fiber where no `record.settings` call set the
    # scope (or the request/job that set it has completed) -- a loud failure rather than a silent
    # global read. Note this does NOT cover a STALE binding: because `settings` returns this class,
    # a handle held across another record's `settings` call is silently rebound to that record.
    # Chain the call (`record.settings.foo`); see the README.
    class MissingScope < StandardError; end

    class << self
      # Scope state is per thread (or per fiber when the app sets
      # config.active_support.isolation_level = :fiber), never a class ivar.
      def for_thing(object, settings_scope)
        ExecutionState[ExecutionState::OBJECT_KEY] = object
        ExecutionState[ExecutionState::SCOPE_KEY]  = settings_scope
        self
      end

      # Drops everything, the transaction memo included: it pins an ActiveRecord::Transaction and
      # through it a connection adapter, which must not linger on a pooled thread.
      def clear_current!
        ExecutionState.clear!
      end

      def thing_scoped
        object = current_object
        assert_scope!(object)
        unscoped.where(thing_type: object.class.base_class.to_s, thing_id: object.id)
      end

      private

      # Private for the same reason as on Base: the read API is method_missing, so any public
      # class method permanently claims a settings key of that name.
      def current_object
        ExecutionState[ExecutionState::OBJECT_KEY]
      end

      def current_settings_scope
        ExecutionState[ExecutionState::SCOPE_KEY]
      end

      def assert_scope!(object)
        if object.nil?
          raise MissingScope, 'RailsSettings::ScopedSettings used without a scope object; call `record.settings` first'
        end
        return unless object.id.nil?

        # Without an id the row is keyed on thing_id NULL, so every unsaved record of this class
        # would share one row and one cache entry.
        raise MissingScope, "#{object.class} must be saved before its settings can be read or written"
      end
    end
  end
end
