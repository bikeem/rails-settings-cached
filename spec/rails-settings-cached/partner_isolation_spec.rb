require 'spec_helper'

# Mirrors the consumer's shape: many partners, each with its own values for the same keys, read
# concurrently. Asserts both halves of the question -- the value each caller receives, and the
# cache entry each key ends up holding.
describe 'partner isolation of values and cache entries' do
  PARTNER_COUNT = 8
  KEYS = %w[login_as_url is_spa country user_phone_mandatory home_url].freeze

  before(:all) { @partners = (1..PARTNER_COUNT).map { |i| Partner.create!(code: "iso#{i}") } }

  # Seeded per example: the settings table is cleared before each one.
  before(:each) do
    @expected = {}
    @partners.each do |p|
      KEYS.each do |k|
        value = "#{p.code}-#{k}"
        p.settings.send("#{k}=", value)
        @expected[[p.id, k]] = value
      end
    end
  end

  it 'stores each partner under its own row' do
    @partners.each do |p|
      # #value, not pluck: pluck returns the raw YAML column and bypasses the decoder.
      rows = Setting.unscoped.where(thing_type: 'Partner', thing_id: p.id).map { |r| [r.var, r.value] }
      expect(rows.map(&:first)).to match_array(KEYS.map { |k| "partner.#{k}" })
      rows.each { |var, value| expect(value).to eq @expected[[p.id, var.delete_prefix('partner.')]] }
    end
  end

  it 'gives every partner a distinct cache key naming that partner' do
    keys = @partners.flat_map { |p| KEYS.map { |k| Setting.cache_key(Setting.scoped_key(k, p), p) } }
    expect(keys.uniq.size).to eq(PARTNER_COUNT * KEYS.size)
    @partners.each do |p|
      KEYS.each do |k|
        expect(Setting.cache_key(Setting.scoped_key(k, p), p)).to include("/Partner-#{p.id}/partner.#{k}")
      end
    end
  end

  # A broad smoke test over many partners, keys and read forms. It has ZERO unique mutation
  # coverage -- every mutant it catches is caught by another example -- and it does NOT prove
  # thread safety: the chained form binds and reads two operations apart, so the race window is
  # too small to hit reliably, and it passes even on the old class-ivar implementation. Kept as a
  # cheap end-to-end sanity check (1,920 reads in ~0.04s), not as a guard.
  it 'returns the right partner value across all read forms under load' do
    Rails.cache.clear
    errors = Queue.new

    threads = 16.times.map do |n|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          120.times do
            p = @partners[(n + rand(PARTNER_COUNT)) % PARTNER_COUNT]
            k = KEYS.sample
            want = @expected[[p.id, k]]

            got = case rand(3)
                  when 0 then p.settings.send(k)            # chained read, no object passed
                  when 1 then p.settings.send(k, p)         # object passed explicitly
                  else        Setting.send(k, p)            # class-level read
                  end

            errors << "partner #{p.id} key #{k}: got #{got.inspect} want #{want.inspect}" if got != want
          end
        end
      rescue => e
        errors << "#{e.class}: #{e.message}"
      end
    end
    threads.each { |t| expect(t.join(30)).to be(t), 'thread did not finish' }

    expect(errors.size).to eq(0), -> { "#{errors.size} leaks, first: #{errors.pop}" }
  end

  it 'leaves every cache entry holding its own partner value' do
    @partners.each { |p| KEYS.each { |k| p.settings.send(k) } }   # warm every key

    @partners.each do |p|
      KEYS.each do |k|
        ckey = Setting.cache_key(Setting.scoped_key(k, p), p)
        expect(Rails.cache.read(ckey)).to eq(@expected[[p.id, k]]),
          "cache entry #{ckey} held the wrong partner's value"
      end
    end
  end

  # A handle is bound to its record, so intervening work on another record cannot rebind it.
  it 'keeps its record when another record.settings call intervenes' do
    a, b = @partners[0], @partners[1]
    handle = a.settings
    expect(handle.send('login_as_url')).to eq @expected[[a.id, 'login_as_url']]

    b.settings.login_as_url                                   # would have rebound the handle

    expect(handle.send('login_as_url')).to eq @expected[[a.id, 'login_as_url']]
    expect(handle.send('login_as_url', a)).to eq @expected[[a.id, 'login_as_url']]
  end

  it 'keeps its record when handles are interleaved many times' do
    handles = @partners.map { |p| [p, p.settings] }
    20.times do
      handles.shuffle.each do |p, h|
        KEYS.each { |k| expect(h.send(k)).to eq @expected[[p.id, k]] }
      end
    end
  end

  # Deliberately asserted through get_all: a plain read of a scoped key is separated by the var
  # prefix ('partner.x' vs 'x') even with the thing_type filter removed, so it would pass whether
  # or not that guard exists. get_all returns every row the filter admits, so it cannot.
  it 'keeps a user and a partner with the same id apart' do
    shared_id = [Partner.maximum(:id).to_i, User.maximum(:id).to_i].max + 1
    p = Partner.new(code: 'collide'); p.id = shared_id; p.save!
    p.settings.login_as_url = 'PARTNER-VALUE'
    u = User.new(login: 'collide', password: 'x'); u.id = shared_id; u.save!
    u.settings.login_as_url = 'USER-VALUE'

    # get_all also merges the YAML defaults, so assert on what must NOT cross: with the
    # thing_type filter removed both records share thing_id and each would see the other's var.
    expect(p.settings.get_all.keys).to include('partner.login_as_url')
    expect(p.settings.get_all.keys).not_to include('login_as_url')
    expect(u.settings.get_all.keys).to include('login_as_url')
    expect(u.settings.get_all.keys).not_to include('partner.login_as_url')
    expect(p.settings.login_as_url).to eq 'PARTNER-VALUE'
    expect(u.settings.login_as_url).to eq 'USER-VALUE'
  end

  describe 'the handle belongs to exactly one record' do
    # `dup` copies instance variables, so a memo trusted with a bare ||= would hand the copy a
    # handle still bound to the ORIGINAL -- sending the copy's writes to the original's rows.
    it 'does not let a dup write to the record it was copied from' do
      src = Partner.create!(code: "dup-src-#{rand(10**9)}")
      src.settings.home_url = 'https://original.example'

      copy = src.dup
      copy.code = "dup-copy-#{rand(10**9)}"
      copy.save!
      copy.settings.home_url = 'https://copy.example'

      expect(copy.settings.__scope_object__).to equal(copy)
      expect(Partner.find(src.id).settings.home_url).to eq 'https://original.example'
      expect(Partner.find(copy.id).settings.home_url).to eq 'https://copy.example'
    end

    it 'refuses an unsaved dup rather than aliasing the original' do
      src = Partner.create!(code: "dup-unsaved-#{rand(10**9)}")
      src.settings.home_url = 'https://original.example'

      expect { src.dup.settings.home_url }
        .to raise_error(RailsSettings::ScopedSettings::MissingScope, /must be saved/)
      expect { src.dup.settings.home_url = 'x' }
        .to raise_error(RailsSettings::ScopedSettings::MissingScope)
      expect(src.settings.home_url).to eq 'https://original.example'
    end

    it 'gives deep_dup and clone the right record too' do
      src = Partner.create!(code: "clone-#{rand(10**9)}")
      src.settings.home_url = 'https://original.example'

      twin = src.clone
      expect(twin.settings.__scope_object__).to equal(twin)
      deep = src.deep_dup
      deep.code = "deep-#{rand(10**9)}"
      deep.save!
      expect(deep.settings.__scope_object__).to equal(deep)
    end

    it 'follows a settings_scope that changes on the record' do
      rec = Account.create!(code: 'scopeA')
      def rec.settings_scope = code
      rec.settings.thing = 'v1'
      rec.update!(code: 'scopeB')
      rec.settings.thing = 'v2'

      vars = Setting.unscoped.where(thing_type: 'Account', thing_id: rec.id).pluck(:var)
      expect(vars).to match_array(%w[scopeA.thing scopeB.thing])
    end

    it 'still returns the same handle for the same record instance' do
      p = @partners.first
      expect(p.settings).to equal(p.settings)
    end
  end

  describe 'the handle answers for the API it forwards' do
    it 'responds to real settings methods but not to plain keys' do
      h = @partners.first.settings
      expect(h.respond_to?(:get_all)).to be true
      expect(h.try(:get_all)).to be_a(Hash)
      expect(h.respond_to?(:login_as_url)).to be false
      expect(count_setting_queries { h.try(:no_such_key_at_all) }).to eq 0
    end

    it 'inspects without dumping the whole record' do
      p = @partners.first
      expected = "#<RailsSettings::Scope Partner##{p.id} scope=\"partner\">"
      # as_json and to_s too: Object#as_json falls through to instance_values, which would put the
      # bound record into logs, Sentry breadcrumbs and any accidental render of a handle.
      expect([p.settings.inspect, p.settings.to_s, p.settings.as_json]).to all(eq expected)
      expect(p.settings.to_json).not_to include('code')
    end

    # Not a guard test -- the settings class answers false to :empty? anyway. It pins that a
    # handle reads as present and costs nothing, so a future delegation change must be deliberate.
    it 'answers blank?/present? without querying the settings table' do
      h = @partners.first.settings
      queries = count_setting_queries do
        expect(h.blank?).to be false
        expect(h.present?).to be true
      end
      expect(queries).to eq 0
    end
  end
end
