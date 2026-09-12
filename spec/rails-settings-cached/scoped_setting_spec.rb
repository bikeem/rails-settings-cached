require 'spec_helper'

describe RailsSettings::ScopedSettings do
  before(:all) do
    @partner_a = Partner.create!(code: 'a')
    @partner_b = Partner.create!(code: 'b')
    @user = User.create!(login: 'scoped', password: 'x')
  end

  before(:each) do
    Setting.unscoped.delete_all
    Rails.cache.clear
  end

  it 'extends `RailsSettings::Base`' do
    expect(described_class.ancestors).to include(RailsSettings::Base)
  end

  it 'returns a handle bound to the record, memoised per instance' do
    handle = @partner_a.settings
    expect(handle).to be_a(RailsSettings::Scope)
    expect(handle.__scope_object__).to eq @partner_a
    # Memoised, so a stub placed on `record.settings` is the handle the code under test uses.
    expect(@partner_a.settings).to equal(handle)
    expect(@partner_b.settings).not_to equal(handle)
  end

  describe 'scoping semantics' do
    it 'stores the scope-prefixed var on a row bound to the object' do
      @partner_a.settings.color = 'red'
      row = Setting.unscoped.find_by(thing_type: 'Partner', thing_id: @partner_a.id)
      expect(row.var).to eq 'partner.color'
      expect(row.value).to eq 'red'
    end

    it 'resolves the three read forms to the same row and the same cache key' do
      @partner_a.settings.color = 'red'
      expect(@partner_a.settings.color).to eq 'red'
      expect(@partner_a.settings.color(@partner_a)).to eq 'red'
      expect(Setting.color(@partner_a)).to eq 'red'

      key = Setting.cache_key(Setting.scoped_key('color', @partner_a), @partner_a)
      expect(key).to end_with("/Partner-#{@partner_a.id}/partner.color")
      expect(Rails.cache.read(key)).to eq 'red'
    end

    it 'does not collide across scopes, objects, or the global namespace' do
      @partner_a.settings.color = 'red'
      @partner_b.settings.color = 'blue'
      @user.settings.color = 'green'
      Setting.color = 'global'

      expect(@partner_a.settings.color).to eq 'red'
      expect(@partner_b.settings.color).to eq 'blue'
      expect(@user.settings.color).to eq 'green'
      expect(Setting.color).to eq 'global'
    end

    it 'supports the 3-arg []= write form used by the admin controllers' do
      @partner_a.settings[:color, 'red'] = @partner_a
      row = Setting.unscoped.find_by(thing_type: 'Partner', thing_id: @partner_a.id, var: 'partner.color')
      expect(row.value).to eq 'red'
      expect(@partner_a.settings.color(@partner_a)).to eq 'red'
    end

    it 'supports dynamic send with and without the object' do
      @partner_a.settings.send('color=', 'red')
      expect(@partner_a.settings.send(:color, @partner_a)).to eq 'red'
      expect(@partner_a.settings.send(:color)).to eq 'red'
    end

    it 'reads the object passed to [], not the record the handle is bound to' do
      @partner_a.settings.color = 'red'
      @partner_b.settings.color = 'blue'
      expect(@partner_a.settings[:color, @partner_b]).to eq 'blue'
      expect(@partner_b.settings[:color, @partner_a]).to eq 'red'
    end

    it 'forwards a block through method_missing' do
      ran = false
      @partner_a.settings.transaction { ran = true }
      expect(ran).to be true
    end

    it 'falls back to the nested default under the scope' do
      allow(RailsSettings::Default).to receive(:instance).and_return({ 'partner' => { 'color' => 'default-red' } })
      expect(@partner_a.settings.color).to eq 'default-red'
      expect(Setting.color(@partner_a)).to eq 'default-red'
    end
  end

  describe 'class-level reads stay global after a scoped call on the same thread' do
    before do
      allow(RailsSettings::Default).to receive(:instance).and_return({ 'partner' => { 'color' => 'default-red' } })
    end

    it 'Setting.partner returns the whole default hash, not a scoped lookup' do
      @partner_a.settings.color = 'red'                # sets scope state for this thread
      expect(Setting.partner).to eq({ 'color' => 'default-red' })
    end

    it "Setting['partner.color'] resolves the global namespace" do
      @partner_a.settings.color = 'red'
      expect(Setting['partner.color']).to eq 'default-red'
    end
  end

  describe 'thread isolation' do
    it "does not leak one object's scope into another thread" do
      @partner_a.settings.color = 'red'
      @partner_b.settings.color = 'blue'
      Rails.cache.clear

      a_ready  = Queue.new
      b_done   = Queue.new
      result   = nil
      b_result = nil

      thread_a = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          scoped = @partner_a.settings      # sets A's scope state
          a_ready << true
          b_done.pop                        # wait until B has set its own scope
          result = scoped.color
        end
      end

      thread_b = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          a_ready.pop
          b_result = @partner_b.settings.color   # clobbers A's class ivars on model_scopes_2
          b_done << true
        end
      end

      # join(5) rather than join: if a thread dies before its handoff the other blocks forever,
      # and an unbounded join would hang the whole suite instead of failing this example.
      [thread_a, thread_b].each { |t| expect(t.join(5)).to be(t), 'thread did not finish within 5s' }
      expect(result).to eq 'red'
      expect(b_result).to eq 'blue'
    end
  end

  describe 'lifecycle' do
    it 'leaves neither key bound once a call returns' do
      # The handle binds only for the duration of each call, so nothing is left on the thread.
      @partner_a.settings.color
      expect(described_class.send(:current_object)).to be_nil
      expect(described_class.send(:current_settings_scope)).to be_nil
    end

    it 'clears BOTH residual keys when the Rails executor completes' do
      RailsSettings::ExecutionState[RailsSettings::ExecutionState::OBJECT_KEY] = @partner_a
      RailsSettings::ExecutionState[RailsSettings::ExecutionState::SCOPE_KEY]  = 'partner'
      Rails.application.executor.wrap { }
      expect(described_class.send(:current_object)).to be_nil
      expect(described_class.send(:current_settings_scope)).to be_nil
    end

    # The binding must not survive a raise, or a later unbound class-level read serves the leaked
    # record instead of raising. App code that rescues a write error would run on a poisoned thread.
    it 'unbinds even when the call raises' do
      expect { @partner_a.settings.color = Object.new }.to raise_error(ArgumentError)
      expect(described_class.send(:current_object)).to be_nil
      expect(described_class.send(:current_settings_scope)).to be_nil
      expect { described_class.color }.to raise_error(described_class::MissingScope)
    end

    it 'restores the exact previous binding when handles nest' do
      @partner_b.settings.color = 'blue'
      seen_o = seen_s = nil
      @partner_a.settings.transaction do
        @partner_b.settings.color
        seen_o = described_class.send(:current_object)
        seen_s = described_class.send(:current_settings_scope)
      end
      expect(seen_o).to eq @partner_a
      expect(seen_s).to eq 'partner'
    end

    it 'raises MissingScope instead of reading anything when used without state' do
      described_class.clear_current!
      expect { described_class.thing_scoped }.to raise_error(described_class::MissingScope)
      # The read entry point must raise too, even with the global key warm in the cache -- an
      # unbound scoped read computes exactly that key.
      Setting.color = 'GLOBAL'
      expect(Setting.color).to eq 'GLOBAL'
      described_class.clear_current!
      expect { described_class.color }.to raise_error(described_class::MissingScope)
      described_class.clear_current!
      expect { described_class.color = 'x' }.to raise_error(described_class::MissingScope)
    end
  end
end
