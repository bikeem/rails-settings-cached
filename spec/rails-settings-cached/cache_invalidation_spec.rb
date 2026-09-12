require 'spec_helper'

describe 'RailsSettings::Base guards that survived mutation testing' do
  before(:all) { @cand_partner = Partner.create!(code: 'cand') }
  before(:each) { Setting.unscoped.delete_all; Rails.cache.clear }

  let(:key) { Setting.cache_key(Setting.scoped_key('color', @cand_partner), @cand_partner) }

  # Publishes the committed value into the shared cache from another connection, the way a
  # concurrent request would, and waits for it to land.
  def concurrent_read
    done = Queue.new
    t = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { @cand_partner.settings.color }
      done << true
    end
    done.pop
    t.join(5)
  end

  # Invalidating inside the transaction is not enough: between that and COMMIT another connection
  # can read the OLD committed value and republish it. These keys have no TTL, so without the
  # commit-time sweep that entry is stale forever.
  describe 'after_commit :expire_cache' do
    it 'expires an entry a concurrent reader republished before the UPDATE committed' do
      @cand_partner.settings.color = 'old'
      Rails.cache.clear

      ActiveRecord::Base.transaction do
        @cand_partner.settings.color = 'new'
        concurrent_read
        expect(Rails.cache.read(key)).to eq 'old'
      end

      expect(Rails.cache.read(key)).to be_nil
      expect(@cand_partner.settings.color).to eq 'new'
    end

    it 'expires an entry a concurrent reader republished before the CREATE committed' do
      Rails.cache.clear

      ActiveRecord::Base.transaction do
        @cand_partner.settings.color = 'created'
        concurrent_read
        expect(Rails.cache.exist?(key)).to be true
        expect(Rails.cache.read(key)).to be_nil
      end

      expect(Rails.cache.exist?(key)).to be false
      expect(@cand_partner.settings.color).to eq 'created'
    end

    it 'expires an entry a concurrent reader republished before the DESTROY committed' do
      @cand_partner.settings.color = 'doomed'
      Rails.cache.clear

      ActiveRecord::Base.transaction do
        Setting.unscoped.where(thing_type: 'Partner', thing_id: @cand_partner.id,
                               var: 'partner.color').destroy_all
        concurrent_read
        expect(Rails.cache.read(key)).to eq 'doomed'
      end

      expect(Rails.cache.read(key)).to be_nil
      expect(@cand_partner.settings.color).to be_nil
    end
  end

  # The memo holds an ActiveRecord::Transaction, and through it a connection adapter, which must
  # not linger on a pooled thread.
  it 'drops the transaction memo when the scope state is cleared' do
    ActiveRecord::Base.transaction { @cand_partner.settings.color }
    expect(RailsSettings::ExecutionState[RailsSettings::ExecutionState::MEMO_KEY]).not_to be_nil

    RailsSettings::ScopedSettings.clear_current!
    expect(RailsSettings::ExecutionState[RailsSettings::ExecutionState::MEMO_KEY]).to be_nil
  end

  it 'serves a memoised nil from the transaction memo without re-querying' do
    ActiveRecord::Base.transaction do
      expect(@cand_partner.settings.absent).to be_nil
      queries = count_setting_queries { expect(@cand_partner.settings.absent).to be_nil }
      expect(queries).to eq 0
    end
  end

  it 'serves a memoised false from the transaction memo without re-querying' do
    @cand_partner.settings.flag = false
    Rails.cache.clear

    ActiveRecord::Base.transaction do
      expect(@cand_partner.settings.flag).to be false
      queries = count_setting_queries { expect(@cand_partner.settings.flag).to be false }
      expect(queries).to eq 0
    end
  end

  it 'memoises many distinct keys inside one transaction' do
    ActiveRecord::Base.transaction do
      50.times { |i| @cand_partner.settings.send("memo_k#{i}") }
      queries = count_setting_queries { 50.times { |i| @cand_partner.settings.send("memo_k#{i}") } }
      expect(queries).to eq 0
    end
  end

  it 'caps the memo so an unbounded key loop cannot grow it without limit' do
    limit = RailsSettings::Base::TRANSACTION_MEMO_LIMIT
    ActiveRecord::Base.transaction do
      (limit + 2).times { |i| @cand_partner.settings.send("cap_k#{i}") }
      memo = RailsSettings::ExecutionState[RailsSettings::ExecutionState::MEMO_KEY].last
      expect(memo.size).to be <= limit
    end
  end

  it 'addresses an STI record under its base class' do
    admin = AdminUser.create!(login: "sti-key-#{rand(10**9)}", password: 'x')

    expect(RailsSettings::Base.scoped_key('color', admin)).to eq 'user.color'
    Setting[:color, 'red'] = admin
    expect(Setting.unscoped.find_by(thing_id: admin.id).var).to eq 'user.color'
    expect(Setting.color(User.find(admin.id))).to eq 'red'
  end

  it 'does not check a connection out of the pool just to look for a transaction' do
    pool = Setting.connection_pool
    ok = nil
    Thread.new do
      pool.release_connection
      before = pool.stat[:busy]
      expect(Setting.send(:open_transaction)).to be_nil
      ok = (pool.stat[:busy] == before)
    ensure
      pool.release_connection
    end.join(5)
    expect(ok).to be true
  end

  it 'does not read the defaults file when there is none' do
    RailsSettings::Base.send(:remove_instance_variable, :@cache_prefix_by_startup) if
      RailsSettings::Base.instance_variable_defined?(:@cache_prefix_by_startup)
    RailsSettings::Default.send(:remove_instance_variable, :@instance) if
      RailsSettings::Default.instance_variable_defined?(:@instance)
    allow(RailsSettings::Default).to receive(:source_path).and_return('/nonexistent/app.yml')

    expect(RailsSettings::Base.cache_prefix_by_startup).to eq ''
  ensure
    RailsSettings::Default.send(:remove_instance_variable, :@instance) if
      RailsSettings::Default.instance_variable_defined?(:@instance)
    RailsSettings::Base.send(:remove_instance_variable, :@cache_prefix_by_startup) if
      RailsSettings::Base.instance_variable_defined?(:@cache_prefix_by_startup)
  end

  it 'falls back when ActiveRecord does not expose the setting' do
    expect(RailsSettings.config.send(:active_record_config, :no_such_ar_setting) { :fallback })
      .to eq :fallback
  end

  it 'defaults to safe loading when ActiveRecord does not expose use_yaml_unsafe_load' do
    RailsSettings.config.yaml_unsafe_load = nil
    allow(ActiveRecord).to receive(:respond_to?).and_call_original
    allow(ActiveRecord).to receive(:respond_to?).with(:use_yaml_unsafe_load).and_return(false)

    expect(RailsSettings.config.yaml_unsafe_load).to be false
  end

  it 'permits Symbol on its own account, not only via ActiveRecord' do
    # The memo must be dropped BEFORE the stub, or the stub cannot take effect.
    RailsSettings.config.yaml_permitted_classes = nil
    allow(ActiveRecord).to receive(:yaml_column_permitted_classes).and_return([])

    expect(RailsSettings.config.yaml_permitted_classes).to include(Symbol)
  ensure
    RailsSettings.config.yaml_permitted_classes = nil
  end

  it 'without_settings_for ignores another model sharing the id' do
    u = User.create!(login: "wsf-#{rand(10**9)}", password: 'x')
    p = Partner.new(code: 'wsf'); p.id = u.id
    p.save! unless Partner.exists?(u.id)
    Partner.find(u.id).settings.color = 'partner-red'

    expect(User.without_settings_for('partner.color')).to include(u)
  end

  it 'merge! refuses a non-hash argument' do
    expect { Setting.merge!(:mergeable, 'not a hash') }.to raise_error(ArgumentError)
  end

  it 'leaves the global cache entry alone when an unbound scoped write is rejected' do
    Setting.color = 'GLOBAL'
    expect(Setting.color).to eq 'GLOBAL'
    global_key = Setting.cache_key('color', nil)
    expect(Rails.cache.read(global_key)).to eq 'GLOBAL'

    RailsSettings::ScopedSettings.clear_current!
    expect { RailsSettings::ScopedSettings.color = 'x' }
      .to raise_error(RailsSettings::ScopedSettings::MissingScope)

    expect(Rails.cache.read(global_key)).to eq 'GLOBAL'
  end

  describe 'read-your-own-write against a concurrent reader' do
    # The writer deletes the entry, but another connection cannot see the uncommitted row, so its
    # read republishes the PRE-IMAGE. If the writer then trusted the shared cache it would read
    # its own write back as stale -- and merge!, being read-modify-write, would persist a hash
    # built from that stale value.
    it 'reads its own uncommitted write even after a concurrent reader republished the old value' do
      @cand_partner.settings.color = 'old'
      expect(@cand_partner.settings.color).to eq 'old'

      ActiveRecord::Base.transaction do
        @cand_partner.settings.color = 'new'
        concurrent_read
        expect(Rails.cache.read(key)).to eq 'old'   # the republished pre-image
        expect(@cand_partner.settings.color).to eq 'new'
      end

      expect(@cand_partner.settings.color).to eq 'new'
    end

    it 'does not let merge! build on a republished pre-image' do
      @cand_partner.settings.hash_key = { 'a' => 1 }
      expect(@cand_partner.settings.hash_key).to eq('a' => 1)
      hkey = Setting.cache_key(Setting.scoped_key('hash_key', @cand_partner), @cand_partner)

      ActiveRecord::Base.transaction do
        @cand_partner.settings.hash_key = { 'a' => 1, 'b' => 2 }
        done = Queue.new
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection { @cand_partner.settings.hash_key }
          done << true
        end.tap { done.pop }.join(5)
        expect(Rails.cache.read(hkey)).to eq('a' => 1)   # pre-image republished

        @cand_partner.settings.merge!('hash_key', 'c' => 3)
      end

      expect(@cand_partner.settings.hash_key).to eq('a' => 1, 'b' => 2, 'c' => 3)
    end

    it 'keeps the mark across a savepoint release' do
      @cand_partner.settings.color = 'old'
      expect(@cand_partner.settings.color).to eq 'old'

      ActiveRecord::Base.transaction do
        ActiveRecord::Base.transaction(requires_new: true) { @cand_partner.settings.color = 'new' }
        concurrent_read
        expect(@cand_partner.settings.color).to eq 'new'
      end
    end

    it 'releases the mark once the transaction settles' do
      ActiveRecord::Base.transaction { @cand_partner.settings.color = 'x' }
      expect(RailsSettings::ExecutionState[RailsSettings::ExecutionState::DIRTY_KEY].to_a).to eq []
    end
  end

  describe 'cache key is built from the stored columns' do
    # `thing` is nil for a soft-deleted or out-of-scope record, which would yield the GLOBAL key:
    # the scoped entry stays stale forever and an unrelated global key is evicted.
    it 'invalidates the scoped key even when the thing association cannot load' do
      user = User.create!(login: "soft-#{rand(10**9)}", password: 'x')
      user.settings.color = 'scoped'
      expect(user.settings.color).to eq 'scoped'
      scoped_key = Setting.cache_key('color', user)   # User defines no settings_scope, so var is 'color'
      expect(Rails.cache.read(scoped_key)).to eq 'scoped'

      row = Setting.unscoped.find_by(thing_type: 'User', thing_id: user.id, var: 'color')
      allow_any_instance_of(RailsSettings::Base).to receive(:thing).and_return(nil)

      expect(row.cache_key).to eq scoped_key
      row.update!(value: 'changed')
      expect(Rails.cache.exist?(scoped_key)).to be false
    end

    it 'does not query to build the key of a row whose thing is not loaded' do
      user = User.create!(login: "noq-#{rand(10**9)}", password: 'x')
      user.settings.color = 'v'
      row = Setting.unscoped.find_by(thing_type: 'User', thing_id: user.id, var: 'color')

      expect(count_setting_queries { row.cache_key }).to eq 0
    end
  end

  describe 'guards on what can be stored and scoped' do
    it 'refuses settings on an unsaved record instead of sharing one NULL row' do
      fresh = User.new(login: 'unsaved', password: 'x')
      expect { fresh.settings.color }.to raise_error(RailsSettings::ScopedSettings::MissingScope, /must be saved/)
      expect { fresh.settings.color = 'x' }.to raise_error(RailsSettings::ScopedSettings::MissingScope)
    end

    it 'refuses a value that would not decode again, at the call site' do
      # Otherwise the row is written and every later read -- including get_all, for everyone --
      # raises Psych::DisallowedClass with no clue which call site caused it.
      expect { Setting.junk = Object.new }.to raise_error(ArgumentError, /cannot store a value of type Object/)
      expect(Setting.unscoped.find_by(var: 'junk')).to be_nil
      expect { Setting.get_all }.not_to raise_error
    end

    it 'stores a value once its class is permitted' do
      RailsSettings.config.yaml_permitted_classes = RailsSettings.config.yaml_permitted_classes + [Struct]
      expect { Setting.structy = Struct }.not_to raise_error
    ensure
      RailsSettings.config.yaml_permitted_classes = nil
    end
  end

  describe 'cache entries expire' do
    # A reader descheduled between its DB read and its cache write can publish a stale value after
    # a writer invalidated the key. Nothing closes that race, so entries must not live forever.
    it 'writes entries with a TTL' do
      Setting.ttl_key = 'v'
      expect(Setting.ttl_key).to eq 'v'
      entry = Rails.cache.send(:read_entry, Rails.cache.send(:normalize_key, Setting.cache_key('ttl_key', nil), {}), **{})
      expect(entry.expires_at).not_to be_nil
    end

    it 'can be configured off' do
      expect(RailsSettings.config.cache_expires_in).to eq RailsSettings::Configuration::DEFAULT_CACHE_EXPIRES_IN
      RailsSettings.config.cache_expires_in = nil
      expect(RailsSettings.config.cache_expires_in).to be_nil
    ensure
      if RailsSettings.config.instance_variable_defined?(:@cache_expires_in)
        RailsSettings.config.send(:remove_instance_variable, :@cache_expires_in)
      end
    end
  end
end
