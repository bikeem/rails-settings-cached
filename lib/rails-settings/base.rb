require 'set'

module RailsSettings
  class Base < Settings
    # Cap on the per-transaction read memo, so a batch job that touches an unbounded number of
    # distinct keys inside one transaction cannot grow it without limit.
    TRANSACTION_MEMO_LIMIT = 1_000

    def expire_cache
      Rails.cache.delete(cache_key)
    end

    # Built from the stored columns, never from the `thing` association: a soft-deleted or
    # otherwise out-of-scope record makes `thing` nil, which would yield the GLOBAL key -- leaving
    # the scoped entry stale forever and evicting an unrelated key. It also avoids a SELECT.
    def cache_key
      self.class.send(:cache_key_for, var, thing_type, thing_id)
    end

    # Runs inside the transaction, unlike after_commit -- which is the point. It drops both the
    # shared-cache entry and the per-transaction memo, so nothing later in this transaction can
    # serve the value this write replaced. Covers destroys and plain `Setting.new(...).save!`,
    # neither of which goes through []=. after_commit :expire_cache drops it again once durable.
    def invalidate_caches
      ckey = cache_key
      expire_cache
      self.class.send(:forget_memoised, ckey)
      # Mark it written-by-this-transaction. Until the transaction ends, reads of this key must
      # bypass the shared cache: another connection can repopulate the entry with the pre-image
      # (it cannot see our uncommitted row) and we would then read our own write back as stale.
      self.class.send(:mark_dirty, ckey)
    end

    # Fires on commit and on rollback, so the mark is released exactly when the write's fate is
    # settled -- and survives a savepoint release, which runs no callbacks.
    def release_dirty_key
      self.class.send(:unmark_dirty, cache_key)
    end

    class << self
      def cache_prefix_by_startup
        return @cache_prefix_by_startup if defined? @cache_prefix_by_startup
        return '' unless Default.enabled?
        @cache_prefix_by_startup = Digest::MD5.hexdigest(Default.instance.to_s)
      end

      # Stored on Base so every subclass shares it -- including ScopedSettings, which is a sibling
      # of the app's own Setting class. Per-class storage silently gave `record.settings` and
      # `Setting[...]` two different keys for the same row.
      def cache_prefix(&block)
        RailsSettings::Base.instance_variable_set(:@cache_prefix, block)
      end

      def cache_key(var_name, scope_object)
        cache_key_for(var_name,
                      scope_object && scope_object.class.base_class.to_s,
                      scope_object && scope_object.id)
      end

      def [](key, object = nil)
        settings_key = scoped_key(key, object)
        object ||= current_object
        assert_scope!(object)
        return super(settings_key, object) unless rails_initialized?

        ckey = cache_key(settings_key, object)
        txn  = open_transaction
        if txn.nil?
          # No transaction: drop anything left over from the last one rather than pinning a
          # finished transaction (and its connection) on a pooled thread.
          ExecutionState[ExecutionState::MEMO_KEY] = nil
          ExecutionState[ExecutionState::DIRTY_KEY] = nil
          return Rails.cache.fetch(ckey, expires_in: RailsSettings.config.cache_expires_in) { super(settings_key, object) }
        end

        # While any transaction is open, nothing is published to the shared cache: anything read
        # here can still be rolled back, and these keys have no expiry, so one bad publish is
        # permanent and fleet-wide. Memoise per transaction instead, so a loop of reads costs one
        # query rather than one per iteration. The cost is one query per transaction for a key
        # that is only ever read inside one -- see the README.
        memo = transaction_memo(txn)
        return memo[ckey] if memo.key?(ckey)

        # A key this transaction has written must come from the database: the shared entry may have
        # been repopulated with the pre-image by another connection since we deleted it.
        return memo[ckey] = super(settings_key, object) if dirty_keys.include?(ckey)

        # Otherwise the shared cache holds committed data and is safe to read (never to write).
        # One round trip, and a cached nil or false counts as a hit.
        hit = Rails.cache.read_multi(ckey)
        memo[ckey] = hit.key?(ckey) ? hit[ckey] : super(settings_key, object)
      end

      # set a setting value by [] notation
      def []=(var_name, value, object = nil)
        settings_key = scoped_key(var_name, object)
        object ||= current_object
        assert_scope!(object)
        # Invalidate before saving. after_commit :expire_cache invalidates again once the row is
        # durable; both are deletes, so it does not matter which instance's callback runs.
        Rails.cache.delete(cache_key(settings_key, object)) if rails_initialized?
        super(settings_key, value, object)
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
        output = "#{current_settings_scope}.#{key}" if current_settings_scope.present?
        output = "#{object.class.base_class.to_s.downcase}.#{key}" if object.present?

        output
      end

      def save_default(key, value)
        Kernel.warn 'DEPRECATION WARNING: RailsSettings save_default is deprecated and it will removed in 1.0. ' << 'Please use YAML file for default setting.'
        return false unless self[key].nil?
        self[key] = value
      end

      private

      # Scope state lives on ScopedSettings, which overrides these. On Base and every non-scoped
      # subclass -- the app's `Setting`, say -- reads are always global, so `Setting.partner` keeps
      # returning the default hash after `partner.settings` has run on this thread.
      #
      # Private because every public class method here permanently claims a settings key: the read
      # API is method_missing, so `Setting.current_object` would shadow a key of that name.
      def current_object
        nil
      end

      def current_settings_scope
        nil
      end

      # No-op here; ScopedSettings overrides it. Checked before the cache is consulted, because an
      # unbound scoped read computes the *unprefixed* key -- byte-identical to the global one --
      # and a warm cache would otherwise answer it with the global value instead of raising.
      def assert_scope!(_object)
        nil
      end

      # The innermost open transaction on THIS class's connection, or nil. Deliberately asks the
      # connection rather than ActiveRecord::Base.current_transaction: the latter reports
      # NULL_TRANSACTION for a non-joinable transaction, and a non-joinable transaction -- a
      # fixture wrapper, or every connection under `rails console --sandbox` -- rolls back just as
      # readily as any other. Uses active_connection, so it never checks one out.
      def open_transaction
        txn = connection_pool.active_connection&.current_transaction
        txn if txn&.open?
      end

      # Values read during the current transaction. Discarded as soon as the transaction is no
      # longer the one memoised against -- commit, rollback and entering a savepoint all change it.
      def transaction_memo(txn)
        store = ExecutionState[ExecutionState::MEMO_KEY]
        unless store && store.first.equal?(txn)
          store = [txn, {}]
          ExecutionState[ExecutionState::MEMO_KEY] = store
        end
        memo = store.last
        memo.clear if memo.size > TRANSACTION_MEMO_LIMIT
        memo
      end

      def forget_memoised(ckey)
        txn = open_transaction
        return if txn.nil?
        transaction_memo(txn).delete(ckey)
        nil
      end

      def cache_key_for(var_name, thing_type, thing_id)
        prefix = RailsSettings::Base.instance_variable_get(:@cache_prefix)
        scope = ['rails_settings_cached', cache_prefix_by_startup]
        scope << prefix.call if prefix
        scope << "#{thing_type}-#{thing_id}" if thing_type || thing_id
        scope << var_name.to_s
        scope.join('/')
      end

      # Kept out of the memo so the TRANSACTION_MEMO_LIMIT clear cannot drop the marks.
      def dirty_keys
        ExecutionState[ExecutionState::DIRTY_KEY] ||= Set.new
      end

      def mark_dirty(ckey)
        dirty_keys << ckey
        nil
      end

      def unmark_dirty(ckey)
        keys = ExecutionState[ExecutionState::DIRTY_KEY]
        keys.delete(ckey) if keys
        nil
      end
    end
  end
end
