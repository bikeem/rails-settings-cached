module RailsSettings
  # Per-thread state owned by the gem -- per-fiber when the app sets
  # config.active_support.isolation_level = :fiber, since IsolatedExecutionState follows Rails.
  #
  # All of it is request/job scoped and cleared together when the executor completes, so the keys
  # live in one place rather than being spread across the classes that happen to read them.
  module ExecutionState
    OBJECT_KEY = :rails_settings_cached_scope_object       # the record `record.settings` bound
    SCOPE_KEY  = :rails_settings_cached_settings_scope     # that record's settings_scope
    MEMO_KEY   = :rails_settings_cached_transaction_memo   # [transaction, {cache_key => value}]
    DIRTY_KEY  = :rails_settings_cached_dirty_keys         # cache keys this transaction has written

    KEYS = [OBJECT_KEY, SCOPE_KEY, MEMO_KEY, DIRTY_KEY].freeze

    class << self
      def [](key)
        ActiveSupport::IsolatedExecutionState[key]
      end

      def []=(key, value)
        ActiveSupport::IsolatedExecutionState[key] = value
      end

      def clear!
        KEYS.each { |key| ActiveSupport::IsolatedExecutionState.delete(key) }
        nil
      end
    end
  end
end
