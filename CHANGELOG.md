## 0.8.0

Hardening release. Existing stored rows, `var` names and cache-key formats are unchanged, so no
data migration or cache flush is needed.

### Requirements

- Ruby >= 3.3 (was >= 2.1), Rails >= 7.2 (was >= 4.2). Tested on Rails 7.2, 8.0 and 8.1.

### Fixed

- **Scoped settings are no longer shared between threads.** `record.settings` stored the bound
  record in a class instance variable, so two Puma or Sidekiq threads could read each other's
  records. State now lives in `ActiveSupport::IsolatedExecutionState` and is cleared when the Rails
  executor completes the request or job. Using `ScopedSettings` with no binding raises
  `RailsSettings::ScopedSettings::MissingScope` instead of silently reading the global row.
- **The cache can no longer hold a value that was rolled back.** Nothing is published to
  `Rails.cache` while any transaction is open -- including non-joinable ones, which is what
  transactional fixtures and `rails console --sandbox` use.
- **Writes now invalidate rather than publish.** Rails runs commit callbacks on only one instance
  per record, so publishing on commit could leave the *first* of two values written in one
  transaction cached permanently. `after_commit` now deletes the key and the next read repopulates.
- `belongs_to :thing` is `optional: true`, so global rows save under `belongs_to_required_by_default`.
- YAML decoding no longer uses `Kernel#open` and no longer hardcodes `permitted_classes: [Time, Symbol]`.
- `var` is bound rather than interpolated in `get_all` and in all four `Extend` scopes, which also
  now use the model's own table name instead of a hardcoded `settings`.
- `method_missing` forwards keyword arguments and blocks. A scope object is detected with
  `is_a?(ActiveRecord::Base)` rather than `respond_to?(:id)`.
- `Setting[key, value] = record` binds the new row to the record instead of writing a global row.
- `get_all` accepts a Symbol prefix without raising `TypeError`.
- A read inside a transaction no longer trusts the shared cache for a key that transaction has
  written: a concurrent reader on another connection could otherwise repopulate the entry with the
  pre-image, so the writer read its own write back as stale -- and `merge!`, being read-modify-write,
  would persist a hash built from it.
- The cache key of a row is built from its stored `thing_type`/`thing_id` rather than the `thing`
  association, which is nil for a soft-deleted or out-of-scope record. Previously such a row
  invalidated the *global* key, leaving the scoped entry stale and evicting an unrelated key.
- `cache_prefix` is stored on `RailsSettings::Base`, so `record.settings` and `Setting[...]` agree
  on the key. Per-class storage gave them two different keys for the same row.
- A setting on an unsaved record raises `MissingScope` instead of writing to a shared
  `thing_id IS NULL` row that every unsaved record of that class would share.
- Storing a value whose class the decoder will refuse now raises `ArgumentError` at the call site
  instead of poisoning the row -- an undecodable row broke `get_all` for everyone, permanently.
- An idempotent save no longer evicts the cache entry.

### Added

- `RailsSettings.config` / `RailsSettings.configure` for YAML decoding: `yaml_permitted_classes`
  (defaults to `ActiveRecord.yaml_column_permitted_classes` plus `Symbol, Time, Date,
  ActiveSupport::HashWithIndifferentAccess`), `yaml_aliases`, `yaml_unsafe_load` (follows
  `ActiveRecord.use_yaml_unsafe_load`).
- `RailsSettings.config.cache_expires_in` (12 hours by default, `nil` to disable): a reader
  descheduled between its database read and its cache write can publish a stale value after a
  writer invalidated the key, and no invalidation scheme closes that race.
- GitHub Actions CI across Ruby 3.3/3.4 x Rails 7.2/8.0/8.1, replacing Travis.

### Changed behaviour to be aware of

- A write no longer leaves its value in the cache; the next read costs one query.
- A key only ever read inside a transaction is never cached, so it costs one query per transaction.
  Read it once outside a transaction to warm it.
