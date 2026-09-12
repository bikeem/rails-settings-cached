require 'spec_helper'

describe 'RailsSettings::Base cache vs. transactions' do
  before(:all) { @partner = Partner.create!(code: 'txn') }

  before(:each) do
    Setting.unscoped.delete_all
    Rails.cache.clear
  end

  let(:key) { Setting.cache_key(Setting.scoped_key('color', @partner), @partner) }

  it 'leaves nothing in the cache when the wrapping transaction rolls back' do
    @partner.settings.color = 'committed'
    Rails.cache.clear

    ActiveRecord::Base.transaction do
      @partner.settings.color = 'uncommitted'
      expect(@partner.settings.color).to eq 'uncommitted'   # read-your-write inside the transaction
      raise ActiveRecord::Rollback
    end

    expect(Rails.cache.exist?(key)).to be false
    expect(@partner.settings.color).to eq 'committed'
  end

  it 'does not populate the cache from a read inside a joinable transaction' do
    @partner.settings.color = 'red'
    Rails.cache.clear

    ActiveRecord::Base.transaction do
      expect(@partner.settings.color).to eq 'red'
      expect(Rails.cache.exist?(key)).to be false
    end
  end

  it 'populates the cache from a read at top level' do
    @partner.settings.color = 'red'
    Rails.cache.clear

    expect(@partner.settings.color).to eq 'red'
    expect(Rails.cache.read(key)).to eq 'red'
  end

  # A non-joinable transaction is what transactional fixtures use -- and what
  # `rails console --sandbox` opens on every connection. It rolls back like any other, so a value
  # written inside one must not reach the shared cache either.
  it 'does not publish a value written inside a rolled-back NON-joinable transaction' do
    @partner.settings.color = 'committed'
    Rails.cache.clear

    ActiveRecord::Base.transaction(joinable: false) do
      @partner.settings.color = 'sandbox-typo'
      expect(@partner.settings.color).to eq 'sandbox-typo'
      raise ActiveRecord::Rollback
    end

    expect(Rails.cache.exist?(key)).to be false
    expect(@partner.settings.color).to eq 'committed'
  end

  it 'does not publish a value written inside a rolled-back non-joinable SAVEPOINT' do
    @partner.settings.color = 'committed'
    Rails.cache.clear

    ActiveRecord::Base.transaction do
      ActiveRecord::Base.transaction(requires_new: true, joinable: false) do
        @partner.settings.color = 'poison'
        expect(@partner.settings.color).to eq 'poison'
        raise ActiveRecord::Rollback
      end
    end

    expect(Rails.cache.exist?(key)).to be false
    expect(@partner.settings.color).to eq 'committed'
  end

  it 'never publishes to the shared cache while any transaction is open' do
    @partner.settings.color = 'red'
    Rails.cache.clear

    ActiveRecord::Base.transaction do
      expect(@partner.settings.color).to eq 'red'
      expect(Rails.cache.exist?(key)).to be false
    end
    ActiveRecord::Base.transaction(joinable: false) do
      expect(@partner.settings.color).to eq 'red'
      expect(Rails.cache.exist?(key)).to be false
    end
  end

  it 'invalidates on write and repopulates on the next read' do
    # Cache-aside: writes delete, reads populate. Publishing on commit instead would let a key
    # written twice in one transaction keep the FIRST value forever, because Rails runs commit
    # callbacks on only one instance per record.
    @partner.settings.color = 'red'
    expect(Rails.cache.exist?(key)).to be false
    expect(@partner.settings.color).to eq 'red'
    expect(Rails.cache.read(key)).to eq 'red'
  end

  it 'keeps the cache correct when the same key is written twice in one transaction' do
    ActiveRecord::Base.transaction do
      @partner.settings.color = 'first'
      @partner.settings.color = 'second'
    end

    expect(@partner.settings.color).to eq 'second'
    expect(Rails.cache.read(key)).to eq 'second'
  end

  it 'does not serve a destroyed setting from the cache after commit' do
    @partner.settings.color = 'red'
    expect(@partner.settings.color).to eq 'red'   # warm the cache

    ActiveRecord::Base.transaction do
      Setting.unscoped.where(thing_type: 'Partner', thing_id: @partner.id, var: 'partner.color').destroy_all
      expect(@partner.settings.color).to be_nil
    end

    expect(@partner.settings.color).to be_nil
    expect(Rails.cache.read(key)).to be_nil
  end

  it 'serves a cached false inside a transaction without a query' do
    @partner.settings.flag = false
    expect(@partner.settings.flag).to be false     # repopulates after the write invalidated it
    flag_key = Setting.cache_key(Setting.scoped_key('flag', @partner), @partner)
    expect(Rails.cache.read(flag_key)).to be false

    ActiveRecord::Base.transaction do
      queries = count_setting_queries { expect(@partner.settings.flag).to be false }
      expect(queries).to eq 0
    end
  end

  it 'serves a cached nil inside a transaction without a query' do
    # Pins the read_multi/key? choice: a plain `read(...) unless nil?` cannot tell a cached nil
    # from a miss and would re-query here.
    expect(@partner.settings.absent).to be_nil
    absent_key = Setting.cache_key(Setting.scoped_key('absent', @partner), @partner)
    expect(Rails.cache.exist?(absent_key)).to be true

    ActiveRecord::Base.transaction do
      queries = count_setting_queries { expect(@partner.settings.absent).to be_nil }
      expect(queries).to eq 0
    end
  end

  describe 'per-transaction memo' do
    it 'queries once for repeated reads of the same key inside one transaction' do
      @partner.settings.color = 'red'
      Rails.cache.clear

      ActiveRecord::Base.transaction do
        queries = count_setting_queries { 5.times { expect(@partner.settings.color).to eq 'red' } }
        expect(queries).to eq 1
      end
    end

    it 'does not serve a memo from an earlier transaction' do
      @partner.settings.color = 'red'
      Rails.cache.clear
      ActiveRecord::Base.transaction { expect(@partner.settings.color).to eq 'red' }

      Setting.unscoped.delete_all
      Rails.cache.clear
      ActiveRecord::Base.transaction { expect(@partner.settings.color).to be_nil }
    end

    it 'is invalidated by a write, so a later read in the same transaction sees it' do
      @partner.settings.color = 'red'
      Rails.cache.clear

      ActiveRecord::Base.transaction do
        expect(@partner.settings.color).to eq 'red'      # memoises 'red'
        @partner.settings.color = 'blue'
        expect(@partner.settings.color).to eq 'blue'
        raise ActiveRecord::Rollback
      end

      expect(@partner.settings.color).to eq 'red'
    end
  end

  it 'asks its own connection pool for the open transaction rather than a hardcoded class' do
    # A subclass may sit on another connection, and it is that connection's transaction which
    # governs the row being read.
    expect(Setting).to receive(:connection_pool).at_least(:once).and_call_original
    Setting.send(:open_transaction)
  end

  it 'detects a non-joinable transaction as open' do
    # ActiveRecord::Base.current_transaction reports NULL_TRANSACTION for these, which is exactly
    # the trap: they roll back like any other transaction.
    ActiveRecord::Base.transaction(joinable: false) do
      expect(Setting.send(:open_transaction)).not_to be_nil
      expect(Setting.current_transaction.open?).to be false   # the misleading answer
    end
  end
end
