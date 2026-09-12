require 'spec_helper'

describe RailsSettings::CachedSettings do
  before(:each) { Rails.cache.clear }

  describe '.cache_key' do
    before do
      allow(Setting).to receive(:cache_prefix_by_startup).and_return('t123456')
    end

    it 'should work with instance method' do
      obj = Setting.unscoped.first
      expect(obj.cache_key).to eq("rails_settings_cached/t123456/#{obj.var}")
    end

    it 'should work with class method' do
      expect(Setting.cache_key('abc', nil)).to eql('rails_settings_cached/t123456/abc')
    end

    it 'should work with class method and scoped object' do
      obj = User.first
      expect(Setting.cache_key('abc', obj)).to eql('rails_settings_cached/t123456/User-1/abc')
    end
  end

  describe '.cache_prefix_by_startup' do
    it 'should work' do
      digest = Digest::MD5.hexdigest(RailsSettings::Default.instance.to_s)
      expect(described_class.cache_prefix_by_startup).to eq(digest)
    end
  end

  describe '.cache_prefix' do
    before do
      allow(described_class).to receive(:cache_prefix_by_startup).and_return('t123456')
    end

    it 'sets cache key prefix' do
      described_class.cache_prefix { 'stuff' }
      expect(described_class.cache_key('abc', nil)).to eql('rails_settings_cached/t123456/stuff/abc')
    end
  end

  describe 'Unscoped' do
    it 'should set a key and fetch with one query' do
      expect(Setting.test_cache).to eq(nil)
      Setting.test_cache = 123

      # A write invalidates the key rather than publishing to it, so the first read afterwards
      # costs one query and every read after that is free.
      first = count_setting_queries { expect(Setting.test_cache).to eq(123) }
      rest  = count_setting_queries { 2.times { expect(Setting.test_cache).to eq(123) } }
      expect([first, rest]).to eq([1, 0])

      Setting.test_cache = 321
      expect(Setting.test_cache).to eq(321)
    end
  end

  it 'caches unscoped settings' do
    expect(described_class['gender']).to be nil
    described_class['gender'] = 'female'

    # One query to repopulate after the write invalidated the key, then nothing.
    first = count_setting_queries { expect(described_class['gender']).to eq('female') }
    rest  = count_setting_queries { 3.times { expect(described_class['gender']).to eq('female') } }
    expect([first, rest]).to eq([1, 0])
  end

  it 'caches unscoped settings' do
    expect(described_class['gender']).to eq('female')
    ActiveRecord::Base.transaction do
      described_class['gender'] = 'trans'
      expect(described_class['gender']).to eq('trans')
    end

    expect(described_class['gender']).to eq('trans')
  end

  it 'caches scoped settings' do
    user = User.create!(login: 'another_test', password: 'foobar')

    expect(user.settings['gender']).to be nil
    user.settings['gender'] = 'male'

    first = count_setting_queries { expect(user.settings['gender']).to eq('male') }
    rest  = count_setting_queries { expect(user.settings['gender']).to eq('male') }
    expect([first, rest]).to eq([1, 0])
  end

  it 'caches scoped settings after the transaction commits, not during it' do
    user = User.create!(login: 'another_test2', password: 'foobar')
    expect(user.settings['gender']).to be nil   # cold read caches nil; the write below must clear it

    ActiveRecord::Base.transaction do
      user.settings['gender'] = 'male'

      # A read inside an open transaction deliberately neither uses nor populates the cache: the
      # value can still be rolled back and these keys have no TTL. Before this fix []= wrote the
      # cache before commit -- the D2 bug -- which made this read a free cache hit and left the
      # rolled-back value cached fleet-wide. cache_transaction_spec.rb pins the safety property.
      reads = count_setting_queries { expect(user.settings['gender']).to eq('male') }
      expect(reads).to eq(1)
    end

    # After commit the key was invalidated, so the first read repopulates and the rest are free.
    first = count_setting_queries { expect(user.settings['gender']).to eq('male') }
    rest  = count_setting_queries { 3.times { expect(user.settings['gender']).to eq('male') } }
    expect([first, rest]).to eq([1, 0])
  end

  it 'caches values from db' do
    described_class['some_random_key'] = 'asd'
    Rails.cache.clear

    queries_count = count_queries do
      expect(described_class['some_random_key']).to eq('asd')
      expect(described_class['some_random_key']).to eq('asd')
      expect(described_class['another_random_key']).to be nil
      expect(described_class['another_random_key']).to be nil
    end
    expect(queries_count).to eq(2)
  end
end
