module RailsSettings
  class Railtie < Rails::Railtie
    initializer 'rails_settings.active_record.initialization' do
      # These run inside the transaction, so a read later in the same transaction sees the write
      # rather than a stale cache entry or memo. Registered on save/destroy rather than only on
      # the []= path, so a plain `Setting.new(...).save!` or a `destroy` is covered too.
      RailsSettings::Base.after_save :invalidate_caches, if: :saved_changes?
      RailsSettings::Base.after_destroy :invalidate_caches

      # On commit, invalidate rather than publish. Rails runs commit callbacks on only one
      # instance per record -- with the legacy default, the FIRST one saved -- so writing the
      # value here would publish a stale one permanently when a key is written twice in one
      # transaction. A delete is idempotent and correct whichever instance runs it.
      RailsSettings::Base.after_commit :expire_cache, on: %i(create update destroy)

      # Release the written-by-this-transaction mark once the write's fate is settled, whichever
      # way it went. after_commit also sweeps an entry a concurrent reader republished pre-commit.
      RailsSettings::Base.after_commit :release_dirty_key
      RailsSettings::Base.after_rollback :release_dirty_key
    end

    # Scope state must not outlive the request or job that set it (puma and Sidekiq reuse threads).
    initializer 'rails_settings.executor.clear_scope' do |app|
      app.executor.to_complete { RailsSettings::ScopedSettings.clear_current! }
    end
  end
end
