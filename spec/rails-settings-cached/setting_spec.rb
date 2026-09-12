require 'spec_helper'

describe RailsSettings do
  before(:each) do
    @str = 'Foo bar'
    @tm = Time.now
    @items = [1, 3, 5, 'as']
    @hash = { name: @str, items: @items }
    @merged_hash = { name: @str, items: @items, id: 32 }
    @bar = 'Bar foo'
    @user = User.create!(login: "test-#{rand(10**9)}", password: 'foobar')
  end

  describe "#thing" do
    it "has belongs_to relationship to `thing`" do
      expect(Setting.reflect_on_association(:thing).macro).to eq(:belongs_to)
    end
  end

  describe 'Getter and Setter' do
    context 'String value' do
      it 'can work with String value' do
        Setting.foo = @str
        expect(Setting.foo).to eq @str
      end
    end

    context 'Boolean value' do
      before(:each) do
        Setting.boolean_foo = true
        Setting.boolean_bar = false
      end

      it { expect(Setting.boolean_foo).to be true }
      it { expect(Setting.boolean_bar).to be false }

      it "returns the same values if the cache is cleared" do
        Rails.cache.clear
        expect(Setting.boolean_foo).to be true
        expect(Setting.boolean_bar).to be false
      end
    end

    context 'Array value' do
      before(:each) do
        Setting.items = @items
      end

      it { expect(Setting.items).to eq @items }
      it { expect(Setting.items).to be_a(Array) }
    end

    context 'DateTime value' do
      before(:each) do
        Setting.created_on = @tm
      end
      it { expect(Setting.created_on).to eq @tm }
      it { expect(Setting.created_on).to be_a(Time) }
    end

    context 'Hash value' do
      before(:each) do
        Setting.hashes = @hash
      end
      it { expect(Setting.hashes).to eq @hash }
      it { expect(Setting.hashes).to be_a(Hash) }
    end

    context 'namespace for key' do
      before(:each) do
        Setting['config.color'] = :red
        Setting['config.limit'] = 100
      end
      it { expect(Setting['config.color']).to eq :red }
      it { expect(Setting['config.limit']).to eq 100 }
    end

    context 'defaults within namespace for key' do
      before do
        allow(RailsSettings::Default).to receive(:instance).and_return({ "config.dcolor" => :blue, "config.dlimit" => 200 })
      end

      it { expect(Setting['config.dcolor']).to eq :blue }
      it { expect(Setting['config.dlimit']).to eq 200 }
    end

    context 'Merge hash' do
      before(:each) do
        Setting.hashes = @hash
        Setting.merge!(:hashes, id: 32)
      end
      it { expect(Setting.hashes).to include(id: 32) }
      it { expect(Setting.hashes).to include(@hash) }
    end
  end

  describe '#all' do
    it 'returns every row it was given, scoped and global alike' do
      3.times { |i| Setting.send("all_k#{i}=", i) }
      @user.settings.scoped_one = 'x'

      # `all` is plain ActiveRecord: the whole table. `thing_scoped` is the global-only relation.
      expect(Setting.all.map(&:var)).to match_array(%w[all_k0 all_k1 all_k2 scoped_one])
      expect(Setting.thing_scoped.map(&:var)).to match_array(%w[all_k0 all_k1 all_k2])
    end
  end

  describe '#get_all' do
    it "should include defaults" do
      expect(RailsSettings::Default).to receive(:instance).and_return({ default1: 1, default2: '2' })
      expect(Setting.get_all).to include(:default1, :default2)
    end

    it "should include namespace defaults" do
      expect(RailsSettings::Default).to receive(:instance).and_return({ "test.default1" => 1, "test.default2" => '2', demo: 3 })
      expect(Setting.get_all('test.')).to include(:'test.default1', :'test.default2')
    end

    it "should all('namespace')" do
      Setting['config.color'] = :red
      Setting['config.limit'] = 100
      expect(Setting.get_all('config')).to eq({ "config.color" => :red, "config.limit" => 100 })
      expect(Setting.get_all('config').count).to eq 2
    end

    it 'overwrites default values' do
      Setting.str = 'abc'
      expect(Setting.get_all['str']).to eq('abc')
    end
  end

  describe '#destroy' do
    before(:each) do
      Setting.foo = @str
      Setting.other_key = 'kept'
      Setting.destroy(:foo)
    end

    it { expect(Setting.foo).to be_nil }
    it { expect(Setting.all.map(&:var)).to eq ['other_key'] }

    it 'can destroy a falsy value' do
      Setting.falsy_value = false
      Setting.destroy(:falsy_value)
      expect(Setting.falsy_value).to be_nil
    end
  end

  describe 'Save Default values' do
    it '#save_default' do
      Setting.test_save_default_key
      Setting.save_default(:test_save_default_key, '321')
      expect(Setting.where(var: 'test_save_default_key').count).to eq 1
      expect(Setting.test_save_default_key).to eq '321'
      Setting.save_default(:test_save_default_key, '3211')
      expect(Setting.test_save_default_key).to eq '321'
    end
  end

  describe 'Implementation by embeds a Model' do
    before(:each) do
      @user.settings.level = 30
      @user.settings.locked = true
      @user.settings.last_logined_at = @tm
    end

    it 'can set values' do
      Setting.level = 20
      expect(Setting.unscoped.where(var: 'level').count).to eq 2
      expect(Setting.where(var: 'level').count).to eq 1
      Setting.where(var: 'level').first.value == 20
    end

    it 'can read values' do
      expect(@user.settings.level).to eq 30
      expect(@user.settings.locked).to eq true
      expect(@user.settings.last_logined_at).to eq @tm
    end
  end

  describe 'Query all items' do
    describe '#unscoped' do
      it 'should work' do
        expect(Setting.unscoped).to be_a(ActiveRecord::Relation)
      end

      it 'counts scoped and global rows together' do
        Setting.aa = Time.now
        @user.settings.bb = Time.now
        expect(Setting.unscoped.count).to eq 2
        expect(Setting.thing_scoped.count).to eq 1   # thing_scoped is the global-only relation
      end
    end

    describe '#find' do
      let(:obj) { Setting.foo = 'x'; Setting.unscoped.first }
      let(:id) { obj.id }

      it 'should work with find' do
        expect(Setting.unscoped.find(id)).to eq obj
      end
    end
  end

  describe 'Custom table name' do
    it 'should work' do
      expect(CustomSetting.foo).to eq(nil)
      CustomSetting.foo = 123
      expect(CustomSetting.foo).to eq(123)
    end
  end
end
