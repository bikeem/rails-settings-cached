require 'spec_helper'

describe 'RailsSettings::Extend scopes and get_all' do
  before(:all) do
    @with    = User.create!(login: "with-#{rand(10**9)}",    password: 'x')
    @without = User.create!(login: "without-#{rand(10**9)}", password: 'x')
    @leak    = User.create!(login: "leak-#{rand(10**9)}",    password: 'x')
  end

  before(:each) do
    @with.settings.color = 'red'
    @leak.settings.secret = 'classified'
  end

  it 'with_settings / without_settings' do
    expect(User.with_settings).to include(@with)
    expect(User.with_settings).not_to include(@without)
    expect(User.without_settings).to include(@without)
    expect(User.without_settings).not_to include(@with)
  end

  it 'with_settings_for / without_settings_for' do
    expect(User.with_settings_for('color')).to include(@with)
    expect(User.with_settings_for('other')).to be_empty
    expect(User.without_settings_for('color')).to include(@without)
    expect(User.without_settings_for('color')).not_to include(@with)
  end

  # Behavioural rather than to_sql-shaped: these still fail if `var` is interpolated, but they
  # survive a future move to real bind parameters and do not depend on one adapter's quoting.
  describe 'var is bound, not interpolated' do
    # Interpolated, this closes the literal and ORs in a second condition, so the join matches
    # rows it must not see. Bound, the whole string is one var name that nobody has.
    let(:injection) { "color' OR #{RailsSettings::Settings.quoted_table_name}.var = 'secret" }

    it 'with_settings_for cannot be widened to another var' do
      expect(User.with_settings_for(injection)).to be_empty
    end

    it 'without_settings_for cannot be widened to another var' do
      # Nobody has this var, so everyone -- @with included -- lacks it. Interpolated, @with would
      # match the smuggled `color` condition and be excluded.
      expect(User.without_settings_for(injection)).to include(@with, @without, @leak)
    end
  end

  describe '.get_all(starting_with)' do
    before do
      Setting['a_b.k'] = 1
      Setting['axb.k'] = 2
      Setting['y.k']   = 3
    end

    it 'treats the prefix literally (underscore is not a wildcard)' do
      expect(Setting.get_all('a_b').keys).to eq ['a_b.k']
    end

    it 'cannot be widened by quote injection' do
      # Interpolated this becomes `var LIKE 'x' OR var LIKE 'y%'` and leaks the y.k row.
      expect(Setting.get_all("x' OR var LIKE 'y").keys).not_to include('y.k')
    end

    it 'accepts a symbol prefix' do
      expect(Setting.get_all(:a_b).keys).to eq ['a_b.k']
    end
  end
end
