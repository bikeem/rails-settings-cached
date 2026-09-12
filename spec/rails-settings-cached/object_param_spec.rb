require 'spec_helper'

describe 'RailsSettings::Settings object parameter handling' do
  before(:all) { @partner = Partner.create!(code: 'obj') }

  before(:each) do
    Setting.unscoped.delete_all
    Rails.cache.clear
  end

  describe 'D7: explicit object on the non-scoped class' do
    it 'creates the row bound to the object, not a global row' do
      Setting[:color, 'red'] = @partner
      row = Setting.unscoped.find_by(var: 'partner.color')
      expect(row.thing_type).to eq 'Partner'
      expect(row.thing_id).to eq @partner.id
      expect(Setting.color(@partner)).to eq 'red'
      Rails.cache.clear
      expect(Setting.color(@partner)).to eq 'red'
    end

    it 'still creates a global row when no object is given' do
      Setting.plain = 1
      row = Setting.unscoped.find_by(var: 'plain')
      expect(row.thing_type).to be_nil
      expect(row.thing_id).to be_nil
    end
  end

  describe 'D5: method_missing' do
    it 'accepts keyword arguments without raising' do
      expect { Setting.some_key(foo: 1) }.not_to raise_error
      expect(Setting.some_key(foo: 1)).to be_nil
    end

    it 'treats only ActiveRecord records as a scope object' do
      not_a_record = Struct.new(:id).new(@partner.id)
      expect(Setting.color(not_a_record)).to be_nil            # global lookup, not Struct-scoped
      expect(Setting.color(@partner)).to be_nil
      @partner.settings.color = 'red'
      expect(Setting.color(@partner)).to eq 'red'
      expect(Setting.color(not_a_record)).to be_nil
    end
  end

  describe 'KNOWN divergence: scoped_key does not compose scope and object' do
    # scoped_key prefixes with settings_scope when no object is passed, but with
    # base_class.to_s.downcase when one is -- the object branch overwrites rather than composes.
    # For MEX's Partner and User the two strings coincide ('partner', 'user'), which is why this is
    # invisible there; a model with no settings_scope (or a mismatched one) addresses two rows.
    # Pinned so that changing key derivation -- which would strand existing rows -- is deliberate.
    it 'addresses different rows for a model whose scope does not match its class name' do
      user = User.create!(login: 'divergence', password: 'x')
      user.settings.color = 'via-settings'
      Setting[:color, 'via-bracket'] = user

      vars = Setting.unscoped.where(thing_type: 'User', thing_id: user.id).pluck(:var)
      expect(vars).to match_array(%w[color user.color])
      expect(user.settings.color).to eq 'via-settings'
      expect(Setting.color(user)).to eq 'via-bracket'
    end
  end
end
