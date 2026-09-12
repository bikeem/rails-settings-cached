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

  it 'is what record.settings returns (MEX specs stub the class)' do
    expect(@partner_a.settings).to equal(described_class)
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
    it 'clears scope state when the Rails executor completes' do
      Rails.application.executor.wrap do
        @partner_a.settings
        expect(described_class.send(:current_object)).to eq @partner_a
      end
      expect(described_class.send(:current_object)).to be_nil
      expect(described_class.send(:current_settings_scope)).to be_nil
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