- `get_all('a_b')` treats `_` literally rather than as a SQL wildcard, so it can return fewer keys.
- A write followed by a read returns the YAML round-trip of the value rather than the object passed
  in; symbol keys in a Hash come back as strings, matching what the database holds.
- Rows previously created by `Setting[key, value] = record` are global (`thing` NULL) and are not
  visible to the scoped read path. Check for them before upgrading if you used that form.
- Cache entries now expire after 12 hours by default; set `cache_expires_in` to `nil` for the old
  never-expire behaviour.
- `RailsSettings::Base#rewrite_cache` is removed. It published a value that might still roll back,
  which is what this release exists to prevent.
- `new_thing_scoped` is private; unguarded, it returned the whole table for a nil object.
- Writes that bypass ActiveRecord callbacks (`update_column`, `update_all`, `delete_all`,
  `insert_all`, raw SQL) leave a stale entry until it expires. The gem cannot observe them.
- `RailsSettings::CachedSettings` and `save_default` now say they will be removed in 1.0.

## 0.6.5

- Return direct value first for existing default keys. (#111)
- Fix defaults merge when get_all. (#110)
- Fix deprecated syntax in the model generator (#107)

## 0.6.4

- Fix cache key with multiple processes.

## 0.6.3

- Ensure defaults not overwrite persisted settings (#98) (Kevin Sjöberg)

## 0.6.2

- Make sure YAML default settings can work when Rails not initialized (in Rails initializes or environments/*.rb)

## 0.6.1

- Make sure YAML default settings can work when settings table does not exist (For example in Rails initializes).

## 0.6.0

- Add `config/app.yml` for write you default settings in file.
- Change generator command from `rails g settings` to `rails g settings:install`.
- [Deprecated] RailsSettings::CachedSettings, please use RailsSettings::Base.
- [Deprecated] Setting.defaults method, use YAML file instead.
- [Deprecated] Setting.save_default method, use YAML file instead.
- Removed `SettingsDefaults::DEFAULTS` support.
- Change cache key prefix after restart Rails application server (This for make sure cache will expire, when you update default config in YAML file).
- If the value was set to false, either the default is returned or if there is no default, then nil would be returned. @dangerous

## 0.5.6

- Fixed inheritance of RailsSettings::CachedSettings to use RailsSettings::Base.

## 0.5.5

- Change default g
- [Deprecated] RailsSettings::Settings, please use RailsSettings::Base.


## 0.5.4

- Update the cached value for the key when value set.
- Return nil if value not present;

## 0.5.3

- Fixed mistake, when scoped result contains global defaults which not in scope. (Alexander Merkulov)

## 0.5.2

- Gem spec require Ruby 2.0+; @alexanderadam
- Include defaults in get_all call; @alexanderadam

## 0.5.0

- Allow setting dynamic cache prefix. So that settings can be arbitrarily
scoped based on some context (e.g. current tenant). @artemave

# For Rails 4.1.x

## 0.4.6

- Fix scoped cache key name.


## 0.4.5

- Cache db values that does not exist within rails cache.

## 0.4.4

- Add cached to model scoped settings.

## 0.4.3

- Fix Rails 4.2.4 `after_rollback`/`after_commit` depreciation warnings. @miks

## 0.4.2

- Ruby new hash syntax and do not support Ruby 1.9.2 from now.
- Cache key has changed with `rails_settings_cached` prefix.

## 0.4.1

- ActiveRecord `table_name_prefix` support; #31

## 0.4.0

- Rails 4.1.0 compatibility.
- Setting.all -> Setting.get_all

# For Rails 4.0.x - 4.1.x

## 0.3.2

- Enable destroy-ing a key with falsy data; #32
- Require Rails 4.0.0+;

## 0.3.1

- false value can't got back bug has fixed.

## 0.3.0

- Fix to work with Rails 4.0.0

# For Rails 3.x

## 0.2.4

- Setting.save_default method to direct write default value in database.
- fix mass-update bug.

## 0.2.3

- Fix bug with when key has cached a nil value, and then set a default value for that key,
the default value can't right return.

## 0.2.2

- Add auto cache feature to all key visit.
